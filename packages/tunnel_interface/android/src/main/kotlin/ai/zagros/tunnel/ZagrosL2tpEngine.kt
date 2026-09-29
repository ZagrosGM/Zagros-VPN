package ai.zagros.tunnel

import android.content.SharedPreferences
import android.net.VpnService
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kittoku.osc.MapSharedPreferences
import kittoku.osc.OsscHost
import kittoku.osc.SharedBridge
import kittoku.osc.preference.AUTH_PROTOCOL_MSCHAPv2
import kittoku.osc.preference.OscPrefKey
import ai.zagros.tunnel.l2tp.L2tpController
import ai.zagros.tunnel.l2tp.L2tpTerminal
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import ai.zagros.tunnel.l2tp.L2tpTrace
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONObject

/**
 * Raw-L2TP engine host. Reuses the MIT-licensed (kittoku) userspace PPP stack
 * — the exact code path already validated against the SoftEther server over
 * MS-SSTP — over an L2TP/UDP medium implemented in ai.zagros.tunnel.l2tp.
 *
 * Raw L2TP carries NO encryption (the panel flags this in the config payload);
 * authentication is MS-CHAPv2 only. The TUN default route plus the
 * self-package exclusion preserve the crash kill-switch semantics.
 */
class ZagrosL2tpEngine(private val service: ZagrosVpnService) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val isRunning = AtomicBoolean(false)
    private val stopRequested = AtomicBoolean(false)
    private val sessionGeneration = AtomicLong(0)
    private val uplinkBytes = AtomicLong(0)
    private val downlinkBytes = AtomicLong(0)

    @Volatile private var established = false
    private var controller: L2tpController? = null
    private var terminal: L2tpTerminal? = null

    fun isAlive(): Boolean = isRunning.get()
    fun isEstablished(): Boolean = isRunning.get() && established
    fun getUplink(): Long = uplinkBytes.get()
    fun getDownlink(): Long = downlinkBytes.get()

    /**
     * @param payload panel-rendered raw-L2TP config:
     *   {server, port, username, password, options:{dns?}}
     * @return false when the payload is invalid (never fakes a connection).
     */
    fun start(
        payload: JSONObject,
        onEstablished: () -> Unit,
        onError: (String) -> Unit,
        onClosed: () -> Unit,
    ): Boolean {
        val server = payload.optString("server").trim()
        val port = payload.optInt("port", 1701)
        val username = payload.optString("username")
        val password = payload.optString("password")
        val options = payload.optJSONObject("options") ?: JSONObject()
        val customDns = sequenceOf(payload.optString("dns", ""), options.optString("dns", ""))
            .map { it.trim() }.firstOrNull { it.isNotEmpty() }?.ifEmpty { null }

        // L2TP/IPsec (panel protocol "l2tp"): the driver payload carries
        // format=l2tp-ipsec + ipsec_psk. Raw L2TP payloads never carry a PSK.
        val format = payload.optString("format", "").trim()
        val ipsecPsk = sequenceOf(
            payload.optString("ipsec_psk", ""),
            payload.optString("psk", ""),
            options.optString("ipsec_psk", ""),
        ).map { it.trim() }.firstOrNull { it.isNotEmpty() }?.ifEmpty { null }
        val ipsecMode = format == "l2tp-ipsec" || ipsecPsk != null
        if (ipsecMode && ipsecPsk == null) {
            Log.w(TAG, "L2TP/IPsec config missing ipsec_psk")
            return false
        }
        val pppMtu = if (ipsecMode) IPSEC_L2TP_MTU else RAW_L2TP_MTU

        if (server.isEmpty() || username.isEmpty() || password.isEmpty()) {
            Log.w(TAG, "L2TP config incomplete (server/user/pass required)")
            return false
        }
        if (port !in 1..65535) {
            Log.w(TAG, "L2TP port out of range")
            return false
        }

        stop()
        stopRequested.set(false)
        established = false
        sessionGeneration.incrementAndGet()
        L2tpTrace.reset()
        L2tpTrace.mark("start")

        val prefs = MapSharedPreferences(
            mapOf(
                // kittoku reads HOME_USERNAME/HOME_PASSWORD at SharedBridge
                // construction; omitting them silently authenticated with empty
                // credentials (MS-CHAPv2 ChapFailure on a real device).
                OscPrefKey.HOME_USERNAME to username,
                OscPrefKey.HOME_PASSWORD to password,
                OscPrefKey.PPP_MRU to pppMtu,
                OscPrefKey.PPP_MTU to pppMtu,
                OscPrefKey.PPP_AUTH_PROTOCOLS to setOf(AUTH_PROTOCOL_MSCHAPv2),
                OscPrefKey.PPP_IPv4_ENABLED to true,
                OscPrefKey.PPP_IPv6_ENABLED to false,
                OscPrefKey.PPP_AUTH_TIMEOUT to 10,
                OscPrefKey.ROUTE_DO_ENABLE_APP_BASED_RULE to true,
                OscPrefKey.ROUTE_APP_LIST_TYPE to "Disallowed Apps",
                OscPrefKey.ROUTE_DO_ADD_DEFAULT_ROUTE to true,
                OscPrefKey.ROUTE_DO_ROUTE_PRIVATE_ADDRESSES to false,
                OscPrefKey.ROUTE_DO_ADD_CUSTOM_ROUTES to false,
                OscPrefKey.ROUTE_CUSTOM_ROUTES to "",
                OscPrefKey.DNS_DO_USE_CUSTOM_SERVER to (customDns != null),
                OscPrefKey.DNS_CUSTOM_ADDRESS to (customDns ?: ""),
            ),
        )

        val host = object : OsscHost {
            override val scope: CoroutineScope = this@ZagrosL2tpEngine.scope
            override val prefs: SharedPreferences = prefs
            override val disallowedPackages: List<String> = listOf(service.packageName)
            override val certSha256Pin: String? = null

            override fun vpnBuilder(): VpnService.Builder = service.Builder()

            override fun protectSocket(socket: java.net.Socket): Boolean = true

            override fun protectDatagram(socket: java.net.DatagramSocket): Boolean {
                return try {
                    service.protect(socket)
                } catch (_: Throwable) {
                    false
                }
            }

            override fun onLog(message: String) {
                Log.i(TAG, "l2tp: ${message.take(LOG_LINE_LIMIT)}")
            }

            override fun onEstablished() {
                established = true
                Log.i(TAG, "L2TP engine established (TUN up)")
                onEstablished()
            }

            override fun onError(message: String) {
                L2tpTrace.mark("err")
                L2tpTrace.markError(message)
                Log.w(TAG, "L2TP engine error: ${message.take(LOG_LINE_LIMIT)}")
                onError(message)
            }

            override fun onClose() {
                val intentional = stopRequested.get()
                Log.i(TAG, "L2TP engine closed (intentional=$intentional)")
                if (!intentional) {
                    // Surface BEFORE isRunning drops: the plugin monitor reacts
                    // to isRunning=false and must be able to read the reason.
                    L2tpTrace.mark("closed_unexpected")
                    onError("engine_stopped")
                }
                isRunning.set(false)
                onClosed()
            }

            override fun countTunnelBytes(tx: Int, rx: Int) {
                if (tx > 0) uplinkBytes.addAndGet(tx.toLong())
                if (rx > 0) downlinkBytes.addAndGet(rx.toLong())
            }
        }

        val bridge = SharedBridge(host)
        onClosedCallback = onClosed

        val l2tpTerminal = L2tpTerminal(bridge).also {
            bridge.sslTerminal = it
            terminal = it
            if (ipsecMode) it.ipsecPsk = ipsecPsk!!.toByteArray(Charsets.UTF_8)
        }
        val controller = L2tpController(bridge, l2tpTerminal).also {
            this.controller = it
            isRunning.set(true)
            it.launchJobMain(server, port, server)
        }

        // Deterministic failure if negotiation never completes.
        scope.launch {
            delay(CONNECT_TIMEOUT_MS)
            if (isRunning.get() && !established) {
                Log.w(TAG, "L2TP connect timeout")
                L2tpTrace.mark("watchdog_timeout")
                stop()
            }
        }

        return true
    }

    private var onClosedCallback: () -> Unit = {}

    fun stop() {
        if (!isRunning.get()) return
        stopRequested.set(true)
        try {
            controller?.disconnect()
        } catch (_: Throwable) {
        }
        val gen = sessionGeneration.get()
        scope.launch {
            delay(FORCE_STOP_DELAY_MS)
            // Generation guard: a stale timer from a previous session must
            // never kill the current one (a silent +3s engine_died).
            if (isRunning.get() && sessionGeneration.get() == gen) {
                isRunning.set(false)
                L2tpTrace.mark("force_stopped")
                Log.w(TAG, "L2TP engine force-stopped")
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
        private const val TAG = "ZagrosL2tpEngine"
        private const val RAW_L2TP_MTU = 1400
        // ESP-in-UDP overhead (SPI+seq+IV+ICV+pad+UDP+IP) ≈ 60B; keep PPP
        // frames comfortably inside the typical 1400B path MTU.
        private const val IPSEC_L2TP_MTU = 1360
        private const val CONNECT_TIMEOUT_MS = 60_000L
        private const val FORCE_STOP_DELAY_MS = 3_000L
        private const val LOG_LINE_LIMIT = 400
    }
}
