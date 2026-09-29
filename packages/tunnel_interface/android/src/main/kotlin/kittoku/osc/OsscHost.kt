package kittoku.osc

import android.net.VpnService
import kotlinx.coroutines.CoroutineScope
import java.net.Socket

/**
 * Integration host interface for embedding the Open SSTP Client engine
 * (https://github.com/kittoku/Open-SSTP-Client, MIT) into the Zagros VPN
 * tunnel runtime.
 *
 * Proprietary glue (C) 2026 Zagros. The upstream MIT engine itself stays in
 * the kittoku.osc package; only this interface and MapSharedPreferences are
 * original integration code.
 */
internal interface OsscHost {
    /** Scope on which every engine coroutine is launched. */
    val scope: CoroutineScope

    /** Connection-scoped preference values backing the upstream accessors. */
    val prefs: android.content.SharedPreferences

    /** A fresh VpnService.Builder owned by the active foreground VpnService. */
    fun vpnBuilder(): VpnService.Builder

    /** Marks the SSTP socket to bypass the VPN tunnel (VpnService.protect). */
    fun protectSocket(socket: Socket): Boolean

    /** Marks the L2TP UDP socket to bypass the VPN tunnel. */
    fun protectDatagram(socket: java.net.DatagramSocket): Boolean = false

    /** Packages excluded from the TUN (the VPN app itself; kill-switch parity). */
    val disallowedPackages: List<String>

    /** Optional server-certificate SHA-256 pin (hex, case-insensitive). */
    val certSha256Pin: String?

    /** Engine log line (already redacted upstream: no credentials are logged). */
    fun onLog(message: String) {}

    /** Called exactly once when the PPP/IPCP negotiation completed and the TUN is up. */
    fun onEstablished()

    /** Called on any engine error after a clean abort. */
    fun onError(message: String)

    /** Called when the engine fully released all resources. */
    fun onClose()

    /** TUN byte counters (tx = written into tunnel, rx = read from tunnel). */
    fun countTunnelBytes(tx: Int, rx: Int)
}
