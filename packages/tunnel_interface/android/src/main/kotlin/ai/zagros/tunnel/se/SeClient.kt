package ai.zagros.tunnel.se

import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509TrustManager

/**
 * SoftEther native (SSL-VPN) client — protocol + L2/L3 shim.
 *
 * Pure Kotlin (no Android imports) so the whole data path is unit-testable on
 * the JVM against a real SoftEther server. The Android engine
 * (ai.zagros.tunnel.ZagrosSeEngine) supplies the TUN sink and protected socket.
 *
 * Wire protocol (verified against SoftEtherVPN @10a2806f):
 *  - TLS; POST /vpnsvc/connect.cgi body "VPNCONNECT" -> Hello pack (server random);
 *  - POST /vpnsvc/vpn.cgi with login pack (method=login; authtype 1 secure / 2 plain);
 *  - the same TLS socket degrades to a raw block stream:
 *      group = BE32(n) then n x [BE32(size) + data]; keepalive = BE32(0xFFFFFFFF)+BE32(size)+rand;
 *  - data blocks are full Ethernet frames (hub-switched);
 *  - use_encrypt MUST be 1 (server mirrors it into Recv(secure=...));
 *  - VALUE_STR length is exact (no NUL); element names are len+1; all ints BE.
 *
 * Security posture: TLS with optional SHA-256 certificate pin (panel-rendered);
 * plain-password auth only travels inside TLS; no credential caching beyond the
 * session; P3 kill-switch semantics preserved by the engine (TUN default route +
 * self-package exclusion, see ZagrosSeEngine).
 */
class SeConfig(
    val server: String,
    val port: Int,
    val hub: String,
    val username: String,
    val password: String,
    val tlsSha256Pin: String? = null,
    val mtu: Int = 1500,
    val connectTimeoutMs: Int = 15_000,
    val dhcpTimeoutMs: Int = 20_000,
    /** stable MAC for the virtual NIC; default random locally-administered */
    val mac: ByteArray = randomLocalMac(),
    /** Android: protect the TLS socket against the TUN default route (routing loop). */
    val protect: ((java.net.Socket) -> Boolean)? = null,
) {
    companion object {
        fun randomLocalMac(): ByteArray {
            val r = ByteArray(5)
            SecureRandom().nextBytes(r)
            return byteArrayOf(0x5e.toByte(), r[0], r[1], r[2], r[3], r[4])
        }
    }
}

interface SeTunnelSink { /** SeClient -> TUN (IPv4 packet, no Ethernet header) */
    fun writeL3(packet: ByteArray)
}

interface SeListener {
    fun onLog(message: String)
    fun onTunnelUp()
    fun onEstablished(ip: String, prefixLen: Int, gateway: String, dns: List<String>)
    fun onError(message: String)
    fun onClose()
}

class SeClient(private val cfg: SeConfig, private val sink: SeTunnelSink, private val listener: SeListener) {

    private val running = AtomicBoolean(false)
    private val established = AtomicBoolean(false)
    private val outLock = Object()
    private var socket: SSLSocket? = null
    private var sin: DataInputStream? = null
    private var sout: DataOutputStream? = null
    private val arpCache = ConcurrentHashMap<String, ByteArray>()
    @Volatile private var myIp = 0
    @Volatile private var myMask = 0
    @Volatile private var myGateway = 0
    @Volatile private var dhcpXid = 0
    @Volatile private var dhcpServerMac: ByteArray? = null
    @Volatile private var lastServerSeen = 0L
    private val rxQueue = LinkedBlockingQueue<ByteArray>()
    private val dhcpOffer = LinkedBlockingQueue<DhcpResult>()
    private val uplink = AtomicLong(0)
    private val downlink = AtomicLong(0)
    private var serverRandom: ByteArray = ByteArray(0)

    fun uplinkBytes(): Long = uplink.get()
    fun downlinkBytes(): Long = downlink.get()
    fun isEstablished(): Boolean = established.get()

