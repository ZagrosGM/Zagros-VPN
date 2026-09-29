package ai.zagros.tunnel

import android.app.Notification
import android.net.LocalServerSocket
import android.net.LocalSocketAddress
import android.net.LocalSocket
import android.os.ParcelFileDescriptor
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.util.Log
import ai.zagros.tunnel.l2tp.L2tpTrace
import hev.htproxy.TProxyService
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android VpnService implementation managing the virtual TUN interface lifecycle
 * for both sing-box/hev-socks5-tunnel and native OpenVPN.
 */
class ZagrosVpnService : VpnService() {
    private var tunInterface: ParcelFileDescriptor? = null

    /** True between a successful startTunnel() and stopTunnel(); protect()
     *  only succeeds while a VPN interface exists. */
    @Volatile var isVpnUp: Boolean = false
    @Volatile var protectedFdCount: Long = 0
    @Volatile var failedProtectFdCount: Long = 0
    private val isServiceRunning = AtomicBoolean(false)
    private var activeHevConfigFile: File? = null
    private var sstpEngine: ZagrosSstpEngine? = null
    private var l2tpEngine: ZagrosL2tpEngine? = null
    private var seEngine: ZagrosSeEngine? = null

    companion object {
        private const val TAG = "ZagrosVpnService"

        @Volatile
        private var vpnRevokedAtMs: Long = 0L

        fun noteVpnRevoked() {
            vpnRevokedAtMs = System.currentTimeMillis()
        }

        /**
         * Returns a one-shot hint when the system revoked the VPN recently,
         * so an engine death right after onRevoke is reported accurately.
         */
        fun takeVpnRevokedHint(): String? {
            val at = vpnRevokedAtMs
            if (at == 0L) return null
            vpnRevokedAtMs = 0L
            return if (System.currentTimeMillis() - at <= 15_000L) {
                "vpn_revoked_by_system"
            } else {
                null
            }
        }
        private const val NOTIFICATION_CHANNEL_ID = "zagros_vpn_tunnel"
        private const val NOTIFICATION_ID = 20808

        @Volatile
        private var instance: ZagrosVpnService? = null

        fun getInstance(): ZagrosVpnService? = instance

        fun startService(context: Context) {
            try {
                val intent = Intent(context, ZagrosVpnService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Throwable) {
                Log.e(TAG, "Failed to start ZagrosVpnService intent: ${e.message}", e)
            }
        }

        fun stopService(context: Context) {
            try {
                instance?.stopTunnel()
                val intent = Intent(context, ZagrosVpnService::class.java)
                context.stopService(intent)
            } catch (e: Throwable) {
                Log.e(TAG, "Failed to stop ZagrosVpnService: ${e.message}", e)
            }
        }

        fun protectSocket(socketFd: Int): Boolean {
            return instance?.protect(socketFd) ?: false
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification("Zagros VPN is ready"))
        Log.i(TAG, "ZagrosVpnService created")
    }

    // ------------------------------------------------------------------
    // Out-of-process socket protector.
    //
    // The native core runs as an exec'd child; on several Android builds the
    // per-UID VPN bypass does NOT cover exec'd child processes, so their UDP
    // (hysteria2/QUIC) loops into our own tun and dies — "no recent network
    // activity" while the UI shows connected. sing-box supports the Android
    // protect-path protocol: for every outbound socket it connects to a unix
    // socket, sends the fd via SCM_RIGHTS, and we call VpnService.protect().
    // ------------------------------------------------------------------
    private var protectServer: LocalServerSocket? = null
    private var protectThread: Thread? = null

    /** Abstract-namespace socket name. The child dials it through the
     *  protect_path value "\u0000zagros.protect" (a leading NUL selects the
     *  abstract namespace per sockaddr_un semantics) — NO filesystem node is
     *  involved anywhere. */
    val protectAbstractName: String
        get() = "zagros.protect"

    /** The name the server ACTUALLY bound (base name, or a suffixed one if a
     *  lingering socket held the base name). */
    @Volatile var protectBoundName: String? = null

    /** The protect_path value injected into the child config. Go's
     *  SockaddrUnix treats a leading '@' as the abstract namespace and rewrites
     *  it to NUL at dial time (syscall_linux.go) — byte-identical to the
     *  Android abstract bind above. '@' also keeps the JSON config clean. */
    val protectPathValue: String
        get() = "@" + (protectBoundName ?: protectAbstractName)

    /** Result of the bind+connect self-test (null = not run). Surfaced in the
     *  Logs tab so a device test proves the protect channel end-to-end. */
    @Volatile var protectSelfTestOk: Boolean? = null

    /** Human-readable failure detail of the last self-test / server start —
     *  piped into the UI Logs tab because the device has no logcat access. */
    @Volatile var protectSelfTestDetail: String = "not run"

    /** Protect-channel command byte: 0 = PING (channel self-test; acked
     *  immediately, no fd handling), 1 = real protect request (the sing
     *  child sends exactly this). */
    private val PROTECT_CMD_PING = 0
    private val PROTECT_CMD_PROTECT = 1

    val protectPathFile: java.io.File
        get() = java.io.File(filesDir, "protect.sock")

    fun startProtectServer() {
        if (protectServer != null) return
        val path = protectPathFile
        try { path.delete() } catch (_: Throwable) {}
        try {
            // History: (1) LocalServerSocket(String) is ABSTRACT-namespace only
            // (official docs) while the child dialed a FILE path -> ENOENT.
            // (2) A filesystem bind via the JNI FileDescriptor(int) ctor is a
            // hidden API that silently failed on device -> ECONNREFUSED.
            // (3) LocalSocket.bind(FILESYSTEM) also failed on that device.
            // Current design: Java listens on the ABSTRACT namespace; the Go
            // child dials the same abstract namespace via '@'-prefixed
            // protect_path; the self-test dials it NATIVELY (POSIX, errno-
            // coded) because the java.net LocalSocket stack failed on one
            // device with "socket not created".
            // A lingering server (blocked accept() holds the name even after
            // close) can make the next bind fail with EADDRINUSE — retry with
            // suffixed names and inject whichever name actually bound.
            var server: LocalServerSocket? = null
            var boundName = protectAbstractName
            var lastBindErr = ""
            for (attempt in 0 until 5) {
                boundName = if (attempt == 0) protectAbstractName else "$protectAbstractName.$attempt"
                server = try {
                    LocalServerSocket(boundName)
                } catch (e: Throwable) {
                    lastBindErr = "${e.javaClass.simpleName}: ${e.message}"
                    null
                }
                if (server != null) break
            }
            if (server == null) {
                protectSelfTestOk = false
                protectSelfTestDetail = "bind failed on 5 names; last: $lastBindErr"
                Log.e(TAG, "protect: $protectSelfTestDetail")
                return
            }
            protectBoundName = boundName
            protectServer = server
            Log.i(TAG, "protect: abstract socket bound: $boundName")
            protectThread = Thread {
                while (!Thread.currentThread().isInterrupted) {
                    val client = try {
                        server.accept()
                    } catch (_: Throwable) {
                        break
                    }
                    handleProtectClient(client)
                }
            }.apply { name = "zagros-protect"; start() }
            // End-to-end self-test: dial the exact namespace the child will
            // use. Any failure here aborts the connect BEFORE the child runs,
            // so a broken protect channel can never produce "connected, no
            // data".
            protectSelfTestOk = try {
                // Native POSIX PING: connect(abstract) + send cmd 0 + expect
                // ack 1. Returns 0 or -errno. (The java.net LocalSocket probe
                // died with "socket not created" on one device.)
                val r = TProxyService.TProxyProtectProbe(boundName)
                if (r != 0) {
                    protectSelfTestDetail = "native probe r=$r (${describeProbeErrno(r)})"
                    Log.e(TAG, "protect self-test: $protectSelfTestDetail")
                }
                r == 0
            } catch (e: Throwable) {
                protectSelfTestDetail = "${e.javaClass.simpleName}: ${e.message}"
                Log.e(TAG, "protect self-test failed: $protectSelfTestDetail")
                false
            }
            if (protectSelfTestOk == true) protectSelfTestDetail = "ok"
            Log.i(TAG, "protect server started (abstract=${protectAbstractName}, selfTest=$protectSelfTestOk)")
        } catch (e: Throwable) {
            protectSelfTestOk = false
            protectSelfTestDetail = "server start ${e.javaClass.simpleName}: ${e.message}"
            Log.e(TAG, "protect server failed to start: ${e.message}")
        }
    }

    fun stopProtectServer() {
        try { protectThread?.interrupt() } catch (_: Throwable) {}
        protectThread = null
        try { protectServer?.close() } catch (_: Throwable) {}
        protectServer = null
        protectBoundName = null
        // Remove any stale filesystem socket left by older builds.
        try { protectPathFile.delete() } catch (_: Throwable) {}
    }

    // ------------------------------------------------------------------
    // In-process UDP relay for hysteria2 (QUIC) outbounds.
    //
    // Evidence (2026-09-24): the exec'd child's PROTECTED UDP socket never
    // emits packets on one device/OEM (TCP from the same child works; the
    // same server:port works from v2rayNG on the same phone and from an
    // external sing-box). The fix routes the child's QUIC through an
    // in-process relay (app process — the same class of UDP path that works
    // in v2rayNG): child -> 127.0.0.1:relayPort -> UNCONNECTED DatagramSocket
    // (explicit per-send address — the only UDP pattern proven to egress on
    // this device: connected UDP sockets blackhole, f48/f49/f50 evidence)
    // -> real server; replies are sent back to the child's source port.
    // Only hysteria2 outbounds are rewritten; every other protocol keeps
    // its (working) direct path.
    // ------------------------------------------------------------------
    private var hy2RelayListener: java.net.DatagramSocket? = null
    private var hy2RelayUpstream: java.net.DatagramSocket? = null
    private var hy2RelayThreads: MutableList<Thread> = java.util.Collections.synchronizedList(mutableListOf())
    @Volatile var hy2RelayRunning: Boolean = false
    @Volatile var hy2RelayUpstreamBytes: Long = 0
    @Volatile var hy2RelayDownstreamBytes: Long = 0
    @Volatile var hy2RelayDetail: String = "not started"
    @Volatile var hy2RelayLocalPort: Int = -1

    // ---- app-UID UDP round-trip probe (ground truth, no tcpdump needed) ----
    // Every 2s the app alternates an 8-byte and a 1250-byte datagram from
    // THIS app process, unprotected, to server:<targetPort+1> (kernel-level
    // echo responder) and awaits the echo. ok>0: small UDP round-trips;
    // bigOk>0: QUIC-size datagrams round-trip too (rules out size drops).
    private var hy2ProbeSocket: java.net.DatagramSocket? = null
    private var hy2ProbeThread: Thread? = null
    @Volatile var hy2ProbeRunning: Boolean = false
    @Volatile var hy2ProbeLastRttMs: Long = -1
    // UDP size ladder (f52): f51b kernel evidence — the relay flow is
    // blackholed at EVERY destination port while the 8B/1250B probe
    // round-trips from the same process/socket pattern. Prime suspect is a
    // QUIC-size UDP datagram filter (~1250-1280 cliff). The ladder pins the
    // exact edge; relaysizes logs the real child datagram sizes.
    val hy2ProbeLadder = intArrayOf(8, 1200, 1250, 1251, 1252, 1280, 1350)
    private val hy2ProbeOkArr = IntArray(hy2ProbeLadder.size)
    private val hy2ProbeFailArr = IntArray(hy2ProbeLadder.size)
    @Volatile var hy2ProbeSizeStats: String = "starting"
    @Volatile var hy2RelaySentSizes: String = ""
    @Volatile var hy2ProbeDetail: String = "not started"

    fun startHy2Relay(listenPort: Int, targetHost: String, targetPort: Int): Boolean {
        stopHy2Relay()
        try {
            // NO protect() here on purpose. Device evidence (2026-09-24):
            // protect()ed UDP sockets never egress on this OEM (child
            // protect-path sockets: 0 packets on wire; this relay protected:
            // up grew, down stayed 0), while UNprotected in-process UDP
            // (v2rayNG) and app-UID TCP (our API traffic during VPN) work.
            // Our UID is excluded from the tun via addDisallowedApplication,
            // so an unprotected relay socket leaves through the underlying
            // network directly — the same path that demonstrably works.
            // UNCONNECTED upstream (f51): connected DatagramSocket.send()
            // "succeeds" into the kernel but never egresses on this device
            // (server iptables+pcap: zero packets, f48/f49/f50), while
            // unconnected send(packet, addr) demonstrably egresses (probe
            // 8/8 received). quic-go (v2rayNG) also sends unconnected —
            // mirror the working pattern exactly.
            val upstream = java.net.DatagramSocket()
            val serverAddr = java.net.InetSocketAddress(
                java.net.InetAddress.getByName(targetHost), targetPort)
            val listener = java.net.DatagramSocket(null).apply {
                reuseAddress = true
                bind(java.net.InetSocketAddress("127.0.0.1", listenPort))
            }
            hy2RelayListener = listener
            hy2RelayUpstream = upstream
            hy2RelayRunning = true
            hy2RelayUpstreamBytes = 0
            hy2RelayDownstreamBytes = 0
            hy2RelaySentSizes = ""
            hy2RelayLocalPort = upstream.localPort
            hy2RelayDetail = "ok unconnected (127.0.0.1:$listenPort -> $targetHost:$targetPort)"
            // Child -> upstream. The child's QUIC source port is learned on
            // the first datagram; QUIC uses one connection, so a single
            // "last sender" is sufficient and replies go exactly there.
            val childAddr = arrayOfNulls<java.net.SocketAddress>(1)
            hy2RelayThreads.add(Thread {
                val buf = ByteArray(65535)
                val pkt = java.net.DatagramPacket(buf, buf.size)
                while (hy2RelayRunning && !Thread.currentThread().isInterrupted) {
                    try {
                        listener.receive(pkt)
                        childAddr[0] = pkt.socketAddress
                        val data = buf.copyOf(pkt.length)
                        upstream.send(java.net.DatagramPacket(data, data.size, serverAddr))
                        hy2RelayUpstreamBytes += pkt.length
                        val s = hy2RelaySentSizes
                        if (s.length < 48) hy2RelaySentSizes =
                            (if (s.isEmpty()) "" else "$s,") + data.size
                    } catch (_: Throwable) {
                        if (!hy2RelayRunning) break
                    }
                }
            }.apply { name = "hy2-relay-c2u"; start() })
            // Upstream -> child.
            hy2RelayThreads.add(Thread {
                val buf = ByteArray(65535)
                val pkt = java.net.DatagramPacket(buf, buf.size)
                while (hy2RelayRunning && !Thread.currentThread().isInterrupted) {
                    try {
                        upstream.receive(pkt)
                        if (pkt.socketAddress == serverAddr) {
                            val target = childAddr[0]
                            if (target != null) {
                                val data = buf.copyOf(pkt.length)
                                listener.send(java.net.DatagramPacket(data, data.size, target))
                                hy2RelayDownstreamBytes += pkt.length
                            }
                        }
                    } catch (_: Throwable) {
                        if (!hy2RelayRunning) break
                    }
                }
            }.apply { name = "hy2-relay-u2c"; start() })
            Log.i(TAG, "hy2 relay: $hy2RelayDetail (upstream local port=$hy2RelayLocalPort)")
            startHy2Probe(targetHost, targetPort + 1)
            return true
        } catch (e: Throwable) {
            hy2RelayDetail = "${e.javaClass.simpleName}: ${e.message}"
            Log.e(TAG, "hy2 relay failed to start: $hy2RelayDetail")
            stopHy2Relay()
            return false
        }
    }

    private fun startHy2Probe(targetHost: String, echoPort: Int) {
        stopHy2Probe()
        try {
            val probe = java.net.DatagramSocket()
            probe.soTimeout = 3000
            hy2ProbeSocket = probe
            hy2ProbeRunning = true
            for (i in hy2ProbeOkArr.indices) { hy2ProbeOkArr[i] = 0; hy2ProbeFailArr[i] = 0 }
            hy2ProbeLastRttMs = -1
            hy2ProbeSizeStats = "starting"
            hy2ProbeDetail = "starting -> $targetHost:$echoPort"
            hy2ProbeThread = Thread {
                val addr = try {
                    java.net.InetSocketAddress(java.net.InetAddress.getByName(targetHost), echoPort)
                } catch (e: Throwable) {
                    hy2ProbeDetail = "resolve failed: ${e.message}"
                    return@Thread
                }
                val ladder = hy2ProbeLadder
                var round = 0
                while (hy2ProbeRunning && !Thread.currentThread().isInterrupted) {
                    val idx = round % ladder.size
                    val size = ladder[idx]
                    val payload = ByteArray(size)
                    "ZGR".toByteArray(Charsets.US_ASCII).copyInto(payload)
                    try {
                        val t0 = android.os.SystemClock.elapsedRealtime()
                        probe.send(java.net.DatagramPacket(payload, size, addr))
                        val back = java.net.DatagramPacket(ByteArray(2048), 2048)
                        probe.receive(back)
                        val rtt = android.os.SystemClock.elapsedRealtime() - t0
                        if (back.length == size) {
                            hy2ProbeOkArr[idx] += 1
                            hy2ProbeLastRttMs = rtt
                            hy2ProbeDetail = "rtt=${rtt}ms"
                        } else {
                            hy2ProbeFailArr[idx] += 1
                            hy2ProbeDetail = "len ${back.length}!=${size}"
                        }
                    } catch (e: Throwable) {
                        hy2ProbeFailArr[idx] += 1
                        hy2ProbeDetail = "${e.javaClass.simpleName}"
                    }
                    hy2ProbeSizeStats = ladder.indices.joinToString(",") { i ->
                        "${'$'}{ladder[i]}:${'$'}{hy2ProbeOkArr[i]}/${'$'}{hy2ProbeFailArr[i]}"
                    }
                    round += 1
                    try { Thread.sleep(2000) } catch (_: InterruptedException) { break }
                }
            }.apply { name = "hy2-udp-probe"; start() }
        } catch (e: Throwable) {
            hy2ProbeDetail = "start failed ${e.javaClass.simpleName}: ${e.message}"
        }
    }

    private fun stopHy2Probe() {
        hy2ProbeRunning = false
        try { hy2ProbeThread?.interrupt() } catch (_: Throwable) {}
        hy2ProbeThread = null
        try { hy2ProbeSocket?.close() } catch (_: Throwable) {}
        hy2ProbeSocket = null
    }

    fun stopHy2Relay() {
        stopHy2Probe()
        hy2RelayRunning = false
        synchronized(hy2RelayThreads) {
            for (t in hy2RelayThreads) {
                try { t.interrupt() } catch (_: Throwable) {}
            }
            hy2RelayThreads.clear()
        }
        try { hy2RelayListener?.close() } catch (_: Throwable) {}
        hy2RelayListener = null
        try { hy2RelayUpstream?.close() } catch (_: Throwable) {}
        hy2RelayUpstream = null
    }

    private fun describeProbeErrno(r: Int): String = when (-r) {
        111 -> "ECONNREFUSED (server not listening)"
        104 -> "ECONNRESET"
        107 -> "ENOTCONN"
        32 -> "EPIPE"
        13 -> "EACCES"
        2 -> "ENOENT"
        71 -> "EPROTO (unexpected ack)"
        else -> "errno"
    }

    private fun handleProtectClient(client: LocalSocket) {
        try {
            client.soTimeout = 3000
            // First data byte selects the command: PING (self-test, acked
            // immediately, VPN-independent) or PROTECT (the real request the
            // sing child sends: one data byte + fd via SCM_RIGHTS). Ancillary
            // fds are parsed when that message is read.
            val cmd = try { client.inputStream.read() } catch (_: Throwable) { -1 }
            if (cmd == PROTECT_CMD_PING) {
                try { client.outputStream.write(1) } catch (_: Throwable) {}
                try { client.outputStream.flush() } catch (_: Throwable) {}
                return
            }
            val fds = client.ancillaryFileDescriptors
            if (fds != null && fds.isNotEmpty()) {
                for (fd in fds) {
                    var pfd: ParcelFileDescriptor? = null
                    val ok = try {
                        pfd = ParcelFileDescriptor.dup(fd)
                        protectWithWait(pfd!!.fd)
                    } catch (e: Throwable) {
                        Log.w(TAG, "protect(fd) failed: ${e.message}")
                        false
                    } finally {
                        try { pfd?.close() } catch (_: Throwable) {}
                    }
                    if (ok) {
                        protectedFdCount += 1
                        Log.i(TAG, "protect: fd protected (total=$protectedFdCount)")
                    } else {
                        failedProtectFdCount += 1
                        Log.w(TAG, "protect: fd NOT protected (vpnUp=$isVpnUp, failed=$failedProtectFdCount)")
                    }
                    // sing's client treats any non-1-byte ack as a dial failure
                    // ("failed to protect fd"); an honest 0 keeps the failure
                    // visible in the child's log instead of a silent loop.
                    try { client.outputStream.write(if (ok) 1 else 0) } catch (_: Throwable) {}
                    try { client.outputStream.flush() } catch (_: Throwable) {}
                }
            } else {
                try { client.outputStream.write(1) } catch (_: Throwable) {}
                try { client.outputStream.flush() } catch (_: Throwable) {}
            }
        } catch (e: Throwable) {
            Log.w(TAG, "protect client handling failed: ${e.message}")
        } finally {
            try { client.close() } catch (_: Throwable) {}
        }
    }

    /** protect() only succeeds once a VPN interface exists; the child may dial
     *  right at config load before establish() finishes. Wait briefly so the
     *  first dials are genuinely protected instead of fake-acked. */
    private fun protectWithWait(fd: Int): Boolean {
        var attempt = 0
        while (attempt < 30) {
            if (protect(fd)) return true
            if (!isVpnUp) {
                attempt += 1
                try { Thread.sleep(100) } catch (_: InterruptedException) { return false }
            } else {
                // VPN is up but protect() refused — do not spin; report failure.
                return false
            }
        }
        return protect(fd)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        instance = this
        isServiceRunning.set(true)
        createNotificationChannel()
        // A null intent means the system restarted a sticky service after the
        // process was killed (e.g. aggressive OEM battery management). The
        // tunnel itself cannot be silently restored (runtime configs are
        // zeroized by design), so re-assert the honest foreground state.
        startForeground(
            NOTIFICATION_ID,
            buildNotification(
                if (intent == null) "Zagros VPN is ready"
                else "Zagros VPN service is active",
            ),
        )
        Log.i(TAG, "ZagrosVpnService started (intent==null: ${intent == null})")
        // Sticky: the foreground service (and its notification) must come back
        // after an OEM process kill instead of silently disappearing.
        return START_STICKY
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java) ?: return
            val existing = manager.getNotificationChannel(NOTIFICATION_CHANNEL_ID)
            if (existing == null) {
                val channel = NotificationChannel(
                    NOTIFICATION_CHANNEL_ID,
                    "Zagros VPN Service",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "VPN Tunnel status and connectivity"
                    setShowBadge(false)
                }
                manager.createNotificationChannel(channel)
            }
        }
    }

    private fun buildNotification(text: String): Notification {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
                .setContentTitle("Zagros VPN")
                .setContentText(text)
                .setSmallIcon(android.R.drawable.ic_lock_lock)
                .setOngoing(true)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setContentTitle("Zagros VPN")
                .setContentText(text)
                .setSmallIcon(android.R.drawable.ic_lock_lock)
                .setOngoing(true)
                .build()
        }
    }

    /**
     * Creates and configures the TUN interface for OpenVPN management handover.
     */
    fun openTunForOpenVpn(
        ip: String,
        prefixLength: Int,
        mtu: Int = 1400,
        dnsServers: List<String> = emptyList(),
        routes: List<Pair<String, Int>> = emptyList(),
    ): ParcelFileDescriptor? {
        stopTunnel()

        try {
            val builder = Builder()
                .setSession("Zagros OpenVPN")
                .setMtu(mtu)
                .addAddress(ip, prefixLength)

            if (routes.isNotEmpty()) {
                for (r in routes) {
                    try {
                        builder.addRoute(r.first, r.second)
                    } catch (e: Throwable) {
                        Log.w(TAG, "addRoute ${r.first}/${r.second} error: ${e.message}")
                    }
                }
            } else {
                builder.addRoute("0.0.0.0", 0)
            }

            if (dnsServers.isNotEmpty()) {
                for (dns in dnsServers) {
                    try {
                        builder.addDnsServer(dns)
                    } catch (_: Throwable) {
                    }
                }
            } else {
                builder.addDnsServer("1.1.1.1")
                builder.addDnsServer("8.8.8.8")
            }

            try {
                builder.addDisallowedApplication(packageName)
            } catch (e: Throwable) {
                Log.w(TAG, "Could not add disallowed application: ${e.message}")
            }

            builder.setBlocking(false)
            val pfd = builder.establish() ?: run {
                Log.e(TAG, "VpnService.Builder.establish() returned null for OpenVPN")
                return null
            }
            tunInterface = try { pfd.dup() } catch (_: Throwable) { pfd }
            Log.i(TAG, "OpenVPN TUN established successfully: fd=${pfd.fd}")
            startForeground(NOTIFICATION_ID, buildNotification("Connected to Zagros OpenVPN"))
            return pfd
        } catch (e: Throwable) {
            Log.e(TAG, "Failed to open TUN for OpenVPN: ${e.message}", e)
            return null
        }
    }

    /**
     * Creates and configures the TUN interface, writes the hev-socks5-tunnel config,
     * and starts the native TProxy bridge to the sing-box mixed inbound.
     */
    fun startTunnel(
        socksPort: Int = 20808,
        socksAddress: String = "127.0.0.1",
        mtu: Int = 1400,
        ipv4Address: String = "172.19.0.1",
        ipv4PrefixLength: Int = 30,
        ipv6Address: String? = null,
        ipv6PrefixLength: Int = 126,
        dnsServers: List<String> = listOf("1.1.1.1", "8.8.8.8"),
        perAppMode: String = "off",
        perAppPackages: List<String> = emptyList(),
    ): Boolean {
        stopTunnel()

        try {
            val hevConfig = """
tunnel:
  mtu: $mtu
  ipv4: $ipv4Address
${if (ipv6Address != null) "  ipv6: '$ipv6Address'\n" else ""}
socks5:
  port: $socksPort
  address: $socksAddress
  udp: 'udp'

misc:
  task-stack-size: 86016
  connect-timeout: 10000
  read-write-timeout: 60000
  log-level: warn
""".trimIndent()

            val configFile = File(filesDir, "hev_tun_active.yml")
            FileOutputStream(configFile).use { out ->
                out.write(hevConfig.toByteArray(Charsets.UTF_8))
                out.flush()
            }
            activeHevConfigFile = configFile

            val builder = Builder()
                .setSession("Zagros VPN")
                .setMtu(mtu)
                .addAddress(ipv4Address, ipv4PrefixLength)
                .addRoute("0.0.0.0", 0)

            if (ipv6Address != null) {
                try {
                    builder.addAddress(ipv6Address, ipv6PrefixLength)
                    builder.addRoute("::", 0)
                } catch (_: Throwable) {
                }
            }

            for (dns in dnsServers) {
                try {
                    builder.addDnsServer(dns)
                } catch (_: Throwable) {
                }
            }

            // Per-app proxy (f55): allow = ONLY listed apps use the tun
            // (our own package is always included so the engine transport
            // keeps bypassing); deny = listed apps bypass; off = legacy
            // self-exclusion. Package names map to UIDs inside Builder.
            when (perAppMode) {
                "allow" -> {
                    var added = 0
                    try {
                        builder.addAllowedApplication(packageName)
                        added++
                    } catch (e: Throwable) {
                        Log.w(TAG, "per-app allow self failed: ${e.message}")
                    }
                    for (pkg in perAppPackages) {
                        if (pkg == packageName) continue
                        try {
                            builder.addAllowedApplication(pkg)
                            added++
                        } catch (e: Throwable) {
                            Log.w(TAG, "per-app allow $pkg failed: ${e.message}")
                        }
                    }
                    Log.i(TAG, "per-app proxy: allow ($added apps)")
                }
                "deny" -> {
                    var added = 0
                    try {
                        builder.addDisallowedApplication(packageName)
                        added++
                    } catch (e: Throwable) {
                        Log.w(TAG, "per-app deny self failed: ${e.message}")
                    }
                    for (pkg in perAppPackages) {
                        if (pkg == packageName) continue
                        try {
                            builder.addDisallowedApplication(pkg)
                            added++
                        } catch (e: Throwable) {
                            Log.w(TAG, "per-app deny $pkg failed: ${e.message}")
                        }
                    }
                    Log.i(TAG, "per-app proxy: deny ($added apps)")
                }
                else -> {
                    // Exclude our own package so sing-box outgoing traffic bypasses the VPN tunnel
                    try {
                        builder.addDisallowedApplication(packageName)
                    } catch (e: Throwable) {
                        Log.w(TAG, "Could not add disallowed application: ${e.message}")
                    }
                }
            }

            builder.setBlocking(false)
            val pfd = builder.establish() ?: run {
                Log.e(TAG, "VpnService.Builder.establish() returned null (VPN permission may be missing or revoked)")
                return false
            }
            tunInterface = pfd
            Log.i(TAG, "VPN TUN established successfully: fd=${pfd.fd}")

            startForeground(NOTIFICATION_ID, buildNotification("Connected to Zagros VPN"))

            val started = try {
                TProxyService.TProxyStartService(configFile.absolutePath, pfd.fd)
            } catch (e: Throwable) {
                Log.e(TAG, "TProxyService native call failed: ${e.message}", e)
                false
            }

            if (!started) {
                Log.e(TAG, "TProxyService.TProxyStartService returned false")
                closeTun()
                return false
            }

            Log.i(TAG, "hev-socks5-tunnel bridge started successfully")
            isVpnUp = true
            return true
        } catch (e: Throwable) {
            Log.e(TAG, "Failed to start VPN tunnel: ${e.message}", e)
            stopTunnel()
            return false
        }
    }

    /**
     * Starts the embedded SSTP engine (userspace PPP; MIT core, pinned).
     * The engine creates its own TUN via this service's Builder.
     */
    fun startSstpEngine(
        payload: JSONObject,
        onEstablished: () -> Unit,
        onError: (String) -> Unit,
        onClosed: () -> Unit,
    ): Boolean {
        stopSstpEngine()
        val engine = sstpEngine ?: ZagrosSstpEngine(this).also { sstpEngine = it }
        val started = engine.start(payload, onEstablished, onError, onClosed)
        if (started) {
            startForeground(
                NOTIFICATION_ID,
                buildNotification("Connecting to Zagros VPN (SSTP)"),
            )
        }
        return started
    }

    fun stopSstpEngine() {
        sstpEngine?.stop()
    }

    /**
     * Starts the embedded SoftEther-native engine (our own userspace
     * implementation: TLS block stream + Ethernet shim; no third-party GPL).
     */
    fun startSeEngine(
        payload: JSONObject,
        onEstablished: () -> Unit,
        onError: (String) -> Unit,
        onClosed: () -> Unit,
        traceSink: ((String) -> Unit)? = null,
    ): Boolean {
        stopSeEngine()
        val engine = seEngine ?: ZagrosSeEngine(this).also { seEngine = it }
        engine.traceSink = traceSink
        val started = engine.start(payload, onEstablished, onError, onClosed)
        if (started) {
            startForeground(
                NOTIFICATION_ID,
                buildNotification("Connecting to Zagros VPN (SoftEther)"),
            )
        }
        return started
    }

    fun stopSeEngine() {
        seEngine?.stop()
    }

    fun seEngineAlive(): Boolean = seEngine?.isAlive() == true

    fun seEngineEstablished(): Boolean = seEngine?.isEstablished() == true

    fun seUplink(): Long = seEngine?.getUplink() ?: 0L

    fun seDownlink(): Long = seEngine?.getDownlink() ?: 0L

    /**
     * Starts the embedded raw-L2TP engine (userspace PPP; MIT core, pinned).
     */
    fun startL2tpEngine(
        payload: JSONObject,
        onEstablished: () -> Unit,
        onError: (String) -> Unit,
        onClosed: () -> Unit,
    ): Boolean {
        stopL2tpEngine()
        val engine = l2tpEngine ?: ZagrosL2tpEngine(this).also { l2tpEngine = it }
        val started = engine.start(payload, onEstablished, onError, onClosed)
        if (started) {
            startForeground(
                NOTIFICATION_ID,
                buildNotification("Connecting to Zagros VPN (L2TP)"),
            )
        }
        return started
    }

    fun stopL2tpEngine() {
        l2tpEngine?.stop()
    }

    fun l2tpEngineAlive(): Boolean = l2tpEngine?.isAlive() == true

    fun l2tpEngineEstablished(): Boolean = l2tpEngine?.isEstablished() == true

    fun l2tpUplink(): Long = l2tpEngine?.getUplink() ?: 0L

    fun l2tpDownlink(): Long = l2tpEngine?.getDownlink() ?: 0L

    fun sstpEngineAlive(): Boolean = sstpEngine?.isAlive() == true

    fun sstpEngineEstablished(): Boolean = sstpEngine?.isEstablished() == true

    fun sstpUplink(): Long = sstpEngine?.getUplink() ?: 0L

    fun sstpDownlink(): Long = sstpEngine?.getDownlink() ?: 0L

    fun updateNotification(text: String) {
        try {
            startForeground(NOTIFICATION_ID, buildNotification(text))
        } catch (_: Throwable) {
        }
    }

    fun stopTunnel() {
        isVpnUp = false
        try {
            if (sstpEngine?.isAlive() == true) {
                sstpEngine?.stop()
                Log.i(TAG, "SSTP engine stopped")
            }
        } catch (e: Throwable) {
            Log.e(TAG, "Error stopping SSTP engine: ${e.message}", e)
        }

        try {
            if (l2tpEngine?.isAlive() == true) {
                l2tpEngine?.stop()
                Log.i(TAG, "L2TP engine stopped")
            }
        } catch (e: Throwable) {
            Log.e(TAG, "Error stopping L2TP engine: ${e.message}", e)
        }

        try {
            if (seEngine?.isAlive() == true) {
                seEngine?.stop()
                Log.i(TAG, "SoftEther engine stopped")
            }
        } catch (e: Throwable) {
            Log.e(TAG, "Error stopping SoftEther engine: ${e.message}", e)
        }

        try {
            if (TProxyService.TProxyIsRunning()) {
                TProxyService.TProxyStopService()
                Log.i(TAG, "hev-socks5-tunnel bridge stopped")
            }
        } catch (e: Throwable) {
            Log.e(TAG, "Error stopping TProxyService: ${e.message}", e)
        }

        closeTun()

        activeHevConfigFile?.let { file ->
            try {
                if (file.exists()) {
                    file.delete()
                }
            } catch (_: Throwable) {
            }
            activeHevConfigFile = null
        }
    }

    private fun closeTun() {
        try {
            tunInterface?.close()
            Log.i(TAG, "VPN TUN closed")
        } catch (_: Throwable) {
        } finally {
            tunInterface = null
        }
    }

    override fun onDestroy() {
        stopProtectServer()
        sstpEngine?.destroy()
        sstpEngine = null
        l2tpEngine?.destroy()
        l2tpEngine = null
        seEngine?.destroy()
        seEngine = null
        stopTunnel()
        isServiceRunning.set(false)
        if (instance === this) {
            instance = null
        }
        Log.i(TAG, "ZagrosVpnService destroyed")
        super.onDestroy()
    }

    override fun onRevoke() {
        noteVpnRevoked()
        L2tpTrace.mark("on_revoke")
        stopTunnel()
        Log.i(TAG, "ZagrosVpnService revoked by user/system")
        super.onRevoke()
    }
}
