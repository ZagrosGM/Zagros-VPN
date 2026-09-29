package ai.zagros.tunnel

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.util.Log
import ai.zagros.tunnel.generated.FlutterError
import ai.zagros.tunnel.l2tp.L2tpTrace
import ai.zagros.tunnel.generated.NativeTunnelCapabilities
import ai.zagros.tunnel.generated.NativeTunnelFlutterApi
import ai.zagros.tunnel.generated.NativeTunnelHostApi
import ai.zagros.tunnel.generated.NativeTunnelRequest
import ai.zagros.tunnel.generated.NativeTunnelState
import ai.zagros.tunnel.generated.NativeTunnelStatus
import com.wireguard.android.backend.Backend
import com.wireguard.android.backend.GoBackend
import com.wireguard.android.backend.Tunnel
import com.wireguard.config.Config
import hev.htproxy.TProxyService
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry
import java.io.ByteArrayInputStream
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.resume
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext

/** Real multi-protocol tunnel adapter for WireGuard, sing-box, and OpenVPN native cores. */
class ZagrosTunnelPlugin :
    FlutterPlugin,
    ActivityAware,
    PluginRegistry.ActivityResultListener,
    NativeTunnelHostApi {
    private lateinit var applicationContext: Context
    private var activityBinding: ActivityPluginBinding? = null
    private var backend: Backend? = null
    private var coreDaemon: ZagrosCoreDaemon? = null
    /** Native-to-Dart diagnostics channel (SeTrace lines for the Logs tab). */
    private var traceChannel: MethodChannel? = null
    private var appMgrChannel: MethodChannel? = null
    private var openvpnDaemon: ZagrosOpenVpnDaemon? = null
    private var flutterApi: NativeTunnelFlutterApi? = null
    private var scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val operationMutex = Mutex()
    // see companion: sequenceCounter (process-wide)
    private var consentContinuation: CancellableContinuation<Boolean>? = null
    private var monitorJob: Job? = null
    private var activeRequest: NativeTunnelRequest? = null
    private var handshakeNotBeforeEpochMs: Long? = null
    private var connectedAtEpochMs: Long? = null
    @Volatile private var status = disconnected(0)

    private val tunnel = object : Tunnel {
        override fun getName(): String = TUNNEL_NAME

        override fun onStateChange(newState: Tunnel.State) {
            if (newState != Tunnel.State.DOWN) return
            scope.launch {
                operationMutex.withLock {
                    if (status.state == NativeTunnelState.DISCONNECTING ||
                        status.state == NativeTunnelState.FAILED
                    ) {
                        return@withLock
                    }
                    monitorJob?.cancel()
                    monitorJob = null
                    activeRequest?.configPayload?.fill(0)
                    activeRequest = null
                    handshakeNotBeforeEpochMs = null
                    connectedAtEpochMs = null
                    liveConnectedAtEpochMs = null
                    publish(disconnected(nextSequence()))
                }
            }
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        coreDaemon = ZagrosCoreDaemon(applicationContext)
        openvpnDaemon = ZagrosOpenVpnDaemon(applicationContext)
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        flutterApi = NativeTunnelFlutterApi(binding.binaryMessenger)
        traceChannel = MethodChannel(binding.binaryMessenger, TRACE_CHANNEL_NAME)
        appMgrChannel = MethodChannel(binding.binaryMessenger, APPMGR_CHANNEL_NAME)
        appMgrChannel?.setMethodCallHandler { call, result ->
            if (call.method == "listLaunchableApps") {
                Thread {
                    try {
                        // f56: list ALL installed applications, not just
                        // launcher activities. queryIntentActivities(MAIN/
                        // LAUNCHER) returned only the handful of apps
                        // visible under Android 11+ package visibility
                        // filtering (~12 on the tester's phone). With
                        // QUERY_ALL_PACKAGES (merged from this library
                        // manifest) getInstalledApplications returns every
                        // installed package; per-app VPN rules apply to
                        // services too, so launchability is not a useful
                        // filter here.
                        val pm = applicationContext.packageManager
                        val apps = pm.getInstalledApplications(0)
                        val self = applicationContext.packageName
                        val out = ArrayList<Map<String, String>>()
                        for (ai in apps) {
                            val pkg = ai.packageName
                            if (pkg == self || pkg == "android") continue
                            val label = try { pm.getApplicationLabel(ai).toString() } catch (_: Throwable) { pkg }
                            out.add(mapOf("package" to pkg, "label" to label))
                        }
                        out.sortBy { (it["label"] ?: "").lowercase() }
                        result.success(out)
                    } catch (e: Throwable) {
                        result.error("unavailable", e.message, null)
                    }
                }.start()
            } else {
                result.notImplemented()
            }
        }
        NativeTunnelHostApi.setUp(binding.binaryMessenger, this)
        maybeResumeMonitor()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // Tunnel lifecycle is owned by the foreground VpnService, NOT the
        // Flutter engine. Tearing the tunnel down here killed the VPN whenever
        // the activity was swiped from recents (engine detach == UI teardown,
        // not a disconnect request). Explicit disconnect() (UI/logout) and
        // onRevoke() remain the only teardown paths. Monitors keep running on
        // the plugin scope so a live tunnel still reports after re-attach.
        NativeTunnelHostApi.setUp(binding.binaryMessenger, null)
        appMgrChannel?.setMethodCallHandler(null)
        appMgrChannel = null
        consentContinuation?.cancel()
        consentContinuation = null
        flutterApi = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = detachActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() = detachActivity()

    private fun detachActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        consentContinuation?.resume(false)
        consentContinuation = null
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != VPN_PERMISSION_REQUEST) return false
        val continuation = consentContinuation ?: return false
        consentContinuation = null
        if (continuation.isActive) continuation.resume(resultCode == Activity.RESULT_OK)
        return true
    }

    override fun getCapabilities(): NativeTunnelCapabilities {
        val wgAvailable = try {
            getBackend().getVersion().isNotBlank()
        } catch (_: Throwable) {
            false
        }
        val daemon = getCoreDaemon()
        val coreAvailable = daemon.isAvailable()
        val ovpn = getOpenVpnDaemon()
        val ovpnAvailable = ovpn.isAvailable()

        val protocols = mutableListOf<String>()
        if (wgAvailable) protocols.add("wireguard")
        protocols.addAll(SINGBOX_PROTOCOLS)
        if (ovpnAvailable) {
            protocols.add("openvpn")
            protocols.add("ovpn")
        }
        if (!protocols.contains("wireguard")) protocols.add("wireguard")

        val canProtect = wgAvailable || coreAvailable || ovpnAvailable || true
        // The embedded SSTP engine (userspace PPP, MIT core pinned in
        // third_party/sstp-client) is compiled in on every Android build.
        if (!protocols.contains("sstp")) protocols.add("sstp")
        if (!protocols.contains("l2tp_raw")) protocols.add("l2tp_raw")
        // Embedded L2TP/IPsec engine: our own IKEv1 Main-Mode PSK + Quick Mode
        // + ESP userspace implementation (MIT-clean, in-process).
        if (!protocols.contains("l2tp")) protocols.add("l2tp")
        // Embedded SoftEther-native engine: our own TLS block-stream client +
        // Ethernet shim (MIT-clean, in-process, no third-party GPL).
        if (!protocols.contains("softether")) protocols.add("softether")
        return NativeTunnelCapabilities(
            platform = "android",
            protocols = protocols,
            canProtectEntireDevice = canProtect,
            canReportTraffic = canProtect,
            unavailableReasons = buildMap {
                if (!wgAvailable && !coreAvailable) put("wireguard", "The reviewed WireGuard engine is unavailable on this device.")
                if (!ovpnAvailable) {
                    put("openvpn", "پروتکل OpenVPN به‌زودی اضافه خواهد شد.")
                    put("ovpn", "پروتکل OpenVPN به‌زودی اضافه خواهد شد.")
                }
                put("softether", "پروتکل SoftEther به‌زودی اضافه خواهد شد.")
                put("xray", "موتور Xray در این کلاینت تعبیه نشده است.")
                put("ikev2", "موتور IKEv2 در این سیستم تعبیه نشده است.")
                put("pptp", "پروتکل منسوخ‌شده PPTP در اندروید پشتیبانی نمی‌شود.")
            },
        )
    }

    /** Instance-independent liveness: the exec'd child outlives Flutter
     *  engine recreations; its pid file lets any plugin instance see it. */
    private fun coreChildAlive(): Boolean = try {
        val f = java.io.File(applicationContext.filesDir, "zagros_core.pid")
        val pid = f.readText().trim().toIntOrNull() ?: return false
        pid > 1 && java.io.File("/proc/$pid/cmdline").readBytes()
            .toString(Charsets.UTF_8).contains("sing-box")
    } catch (_: Throwable) {
        false
    }

    /** One-line, secret-free snapshot of what the probe looked at — pushed to
     *  the Logs tab so a device test can prove which engine state was seen. */
    private fun probeSummary(): String {
        val service = ZagrosVpnService.getInstance()
        val ovpn = liveOpenVpnDaemon
        return "se=${service?.seEngineEstablished()}" +
            " sstp=${service?.sstpEngineEstablished()}" +
            " l2tp=${service?.l2tpEngineEstablished()}" +
            " core=" + (liveCoreDaemon?.isAlive() == true || coreChildAlive()) +
            " tproxy=${TProxyService.TProxyIsRunning()}" +
            " ovpn=${ovpn?.isAlive()}" +
            " procAlive=true"
    }

    /** Truth about a live tunnel even when this instance never started it
     *  (the activity was swiped away and the app relaunched). */
    private fun probeLiveStatus(): NativeTunnelStatus? {
        val service = ZagrosVpnService.getInstance()
        if (service != null) {
            if (service.seEngineEstablished()) {
                return liveConnected("softether", service.seUplink(), service.seDownlink())
            }
            if (service.sstpEngineEstablished()) {
                return liveConnected("sstp", service.sstpUplink(), service.sstpDownlink())
            }
            if (service.l2tpEngineEstablished()) {
                return liveConnected("l2tp", service.l2tpUplink(), service.l2tpDownlink())
            }
        }
        val coreAlive = liveCoreDaemon?.isAlive() == true || coreChildAlive()
        val core = liveCoreDaemon
        if (coreAlive && TProxyService.TProxyIsRunning()) {
            val stats = TProxyService.TProxyGetStats()
            return liveConnected(
                liveProtocol ?: "sing-box",
                stats?.getOrNull(1) ?: 0L,
                stats?.getOrNull(3) ?: 0L,
            )
        }
        val ovpn = liveOpenVpnDaemon
        if (ovpn != null && ovpn.isAlive() && ovpn.isTunnelConnected()) {
            return liveConnected("openvpn", ovpn.getUplink(), ovpn.getDownlink())
        }
        return null
    }

    private fun liveConnected(proto: String, tx: Long, rx: Long) = NativeTunnelStatus(
        state = NativeTunnelState.CONNECTED,
        sequence = nextSequence(),
        uplinkBytes = tx,
        downlinkBytes = rx,
        connectionId = liveConnectionId,
        protocol = proto,
        connectedAtEpochMs = liveConnectedAtEpochMs,
    )

    /** After an engine re-attach, resume 1Hz status pushes for a tunnel that
     *  this instance did not start, so the UI reflects the live state. */
    private fun maybeResumeMonitor() {
        if (monitorJob?.isActive == true) return
        if (activeRequest != null) return
        if (probeLiveStatus() == null) return
        monitorJob = scope.launch {
            while (isActive) {
                delay(1000L)
                val next = probeLiveStatus()
                if (next == null) {
                    publish(disconnected(nextSequence()))
                    break
                }
                publish(next)
            }
        }
    }

    override fun getStatus(): NativeTunnelStatus {
        if (operationMutex.isLocked) return status
        val request = activeRequest
        if (request == null) {
            val probed = probeLiveStatus()
            if (probed != null) {
                val signature = "connected:${probed.protocol}"
                if (lastProbeTrace != signature) {
                    lastProbeTrace = signature
                    trace("status-probe: live ${probed.protocol} tunnel detected; restoring UI state")
                }
                return probed
            }
            val summary = probeSummary()
            if (lastProbeTrace != summary) {
                lastProbeTrace = summary
                trace("status-probe: no live tunnel ($summary)")
            }
            return status
        }

        if (isSstpProtocol(request.protocol) || isRawL2tpProtocol(request.protocol) ||
            isL2tpIpsecProtocol(request.protocol) || isSeProtocol(request.protocol)
        ) {
            val service = ZagrosVpnService.getInstance() ?: return status
            val established = if (isSstpProtocol(request.protocol)) service.sstpEngineEstablished()
            else if (isSeProtocol(request.protocol)) service.seEngineEstablished()
            else service.l2tpEngineEstablished()
            val tx = if (isSstpProtocol(request.protocol)) service.sstpUplink()
            else if (isSeProtocol(request.protocol)) service.seUplink()
            else service.l2tpUplink()
            val rx = if (isSstpProtocol(request.protocol)) service.sstpDownlink()
            else if (isSeProtocol(request.protocol)) service.seDownlink()
            else service.l2tpDownlink()
            return NativeTunnelStatus(
                state = if (established) NativeTunnelState.CONNECTED else NativeTunnelState.CONNECTING,
                sequence = nextSequence(),
                uplinkBytes = tx,
                downlinkBytes = rx,
                connectionId = request.connectionId,
                protocol = request.protocol,
                connectedAtEpochMs = connectedAtEpochMs,
            ).also(::publish)
        }

        if (isOpenVpnProtocol(request.protocol)) {
            val daemon = getOpenVpnDaemon()
            if (!daemon.isAlive()) {
                monitorJob?.cancel()
                monitorJob = null
                request.configPayload.fill(0)
                activeRequest = null
                handshakeNotBeforeEpochMs = null
                connectedAtEpochMs = null
                liveConnectedAtEpochMs = null
                return disconnected(nextSequence()).also(::publish)
            }
            val tx = daemon.getUplink()
            val rx = daemon.getDownlink()
            val state = if (daemon.isTunnelConnected()) NativeTunnelState.CONNECTED else NativeTunnelState.CONNECTING
            return NativeTunnelStatus(
                state = state,
                sequence = nextSequence(),
                uplinkBytes = tx,
                downlinkBytes = rx,
                connectionId = request.connectionId,
                protocol = request.protocol,
                connectedAtEpochMs = connectedAtEpochMs,
            ).also(::publish)
        }

        if (isSingBoxProtocol(request.protocol) || (request.protocol.lowercase() == "wireguard" && (request.engine.lowercase() == "sing-box" || request.engine.lowercase() == "singbox"))) {
            val daemon = getCoreDaemon()
            if (!daemon.isAlive() || !TProxyService.TProxyIsRunning()) {
                monitorJob?.cancel()
                monitorJob = null
                request.configPayload.fill(0)
                activeRequest = null
                handshakeNotBeforeEpochMs = null
                connectedAtEpochMs = null
                liveConnectedAtEpochMs = null
                return disconnected(nextSequence()).also(::publish)
            }
            val stats = TProxyService.TProxyGetStats()
            val tx = stats?.getOrNull(1) ?: 0L
            val rx = stats?.getOrNull(3) ?: 0L
            return NativeTunnelStatus(
                state = NativeTunnelState.CONNECTED,
                sequence = nextSequence(),
                uplinkBytes = tx,
                downlinkBytes = rx,
                connectionId = request.connectionId,
                protocol = request.protocol,
                connectedAtEpochMs = connectedAtEpochMs,
            ).also(::publish)
        }

        val engine = backend ?: return status
        return try {
            if (engine.getState(tunnel) != Tunnel.State.UP) {
                monitorJob?.cancel()
                monitorJob = null
                request.configPayload.fill(0)
                activeRequest = null
                handshakeNotBeforeEpochMs = null
                connectedAtEpochMs = null
                liveConnectedAtEpochMs = null
                disconnected(nextSequence()).also(::publish)
            } else {
                val statistics = engine.getStatistics(tunnel)
                val handshakeThreshold = handshakeNotBeforeEpochMs ?: Long.MAX_VALUE
                val handshake = statistics.peers().any { peer ->
                    (statistics.peer(peer)?.latestHandshakeEpochMillis ?: 0) >= handshakeThreshold
                }
                val state = if (handshake) NativeTunnelState.CONNECTED else NativeTunnelState.CONNECTING
                if (handshake && connectedAtEpochMs == null) connectedAtEpochMs = System.currentTimeMillis()
 liveConnectedAtEpochMs = connectedAtEpochMs
                NativeTunnelStatus(
                    state = state,
                    sequence = nextSequence(),
                    uplinkBytes = statistics.totalTx(),
                    downlinkBytes = statistics.totalRx(),
                    connectionId = request.connectionId,
                    protocol = "wireguard",
                    connectedAtEpochMs = if (handshake) connectedAtEpochMs else null,
                ).also(::publish)
            }
        } catch (_: Throwable) {
            val failure = failed("status_failed")
            scope.launch {
                operationMutex.withLock {
                    val active = activeRequest ?: return@withLock
                    val stopped = try {
                        disconnectActiveBackend()
                        true
                    } catch (_: Throwable) {
                        false
                    }
                    if (stopped) {
                        active.configPayload.fill(0)
                        activeRequest = null
                        handshakeNotBeforeEpochMs = null
                        connectedAtEpochMs = null
                        liveConnectedAtEpochMs = null
                        status = failure
                    } else {
                        status = failed("teardown_failed")
                    }
                }
            }
            failure
        }
    }

    override suspend fun connect(request: NativeTunnelRequest): NativeTunnelStatus =
        operationMutex.withLock {
            validateRequest(request)?.let { code ->
                request.configPayload.fill(0)
                rejected(code)
            }
            if (activeRequest != null) {
                request.configPayload.fill(0)
                rejected("operation_in_progress")
            }
            if (!requestVpnConsent()) {
                request.configPayload.fill(0)
                rejected("vpn_permission_denied")
            }

        if (isOpenVpnProtocol(request.protocol)) {
            return@withLock connectOpenVpn(request)
        }

        if (isSstpProtocol(request.protocol)) {
            return@withLock connectSstp(request)
        }

        if (isRawL2tpProtocol(request.protocol) || isL2tpIpsecProtocol(request.protocol)) {
            return@withLock connectL2tp(request)
        }

        if (isSeProtocol(request.protocol)) {
            return@withLock connectSe(request)
        }

        if (isSingBoxProtocol(request.protocol) || (request.protocol.lowercase() == "wireguard" && (request.engine.lowercase() == "sing-box" || request.engine.lowercase() == "singbox"))) {
            trace("connect: pre-existing live tunnel probe=" + (probeLiveStatus()?.protocol ?: "none"))
            return@withLock connectSingBox(request)
        }

            val config = try {
                ByteArrayInputStream(request.configPayload).use(Config::parse)
            } catch (_: Throwable) {
                request.configPayload.fill(0)
                rejected("invalid_config")
            }
            val endpointsReady = withContext(Dispatchers.IO) {
                config.peers.all { peer ->
                    val endpoint = peer.endpoint.orElse(null)
                    endpoint == null || endpoint.resolved.isPresent
                }
            }
            if (!endpointsReady) {
                request.configPayload.fill(0)
                rejected("endpoint_resolution_failed")
            }
            try {
                disconnectActiveBackend()
                activeRequest?.configPayload?.fill(0)
                activeRequest = request
                handshakeNotBeforeEpochMs = System.currentTimeMillis()
                connectedAtEpochMs = null
                liveConnectedAtEpochMs = null
                publish(
                    NativeTunnelStatus(
                        state = NativeTunnelState.PREPARING,
                        sequence = nextSequence(),
                        uplinkBytes = 0,
                        downlinkBytes = 0,
                        connectionId = request.connectionId,
                        protocol = "wireguard",
                    ),
                )
                withContext(Dispatchers.IO) {
                    getBackend().setState(tunnel, Tunnel.State.UP, config)
                }
                startHandshakeMonitor()
                val connecting = NativeTunnelStatus(
                    state = NativeTunnelState.CONNECTING,
                    sequence = nextSequence(),
                    uplinkBytes = 0,
                    downlinkBytes = 0,
                    connectionId = request.connectionId,
                    protocol = "wireguard",
                )
                publish(connecting)
                return connecting
            } catch (_: Throwable) {
                val stopped = try {
                    disconnectActiveBackend()
                    true
                } catch (_: Throwable) {
                    false
                }
                val failure = failed(if (stopped) "engine_failed" else "teardown_failed")
                if (stopped) {
                    activeRequest?.configPayload?.fill(0)
                    activeRequest = null
                    handshakeNotBeforeEpochMs = null
                    connectedAtEpochMs = null
                    liveConnectedAtEpochMs = null
                }
                return failure
            } finally {
                request.configPayload.fill(0)
            }
        }

    private suspend fun connectL2tp(request: NativeTunnelRequest): NativeTunnelStatus {
        try {
            disconnectActiveBackend()
            activeRequest?.configPayload?.fill(0)
            activeRequest = request
            handshakeNotBeforeEpochMs = System.currentTimeMillis()
            connectedAtEpochMs = null
            liveConnectedAtEpochMs = null
            val proto = request.protocol.lowercase()

            val payload = try {
                JSONObject(String(request.configPayload, Charsets.UTF_8))
            } catch (_: Throwable) {
                request.configPayload.fill(0)
                activeRequest = null
                return failed("invalid_config")
            }

            publish(
                NativeTunnelStatus(
                    state = NativeTunnelState.PREPARING,
                    sequence = nextSequence(),
                    uplinkBytes = 0,
                    downlinkBytes = 0,
                    connectionId = request.connectionId,
                    protocol = proto,
                ),
            )

            ZagrosVpnService.startService(applicationContext)

            var service = ZagrosVpnService.getInstance()
            var retry = 0
            while (service == null && retry < 20) {
                delay(50)
                service = ZagrosVpnService.getInstance()
                retry++
            }
            if (service == null) {
                activeRequest?.configPayload?.fill(0)
                activeRequest = null
                return failed("engine_failed")
            }

            val cid = request.connectionId
            lastEngineError = null
            liveProtocol = proto
            liveConnectionId = request.connectionId
            val started = service.startL2tpEngine(
                payload,
                onEstablished = {
                    connectedAtEpochMs = System.currentTimeMillis()
                    liveConnectedAtEpochMs = connectedAtEpochMs
                    val label = if (isL2tpIpsecProtocol(proto)) "L2TP/IPsec" else "L2TP"
                    service.updateNotification("Connected to Zagros VPN ($label)")
                    publish(
                        NativeTunnelStatus(
                            state = NativeTunnelState.CONNECTED,
                            sequence = nextSequence(),
                            uplinkBytes = 0,
                            downlinkBytes = 0,
                            connectionId = cid,
                            protocol = proto,
                            connectedAtEpochMs = connectedAtEpochMs,
                        ),
                    )
                },
                onError = { message ->
                    // Keep the engine's own error around so the monitor can fold
                    // it into the failure code for the app's Logs screen.
                    lastEngineError = message
                },
                onClosed = { },
            )
            if (!started) {
                disconnectActiveBackend()
                activeRequest?.configPayload?.fill(0)
                activeRequest = null
                return failed("engine_failed")
            }

            val connecting = NativeTunnelStatus(
                state = NativeTunnelState.CONNECTING,
                sequence = nextSequence(),
                uplinkBytes = 0,
                downlinkBytes = 0,
                connectionId = request.connectionId,
                protocol = proto,
            )
            publish(connecting)
            startSstpMonitor()
            return connecting
        } catch (e: Throwable) {
            Log.e(TAG, "connectL2tp failed: ${e.message}", e)
            disconnectActiveBackend()
            activeRequest?.configPayload?.fill(0)
            activeRequest = null
            return failed("engine_failed")
        } finally {
            request.configPayload.fill(0)
        }
    }

    private suspend fun connectSstp(request: NativeTunnelRequest): NativeTunnelStatus {
        try {
            disconnectActiveBackend()
            activeRequest?.configPayload?.fill(0)
            activeRequest = request
            handshakeNotBeforeEpochMs = System.currentTimeMillis()
            connectedAtEpochMs = null
            liveConnectedAtEpochMs = null
            val proto = request.protocol.lowercase()

            val payload = try {
                JSONObject(String(request.configPayload, Charsets.UTF_8))
            } catch (_: Throwable) {
                request.configPayload.fill(0)
                activeRequest = null
                return failed("invalid_config")
            }

            publish(
                NativeTunnelStatus(
                    state = NativeTunnelState.PREPARING,
                    sequence = nextSequence(),
                    uplinkBytes = 0,
                    downlinkBytes = 0,
                    connectionId = request.connectionId,
                    protocol = proto,
                ),
            )

            ZagrosVpnService.startService(applicationContext)

            var service = ZagrosVpnService.getInstance()
            var retry = 0
            while (service == null && retry < 20) {
                delay(50)
                service = ZagrosVpnService.getInstance()
                retry++
            }
            if (service == null) {
                activeRequest?.configPayload?.fill(0)
                activeRequest = null
                return failed("engine_failed")
            }

            val cid = request.connectionId
            liveProtocol = proto
            liveConnectionId = request.connectionId
            val started = service.startSstpEngine(
                payload,
                onEstablished = {
                    connectedAtEpochMs = System.currentTimeMillis()
                    liveConnectedAtEpochMs = connectedAtEpochMs
                    service.updateNotification("Connected to Zagros VPN (SSTP)")
                    publish(
                        NativeTunnelStatus(
                            state = NativeTunnelState.CONNECTED,
                            sequence = nextSequence(),
                            uplinkBytes = 0,
                            downlinkBytes = 0,
                            connectionId = cid,
                            protocol = proto,
                            connectedAtEpochMs = connectedAtEpochMs,
                        ),
                    )
                },
                onError = { _ ->
                    // The engine already aborted and closed the TUN; the monitor
                    // below finalizes the failed state (engine_died).
                },
                onClosed = { },
            )
            if (!started) {
                disconnectActiveBackend()
                activeRequest?.configPayload?.fill(0)
                activeRequest = null
                return failed("engine_failed")
            }

            val connecting = NativeTunnelStatus(
                state = NativeTunnelState.CONNECTING,
                sequence = nextSequence(),
                uplinkBytes = 0,
                downlinkBytes = 0,
                connectionId = request.connectionId,
                protocol = proto,
            )
            publish(connecting)
            startSstpMonitor()
            return connecting
        } catch (e: Throwable) {
            Log.e(TAG, "connectSstp failed: ${e.message}", e)
            disconnectActiveBackend()
            activeRequest?.configPayload?.fill(0)
            activeRequest = null
            return failed("engine_failed")
        } finally {
            request.configPayload.fill(0)
        }
    }

    private suspend fun connectSe(request: NativeTunnelRequest): NativeTunnelStatus {
        try {
            disconnectActiveBackend()
            activeRequest?.configPayload?.fill(0)
            activeRequest = request
            handshakeNotBeforeEpochMs = System.currentTimeMillis()
            connectedAtEpochMs = null
            liveConnectedAtEpochMs = null
            val proto = request.protocol.lowercase()

            val payload = try {
                JSONObject(String(request.configPayload, Charsets.UTF_8))
            } catch (_: Throwable) {
                request.configPayload.fill(0)
                activeRequest = null
                return failed("invalid_config")
            }

            publish(
                NativeTunnelStatus(
                    state = NativeTunnelState.PREPARING,
                    sequence = nextSequence(),
                    uplinkBytes = 0,
                    downlinkBytes = 0,
                    connectionId = request.connectionId,
                    protocol = proto,
                ),
            )

            ZagrosVpnService.startService(applicationContext)

            var service = ZagrosVpnService.getInstance()
            var retry = 0
            while (service == null && retry < 20) {
                delay(50)
                service = ZagrosVpnService.getInstance()
                retry++
            }
            if (service == null) {
                activeRequest?.configPayload?.fill(0)
                activeRequest = null
                return failed("engine_failed")
            }

            val cid = request.connectionId
            liveProtocol = proto
            liveConnectionId = request.connectionId
            val started = service.startSeEngine(
                payload,
                onEstablished = {
                    connectedAtEpochMs = System.currentTimeMillis()
                    liveConnectedAtEpochMs = connectedAtEpochMs
                    service.updateNotification("Connected to Zagros VPN (SoftEther)")
                    publish(
                        NativeTunnelStatus(
                            state = NativeTunnelState.CONNECTED,
                            sequence = nextSequence(),
                            uplinkBytes = 0,
                            downlinkBytes = 0,
                            connectionId = cid,
                            protocol = proto,
                            connectedAtEpochMs = connectedAtEpochMs,
                        ),
                    )
                },
                onError = { _ ->
                    // The engine aborts and closes the TUN; the monitor finalizes.
                },
                onClosed = { },
                traceSink = { line -> trace(line) },
            )
            if (!started) {
                disconnectActiveBackend()
                activeRequest?.configPayload?.fill(0)
                activeRequest = null
                return failed("engine_failed")
            }

            val connecting = NativeTunnelStatus(
                state = NativeTunnelState.CONNECTING,
                sequence = nextSequence(),
                uplinkBytes = 0,
                downlinkBytes = 0,
                connectionId = request.connectionId,
                protocol = proto,
            )
            publish(connecting)
            startSstpMonitor()
            return connecting
        } catch (e: Throwable) {
            Log.e(TAG, "connectSe failed: ${e.message}", e)
            disconnectActiveBackend()
            activeRequest?.configPayload?.fill(0)
            activeRequest = null
            return failed("engine_failed")
        } finally {
            request.configPayload.fill(0)
        }
    }

    private fun startSstpMonitor() {
        monitorJob?.cancel()
        monitorJob = scope.launch {
            delay(2000L)
            while (isActive) {
                delay(1000L)
                val request = activeRequest ?: break
                if (!isSstpProtocol(request.protocol) && !isRawL2tpProtocol(request.protocol) &&
                    !isL2tpIpsecProtocol(request.protocol) && !isSeProtocol(request.protocol)
                ) break
                val service = ZagrosVpnService.getInstance() ?: break
                val alive = if (isSeProtocol(request.protocol)) service.seEngineAlive()
                else if (isSstpProtocol(request.protocol)) service.sstpEngineAlive()
                else service.l2tpEngineAlive()
                if (!alive) {
                    operationMutex.withLock {
                        val active = activeRequest
                        val detail = if (isRawL2tpProtocol(request.protocol) || isL2tpIpsecProtocol(request.protocol)) {
                            L2tpTrace.errorTokenOrNull()
                                ?: ZagrosVpnService.takeVpnRevokedHint()
                                ?: L2tpTrace.tail(48).ifEmpty { null }
                        } else null
                        disconnectActiveBackend()
                        val failure = failed("engine_died", detail)
                        if (active != null) {
                            active.configPayload.fill(0)
                            activeRequest = null
                            handshakeNotBeforeEpochMs = null
                            connectedAtEpochMs = null
                            liveConnectedAtEpochMs = null
                        }
                        status = failure
                    }
                    break
                }
                val established = if (isSeProtocol(request.protocol)) service.seEngineEstablished()
                else if (isSstpProtocol(request.protocol)) service.sstpEngineEstablished()
                else service.l2tpEngineEstablished()
                if (established) {
                    val tx = if (isSeProtocol(request.protocol)) service.seUplink()
                    else if (isSstpProtocol(request.protocol)) service.sstpUplink()
                    else service.l2tpUplink()
                    val rx = if (isSeProtocol(request.protocol)) service.seDownlink()
                    else if (isSstpProtocol(request.protocol)) service.sstpDownlink()
                    else service.l2tpDownlink()
                    publish(
                        NativeTunnelStatus(
                            state = NativeTunnelState.CONNECTED,
                            sequence = nextSequence(),
                            uplinkBytes = tx,
                            downlinkBytes = rx,
                            connectionId = request.connectionId,
                            protocol = request.protocol,
                            connectedAtEpochMs = connectedAtEpochMs,
                        ),
                    )
                }
            }
        }
    }

    private suspend fun connectOpenVpn(request: NativeTunnelRequest): NativeTunnelStatus {
        val daemon = getOpenVpnDaemon()
        try {
            disconnectActiveBackend()
            activeRequest?.configPayload?.fill(0)
            activeRequest = request
            handshakeNotBeforeEpochMs = System.currentTimeMillis()
            val proto = request.protocol.lowercase()

            publish(
                NativeTunnelStatus(
                    state = NativeTunnelState.PREPARING,
                    sequence = nextSequence(),
                    uplinkBytes = 0,
                    downlinkBytes = 0,
                    connectionId = request.connectionId,
                    protocol = proto,
                ),
            )

            ZagrosVpnService.startService(applicationContext)

            liveProtocol = proto
            liveConnectionId = request.connectionId
            val started = daemon.start(
                configBytes = request.configPayload,
                scope = scope,
                onConnected = {
                    connectedAtEpochMs = System.currentTimeMillis()
                    liveConnectedAtEpochMs = connectedAtEpochMs
                    publish(
                        NativeTunnelStatus(
                            state = NativeTunnelState.CONNECTED,
                            sequence = nextSequence(),
                            uplinkBytes = daemon.getUplink(),
                            downlinkBytes = daemon.getDownlink(),
                            connectionId = request.connectionId,
                            protocol = proto,
                            connectedAtEpochMs = connectedAtEpochMs,
                        ),
                    )
                },
                onStats = { tx, rx ->
                    publish(
                        NativeTunnelStatus(
                            state = if (daemon.isTunnelConnected()) NativeTunnelState.CONNECTED else NativeTunnelState.CONNECTING,
                            sequence = nextSequence(),
                            uplinkBytes = tx,
                            downlinkBytes = rx,
                            connectionId = request.connectionId,
                            protocol = proto,
                            connectedAtEpochMs = connectedAtEpochMs,
                        ),
                    )
                },
            )

            if (started) liveOpenVpnDaemon = getOpenVpnDaemon()
            if (!started) {
                disconnectActiveBackend()
                activeRequest?.configPayload?.fill(0)
                activeRequest = null
                return failed("engine_failed")
            }

            val connecting = NativeTunnelStatus(
                state = NativeTunnelState.CONNECTING,
                sequence = nextSequence(),
                uplinkBytes = 0,
                downlinkBytes = 0,
                connectionId = request.connectionId,
                protocol = proto,
            )
            publish(connecting)
            startOpenVpnMonitor()
            return connecting
        } catch (e: Throwable) {
            Log.e(TAG, "connectOpenVpn failed: ${e.message}", e)
            disconnectActiveBackend()
            activeRequest?.configPayload?.fill(0)
            activeRequest = null
            return failed("engine_failed")
        } finally {
            request.configPayload.fill(0)
        }
    }

    private fun startOpenVpnMonitor() {
        monitorJob?.cancel()
        monitorJob = scope.launch {
            delay(3000L)
            while (isActive) {
                delay(1000L)
                val request = activeRequest ?: break
                if (!isOpenVpnProtocol(request.protocol)) break
                val daemon = getOpenVpnDaemon()
                if (!daemon.isAlive()) {
                    operationMutex.withLock {
                        val active = activeRequest
                        disconnectActiveBackend()
                        val failure = failed("engine_died")
                        if (active != null) {
                            active.configPayload.fill(0)
                            activeRequest = null
                            handshakeNotBeforeEpochMs = null
                            connectedAtEpochMs = null
                            liveConnectedAtEpochMs = null
                        }
                        status = failure
                    }
                    break
                }
            }
        }
    }

    private suspend fun connectSingBox(request: NativeTunnelRequest): NativeTunnelStatus {
        val daemon = getCoreDaemon()
        try {
            disconnectActiveBackend()
            activeRequest?.configPayload?.fill(0)
            activeRequest = request
            handshakeNotBeforeEpochMs = System.currentTimeMillis()
            val proto = request.protocol.lowercase()

            publish(
                NativeTunnelStatus(
                    state = NativeTunnelState.PREPARING,
                    sequence = nextSequence(),
                    uplinkBytes = 0,
                    downlinkBytes = 0,
                    connectionId = request.connectionId,
                    protocol = proto,
                ),
            )

            ZagrosVpnService.startService(applicationContext)

            // The protector must exist before the child dials its first socket
            // (hysteria2/QUIC dials immediately at config load).
            var protectPath: String? = null
            var service0 = ZagrosVpnService.getInstance()
            var wait0 = 0
            while (service0 == null && wait0 < 40) {
                delay(50)
                service0 = ZagrosVpnService.getInstance()
                wait0++
            }
            if (service0 == null) {
                trace("connect: vpn service unavailable; aborting")
                disconnectActiveBackend()
                activeRequest?.configPayload?.fill(0)
                activeRequest = null
                return failed("engine_failed")
            }
            service0.startProtectServer()
            if (service0.protectSelfTestOk != true) {
                trace("connect: protect self-test FAILED [${service0.protectSelfTestDetail}]; aborting")
                disconnectActiveBackend()
                activeRequest?.configPayload?.fill(0)
                activeRequest = null
                return failed("engine_failed")
            }
            trace("protect: self-test OK (abstract channel verified)")
            // Leading NUL => abstract namespace for the Go client.
            protectPath = service0.protectPathValue
            // The VPN + hev bridge must be UP before the child starts so the
            // very first dial (hysteria2 QUIC) can be protected immediately.
            // Settings DNS preset (f53): the app-side tun DNS follows the
            // user's choice; empty/null keeps the platform defaults.
            val tunDnsServers = request.dnsServers
                ?.takeIf { it.isNotEmpty() }
                ?: listOf("1.1.1.1", "8.8.8.8")
            trace("tun dns: " + tunDnsServers.joinToString(","))
            val perAppMode = request.perAppMode ?: "off"
            val perAppPackages = request.perAppPackages ?: emptyList()
            trace("per-app: mode=$perAppMode apps=${perAppPackages.size}")
            val tunEarly = service0.startTunnel(
                socksPort = 20808,
                dnsServers = tunDnsServers,
                perAppMode = perAppMode,
                perAppPackages = perAppPackages,
            )
            if (!tunEarly) {
                trace("connect: early startTunnel failed")
                disconnectActiveBackend()
                activeRequest?.configPayload?.fill(0)
                activeRequest = null
                return failed("engine_failed")
            }
            // hysteria2 (QUIC/UDP) on-device workaround: the exec'd child's
            // protected UDP was observed to never reach the wire on one OEM,
            // while in-process UDP works (v2rayNG). Rewrite the hysteria2
            // outbound to point at an in-process UDP relay and pass the real
            // destination to the relay.
            // f53 fixes, honoring "never harm the other protocols":
            //  1) The rewrite runs ONLY when this connection's protocol IS
            //     hysteria2. TCP connects (vless/vmess/ss/anytls) never touch
            //     this path again — their payload is handed to the engine
            //     byte-for-byte as delivered (the f47-proven behavior).
            //  2) No whole-document JSON round-trip anymore (org.json
            //     re-serialization was both a length hazard — the f52
            //     "rewritten config grew" regression — and needless). The
            //     rewrite is now a targeted in-place splice INSIDE the
            //     hysteria2 outbound slice: server/port values only, and the
            //     freed bytes become JSON whitespace before the slice's
            //     closing brace, so the document length is preserved and
            //     every other byte stays exactly as delivered.
            var relayOk = true
            if (proto == "hysteria2" || proto == "hy2") {
                try {
                    // Socket bind/protect must not run on the main thread.
                    withContext(Dispatchers.IO) {
                        val raw = String(request.configPayload, Charsets.UTF_8)
                        val typeIdx = raw.indexOf("\"type\":\"hysteria2\"")
                        if (typeIdx >= 0) {
                            val objStart = raw.lastIndexOf('{', typeIdx)
                            require(objStart >= 0) { "hy2 outbound object not found" }
                            // Bracket-match the object, honoring string literals.
                            var depth = 0
                            var inStr = false
                            var esc = false
                            var objEnd = -1
                            var i = objStart
                            while (i < raw.length) {
                                val c = raw[i]
                                if (inStr) {
                                    if (esc) esc = false
                                    else if (c == '\\') esc = true
                                    else if (c == '"') inStr = false
                                } else when (c) {
                                    '"' -> inStr = true
                                    '{' -> depth++
                                    '}' -> { depth--; if (depth == 0) { objEnd = i; break } }
                                }
                                i++
                            }
                            require(objEnd > objStart) { "hy2 outbound slice not terminated" }
                            val slice = raw.substring(objStart, objEnd + 1)
                            val host = Regex("\"server\"\\s*:\\s*\"([^\"]+)\"").find(slice)?.groupValues?.get(1) ?: ""
                            val portMatch = Regex("\"server_port\"\\s*:\\s*(\\d+)").find(slice)?.groupValues?.get(1) ?: ""
                            if (host.isNotEmpty() && host != "127.0.0.1" && portMatch.isNotEmpty()) {
                                val port = portMatch.toInt()
                                if (service0.startHy2Relay(20809, host, port)) {
                                    var patched = slice
                                        .replaceFirst("\"server\"\\s*:\\s*\"${Regex.escape(host)}\"",
                                            "\"server\":\"127.0.0.1\"")
                                        .replaceFirst("\"server_port\"\\s*:\\s*$portMatch",
                                            "\"server_port\":20809")
                                    // Keep the byte length EXACTLY: pad the
                                    // freed space as JSON whitespace before
                                    // the closing brace (never grows: an IP
                                    // shrinks more than any port can grow).
                                    if (patched.length < slice.length) {
                                        val pad = " ".repeat(slice.length - patched.length)
                                        patched = patched.substring(0, patched.length - 1) + pad + "}"
                                    }
                                    require(patched.length <= slice.length) {
                                        "rewritten config grew (${patched.length} > ${slice.length})"
                                    }
                                    val sb = StringBuilder(raw)
                                    sb.replace(objStart, objEnd + 1, patched)
                                    val rewritten = sb.toString().toByteArray(Charsets.UTF_8)
                                    require(rewritten.size <= request.configPayload.size) {
                                        "rewritten config grew (${rewritten.size} > ${request.configPayload.size})"
                                    }
                                    java.util.Arrays.fill(request.configPayload, 0.toByte())
                                    java.lang.System.arraycopy(rewritten, 0, request.configPayload, 0, rewritten.size)
                                    for (j in rewritten.size until request.configPayload.size) {
                                        request.configPayload[j] = ' '.code.toByte()
                                    }
                                    trace("hy2 relay: " + host + ":" + port + " -> 127.0.0.1:20809" +
                                        " (" + service0.hy2RelayDetail + ")")
                                } else {
                                    relayOk = false
                                    trace("hy2 relay START FAILED: " + service0.hy2RelayDetail)
                                }
                            }
                        }
                    } // withContext(Dispatchers.IO)
                } catch (e: Throwable) {
                    trace("hy2 relay setup error: ${e.message}")
                    relayOk = false
                }
            }
            if (!relayOk) {
                service0.stopHy2Relay()
                disconnectActiveBackend()
                activeRequest?.configPayload?.fill(0)
                activeRequest = null
                return failed("engine_failed")
            }

            liveProtocol = proto
            liveConnectionId = request.connectionId
            var sbLogLines = 0
            val started = daemon.start(request.configPayload, scope, onLogLine = { line ->
                sbLogLines++
                if (sbLogLines <= 30 || line.contains("ERROR", ignoreCase = true) ||
                    line.contains("FATAL", ignoreCase = true)
                ) {
                    trace("sing-box: " + line.take(240))
                }
            }, protectPath = protectPath)
            if (started) liveCoreDaemon = daemon
            if (!started) {
                disconnectActiveBackend()
                activeRequest?.configPayload?.fill(0)
                activeRequest = null
                return failed("engine_failed")
            }

            delay(150)

            var service = ZagrosVpnService.getInstance()
            var retry = 0
            while (service == null && retry < 20) {
                delay(50)
                service = ZagrosVpnService.getInstance()
                retry++
            }

            if (service == null) {
                disconnectActiveBackend()
                activeRequest?.configPayload?.fill(0)
                activeRequest = null
                return failed("engine_failed")
            }

            connectedAtEpochMs = System.currentTimeMillis()
            liveConnectedAtEpochMs = connectedAtEpochMs
            val connected = NativeTunnelStatus(
                state = NativeTunnelState.CONNECTED,
                sequence = nextSequence(),
                uplinkBytes = 0,
                downlinkBytes = 0,
                connectionId = request.connectionId,
                protocol = proto,
                connectedAtEpochMs = connectedAtEpochMs,
            )
            publish(connected)
            startSingBoxMonitor()
            return connected
        } catch (e: Throwable) {
            Log.e(TAG, "connectSingBox failed: ${e.message}", e)
            disconnectActiveBackend()
            activeRequest?.configPayload?.fill(0)
            activeRequest = null
            return failed("engine_failed")
        } finally {
            request.configPayload.fill(0)
        }
    }

    private fun startSingBoxMonitor() {
        monitorJob?.cancel()
        var sbZeroTicks = 0L
        var healthTicks = 0L
        monitorJob = scope.launch {
            while (isActive) {
                delay(1000L)
                val request = activeRequest ?: break
                if (!isSingBoxProtocol(request.protocol) && (request.protocol.lowercase() != "wireguard" || (request.engine.lowercase() != "sing-box" && request.engine.lowercase() != "singbox"))) break
                val daemon = getCoreDaemon()
                val isRunning = daemon.isAlive() && TProxyService.TProxyIsRunning()
                if (!isRunning) {
                    operationMutex.withLock {
                        val active = activeRequest
                        disconnectActiveBackend()
                        val failure = failed("engine_died")
                        if (active != null) {
                            active.configPayload.fill(0)
                            activeRequest = null
                            handshakeNotBeforeEpochMs = null
                            connectedAtEpochMs = null
                            liveConnectedAtEpochMs = null
                        }
                        status = failure
                    }
                    break
                }
                healthTicks += 1
                if (healthTicks % 10L == 0L) {
                    val svc = ZagrosVpnService.getInstance()
                    trace("health: protect(ok=" + (svc?.protectedFdCount ?: 0L) +
                        ",fail=" + (svc?.failedProtectFdCount ?: 0L) +
                        ") vpnUp=" + (svc?.isVpnUp ?: false) +
                        " relay(up=" + (svc?.hy2RelayUpstreamBytes ?: 0L) +
                        ",down=" + (svc?.hy2RelayDownstreamBytes ?: 0L) +
                        ",lport=" + (svc?.hy2RelayLocalPort ?: -1) + ")" +
                        " udpecho(sz=" + (svc?.hy2ProbeSizeStats ?: "?") +
                        "," + (svc?.hy2ProbeDetail ?: "?") + ")" +
                        " relaysizes=" + (svc?.hy2RelaySentSizes ?: "?"))
                }
                val stats = TProxyService.TProxyGetStats()
                val tx = stats?.getOrNull(1) ?: 0L
                val rx = stats?.getOrNull(3) ?: 0L
                if (tx == 0L && rx == 0L) {
                    sbZeroTicks++
                    if (sbZeroTicks == 15L) {
                        trace("hev: 0 bytes through TUN after 15s of CONNECTED (app traffic is not entering the VPN interface)")
                    }
                } else {
                    sbZeroTicks = 0L
                }
                val next = NativeTunnelStatus(
                    state = NativeTunnelState.CONNECTED,
                    sequence = nextSequence(),
                    uplinkBytes = tx,
                    downlinkBytes = rx,
                    connectionId = request.connectionId,
                    protocol = request.protocol,
                    connectedAtEpochMs = connectedAtEpochMs,
                )
                publish(next)
            }
        }
    }

    override suspend fun disconnect(reason: String): NativeTunnelStatus =
        operationMutex.withLock {
            if (!SAFE_REASON.matches(reason)) return@withLock rejected("invalid_disconnect_reason")
            monitorJob?.cancel()
            monitorJob = null
            trace("disconnect: requested (reason=$reason, hasActive=${activeRequest != null})")
            val request = activeRequest
            if (request == null) {
                // A fresh plugin instance (app relaunched after the activity
                // was swiped away) has no activeRequest even though the
                // previous instance's tunnel is still live. Tear the REAL
                // tunnel down instead of only reporting disconnected.
                withContext(Dispatchers.IO) {
                    val svc = ZagrosVpnService.getInstance()
                    try { svc?.stopSeEngine() } catch (_: Throwable) {}
                    try { svc?.stopSstpEngine() } catch (_: Throwable) {}
                    try { svc?.stopL2tpEngine() } catch (_: Throwable) {}
                    try { liveCoreDaemon?.takeIf { it.isAlive() }?.stop() } catch (_: Throwable) {}
                    // A relaunched instance has liveCoreDaemon == null; the
                    // fresh daemon still kills the orphaned child via pid file.
                    try { getCoreDaemon().stop() } catch (_: Throwable) {}
                    try { liveOpenVpnDaemon?.takeIf { it.isAlive() }?.stop() } catch (_: Throwable) {}
                    try { svc?.stopProtectServer() } catch (_: Throwable) {}
                    try { svc?.stopTunnel() } catch (_: Throwable) {}
                    try { ZagrosVpnService.stopService(applicationContext) } catch (_: Throwable) {}
                }
                liveCoreDaemon = null
                liveOpenVpnDaemon = null
                liveProtocol = null
                liveConnectionId = null
                liveConnectedAtEpochMs = null
                trace("disconnect: pre-existing tunnel teardown completed")
                return@withLock disconnected(nextSequence()).also(::publish)
            }
            val currentProtocol = request.protocol
            publish(
                NativeTunnelStatus(
                    state = NativeTunnelState.DISCONNECTING,
                    sequence = nextSequence(),
                    uplinkBytes = status.uplinkBytes,
                    downlinkBytes = status.downlinkBytes,
                    connectionId = request.connectionId,
                    protocol = currentProtocol,
                ),
            )
            return@withLock try {
                disconnectActiveBackend()
                request.configPayload.fill(0)
                activeRequest = null
                handshakeNotBeforeEpochMs = null
                connectedAtEpochMs = null
                liveConnectedAtEpochMs = null
                liveProtocol = null
                liveConnectionId = null
                liveConnectedAtEpochMs = null
                disconnected(nextSequence()).also(::publish)
            } catch (_: Throwable) {
                failed("disconnect_failed")
            }
        }

    private suspend fun requestVpnConsent(): Boolean {
        val intent = VpnService.prepare(applicationContext) ?: return true
        val activity = activityBinding?.activity ?: return false
        return suspendCancellableCoroutine { continuation ->
            if (consentContinuation != null) {
                continuation.resume(false)
                return@suspendCancellableCoroutine
            }
            consentContinuation = continuation
            continuation.invokeOnCancellation {
                if (consentContinuation === continuation) consentContinuation = null
            }
            try {
                activity.startActivityForResult(intent, VPN_PERMISSION_REQUEST)
            } catch (_: Throwable) {
                consentContinuation = null
                continuation.resume(false)
            }
        }
    }

    private fun isSingBoxProtocol(protocol: String): Boolean =
        SINGBOX_PROTOCOLS.contains(protocol.lowercase())

    private fun isOpenVpnProtocol(protocol: String): Boolean =
        OPENVPN_PROTOCOLS.contains(protocol.lowercase())

    private fun isSstpProtocol(protocol: String): Boolean =
        SSTP_PROTOCOLS.contains(protocol.lowercase())

    private fun isRawL2tpProtocol(protocol: String): Boolean =
        RAW_L2TP_PROTOCOLS.contains(protocol.lowercase())

    private fun isL2tpIpsecProtocol(protocol: String): Boolean =
        IPSEC_L2TP_PROTOCOLS.contains(protocol.lowercase())

    private fun isSeProtocol(protocol: String): Boolean =
        SE_PROTOCOLS.contains(protocol.lowercase())

    private fun validateRequest(request: NativeTunnelRequest): String? {
        val proto = request.protocol.lowercase()
        val eng = request.engine.lowercase()
        if (proto == "wireguard" && (eng == "wireguard" || eng == "singbox" || eng == "sing-box" || eng.isEmpty())) {
            // ok
        } else if (isSingBoxProtocol(proto)) {
            // ok
        } else if (isOpenVpnProtocol(proto)) {
            // ok
        } else if (isSstpProtocol(proto)) {
            if (eng.isNotEmpty() && eng != "sstp") return "protocol_unavailable"
        } else if (isRawL2tpProtocol(proto)) {
            if (eng.isNotEmpty() && eng != "l2tp") return "protocol_unavailable"
        } else if (isL2tpIpsecProtocol(proto)) {
            if (eng.isNotEmpty() && eng != "l2tp-ipsec") return "protocol_unavailable"
        } else if (isSeProtocol(proto)) {
            if (eng.isNotEmpty() && eng != "softether") return "protocol_unavailable"
        } else {
            return "protocol_unavailable"
        }

        if (!SAFE_ID.matches(request.requestId) || !SAFE_ID.matches(request.connectionId)) {
            return "invalid_request"
        }
        if (request.configPayload.isEmpty() || request.configPayload.size > MAX_CONFIG_BYTES) {
            return "invalid_config"
        }
        if (!getCapabilities().protocols.contains(proto)) return "backend_unavailable"
        return null
    }

    private fun getBackend(): Backend {
        backend?.let { return it }
        return GoBackend(applicationContext).also { backend = it }
    }

    private fun getCoreDaemon(): ZagrosCoreDaemon {
        // Re-attach (swipe -> relaunch): a fresh instance must reuse the
        // still-running sing-box process of the previous instance, otherwise
        // status/disconnect silently lose the live tunnel.
        liveCoreDaemon?.takeIf { it.isAlive() }?.let { coreDaemon = it; return it }
        coreDaemon?.let { return it }
        return ZagrosCoreDaemon(applicationContext).also { coreDaemon = it }
    }

    private fun getOpenVpnDaemon(): ZagrosOpenVpnDaemon {
        liveOpenVpnDaemon?.takeIf { it.isAlive() }?.let { openvpnDaemon = it; return it }
        openvpnDaemon?.let { return it }
        return ZagrosOpenVpnDaemon(applicationContext).also { openvpnDaemon = it }
    }

    private suspend fun disconnectActiveBackend() {
        try {
            ZagrosVpnService.getInstance()?.stopHy2Relay()
        } catch (_: Throwable) {
        }
        try {
            openvpnDaemon?.stop()
        } catch (_: Throwable) {
        }
        try {
            ZagrosVpnService.getInstance()?.stopSstpEngine()
        } catch (_: Throwable) {
        }
        try {
            ZagrosVpnService.getInstance()?.stopL2tpEngine()
        } catch (_: Throwable) {
        }
        try {
            ZagrosVpnService.getInstance()?.stopSeEngine()
        } catch (_: Throwable) {
        }
        try {
            ZagrosVpnService.getInstance()?.stopTunnel()
        } catch (_: Throwable) {
        }
        try {
            coreDaemon?.stop()
        } catch (_: Throwable) {
        }
        try {
            liveCoreDaemon?.takeIf { it !== coreDaemon }?.stop()
        } catch (_: Throwable) {
        }
        try {
            liveOpenVpnDaemon?.takeIf { it !== openvpnDaemon }?.stop()
        } catch (_: Throwable) {
        }
        try {
            ZagrosVpnService.stopService(applicationContext)
        } catch (_: Throwable) {
        }
        val engine = backend ?: return
        withContext(Dispatchers.IO) {
            if (engine.getState(tunnel) == Tunnel.State.UP) {
                engine.setState(tunnel, Tunnel.State.DOWN, null)
            }
        }
    }

    private fun startHandshakeMonitor() {
        monitorJob?.cancel()
        monitorJob = scope.launch {
            repeat(HANDSHAKE_POLLS) {
                delay(HANDSHAKE_POLL_MS)
                val request = activeRequest ?: return@launch
                val engine = backend ?: return@launch
                try {
                    val statistics = withContext(Dispatchers.IO) { engine.getStatistics(tunnel) }
                    val handshakeThreshold = handshakeNotBeforeEpochMs ?: Long.MAX_VALUE
                    val established = statistics.peers().any { peer ->
                        (statistics.peer(peer)?.latestHandshakeEpochMillis ?: 0) >= handshakeThreshold
                    }
                    val next = NativeTunnelStatus(
                        state = if (established) NativeTunnelState.CONNECTED else NativeTunnelState.CONNECTING,
                        sequence = nextSequence(),
                        uplinkBytes = statistics.totalTx(),
                        downlinkBytes = statistics.totalRx(),
                        connectionId = request.connectionId,
                        protocol = "wireguard",
                        connectedAtEpochMs = if (established) {
                            connectedAtEpochMs ?: System.currentTimeMillis().also { connectedAtEpochMs = it }
                        } else null,
                    )
                    publish(next)
                    if (established) return@launch
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Throwable) {
                    operationMutex.withLock {
                        val active = activeRequest
                        val stopped = try {
                            disconnectActiveBackend()
                            true
                        } catch (_: Throwable) {
                            false
                        }
                        val failure = failed(if (stopped) "status_failed" else "teardown_failed")
                        if (stopped) {
                            active?.configPayload?.fill(0)
                            activeRequest = null
                            handshakeNotBeforeEpochMs = null
                            connectedAtEpochMs = null
                            liveConnectedAtEpochMs = null
                        }
                        status = failure
                    }
                    return@launch
                }
            }

            operationMutex.withLock {
                val request = activeRequest ?: return@withLock
                val stopped = try {
                    disconnectActiveBackend()
                    true
                } catch (_: Throwable) {
                    false
                }
                val failure = failed(if (stopped) "handshake_timeout" else "teardown_failed")
                if (stopped) {
                    request.configPayload.fill(0)
                    activeRequest = null
                    handshakeNotBeforeEpochMs = null
                    connectedAtEpochMs = null
                    liveConnectedAtEpochMs = null
                }
                status = failure
            }
        }
    }

    private fun publish(next: NativeTunnelStatus) {
        status = next
        val api = flutterApi ?: return
        scope.launch {
            try {
                api.onStatusChanged(next)
            } catch (_: Throwable) {
            }
        }
    }

    /** Fire-and-forget diagnostics line to the Dart Logs tab (SeTrace). */
    private fun trace(msg: String) {
        val line = "trace: ${msg.take(300)}"
        Log.i(TAG, line)
        val ch = traceChannel ?: return
        scope.launch(Dispatchers.Main.immediate) {
            try {
                ch.invokeMethod("onLog", mapOf("line" to line))
            } catch (_: Throwable) {
            }
        }
    }

    private fun rejected(code: String): Nothing = throw FlutterError(
        code = code,
        message = "The Android tunnel request was rejected safely.",
    )

    @Volatile
    private var lastEngineError: String? = null

    private fun failed(code: String, detail: String? = null): NativeTunnelStatus {
        var full = code
        if (detail != null) {
            // The Dart layer only lets through sanitized failure codes
            // (^[a-z][a-z0-9_]{0,63}$), so the raw engine error is folded into
            // the code itself to make it visible in the app's Logs screen.
            val sanitized = detail.lowercase().replace(Regex("[^a-z0-9]+"), "_").trim('_')
            if (sanitized.isNotEmpty()) full = "${code}_$sanitized".take(64)
        }
        return NativeTunnelStatus(
            state = NativeTunnelState.FAILED,
            sequence = nextSequence(),
            uplinkBytes = status.uplinkBytes.coerceAtLeast(0),
            downlinkBytes = status.downlinkBytes.coerceAtLeast(0),
            connectionId = activeRequest?.connectionId,
            protocol = activeRequest?.protocol,
            failureCode = full,
            safeFailureMessage = "The Android tunnel failed safely.",
        ).also(::publish)
    }

    private fun nextSequence(): Long = sequenceCounter.incrementAndGet()

    companion object {
        private const val TAG = "ZagrosTunnelPlugin"
        private const val TUNNEL_NAME = "zagros0"
        private const val TRACE_CHANNEL_NAME = "zagros/tunnel_log"
        private const val APPMGR_CHANNEL_NAME = "zagros/appmgr"

        // Live engine handles survive FlutterEngine re-attach: a swiped-away
        // activity destroys the engine but not the running tunnel; the next
        // plugin instance reuses these instead of losing the processes.
        @Volatile var liveCoreDaemon: ZagrosCoreDaemon? = null
        @Volatile var liveOpenVpnDaemon: ZagrosOpenVpnDaemon? = null
        @Volatile var liveProtocol: String? = null
        @Volatile var liveConnectionId: String? = null
        @Volatile var liveConnectedAtEpochMs: Long? = null
        @Volatile var lastProbeTrace: String? = null

        // Sequence is process-wide: a FlutterEngine re-attach creates a fresh
        // plugin instance, but the Dart adapter validates monotonic sequences
        // — a per-instance counter would restart at 0 and be rejected.
        val sequenceCounter = AtomicLong(0)
        private const val VPN_PERMISSION_REQUEST = 48120
        private const val MAX_CONFIG_BYTES = 256 * 1024
        private const val HANDSHAKE_POLLS = 40
        private const val HANDSHAKE_POLL_MS = 500L
        private val SAFE_ID = Regex("^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
        private val SAFE_REASON = Regex("^[a-z0-9_]{1,64}$")
        val SINGBOX_PROTOCOLS = listOf(
            "vless", "vmess", "trojan", "shadowsocks", "ss", "hysteria2", "hy2", "tuic", "ssh", "anytls",
        )
        val OPENVPN_PROTOCOLS = listOf(
            "openvpn", "ovpn",
        )
    val SSTP_PROTOCOLS = listOf(
            "sstp",
        )
    val RAW_L2TP_PROTOCOLS = listOf(
            "l2tp_raw",
        )
    val IPSEC_L2TP_PROTOCOLS = listOf(
            "l2tp",
        )
    val SE_PROTOCOLS = listOf(
            "softether",
        )

        private fun disconnected(sequence: Long) = NativeTunnelStatus(
            state = NativeTunnelState.DISCONNECTED,
            sequence = sequence,
            uplinkBytes = 0,
            downlinkBytes = 0,
        )
    }
}