    fun start() {
        check(running.compareAndSet(false, true)) { "already running" }
        Thread({ runSession() }, "se-client").apply {
            isDaemon = false
            start()
        }
    }

    fun stop() {
        if (!running.compareAndSet(true, false)) return
        try { socket?.close() } catch (_: Throwable) {}
    }

    // ---------------- session ----------------

    private fun runSession() {
        var soft = false
        try {
            listener.onLog("se: connecting ${cfg.server}:${cfg.port}")
            val s = tlsConnect()
            socket = s
            sin = DataInputStream(s.inputStream.buffered(65536))
            sout = DataOutputStream(s.outputStream.buffered(65536))
            listener.onLog("se: tls ok (${s.session.protocol} ${s.session.cipherSuite})")

            val hello = parsePack(
                post(sin!!, sout!!, "/vpnsvc/connect.cgi", cfg.server, "VPNCONNECT".toByteArray(Charsets.US_ASCII)).body
            )
            serverRandom = hello.data("random") ?: throw SeProtoException("no server random")
            listener.onLog("se: hello ver=${hello.int("version")}.${hello.int("build")} random=${serverRandom.size}B")

            var err = login(1)
            var mode = "secure"
            if (err != 0) {
                // fresh connection for the plain attempt (server state machine is per-socket)
                try { s.close() } catch (_: Throwable) {}
                val s2 = tlsConnect()
                socket = s2
                sin = DataInputStream(s2.inputStream.buffered(65536))
                sout = DataOutputStream(s2.outputStream.buffered(65536))
                parsePack(post(sin!!, sout!!, "/vpnsvc/connect.cgi", cfg.server, "VPNCONNECT".toByteArray(Charsets.US_ASCII)).body)
                err = login(2)
                mode = "plain"
            }
            if (err != 0) throw SeProtoException("login_failed error=$err mode=$mode")
            listener.onLog("se: login ok (authtype=$mode)")
            listener.onTunnelUp()

            Thread({ readerLoop() }, "se-reader").apply { isDaemon = true; start() }
            Thread({ keepaliveLoop() }, "se-ka").apply { isDaemon = true; start() }

            dhcpHandshake()
            established.set(true)
            // Tunnel phase: server keep-alives arrive every ~10-15s; anything
            // silent for a full minute is dead — fail cleanly via read timeout.
            try { socket?.soTimeout = TUNNEL_SO_TIMEOUT_MS } catch (_: Throwable) {}
            listener.onEstablished(intToIp(myIp), maskToPrefix(myMask), intToIp(myGateway), dnsList.map { intToIp(it) })
            listener.onLog("se: established ip=${intToIp(myIp)}/${maskToPrefix(myMask)} gw=${intToIp(myGateway)}")
            // block until stopped; the reader thread owns RX
            while (running.get()) {
                Thread.sleep(500)
                val last = lastServerSeen
                if (last != 0L && System.currentTimeMillis() - last > DEAD_TIMEOUT_MS) {
                    throw SeProtoException("server_silent")
                }
            }
        } catch (t: Throwable) {
            if (running.get()) {
                listener.onError("se_client: ${t.javaClass.simpleName}: ${t.message}")
                soft = true
            }
        } finally {
            val wasRunning = running.getAndSet(false)
            established.set(false)
            try { socket?.close() } catch (_: Throwable) {}
            if (wasRunning || soft) listener.onClose()
        }
    }

