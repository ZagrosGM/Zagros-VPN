package ai.zagros.tunnel

import android.content.SharedPreferences
import android.net.VpnService
import android.util.Log
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kittoku.osc.MapSharedPreferences
import kittoku.osc.OsscHost
import kittoku.osc.SharedBridge
import kittoku.osc.control.Controller
import kittoku.osc.preference.AUTH_PROTOCOL_MSCHAPv2
import kittoku.osc.preference.OscPrefKey
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONObject

/**
 * Embedded SSTP engine host built on the MIT-licensed Open SSTP Client core
 * (third_party/sstp-client, pinned by digest). The engine runs PPP entirely in
 * userspace (no /dev/ppp), establishes the TUN through the enclosing
 * VpnService, and protects its own socket against routing loops.
 *
 * Security posture:
 *  - MS-CHAPv2 only (PAP is never offered);
 *  - TLS verification with an optional server-certificate SHA-256 pin carried
 *    in the panel-rendered config ("tls_sha256" option);
 *  - the TUN default route plus the self-package exclusion preserve the
 *    crash kill-switch semantics (no silent cleartext fallback).
 */
class ZagrosSstpEngine(private val service: ZagrosVpnService) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val isRunning = AtomicBoolean(false)
    private val stopRequested = AtomicBoolean(false)
    private val uplinkBytes = AtomicLong(0)
    private val downlinkBytes = AtomicLong(0)

    @Volatile private var established = false
    private var controller: Controller? = null

    fun isAlive(): Boolean = isRunning.get()
    fun isEstablished(): Boolean = isRunning.get() && established
    fun getUplink(): Long = uplinkBytes.get()
    fun getDownlink(): Long = downlinkBytes.get()

    /**
     * @param payload panel-rendered SSTP config:
     *   {server, port, username, password, options:{tls_sha256?, dns?}}
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
        // The Dart encoder spreads driver options at the top level; accept a
        // nested "options" object as well for forward compatibility.
        val options = payload.optJSONObject("options") ?: JSONObject()
        val pin = sequenceOf(payload.optString("tls_sha256", ""), options.optString("tls_sha256", ""))
            .map { it.trim() }.firstOrNull { it.isNotEmpty() }?.ifEmpty { null }
        val customDns = sequenceOf(payload.optString("dns", ""), options.optString("dns", ""))
            .map { it.trim() }.firstOrNull { it.isNotEmpty() }?.ifEmpty { null }

        if (server.isEmpty() || username.isEmpty() || password.isEmpty()) {
            Log.w(TAG, "SSTP config incomplete (server/user/pass required)")
            return false
        }
        if (pin != null && !Regex("^[0-9a-fA-F: ]{64,70}$").matches(pin)) {
            Log.w(TAG, "SSTP tls_sha256 pin format invalid")
            return false
        }
        if (port !in 1..65535) {
            Log.w(TAG, "SSTP port out of range")
            return false
        }

        stop()
        stopRequested.set(false)
        established = false

        val prefs = MapSharedPreferences(
            mapOf(
                OscPrefKey.HOME_HOSTNAME to server,
                OscPrefKey.SSL_PORT to port,
                OscPrefKey.HOME_USERNAME to username,
                OscPrefKey.HOME_PASSWORD to password,
                OscPrefKey.PPP_MRU to DEFAULT_TUNNEL_MTU,
                OscPrefKey.PPP_MTU to DEFAULT_TUNNEL_MTU,
                OscPrefKey.PPP_AUTH_PROTOCOLS to setOf(AUTH_PROTOCOL_MSCHAPv2),
                OscPrefKey.PPP_IPv4_ENABLED to true,
                OscPrefKey.PPP_IPv6_ENABLED to false,
                // TLS: certificate pin when provided, otherwise system CAs only.
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
            override val scope: CoroutineScope = this@ZagrosSstpEngine.scope
            override val prefs: SharedPreferences = prefs
            override val disallowedPackages: List<String> = listOf(service.packageName)
            override val certSha256Pin: String? = pin

            override fun vpnBuilder(): VpnService.Builder = service.Builder()

            override fun protectSocket(socket: Socket): Boolean {
                return try {
                    service.protect(socket)
                } catch (_: Throwable) {
                    false
                }
            }

            override fun onLog(message: String) {
                Log.i(TAG, "osc: ${message.take(LOG_LINE_LIMIT)}")
            }

            override fun onEstablished() {
                established = true
                Log.i(TAG, "SSTP engine established (TUN up)")
                onEstablished()
            }

            override fun onError(message: String) {
                Log.w(TAG, "SSTP engine error: ${message.take(LOG_LINE_LIMIT)}")
                onError(message)
            }

            override fun onClose() {
                val intentional = stopRequested.get()
                isRunning.set(false)
                Log.i(TAG, "SSTP engine closed (intentional=$intentional)")
                if (!intentional) {
                    onError("engine_stopped")
                }
                onClosed()
            }

            override fun countTunnelBytes(tx: Int, rx: Int) {
                if (tx > 0) uplinkBytes.addAndGet(tx.toLong())
                if (rx > 0) downlinkBytes.addAndGet(rx.toLong())
            }
        }

        val bridge = SharedBridge(host)
        onClosedCallback = onClosed
        controller = Controller(bridge).also {
            isRunning.set(true)
            it.launchJobMain()
        }

        // Deterministic failure if the handshake never completes.
        scope.launch {
            delay(CONNECT_TIMEOUT_MS)
            if (isRunning.get() && !established) {
                Log.w(TAG, "SSTP connect timeout")
                stop()
            }
        }

        return true
    }

    fun stop() {
        if (!isRunning.get()) return
        stopRequested.set(true)
        try {
            controller?.disconnect()
        } catch (_: Throwable) {
        }
        // onClose() finalizes state once the controller drains; force it if hung.
        scope.launch {
            delay(FORCE_STOP_DELAY_MS)
            if (isRunning.get()) {
                isRunning.set(false)
                Log.w(TAG, "SSTP engine force-stopped")
                onClosedCallback()
            }
        }
    }

    private var onClosedCallback: () -> Unit = {}

    /** Final teardown when the enclosing service is destroyed. */
    fun destroy() {
        stop()
        scope.cancel()
    }

    companion object {
        private const val TAG = "ZagrosSstpEngine"
        private const val DEFAULT_TUNNEL_MTU = 1500
        private const val CONNECT_TIMEOUT_MS = 60_000L
        private const val FORCE_STOP_DELAY_MS = 3_000L
        private const val LOG_LINE_LIMIT = 400
    }
}
