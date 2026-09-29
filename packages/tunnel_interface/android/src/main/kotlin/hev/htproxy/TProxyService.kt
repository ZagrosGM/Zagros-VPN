package hev.htproxy

import android.util.Log

/**
 * JNI bridge interface for hev-socks5-tunnel.
 *
 * Links an Android VpnService TUN file descriptor to a local SOCKS5 proxy inbound.
 * MIT Licensed component (see third_party/hev-socks5-tunnel/LICENSE-MIT).
 */
object TProxyService {
    private const val TAG = "TProxyService"

    init {
        try {
            System.loadLibrary("hev-socks5-tunnel")
            Log.i(TAG, "libhev-socks5-tunnel.so loaded successfully")
        } catch (e: UnsatisfiedLinkError) {
            Log.e(TAG, "Failed to load libhev-socks5-tunnel.so: ${e.message}", e)
        }
    }

    @JvmStatic
    external fun TProxyStartService(configPath: String, fd: Int): Boolean

    @JvmStatic
    external fun TProxyStopService(): Boolean

    @JvmStatic
    external fun TProxyIsRunning(): Boolean

    /** Binds a real filesystem unix listening socket (LocalServerSocket(String)
     *  only supports the abstract namespace) and wraps it in a FileDescriptor
     *  for LocalServerSocket(fd). */
    @JvmStatic
    external fun TProxyCreateUnixListen(path: String): java.io.FileDescriptor?

    /** Closes the fd created by TProxyCreateUnixListen and unlinks the path. */
    @JvmStatic
    external fun TProxyCloseUnixListen(fd: java.io.FileDescriptor, path: String): Boolean

    /** Dials the abstract-namespace protect socket natively, sends the PING
     *  command byte and expects ack 1. Returns 0 on success, else -errno.
     *  Bypasses the java.net LocalSocket stack (unreliable on one device). */
    @JvmStatic
    external fun TProxyProtectProbe(name: String): Int

    @JvmStatic
    external fun TProxyGetStats(): LongArray?
}