    private fun tlsConnect(): SSLSocket {
        val ctx = SSLContext.getInstance("TLS")
        val pin = cfg.tlsSha256Pin?.replace(":", "")?.lowercase()
        val tm = object : X509TrustManager {
            override fun checkClientTrusted(c: Array<X509Certificate>, a: String) {}
            override fun checkServerTrusted(c: Array<X509Certificate>, a: String) {
                if (pin == null) return
                val digest = MessageDigest.getInstance("SHA-256").digest(c[0].encoded)
                    .joinToString("") { String.format("%02x", it) }
                if (digest != pin) throw SeProtoException("cert_pin_mismatch")
            }
            override fun getAcceptedIssuers(): Array<X509Certificate> = arrayOf()
        }
        ctx.init(null, arrayOf(tm), SecureRandom())
        val s = ctx.socketFactory.createSocket() as SSLSocket
        cfg.protect?.invoke(s)
        s.connect(InetSocketAddress(cfg.server, cfg.port), cfg.connectTimeoutMs)
        // Bound blocking reads: during login a stalled server must surface as a
        // SocketTimeoutException (clean failure), not an infinite spinner.
        s.soTimeout = HANDSHAKE_SO_TIMEOUT_MS
        // SoftEther 4.x (OpenSSL 1.0.2 era) misbehaves on JSSE TLS1.3 tunnels
        // (post-login protocol_version alerts) — pin the client to TLS1.2.
        s.enabledProtocols = arrayOf("TLSv1.2")
        s.startHandshake()
        return s
    }

    private fun login(authtype: Int): Int {
        val els = ArrayList<El>()
        els.add(eStr("method", "login"))
        els.add(eStr("hello", "ZagrosVPN"))
        els.add(eStr("client_str", "ZagrosVPN Android 1"))
        els.add(eInt("client_ver", 1)); els.add(eInt("client_build", 1))
        els.add(eInt("protocol", 0))
        els.add(eInt("authtype", authtype))
        els.add(eStr("username", cfg.username))
        els.add(eStr("hubname", cfg.hub))
        if (authtype == 1) {
            val hashed = sha1(cfg.password.toByteArray(Charsets.UTF_8) + cfg.username.uppercase().toByteArray(Charsets.US_ASCII))
            els.add(eData("secure_password", sha1(hashed + serverRandom)))
        } else {
            els.add(eStr("plain_password", cfg.password))
        }
        els.add(eInt("use_encrypt", 1)) // REQUIRED: server mirrors into Recv(secure=...)
        els.add(eInt("use_compress", 0))
        els.add(eInt("max_connection", 1))
        els.add(eInt("adjust_mss", 0))
        els.add(eStr("ClientProductName", "ZagrosVPN"))
        els.add(eStr("ClientOsName", "Android"))
        els.add(eStr("ClientOsVer", "Linux"))
        els.add(eStr("ClientHostname", "zagros"))
        val rep = parsePack(post(sin!!, sout!!, "/vpnsvc/vpn.cgi", cfg.server, buildPack(els)).body)
        return rep.int("error")
    }

    // ---------------- RX ----------------

    private fun readerLoop() {
        try {
            val din = DataInputStream(sin!!)
            lastServerSeen = System.currentTimeMillis()
            while (running.get()) {
                val n = din.readInt()
                if (n == KEEP_ALIVE_MAGIC) {
                    lastServerSeen = System.currentTimeMillis()
                    val ks = din.readInt()
                    var left = ks
                    while (left > 0) { val sk = din.skipBytes(left); if (sk <= 0) return; left -= sk }
                    continue
                }
                if (n < 0 || n > 4096) throw SeProtoException("bad group size $n")
                repeat(n) {
                    val sz = din.readInt()
                    if (sz < 0 || sz > MAX_FRAME) throw SeProtoException("bad frame size $sz")
                    if (sz > 0) {
                        val fr = ByteArray(sz); din.readFully(fr)
                        downlink.addAndGet(fr.size.toLong())
                        handleFrame(fr)
                    }
                }
            }
        } catch (t: Throwable) {
            if (running.get()) {
                listener.onError("se_reader: ${t.javaClass.simpleName}: ${t.message}")
                stop()
            }
        }
    }

