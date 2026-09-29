package ai.zagros.tunnel

import android.content.Context
import android.os.Build
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.zip.ZipFile
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * Out-of-Process OpenVPN daemon runner for non-rooted Android.
 * Communicates via the UNIX domain socket management interface to pass credentials,
 * protect outbound sockets, and transfer the VpnService TUN file descriptor.
 */
class ZagrosOpenVpnDaemon(private val context: Context) {
    private var process: Process? = null
    private var activeConfigFile: File? = null
    private var management: ZagrosOpenVpnManagement? = null
    private val isRunning = AtomicBoolean(false)
    private val isConnected = AtomicBoolean(false)
    private val uplinkBytes = AtomicLong(0)
    private val downlinkBytes = AtomicLong(0)
    private var stdoutReaderJob: Job? = null
    private var mgmtJob: Job? = null

    fun isAvailable(): Boolean {
        val binary = findOrExtractBinary()
        return binary != null && binary.exists() && binary.length() > 0
    }

    fun findOrExtractBinary(): File? {
        val libDir = File(context.applicationInfo.nativeLibraryDir)
        val candidates = listOf("libovpnexec.so", "libopenvpn.so", "pie_openvpn")
        for (name in candidates) {
            val binary = File(libDir, name)
            if (binary.exists() && binary.length() > 0) {
                try {
                    binary.setExecutable(true, false)
                } catch (_: Throwable) {
                }
                return binary
            }
        }

        val fallbackDirs = listOf(
            context.codeCacheDir,
            context.filesDir,
            context.cacheDir,
        )
        for (dir in fallbackDirs) {
            for (name in candidates) {
                val f = File(dir, name)
                if (f.exists() && f.length() > 0) {
                    try {
                        f.setExecutable(true, false)
                    } catch (_: Throwable) {
                    }
                    return f
                }
            }
        }

        return extractFromApk()
    }

    private fun extractFromApk(): File? {
        try {
            val apkPath = context.applicationInfo.sourceDir ?: return null
            val apkFile = File(apkPath)
            if (!apkFile.exists()) return null

            val targetDir = context.codeCacheDir ?: context.filesDir
            ZipFile(apkFile).use { zip ->
                val supportedAbis = Build.SUPPORTED_ABIS ?: arrayOf("arm64-v8a", "armeabi-v7a")
                for (name in listOf("libovpnexec.so", "libopenvpn.so", "libovpnutil.so")) {
                    var entry = zip.getEntry("lib/${supportedAbis.firstOrNull() ?: "arm64-v8a"}/$name")
                    if (entry == null) {
                        for (abi in supportedAbis) {
                            entry = zip.getEntry("lib/$abi/$name")
                            if (entry != null) break
                        }
                    }
                    if (entry != null) {
                        val destFile = File(targetDir, name)
                        zip.getInputStream(entry).use { input ->
                            FileOutputStream(destFile).use { output ->
                                input.copyTo(output)
                            }
                        }
                        try {
                            destFile.setExecutable(true, false)
                        } catch (_: Throwable) {
                        }
                        Log.i(TAG, "Extracted $name from APK to ${destFile.absolutePath}")
                    }
                }
            }
            val mainExec = File(targetDir, "libovpnexec.so")
            if (mainExec.exists() && mainExec.length() > 0) return mainExec
        } catch (e: Throwable) {
            Log.w(TAG, "Failed to extract openvpn from APK: ${e.message}")
        }
        return null
    }

