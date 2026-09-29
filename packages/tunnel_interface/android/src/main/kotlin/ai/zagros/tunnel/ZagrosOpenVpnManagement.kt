package ai.zagros.tunnel

import android.content.Context
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.ParcelFileDescriptor
import android.system.Os
import android.util.Log
import java.io.File
import java.io.FileDescriptor
import java.io.OutputStream
import java.net.InetAddress
import java.util.LinkedList
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Handles OpenVPN management interface communication over a UNIX domain socket.
 * Responsible for passing credentials, protecting sockets, configuring routes/DNS,
 * and transferring the VpnService TUN file descriptor.
 */
class ZagrosOpenVpnManagement(
    private val context: Context,
    private val username: String,
    private val password: String,
) {
    private var serverSocketLocal: LocalSocket? = null
    private var serverSocket: LocalServerSocket? = null
    private var clientSocket: LocalSocket? = null
    private val isRunning = AtomicBoolean(false)
    private var socketPath: String = ""

    private val fdList = LinkedList<FileDescriptor>()
    private var localIp: String = "10.8.0.2"
    private var prefixLength: Int = 24
    private var mtu: Int = 1500
    private val dnsServers = mutableListOf<String>()
    private val routes = mutableListOf<Pair<String, Int>>()

    fun initSocket(): String {
        stop()
        val sockFile = File(context.cacheDir, "zagros_ovpn_mgmt.sock")
        if (sockFile.exists()) {
            sockFile.delete()
        }
        socketPath = sockFile.absolutePath

        val local = LocalSocket()
        serverSocketLocal = local
        var bound = false
        var tries = 8
        while (tries > 0 && !bound) {
            try {
                local.bind(LocalSocketAddress(socketPath, LocalSocketAddress.Namespace.FILESYSTEM))
                bound = true
            } catch (_: Throwable) {
                tries--
                Thread.sleep(50)
            }
        }
        serverSocket = LocalServerSocket(local.fileDescriptor)
        isRunning.set(true)
        Log.i(TAG, "OpenVPN management socket bound at $socketPath")
        return socketPath
    }

    fun handleLoop(
        onConnected: () -> Unit,
        onStats: (Long, Long) -> Unit,
        onLog: (String) -> Unit = {}
    ) {
        val srv = serverSocket ?: return
        try {
            val sock = srv.accept()
            clientSocket = sock
            Log.i(TAG, "OpenVPN client connected to management socket")

            try {
                srv.close()
            } catch (_: Throwable) {
            }
            serverSocket = null

            val inStream = sock.inputStream
            val outStream = sock.outputStream

            sendCommand(outStream, "version 3\n")

            val buffer = ByteArray(4096)
            var pending = ""

            while (isRunning.get()) {
                val read = inStream.read(buffer)
                if (read <= 0) break

                val ancillary = try {
                    sock.ancillaryFileDescriptors
                } catch (_: Throwable) {
                    null
                }

                if (ancillary != null && ancillary.isNotEmpty()) {
                    for (fd in ancillary) {
                        fdList.add(fd)
                    }
                }

                val chunk = String(buffer, 0, read, Charsets.UTF_8)
                pending += chunk

                while (pending.contains("\n")) {
                    val parts = pending.split("\n", limit = 2)
                    val line = parts[0].trim()
                    pending = if (parts.size > 1) parts[1] else ""
                    if (line.isNotEmpty()) {
                        processLine(line, sock, outStream, onConnected, onStats, onLog)
                    }
                }
            }
        } catch (e: Throwable) {
            if (isRunning.get()) {
                Log.w(TAG, "Management loop terminated: ${e.message}")
            }
        } finally {
            stop()
        }
    }

    private fun processLine(
        line: String,
        socket: LocalSocket,
        outStream: OutputStream,
        onConnected: () -> Unit,
        onStats: (Long, Long) -> Unit,
        onLog: (String) -> Unit
    ) {
        Log.d(TAG, "MGMT << $line")
        onLog(line)

        if (line.startsWith("PROTECTFD: ")) {
            var fd = if (fdList.isNotEmpty()) fdList.pollFirst() else null
            if (fd == null) {
                val ancillary = try {
                    socket.ancillaryFileDescriptors
                } catch (_: Throwable) {
                    null
                }
                if (ancillary != null && ancillary.isNotEmpty()) {
                    for (f in ancillary) {
                        fdList.add(f)
                    }
                    fd = fdList.pollFirst()
                }
            }
            if (fd != null) {
                protectFileDescriptor(fd)
            }
            return
        }

        if (line.startsWith(">HOLD:")) {
            sendCommand(outStream, "hold release\n")
            sendCommand(outStream, "bytecount 2\n")
            sendCommand(outStream, "state on\n")
            return
        }

        if (line.startsWith(">PROXY:")) {
            sendCommand(outStream, "proxy NONE\n")
            return
        }

        if (line.startsWith(">PASSWORD:")) {
            val after = line.substringAfter(">PASSWORD:").trim()
            val p1 = after.indexOf('\'')
            val p2 = after.indexOf('\'', p1 + 1)
            val needed = if (p1 != -1 && p2 != -1) after.substring(p1 + 1, p2) else "Auth"
            val escapedUser = escapeOpenVpn(username)
            val escapedPass = escapeOpenVpn(password)
            if (username.isNotEmpty()) {
                sendCommand(outStream, "username '$needed' $escapedUser\n")
            }
            sendCommand(outStream, "password '$needed' $escapedPass\n")
            return
        }

        if (line.startsWith(">STATE:")) {
            if (line.contains("CONNECTED")) {
                Log.i(TAG, "OpenVPN reported STATE: CONNECTED")
                onConnected()
            }
            return
        }

        if (line.startsWith(">BYTECOUNT:")) {
            try {
                val csv = line.substringAfter(">BYTECOUNT:").trim()
                val parts = csv.split(",")
                if (parts.size >= 2) {
                    val rx = parts[0].toLongOrNull() ?: 0L
                    val tx = parts[1].toLongOrNull() ?: 0L
                    onStats(tx, rx)
                }
            } catch (_: Throwable) {
            }
            return
        }

        if (line.startsWith(">NEED-OK:")) {
            val after = line.substringAfter(">NEED-OK:").trim()
            val p1 = after.indexOf('\'')
            val p2 = after.indexOf('\'', p1 + 1)
            if (p1 != -1 && p2 != -1) {
                val needed = after.substring(p1 + 1, p2)
                val extra = after.substringAfter(":", "").trim()

                when (needed) {
                    "PROTECTFD" -> {
                        var fd = if (fdList.isNotEmpty()) fdList.pollFirst() else null
                        if (fd == null) {
                            val ancillary = try {
                                socket.ancillaryFileDescriptors
                            } catch (_: Throwable) {
                                null
                            }
                            if (ancillary != null && ancillary.isNotEmpty()) {
                                for (f in ancillary) {
                                    fdList.add(f)
                                }
                                fd = fdList.pollFirst()
                            }
                        }
                        if (fd != null) {
                            protectFileDescriptor(fd)
                        }
                        sendCommand(outStream, "needok '$needed' ok\n")
                    }
                    "IFCONFIG" -> {
                        parseIfconfig(extra)
                        sendCommand(outStream, "needok '$needed' ok\n")
                    }
                    "IFCONFIG6" -> {
                        sendCommand(outStream, "needok '$needed' ok\n")
                    }
                    "ROUTE" -> {
                        val tokens = extra.split(" ").filter { it.isNotBlank() }
                        if (isTunRoute(tokens)) {
                            val dest = tokens[0]
                            val mask = if (tokens.size > 1) tokens[1] else "255.255.255.255"
                            val pfx = netmaskToPrefix(mask)
                            routes.add(Pair(dest, pfx))
                            Log.i(TAG, "Added OpenVPN tunnel route: $dest/$pfx")
                        } else {
                            Log.i(TAG, "Skipped physical/gateway OpenVPN route: $extra")
                        }
                        sendCommand(outStream, "needok '$needed' ok\n")
                    }
                    "ROUTE6" -> {
                        sendCommand(outStream, "needok '$needed' ok\n")
                    }
                    "DNSSERVER", "DNS6SERVER" -> {
                        val dns = extra.trim()
                        if (dns.isNotBlank()) dnsServers.add(dns)
                        sendCommand(outStream, "needok '$needed' ok\n")
                    }
                    "DNSDOMAIN" -> {
                        sendCommand(outStream, "needok '$needed' ok\n")
                    }
                    "PERSIST_TUN_ACTION" -> {
                        sendCommand(outStream, "needok '$needed' OPEN_BEFORE_CLOSE\n")
                    }
                    "OPENTUN" -> {
                        var vpnService = ZagrosVpnService.getInstance()
                        var retries = 0
                        while (vpnService == null && retries < 30) {
                            Thread.sleep(100)
                            retries++
                            vpnService = ZagrosVpnService.getInstance()
                        }
                        val pfd: ParcelFileDescriptor? = vpnService?.openTunForOpenVpn(
                            ip = localIp,
                            prefixLength = prefixLength,
                            mtu = mtu,
                            dnsServers = if (dnsServers.isNotEmpty()) dnsServers else listOf("1.1.1.1", "8.8.8.8"),
                            routes = if (routes.isNotEmpty()) routes else listOf(Pair("0.0.0.0", 0)),
                        )
                        if (pfd != null) {
                            try {
                                val setIntMethod = FileDescriptor::class.java.getDeclaredMethod("setInt$", Int::class.javaPrimitiveType)
                                setIntMethod.isAccessible = true
                                val fdToSend = FileDescriptor()
                                setIntMethod.invoke(fdToSend, pfd.fd)

                                socket.setFileDescriptorsForSend(arrayOf(fdToSend))
                                sendCommand(outStream, "needok '$needed' ok\n")
                                socket.setFileDescriptorsForSend(null)
                                pfd.close()
                                Log.i(TAG, "Sent TUN fd to OpenVPN successfully")
                            } catch (e: Throwable) {
                                Log.e(TAG, "Failed to send TUN fd to OpenVPN: ${e.message}", e)
                                sendCommand(outStream, "needok '$needed' cancel\n")
                            }
                        } else {
                            Log.e(TAG, "openTunForOpenVpn returned null")
                            sendCommand(outStream, "needok '$needed' cancel\n")
                        }
                    }
                    else -> {
                        sendCommand(outStream, "needok '$needed' ok\n")
                    }
                }
            }
        }
    }

    private fun parseIfconfig(extra: String) {
        val tokens = extra.split(" ").filter { it.isNotBlank() }
        if (tokens.isEmpty()) return
        localIp = tokens[0]
        if (tokens.size > 1) {
            val second = tokens[1]
            val mode = if (tokens.size > 3) tokens[3].lowercase() else "subnet"
            if (second.contains(".") && isNetmask(second)) {
                prefixLength = netmaskToPrefix(second)
            } else if (mode == "net30") {
                prefixLength = 30
            } else if (mode == "p2p") {
                prefixLength = 32
            } else {
                prefixLength = 24
            }
        }
        if (tokens.size > 2) {
            mtu = tokens[2].toIntOrNull() ?: 1500
        }
        Log.i(TAG, "OpenVPN IFCONFIG configured: localIp=$localIp prefix=/$prefixLength mtu=$mtu")
    }

    private fun isNetmask(s: String): Boolean {
        return s.startsWith("255.") || s.startsWith("128.") || s.startsWith("192.") ||
                s.startsWith("224.") || s.startsWith("240.") || s.startsWith("248.") ||
                s.startsWith("252.") || s.startsWith("254.")
    }

    private fun isTunRoute(tokens: List<String>): Boolean {
        if (tokens.isEmpty()) return false
        val dest = tokens[0]

        if (tokens.size >= 4) {
            val device = tokens[3].lowercase()
            if (device == "net_gateway" || device == "remote_host" ||
                device.startsWith("eth") || device.startsWith("wlan") ||
                device.startsWith("rmnet")
            ) {
                return false
            }
            if (device == "tun" || device == "vpnservice-tun" ||
                device == "(null)" || device == "null" || device.isEmpty()
            ) {
                return true
            }
        }

        if (tokens.size >= 3) {
            val gateway = tokens[2]
            val localPrefix = localIp.substringBeforeLast(".")
            if (gateway.startsWith(localPrefix)) {
                return true
            }
        }

        if (dest == "0.0.0.0" || dest == "128.0.0.0") {
            return true
        }

        return false
    }

    private fun protectFileDescriptor(fd: FileDescriptor) {
        try {
            val fdInt = getFdInt(fd)
            if (fdInt > 0) {
                val protected = ZagrosVpnService.protectSocket(fdInt)
                Log.i(TAG, "Protected OpenVPN socket fd=$fdInt (result=$protected)")
            }
            try {
                Os.close(fd)
            } catch (_: Throwable) {
            }
        } catch (e: Throwable) {
            Log.w(TAG, "Failed to protect socket: ${e.message}")
        }
    }

    private fun getFdInt(fd: FileDescriptor): Int {
        return try {
            val method = FileDescriptor::class.java.getDeclaredMethod("getInt$")
            method.isAccessible = true
            (method.invoke(fd) as? Int) ?: -1
        } catch (_: Throwable) {
            -1
        }
    }

    private fun sendCommand(outStream: OutputStream, cmd: String) {
        try {
            outStream.write(cmd.toByteArray(Charsets.UTF_8))
            outStream.flush()
            Log.d(TAG, "MGMT >> ${cmd.trim()}")
        } catch (e: Throwable) {
            Log.w(TAG, "Failed to send management command: ${e.message}")
        }
    }

    private fun escapeOpenVpn(s: String): String {
        return "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
    }

    private fun netmaskToPrefix(netmask: String): Int {
        try {
            val bytes = InetAddress.getByName(netmask).address
            var netmaskInt = 0L
            for (b in bytes) {
                netmaskInt = (netmaskInt shl 8) or (b.toLong() and 0xFF)
            }
            netmaskInt += (1L shl 32)
            var zeros = 0
            while ((netmaskInt and 1L) == 0L) {
                zeros++
                netmaskInt = netmaskInt shr 1
            }
            val maskCheck = (1L shl (33 - zeros)) - 1
            if (netmaskInt != maskCheck) {
                return 32
            }
            val len = 32 - zeros
            return len.coerceIn(1, 32)
        } catch (_: Throwable) {
            return 32
        }
    }

    fun stop() {
        isRunning.set(false)
        try {
            clientSocket?.let { sock ->
                try {
                    sock.outputStream.write("signal SIGINT\n".toByteArray(Charsets.UTF_8))
                    sock.outputStream.flush()
                } catch (_: Throwable) {
                }
                sock.close()
            }
        } catch (_: Throwable) {
        } finally {
            clientSocket = null
        }

        try {
            serverSocket?.close()
        } catch (_: Throwable) {
        } finally {
            serverSocket = null
        }

        try {
            serverSocketLocal?.close()
        } catch (_: Throwable) {
        } finally {
            serverSocketLocal = null
        }

        for (fd in fdList) {
            try {
                Os.close(fd)
            } catch (_: Throwable) {
            }
        }
        fdList.clear()

        if (socketPath.isNotEmpty()) {
            try {
                val f = File(socketPath)
                if (f.exists()) f.delete()
            } catch (_: Throwable) {
            }
            socketPath = ""
        }
    }

    companion object {
        private const val TAG = "ZagrosOpenVpnMgmt"
    }
}