    private fun handleFrame(fr: ByteArray) {
        if (fr.size < 14) return
        val dst = fr.copyOfRange(0, 6)
        val ethertype = ((fr[12].toInt() and 0xFF) shl 8) or (fr[13].toInt() and 0xFF)
        val isBroadcast = dst.all { it == 0xFF.toByte() }
        val isMine = dst.contentEquals(cfg.mac)
        if (!isBroadcast && !isMine) return
        when (ethertype) {
            ET_ARP -> handleArp(fr)
            ET_IPV4 -> {
                if (fr.size > 14) {
                    val p = fr[14]
                    val ihl = (p.toInt() and 0x0F) * 4
                    if ((fr[14 + 9].toInt() and 0xFF) == 17 && fr.size > 14 + ihl + 8) {
                        // UDP: route DHCP (67<->68) to the client state machine
                        val sport = ((fr[14 + ihl].toInt() and 0xFF) shl 8) or (fr[14 + ihl + 1].toInt() and 0xFF)
                        val dport = ((fr[14 + ihl + 2].toInt() and 0xFF) shl 8) or (fr[14 + ihl + 3].toInt() and 0xFF)
                        if (sport == 67 && dport == 68) {
                            // learn the DHCP server's L2 address for the ARP cache
                            dhcpServerMac = fr.copyOfRange(6, 12)
                            onDhcpPacket(fr.copyOfRange(14, fr.size))
                            return
                        }
                    }
                    sink.writeL3(fr.copyOfRange(14, fr.size))
                }
            }
        }
    }

    private fun downlinkStat() { /* bytes counted at stream level */ }

    private fun handleArp(fr: ByteArray) {
        if (fr.size < 14 + 28) return
        val op = ((fr[14 + 6].toInt() and 0xFF) shl 8) or (fr[14 + 7].toInt() and 0xFF)
        val spa = ipOf(fr, 14 + 14)
        val tpa = ipOf(fr, 14 + 24)
        if (op == 1 && tpa == myIp && myIp != 0) {
            val reply = ByteArray(42)
            for (i in 0..5) reply[i] = fr[6 + i] // requester mac
            System.arraycopy(cfg.mac, 0, reply, 6, 6)
            reply[12] = 0x08; reply[13] = 0x06
            reply[14] = 0; reply[15] = 1        // hw ethernet
            reply[16] = 8; reply[17] = 0        // proto ip
            reply[18] = 6; reply[19] = 4
            reply[20] = 0; reply[21] = 2        // reply
            System.arraycopy(cfg.mac, 0, reply, 22, 6)
            putIp(reply, 28, myIp)
            System.arraycopy(fr, 22, reply, 32, 6) // target mac = requester
            putIp(reply, 38, tpa)
            sendFrame(reply.copyOfRange(0, 42))
        }
        if (op == 2) arpCache[intToIp(spa)] = fr.copyOfRange(14 + 8, 14 + 14)
    }

    // ---------------- TX (called from TUN thread) ----------------

    fun onTunPacket(pkt: ByteArray) {
        if (!established.get() || pkt.size < 20) return
        if ((pkt[0].toInt() and 0xF0) != 0x40) return // IPv4 only
        uplink.addAndGet(pkt.size.toLong())
        val dstIp = ipOf(pkt, 16)
        val local = (dstIp and myMask) == (myIp and myMask)
        val targetIp = if (local) dstIp else myGateway
        val mac = arpCache[intToIp(targetIp)]
        if (mac == null) {
            sendArpRequest(targetIp)
            return // caller (TCP) retransmits
        }
        val fr = ByteArray(14 + pkt.size)
        System.arraycopy(mac, 0, fr, 0, 6)
        System.arraycopy(cfg.mac, 0, fr, 6, 6)
        fr[12] = 0x08; fr[13] = 0x00
        System.arraycopy(pkt, 0, fr, 14, pkt.size)
        sendFrame(fr)
    }

    private fun sendArpRequest(tpa: Int) {
        val p = ByteArray(42)
        for (i in 0..5) p[i] = 0xFF.toByte()
        System.arraycopy(cfg.mac, 0, p, 6, 6)
        p[12] = 0x08; p[13] = 0x06
        p[14] = 0; p[15] = 1; p[16] = 8; p[17] = 0; p[18] = 6; p[19] = 4
        p[20] = 0; p[21] = 1
        System.arraycopy(cfg.mac, 0, p, 22, 6)
        putIp(p, 28, myIp)
        for (i in 0..5) p[32 + i] = 0
        putIp(p, 38, tpa)
        sendFrame(p)
    }