    suspend fun start(
        configBytes: ByteArray,
        scope: CoroutineScope,
        onConnected: () -> Unit = {},
        onStats: (Long, Long) -> Unit = { _, _ -> },
        onLogLine: (String) -> Unit = {}
    ): Boolean = withContext(Dispatchers.IO) {
        stop()

        try {
            val rawString = String(configBytes, Charsets.UTF_8)
            var profileContent = rawString
            var username = ""
            var password = ""

            try {
                if (rawString.trim().startsWith("{")) {
                    val json = JSONObject(rawString)
                    if (json.has("profile") && json.getString("profile").isNotBlank()) {
                        profileContent = json.getString("profile")
                    } else {
                        val sb = StringBuilder()
                        sb.appendLine("client")
                        sb.appendLine("dev tun")
                        val server = json.optString("server", "")
                        val port = json.optInt("port", 1194)
                        val proto = json.optString("proto", json.optString("transport", "udp"))
                        if (server.isNotEmpty()) {
                            sb.appendLine("remote $server $port $proto")
                        }
                        for (key in json.keys()) {
                            if (key in listOf("protocol", "server", "port", "proto", "transport", "username", "password", "profile")) continue
                            val v = json.opt(key)
                            if (v is Boolean && v) {
                                sb.appendLine(key)
                            } else if (v is String && v.isNotEmpty()) {
                                sb.appendLine("$key $v")
                            } else if (v is Number) {
                                sb.appendLine("$key $v")
                            }
                        }
                        profileContent = sb.toString()
                    }
                    if (json.has("username")) {
                        username = json.getString("username")
                    }
                    if (json.has("password")) {
                        password = json.getString("password")
                    }
                }
            } catch (_: Throwable) {
            }

            val mgmt = ZagrosOpenVpnManagement(context, username, password)
            management = mgmt
            val socketPath = mgmt.initSocket()

            val ovpnLines = mutableListOf<String>()
            var hadAuthUserPass = false
            for (line in profileContent.lines()) {
                val trimmed = line.trim().lowercase()
                if (trimmed.startsWith("auth-user-pass")) {
                    hadAuthUserPass = true
                    continue
                }
                if (trimmed.startsWith("management")) continue
                if (trimmed.startsWith("dev-node")) continue
                if (trimmed.startsWith("dev ")) continue
                if (trimmed.startsWith("dev-type")) continue
                if (trimmed.startsWith("user ")) continue
                if (trimmed.startsWith("group ")) continue
                if (trimmed.startsWith("persist-tun")) continue
                if (trimmed.startsWith("up ")) continue
                if (trimmed.startsWith("down ")) continue
                if (trimmed.startsWith("route-up ")) continue
                if (trimmed.startsWith("plugin ")) continue
                if (trimmed.startsWith("script-security ")) continue
                ovpnLines.add(line)
            }
            ovpnLines.add("dev-type tun")
            ovpnLines.add("dev tun")
            ovpnLines.add("management $socketPath unix")
            ovpnLines.add("management-client")
            ovpnLines.add("management-query-passwords")
            ovpnLines.add("management-query-proxy")
            ovpnLines.add("management-hold")
            if (hadAuthUserPass || username.isNotEmpty()) {
                ovpnLines.add("auth-user-pass")
            }
            ovpnLines.add("allow-recursive-routing")
            ovpnLines.add("ifconfig-nowarn")
            ovpnLines.add("nobind")
            ovpnLines.add("verb 3")

            val configFile = File(context.filesDir, "zagros_ovpn_active.ovpn")
            FileOutputStream(configFile).use { out ->
                out.write(ovpnLines.joinToString("\n").toByteArray(Charsets.UTF_8))
                out.flush()
            }
            activeConfigFile = configFile

            val binary = findOrExtractBinary()
            if (binary == null) {
                Log.e(TAG, "Native OpenVPN binary (libovpnexec.so) not found")
                stop()
                return@withContext false
            }

            Log.i(TAG, "Starting OpenVPN process: ${binary.absolutePath} --config ${configFile.absolutePath}")

            // Start management handler loop before spawning process
            mgmtJob = scope.launch(Dispatchers.IO) {
                mgmt.handleLoop(
                    onConnected = {
                        isConnected.set(true)
                        onConnected()
                    },
                    onStats = { tx, rx ->
                        uplinkBytes.set(tx)
                        downlinkBytes.set(rx)
                        onStats(tx, rx)
                    },
                    onLog = onLogLine,
                )
            }

            val pb = ProcessBuilder(
                binary.absolutePath,
                "--config", configFile.absolutePath,
            )
            pb.directory(context.filesDir)
            val nativeDir = context.applicationInfo.nativeLibraryDir
            val binParent = binary.parentFile?.absolutePath ?: ""
            val ldPath = "$nativeDir:$binParent:${context.codeCacheDir?.absolutePath ?: ""}:${context.filesDir.absolutePath}"
            pb.environment()["LD_LIBRARY_PATH"] = ldPath
            pb.environment()["TMPDIR"] = context.cacheDir.absolutePath
            pb.environment()["HOME"] = context.filesDir.absolutePath
            pb.environment()["PATH"] = "/system/bin:/system/xbin"
            pb.redirectErrorStream(true)

            val p = try {
                pb.start()
            } catch (e: Throwable) {
                Log.e(TAG, "Failed to exec OpenVPN process: ${e.message}", e)
                stop()
                return@withContext false
            }
            process = p
            isRunning.set(true)

            val initialOutput = StringBuilder()
            stdoutReaderJob = scope.launch(Dispatchers.IO) {
                try {
                    p.inputStream.bufferedReader().useLines { lines ->
                        for (line in lines) {
                            if (!isActive || !isRunning.get()) break
                            Log.i("ZagrosOpenVPN", line)
                            if (initialOutput.length < 2048) {
                                initialOutput.append(line).append("\n")
                            }
                            onLogLine(line)
                        }
                    }
                } catch (_: Throwable) {
                }
            }

            delay(500)
            if (!p.isAlive) {
                val exitCode = try { p.exitValue() } catch (_: Throwable) { -1 }
                Log.e(TAG, "OpenVPN process died prematurely with exit code $exitCode. Output: $initialOutput")
                stop()
                return@withContext false
            }

            true
        } catch (e: Throwable) {
            Log.e(TAG, "Failed to start OpenVPN daemon: ${e.message}", e)
            stop()
            false
        }
    }

    suspend fun stop(): Unit = withContext(Dispatchers.IO) {
        isRunning.set(false)
        isConnected.set(false)
        mgmtJob?.cancel()
        mgmtJob = null
        stdoutReaderJob?.cancel()
        stdoutReaderJob = null

        management?.stop()
        management = null

        val p = process
        if (p != null) {
            try {
                if (p.isAlive) {
                    p.destroy()
                    delay(100)
                    if (p.isAlive) {
                        p.destroyForcibly()
                    }
                }
            } catch (_: Throwable) {
            }
            process = null
        }

        activeConfigFile?.let { file ->
            try {
                if (file.exists()) {
                    val len = file.length().toInt()
                    if (len > 0) {
                        FileOutputStream(file).use { out ->
                            out.write(ByteArray(len))
                            out.flush()
                        }
                    }
                    file.delete()
                }
            } catch (_: Throwable) {
            }
            activeConfigFile = null
        }
    }

    fun isAlive(): Boolean = isRunning.get() && process?.isAlive == true
    fun isTunnelConnected(): Boolean = isConnected.get()
    fun getUplink(): Long = uplinkBytes.get()
    fun getDownlink(): Long = downlinkBytes.get()

    companion object {
        private const val TAG = "ZagrosOpenVpnDaemon"
    }
}
