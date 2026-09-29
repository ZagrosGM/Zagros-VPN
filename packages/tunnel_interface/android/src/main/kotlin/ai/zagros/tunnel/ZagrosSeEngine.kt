package ai.zagros.tunnel

import android.net.VpnService
import android.os.ParcelFileDescriptor
import android.util.Log
import ai.zagros.tunnel.se.SeClient
import ai.zagros.tunnel.se.SeConfig
import ai.zagros.tunnel.se.SeListener
import ai.zagros.tunnel.se.SeTunnelSink
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONObject

/**
 * Embedded SoftEther-native engine (our own protocol implementation, no
 * third-party GPL code). Layering:
 *
 *   TUN <-> [SeClient L2/L3 shim: ARP + DHCP + Ethernet framing]
 *              <-> TLS block stream (SoftEther SSL-VPN) -> hub
 *
 * Kill-switch semantics match the SSTP/L2TP engines: the TUN default route is
 * only present while the engine holds the interface; the app's own sockets are
 * excluded (addDisallowedApplication) and protected individually, so a manual
 * disconnect tears the interface down and connectivity drops (verified by the
 * standard 3-condition device test).
 */
class ZagrosSeEngine(private val service: ZagrosVpnService) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val isRunning = AtomicBoolean(false)
    private val stopRequested = AtomicBoolean(false)
    private val uplinkBytes = AtomicLong(0)
    private val downlinkBytes = AtomicLong(0)

    @Volatile private var established = false
    private var client: SeClient? = null
    private var tun: ParcelFileDescriptor? = null
    private var tunOut: FileOutputStream? = null
    private var tunThread: Thread? = null
    private var onClosedCallback: () -> Unit = {}
    /** Optional diagnostics sink (plugin forwards to the app Logs tab). */
    @Volatile var traceSink: ((String) -> Unit)? = null

    private fun trace(msg: String) {
        Log.i(TAG, msg.take(LOG_LINE_LIMIT))
        try {
            traceSink?.invoke(msg.take(LOG_LINE_LIMIT))
        } catch (_: Throwable) {
        }
    }

    fun isAlive(): Boolean = isRunning.get()
    fun isEstablished(): Boolean = isRunning.get() && established
    fun getUplink(): Long = uplinkBytes.get()
    fun getDownlink(): Long = downlinkBytes.get()

    /**
     * @param payload panel-rendered SoftEther-native config:
     *   {server, port, hub, username, password, options:{tls_sha256?}}
     * @return false when the payload is invalid (never fakes a connection).
     */
    fun start(
        payload: JSONObject,
        onEstablished: () -> Unit,
        onError: (String) -> Unit,
        onClosed: () -> Unit,
    ): Boolean {
        val server = payload.optString("server").trim()
        val port = payload.optInt("port", 443)
        val username = payload.optString("username")
        val password = payload.optString("password")
        val options = payload.optJSONObject("options") ?: JSONObject()
        val hub = sequenceOf(payload.optString("hub", ""), options.optString("hub", ""))
            .map { it.trim() }.firstOrNull { it.isNotEmpty() } ?: "DEFAULT"
        val pin = sequenceOf(payload.optString("tls_sha256", ""), options.optString("tls_sha256", ""))
            .map { it.trim() }.firstOrNull { it.isNotEmpty() }?.ifEmpty { null }

        if (server.isEmpty() || username.isEmpty() || password.isEmpty()) {
            Log.w(TAG, "SE config incomplete (server/user/pass required)")
            return false
        }
        if (pin != null && !Regex("^[0-9a-fA-F: ]{64,70}$").matches(pin)) {
            Log.w(TAG, "SE tls_sha256 pin format invalid")
            return false
        }
        if (port !in 1..65535) {
            Log.w(TAG, "SE port out of range")
            return false
        }

        stop()
        stopRequested.set(false)
        established = false
        onClosedCallback = onClosed

        val cfg = SeConfig(
            server = server, port = port, hub = hub,
            username = username, password = password,
            tlsSha256Pin = pin,
            mtu = DEFAULT_TUNNEL_MTU,
            protect = { s ->
                try {
                    service.protect(s)
                } catch (_: Throwable) {
                    false
                }
            },
        )
        val se = SeClient(cfg, object : SeTunnelSink {
            var firstWrite = true
            override fun writeL3(packet: ByteArray) {
                try {
                    if (firstWrite) {
                        firstWrite = false
                        trace("se-tun: first downstream packet ${packet.size}B")
                    }
                    tunOut?.write(packet)
                    tunOut?.flush()
                    downlinkBytes.addAndGet(packet.size.toLong())
                } catch (t: Throwable) {
                    Log.w(TAG, "TUN write failed: ${t.message}")
                }
            }
        }, object : SeListener {
            override fun onLog(message: String) {
                trace(message)
            }

            override fun onTunnelUp() {
                trace("se-engine: login ok (tunnel mode)")
            }

            override fun onEstablished(ip: String, prefixLen: Int, gateway: String, dns: List<String>) {
                // Mark established BEFORE the TUN is brought up: the TUN reader
                // thread spawned inside bringUpTun must never observe a stale
                // flag and exit before reading a single packet.
                established = true
                trace("se-engine: dhcp ip=$ip/$prefixLen gw=$gateway dns=${dns.joinToString(",")}")
                val t = bringUpTun(ip, prefixLen, gateway, dns)
                if (t == null) {
                    Log.w(TAG, "SE TUN establish failed")
                    established = false
                    stop()
                    onError("tun_establish_failed")
                    return
                }
                Log.i(TAG, "SE engine established (TUN up, ip=$ip/$prefixLen)")
                onEstablished()
            }

            override fun onError(message: String) {
                Log.w(TAG, "SE engine error: ${message.take(LOG_LINE_LIMIT)}")
                trace("se-engine error: ${message.take(LOG_LINE_LIMIT)}")
                onError(message)
            }

            override fun onClose() {
                val intentional = stopRequested.get()
                isRunning.set(false)
                established = false
                closeTun()
                Log.i(TAG, "SE engine closed (intentional=$intentional)")
                trace("se-engine: closed (intentional=$intentional)")
                if (!intentional) {
                    onError("engine_stopped")
                }
                onClosed()
            }
        })
        client = se
        isRunning.set(true)
        trace("se-engine: starting $server:$port hub=$hub")
        se.start()

        // Deterministic failure if the handshake+DHCP never completes.
        scope.launch {
            delay(CONNECT_TIMEOUT_MS)
            if (isRunning.get() && !established) {
                Log.w(TAG, "SE connect timeout")
                stop()
            }
        }
        return true
    }

    private fun bringUpTun(ip: String, prefixLen: Int, gateway: String, dns: List<String>): ParcelFileDescriptor? {
        return try {
            val b = service.Builder()
            b.setMtu(DEFAULT_TUNNEL_MTU)
            b.addAddress(ip, prefixLen)
            // default route: all traffic inside the tunnel (crash kill-switch =
            // interface teardown removes the route; same semantics as SSTP/L2TP)
            b.addRoute("0.0.0.0", 0)
            val servers = LinkedHashSet<String>()
            if (dns.isNotEmpty()) servers.addAll(dns) else servers.add(gateway)
            for (d in servers) b.addDnsServer(d)
            b.addDisallowedApplication(service.packageName)
            // Explicit blocking (matches kittoku); a blocking read returns only
            // when a packet arrives - never an EAGAIN-style silent exit.
            b.setBlocking(true)
            val t = b.establish()
            tun = t
            if (t != null) {
                trace("se-tun: interface up (fd=${t.fd})")
                tunOut = FileOutputStream(t.fileDescriptor)
                startTunReader(t)
            }
            t
        } catch (t: Throwable) {
            Log.e(TAG, "bringUpTun failed: ${t.message}", t)
            null
        }
    }

    private fun startTunReader(t: ParcelFileDescriptor) {
        val input = FileInputStream(t.fileDescriptor)
        val th = Thread {
            val buf = ByteArray(32768)
            var first = true
            var packets = 0L
            var bytes = 0L
            try {
                // Loop on isRunning only: established was set before this thread
                // started, and stop() closes the fd, making read() fail out.
                while (isRunning.get()) {
                    val n = input.read(buf)
                    if (n <= 0) {
                        trace("se-tun: read returned $n, reader exits")
                        break
                    }
                    packets++
                    bytes += n
                    if (first) {
                        first = false
                        trace("se-tun: first packet ${n}B dst=${pktDst(buf, n)} (TUN ingest OK)")
                    } else if (packets == 10L || packets == 100L || packets == 1000L || packets == 10000L) {
                        trace("se-tun: $packets pkts / $bytes B ingested")
                    }
                    client?.onTunPacket(buf.copyOf(n))
                }
            } catch (e: Throwable) {
                if (isRunning.get()) {
                    trace("se-tun: reader error after $packets pkts: ${e.javaClass.simpleName}: ${e.message}")
                }
            }
            trace("se-tun: reader exited (pkts=$packets bytes=$bytes)")
        }
        th.name = "se-tun"
        th.isDaemon = true
        th.start()
        trace("se-tun: reader thread started")
        tunThread = th
    }

    private fun pktDst(buf: ByteArray, n: Int): String {
        if (n < 20) return "?"
        val proto = buf[9].toInt() and 0xFF
        val p = when (proto) { 1 -> "ICMP"; 6 -> "TCP"; 17 -> "UDP"; else -> proto.toString() }
        return "${buf[16].toInt() and 0xFF}.${buf[17].toInt() and 0xFF}.${buf[18].toInt() and 0xFF}.${buf[19].toInt() and 0xFF}/$p"
    }

    private fun closeTun() {
        try {
            tun?.close()
        } catch (_: Throwable) {
        } finally {
            tun = null
        }
        try {
            tunOut?.close()
        } catch (_: Throwable) {
        } finally {
            tunOut = null
        }
        tunThread = null
    }

    fun stop() {
        if (!isRunning.get()) return
        stopRequested.set(true)
        client?.stop() // onClose() finalizes state + fires onClosed
        // force-finalize if the client thread hangs on socket close
        scope.launch {
            delay(FORCE_STOP_DELAY_MS)
            if (isRunning.get()) {
                isRunning.set(false)
                established = false
                closeTun()
                Log.w(TAG, "SE engine force-stopped")
                onClosedCallback()
            }
        }
    }

    /** Final teardown when the enclosing service is destroyed. */
    fun destroy() {
        stop()
        scope.cancel()
    }

    companion object {
        private const val TAG = "ZagrosSeEngine"
        private const val DEFAULT_TUNNEL_MTU = 1500
        private const val CONNECT_TIMEOUT_MS = 60_000L
        private const val FORCE_STOP_DELAY_MS = 3_000L
        private const val LOG_LINE_LIMIT = 400
    }
}