    private fun sendFrame(frame: ByteArray) {
        synchronized(outLock) {
            val out = sout ?: return
            try {
                out.writeInt(1)
                out.writeInt(frame.size)
                out.write(frame)
                out.flush()
            } catch (t: Throwable) {
                listener.onError("se_tx: ${t.message}")
                stop()
            }
        }
    }

    private fun keepaliveLoop() {
        while (running.get()) {
            Thread.sleep(10_000)
            val out = sout ?: break
            try {
                synchronized(outLock) {
                    out.writeInt(KEEP_ALIVE_MAGIC.toInt())
                    out.writeInt(0)
                    out.flush()
                }
            } catch (_: Throwable) { break }
        }
    }

    // ---------------- DHCP ----------------

    private class DhcpResult(val yiaddr: Int, val mask: Int, val gateway: Int, val dns: List<Int>, val serverId: Int)

    private var dnsList: List<Int> = emptyList()

    private fun dhcpHandshake() {
        dhcpXid = SecureRandom().nextInt()
        val deadline = System.currentTimeMillis() + cfg.dhcpTimeoutMs
        var offered: DhcpResult? = null
        var requestedSent = 0L
        var lastDiscover = 0L
        while (System.currentTimeMillis() < deadline && running.get()) {
            val now = System.currentTimeMillis()
            if (offered == null && now - lastDiscover > 3000) {
                lastDiscover = now
                sendDhcp(msgType = 1, opts = { b -> option(b, 55, byteArrayOf(1, 3, 6, 15, 28)) })
                listener.onLog("se: DHCPDISCOVER sent")
            }
            if (offered != null && now - requestedSent > 3000) {
                requestedSent = now
                sendDhcp(msgType = 3, reqIp = offered!!.yiaddr, serverId = offered.serverId, opts = { _ -> })
                listener.onLog("se: DHCPREQUEST sent for ${intToIp(offered.yiaddr)}")
            }
            val r = dhcpOffer.poll(500, TimeUnit.MILLISECONDS) ?: continue
            // merge: ACK may omit options that the OFFER carried
            val merged = DhcpResult(
                yiaddr = if (r.yiaddr != 0) r.yiaddr else offered?.yiaddr ?: 0,
                mask = if (r.mask != 0) r.mask else offered?.mask ?: 0,
                gateway = if (r.gateway != 0) r.gateway else offered?.gateway ?: 0,
                dns = if (r.dns.isNotEmpty()) r.dns else offered?.dns ?: emptyList(),
                serverId = if (r.serverId != 0) r.serverId else offered?.serverId ?: 0,
            )
            if (offered == null && merged.gateway != 0) {
                offered = merged
                dhcpServerMac?.let { arpCache[intToIp(merged.serverId)] = it }
                continue
            }
            if (offered != null && merged.yiaddr == offered.yiaddr) {
                myIp = merged.yiaddr; myMask = merged.mask; myGateway = merged.gateway; dnsList = merged.dns
                if (myMask == 0) myMask = 0xFFFFFF00.toInt()
                val mac = arpCache[intToIp(merged.serverId)] ?: arpCache[intToIp(merged.gateway)]
                if (merged.gateway != 0 && mac != null) arpCache[intToIp(merged.gateway)] = mac
                return
            }
        }
        throw SeProtoException("dhcp_timeout")
    }

    private fun sendDhcp(msgType: Int, reqIp: Int = 0, serverId: Int = 0, opts: (ByteArrayOutputStream) -> Unit) {
        val b = ByteArrayOutputStream()
        b.write(1); b.write(1); b.write(6); b.write(0)
        for (sh in intArrayOf(24, 16, 8, 0)) b.write((dhcpXid ushr sh) and 0xFF)
        b.write(0); b.write(0)      // secs (2B)
        b.write(0); b.write(0)      // flags (2B) — MUST be 4 bytes total
        repeat(16) { b.write(0) }
        b.write(cfg.mac); repeat(10) { b.write(0) }
        repeat(64) { b.write(0) }
        repeat(128) { b.write(0) }
        for (v in intArrayOf(99, 130, 83, 99)) b.write(v)
        option(b, 53, byteArrayOf(msgType.toByte()))
        if (reqIp != 0) option(b, 50, intToBytes(reqIp))
        if (serverId != 0) option(b, 54, intToBytes(serverId))
        opts(b)
        b.write(255)
        val dhcp = b.toByteArray()
        val udp = ByteArray(8 + dhcp.size)
        udp[1] = 68; udp[3] = 67
        udp[5] = (udp.size ushr 8).toByte(); udp[7] = dhcp.size.toByte()
        System.arraycopy(dhcp, 0, udp, 8, dhcp.size)
        val ip = ByteArray(20 + udp.size)
        ip[0] = 0x45; ip[2] = (ip.size ushr 8).toByte(); ip[3] = ip.size.toByte()
        ip[8] = 64; ip[9] = 17
        for (i in 0..3) ip[16 + i] = 0xFF.toByte()
        var hs = 0L; var i = 0
        while (i < 20) { hs += ((ip[i].toInt() and 0xFF) shl 8) or (ip[i + 1].toInt() and 0xFF); i += 2 }
        while (hs > 0xFFFF) hs = (hs and 0xFFFF) + (hs ushr 16)
        val hc = ((hs.inv()) and 0xFFFF).toInt()
        ip[10] = (hc ushr 8).toByte(); ip[11] = hc.toByte()
        System.arraycopy(udp, 0, ip, 20, udp.size)
        val fr = ByteArray(14 + ip.size)
        for (j in 0..5) fr[j] = 0xFF.toByte()
        System.arraycopy(cfg.mac, 0, fr, 6, 6)
        fr[12] = 8; fr[13] = 0
        System.arraycopy(ip, 0, fr, 14, ip.size)
        sendFrame(fr)
    }

    private fun onDhcpPacket(payload: ByteArray) {
        // payload = IP packet containing UDP 67->68
        if (payload.size < 20) return
        val ihl = (payload[0].toInt() and 0x0F) * 4
        if (payload.size < ihl + 8 + 240) return
        val sport = ((payload[ihl].toInt() and 0xFF) shl 8) or (payload[ihl + 1].toInt() and 0xFF)
        if (sport != 67) return
        val off = ihl + 8
        val op = payload[off].toInt() and 0xFF
        val xid = ((payload[off + 4].toInt() and 0xFF) shl 24) or ((payload[off + 5].toInt() and 0xFF) shl 16) or
            ((payload[off + 6].toInt() and 0xFF) shl 8) or (payload[off + 7].toInt() and 0xFF)
        if (op != 2 || xid != dhcpXid) return
        val yiaddr = ipOf(payload, off + 16)
        val siaddr = ipOf(payload, off + 20)
        var o = off + 240
        var msgType = 0; var mask = 0; var gw = 0; var serverId = siaddr
        val dns = ArrayList<Int>()
        while (o < payload.size) {
            val code = payload[o].toInt() and 0xFF
            if (code == 0) { o++; continue }
            if (code == 255) break
            if (o + 1 >= payload.size) break
            val len = payload[o + 1].toInt() and 0xFF
            if (o + 2 + len > payload.size) break
            val v = payload.copyOfRange(o + 2, o + 2 + len)
            when (code) {
                53 -> msgType = v[0].toInt() and 0xFF
                1 -> if (len >= 4) mask = ipOf(v, 0)
                3 -> if (len >= 4) gw = ipOf(v, 0)
                6 -> { var i = 0; while (i + 4 <= len) { dns.add(ipOf(v, i)); i += 4 } }
                54 -> if (len >= 4) serverId = ipOf(v, 0)
            }
            o += 2 + len
        }
        if (msgType == 2 || msgType == 5) {
            dhcpOffer.add(DhcpResult(yiaddr, mask, gw, dns, serverId))
        }
    }

    // ---------------- pack codec ----------------

    private class SeProtoException(msg: String) : IllegalStateException(msg)

    // ---------------- helpers ----------------

    private fun ipOf(b: ByteArray, off: Int): Int =
        ((b[off].toInt() and 0xFF) shl 24) or ((b[off + 1].toInt() and 0xFF) shl 16) or
        ((b[off + 2].toInt() and 0xFF) shl 8) or (b[off + 3].toInt() and 0xFF)

    private fun putIp(b: ByteArray, off: Int, v: Int) {
        b[off] = (v ushr 24).toByte(); b[off + 1] = (v ushr 16).toByte()
        b[off + 2] = (v ushr 8).toByte(); b[off + 3] = v.toByte()
    }

    companion object {
        internal const val KEEP_ALIVE_MAGIC = -1 // 0xFFFFFFFF
        internal const val MAX_FRAME = 64 * 1024
        internal const val ET_ARP = 0x0806
        internal const val ET_IPV4 = 0x0800
        private const val DEAD_TIMEOUT_MS = 60_000L
        internal const val HANDSHAKE_SO_TIMEOUT_MS = 20_000
        internal const val TUNNEL_SO_TIMEOUT_MS = 60_000

        internal fun sha1(v: ByteArray): ByteArray = MessageDigest.getInstance("SHA-1").digest(v)

        internal fun intToIp(v: Int): String = "${(v ushr 24) and 0xFF}.${(v ushr 16) and 0xFF}.${(v ushr 8) and 0xFF}.${v and 0xFF}"

        internal fun ipToInt(s: String): Int {
            val p = s.split(".")
            return ((p[0].toInt() and 0xFF) shl 24) or ((p[1].toInt() and 0xFF) shl 16) or
                ((p[2].toInt() and 0xFF) shl 8) or (p[3].toInt() and 0xFF)
        }

        internal fun maskToPrefix(mask: Int): Int = Integer.bitCount(mask)

        internal fun intToBytes(v: Int): ByteArray =
            byteArrayOf((v ushr 24).toByte(), (v ushr 16).toByte(), (v ushr 8).toByte(), v.toByte())

        internal fun option(b: ByteArrayOutputStream, code: Int, data: ByteArray) {
            b.write(code); b.write(data.size); b.write(data)
        }
    }
}

// ---------------- pack wire format ----------------

internal const val T_INT = 0
internal const val T_DATA = 1
internal const val T_STR = 2

internal class El(val name: String, val type: Int, val raw: List<ByteArray>)

internal fun eStr(name: String, v: String) = El(name, T_STR, listOf(v.toByteArray(Charsets.UTF_8)))
internal fun eInt(name: String, v: Int) = El(name, T_INT, listOf(SeClient.intToBytes(v)))
internal fun eData(name: String, v: ByteArray) = El(name, T_DATA, listOf(v))

internal fun buildPack(els: List<El>): ByteArray {
    val out = ByteArrayOutputStream()
    fun i32(v: Int) { out.write(v ushr 24); out.write(v ushr 16); out.write(v ushr 8); out.write(v) }
    fun str(s: String) { val b = s.toByteArray(Charsets.UTF_8); i32(b.size + 1); out.write(b) } // element name: len+1
    i32(els.size)
    for (e in els) {
        str(e.name); i32(e.type); i32(e.raw.size)
        for (r in e.raw) when (e.type) {
            T_DATA -> { i32(r.size); out.write(r) }
            T_STR -> { i32(r.size); out.write(r) }  // VALUE_STR: exact length (WriteValue)
            else -> out.write(r)
        }
    }
    return out.toByteArray()
}

internal class Pack(val fields: MutableMap<String, Pair<Int, ByteArray>> = mutableMapOf()) {
    fun int(name: String): Int = fields[name]?.let { (t, b) ->
        if (t == T_INT && b.size >= 4) ((b[0].toInt() and 0xFF) shl 24) or ((b[1].toInt() and 0xFF) shl 16) or
            ((b[2].toInt() and 0xFF) shl 8) or (b[3].toInt() and 0xFF) else 0 } ?: 0
    fun data(name: String): ByteArray? = fields[name]?.let { (t, b) -> if (t == T_DATA) b else null }
    fun str(name: String): String? = fields[name]?.let { (t, b) -> if (t == T_STR) String(b, Charsets.UTF_8) else null }
}

internal fun parsePack(b: ByteArray): Pack {
    val p = Pack()
    var o = 0
    fun i32(): Int { val v = ((b[o].toInt() and 0xFF) shl 24) or ((b[o + 1].toInt() and 0xFF) shl 16) or
        ((b[o + 2].toInt() and 0xFF) shl 8) or (b[o + 3].toInt() and 0xFF); o += 4; return v }
    fun name(): String { val n = i32() - 1; val s = String(b, o, n, Charsets.UTF_8); o += n; return s }
    val num = i32()
    repeat(num) {
        val key = name(); val type = i32(); val cnt = i32()
        val vals = ArrayList<ByteArray>(cnt)
        repeat(cnt) {
            when (type) {
                T_DATA -> { val n = i32(); vals.add(b.copyOfRange(o, o + n)); o += n }
                T_STR -> { val n = i32(); vals.add(b.copyOfRange(o, o + n)); o += n }
                else -> { vals.add(b.copyOfRange(o, o + 4)); o += 4 }
            }
        }
        if (!p.fields.containsKey(key) && vals.isNotEmpty()) p.fields[key] = Pair(type, vals[0])
    }
    return p
}

internal class HttpResp(val headers: Map<String, String>, val body: ByteArray)

internal fun trustAllContext(): SSLContext {
    val tm = object : X509TrustManager {
        override fun checkClientTrusted(c: Array<X509Certificate>, a: String) {}
        override fun checkServerTrusted(c: Array<X509Certificate>, a: String) {}
        override fun getAcceptedIssuers(): Array<X509Certificate> = arrayOf()
    }
    return SSLContext.getInstance("TLS").apply { init(null, arrayOf(tm), SecureRandom()) }
}

internal fun post(sin: DataInputStream, sout: DataOutputStream, path: String, host: String, body: ByteArray): HttpResp {
    val head = StringBuilder()
    head.append("POST ").append(path).append(" HTTP/1.1\r\n")
    head.append("Host: ").append(host).append("\r\n")
    head.append("Content-Type: application/octet-stream\r\n")
    head.append("Content-Length: ").append(body.size).append("\r\n")
    head.append("Connection: Keep-Alive\r\n")
    head.append("Keep-Alive: timeout=15; max=19\r\n\r\n")
    sout.write(head.toString().toByteArray(Charsets.US_ASCII))
    sout.write(body); sout.flush()
    val hdr = ByteArrayOutputStream()
    val win = IntArray(4)
    while (true) {
        val c = sin.read()
        if (c < 0) throw IllegalStateException("EOF in headers")
        hdr.write(c)
        win[0] = win[1]; win[1] = win[2]; win[2] = win[3]; win[3] = c
        if (win[0] == 13 && win[1] == 10 && win[2] == 13 && win[3] == 10) break
    }
    val text = hdr.toString("ISO-8859-1")
    val lines = text.split("\r\n")
    val map = HashMap<String, String>()
    for (l in lines.drop(1)) { val i = l.indexOf(':'); if (i > 0) map[l.substring(0, i).trim().lowercase()] = l.substring(i + 1).trim() }
    if (!lines[0].contains(" 200")) throw IllegalStateException("HTTP not 200: ${lines[0]}")
    val cl = map["content-length"]?.toIntOrNull() ?: throw IllegalStateException("no content-length")
    val body2 = ByteArray(cl)
    sin.readFully(body2)
    return HttpResp(map, body2)
}
