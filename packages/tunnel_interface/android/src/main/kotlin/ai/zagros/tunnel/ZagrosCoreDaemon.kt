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

/**
 * Out-of-Process native core runner.
 *
 * Executes the compiled native executable in an isolated process boundary,
 * managing configuration handover, log streaming, and deterministic teardown.
 */
class ZagrosCoreDaemon(private val context: Context) {
    private var process: Process? = null
    private var activeConfigFile: File? = null
    private val isRunning = AtomicBoolean(false)
    private val uplinkBytes = AtomicLong(0)
    private val downlinkBytes = AtomicLong(0)
    private var stdoutReaderJob: Job? = null

    fun isAvailable(): Boolean {
        val binary = findOrExtractBinary()
        return binary != null && binary.exists() && binary.length() > 0
    }

    fun findOrExtractBinary(): File? {
        // 1. Primary location: nativeLibraryDir (standard location for extracted JNI libraries)
        try {
            val libDir = File(context.applicationInfo.nativeLibraryDir)
            val binary = File(libDir, "libsingbox.so")
            if (binary.exists() && binary.length() > 0) {
                try {
                    binary.setExecutable(true, false)
                } catch (_: Throwable) {
                }
                return binary
            }
        } catch (e: Throwable) {
            Log.w(TAG, "Error checking nativeLibraryDir: ${e.message}")
        }

        // 2. Secondary locations: codeCacheDir, filesDir, cacheDir
        val fallbackDirs = listOf(
            context.codeCacheDir,
            context.filesDir,
            context.cacheDir,
        )
        for (dir in fallbackDirs) {
            try {
                val f = File(dir, "libsingbox.so")
                if (f.exists() && f.length() > 0) {
                    try {
                        f.setExecutable(true, false)
                    } catch (_: Throwable) {
                    }
                    return f
                }
            } catch (_: Throwable) {
            }
        }

        // 3. Fallback: Extract from APK package
        return extractFromApk()
    }

    private fun extractFromApk(): File? {
        try {
            val apkPath = context.applicationInfo.sourceDir
            if (apkPath.isNullOrEmpty()) return null
            val apkFile = File(apkPath)
            if (!apkFile.exists()) return null

            val targetDir = context.codeCacheDir ?: context.filesDir
            val destFile = File(targetDir, "libsingbox.so")

            ZipFile(apkFile).use { zip ->
                val supportedAbis = Build.SUPPORTED_ABIS ?: arrayOf("arm64-v8a", "armeabi-v7a")
                var entry = zip.getEntry("lib/${supportedAbis.firstOrNull() ?: "arm64-v8a"}/libsingbox.so")
                if (entry == null) {
                    for (abi in supportedAbis) {
                        entry = zip.getEntry("lib/$abi/libsingbox.so")
                        if (entry != null) break
                    }
                }
                if (entry == null) {
                    val entries = zip.entries()
                    while (entries.hasMoreElements()) {
                        val e = entries.nextElement()
                        if (e.name.endsWith("libsingbox.so")) {
                            entry = e
                            break
                        }
                    }
                }
                if (entry != null) {
                    zip.getInputStream(entry).use { input ->
                        FileOutputStream(destFile).use { output ->
                            input.copyTo(output)
                        }
                    }
                    try {
                        destFile.setExecutable(true, false)
                    } catch (_: Throwable) {
                    }
                    Log.i(TAG, "Successfully extracted libsingbox.so from APK to ${destFile.absolutePath} (${destFile.length()} bytes)")
                    return destFile
                }
            }
        } catch (e: Throwable) {
            Log.w(TAG, "Failed to extract libsingbox.so from APK: ${e.message}")
        }
        return null
    }

    suspend fun start(
        configBytes: ByteArray,
        scope: CoroutineScope,
        onLogLine: (String) -> Unit = {},
        protectPath: String? = null,
    ): Boolean = withContext(Dispatchers.IO) {
        var binary = findOrExtractBinary() ?: run {
            Log.e(TAG, "Cannot start sing-box: libsingbox.so binary not found in nativeLibraryDir or fallbacks")
            return@withContext false
        }

        killStaleChildren(binary)
        stop()

        try {
            val configFile = File(context.filesDir, "zagros_core_active.json")
            val effectiveConfig = if (protectPath != null) {
                injectProtectPath(configBytes, protectPath)
            } else {
                configBytes
            }
            FileOutputStream(configFile).use { out ->
                out.write(effectiveConfig)
                out.flush()
            }
            activeConfigFile = configFile

            Log.i(TAG, "Starting sing-box daemon: ${binary.absolutePath} run -c ${configFile.absolutePath}")

            var p: Process? = null
            try {
                val pb = ProcessBuilder(binary.absolutePath, "run", "-c", configFile.absolutePath)
                pb.directory(context.filesDir)
                pb.environment()["TMPDIR"] = context.cacheDir.absolutePath
                pb.environment()["HOME"] = context.filesDir.absolutePath
                pb.environment()["PATH"] = "/system/bin:/system/xbin"
                // quic-go GSO is a known source of silent UDP blackholes on a
                // range of Android devices/kernels. Disabling it is a negligible
                // cost that removes a whole class of "no recent network activity".
                pb.environment()["QUIC_GO_DISABLE_GSO"] = "1"
                pb.redirectErrorStream(true)
                p = pb.start()
            } catch (execError: Throwable) {
                Log.w(TAG, "Direct launch failed (${execError.message}), extracting fresh copy to codeCacheDir...")
                val extracted = extractFromApk()
                if (extracted != null && extracted.absolutePath != binary.absolutePath) {
                    binary = extracted
                    val pb = ProcessBuilder(binary.absolutePath, "run", "-c", configFile.absolutePath)
                    pb.directory(context.filesDir)
                    pb.environment()["TMPDIR"] = context.cacheDir.absolutePath
                    pb.environment()["HOME"] = context.filesDir.absolutePath
                    pb.environment()["PATH"] = "/system/bin:/system/xbin"
                    pb.environment()["QUIC_GO_DISABLE_GSO"] = "1"
                    pb.redirectErrorStream(true)
                    p = pb.start()
                } else {
                    throw execError
                }
            }

            process = p
            isRunning.set(true)
            writePidFile(p)

            val initialOutput = StringBuilder()
            stdoutReaderJob = scope.launch(Dispatchers.IO) {
                try {
                    p.inputStream.bufferedReader().useLines { lines ->
                        for (line in lines) {
                            if (!isActive || !isRunning.get()) break
                            Log.i("ZagrosDaemon", line)
                            if (initialOutput.length < 2048) {
                                initialOutput.append(line).append("\n")
                            }
                            onLogLine(line)
                        }
                    }
                } catch (_: Throwable) {
                }
            }

            delay(300)
            if (!p.isAlive) {
                val exitCode = try { p.exitValue() } catch (_: Throwable) { -1 }
                Log.e(TAG, "sing-box process died prematurely with exit code $exitCode. Output tail: $initialOutput")
                stop()
                return@withContext false
            }

            Log.i(TAG, "sing-box daemon started successfully (PID is alive)")
            true
        } catch (e: Throwable) {
            Log.e(TAG, "Failed to start sing-box daemon: ${e.message}", e)
            stop()
            false
        }
    }

    suspend fun stop(): Unit = withContext(Dispatchers.IO) {
        isRunning.set(false)
        stdoutReaderJob?.cancel()
        stdoutReaderJob = null
        // A fresh plugin instance (app relaunched) holds no Process handle but
        // the exec'd child may still be alive — the pid file finds it.
        killByPidFile()

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

        activeConfigFile?.let { file -> zeroizeAndDelete(file) }
        activeConfigFile = null
        // A relaunched instance (orphans kill path) has no activeConfigFile
        // reference — still zeroize the well-known config location.
        zeroizeAndDelete(File(context.filesDir, "zagros_core_active.json"))
    }

    private fun zeroizeAndDelete(file: File) {
        try {
            if (file.exists()) {
                try {
                    val len = file.length().toInt()
                    if (len > 0) {
                        FileOutputStream(file).use { out ->
                            out.write(ByteArray(len))
                            out.flush()
                        }
                    }
                } catch (_: Throwable) {
                }
                file.delete()
            }
        } catch (_: Throwable) {
        }
    }

    fun isAlive(): Boolean = isRunning.get() && (process?.isAlive == true || readPidFile()?.isProcessAlive == true)

    fun getUplink(): Long = uplinkBytes.get()
    fun getDownlink(): Long = downlinkBytes.get()

    private fun pidFile(): java.io.File = java.io.File(context.filesDir, "zagros_core.pid")

    private fun writePidFile(p: Process) {
        try {
            var pid = -1
            try {
                val field = p.javaClass.getDeclaredField("pid")
                field.isAccessible = true
                pid = field.getInt(p)
            } catch (_: Throwable) {
            }
            if (pid <= 1) {
                // Reflection failed: our child is the only process whose
                // cmdline names the active config file and whose parent is us.
                val me = android.os.Process.myPid()
                for (entry in java.io.File("/proc").listFiles() ?: emptyArray()) {
                    val cand = entry.name.toIntOrNull() ?: continue
                    val cmdline = try {
                        java.io.File(entry, "cmdline").readBytes().toString(Charsets.UTF_8)
                    } catch (_: Throwable) {
                        continue
                    }
                    if (!cmdline.contains("zagros_core_active.json")) continue
                    val stat = try {
                        java.io.File(entry, "stat").readText()
                    } catch (_: Throwable) {
                        continue
                    }
                    val ppid = stat.substringAfterLast(')').trim()
                        .split(' ').getOrNull(1)?.toIntOrNull()
                    if (ppid == me) {
                        pid = cand
                        break
                    }
                }
            }
            pidFile().writeText(pid.toString())
            Log.i(TAG, "sing-box child pid=$pid recorded")
        } catch (e: Throwable) {
            Log.w(TAG, "pid file write failed: ${e.message}")
        }
    }

    private fun readPidFile(): Int? = try {
        pidFile().readText().trim().toIntOrNull()
    } catch (_: Throwable) {
        null
    }

    /** True only when /proc/<pid> exists AND its cmdline still names our
     *  engine (guards against pid reuse handing us an unrelated process). */
    private fun pidIsOurChild(pid: Int): Boolean = try {
        if (pid <= 1) false
        else java.io.File("/proc/$pid/cmdline").readBytes()
            .toString(Charsets.UTF_8).contains("sing-box")
    } catch (_: Throwable) {
        false
    }

    private val Int.isProcessAlive: Boolean
        get() = pidIsOurChild(this)

    private fun killByPidFile(): Int {
        val pid = readPidFile() ?: return 0
        if (!pid.isProcessAlive) return 0
        return try {
            Runtime.getRuntime().exec(arrayOf("kill", "-9", pid.toString())).waitFor()
            Log.i(TAG, "stale sing-box child pid=$pid killed via pid file")
            1
        } catch (_: Throwable) {
            0
        }
    }

    /** Adds `protect_path` to every outbound so each socket the child dials
     *  is handed to the app's VpnService for protection (see protect server
     *  in ZagrosVpnService). Unknown-field tolerant: sing-box accepts the
     *  dialer option on all outbound types. */
    private fun injectProtectPath(configBytes: ByteArray, protectPath: String): ByteArray {
        return try {
            val root = org.json.JSONObject(String(configBytes, Charsets.UTF_8))
            val outbounds = root.optJSONArray("outbounds")
            var patched = 0
            var summary = "none"
            if (outbounds != null) {
                for (i in 0 until outbounds.length()) {
                    val outbound = outbounds.optJSONObject(i)
                    if (outbound != null) {
                        outbound.put("protect_path", protectPath)
                        patched += 1
                        if (summary == "none") {
                            summary = outbound.optString("type") + " -> " +
                                outbound.optString("server") + ":" + outbound.optString("server_port")
                        }
                    }
                }
            }
            val pp0 = root.optJSONArray("outbounds")?.optJSONObject(0)?.optString("protect_path") ?: ""
            val ppReadable = if (pp0.startsWith("@")) "[abstract]" + pp0.substring(1) else pp0
            Log.i(TAG, "protect_path injected into $patched outbound(s): $ppReadable; first=$summary")
            root.toString().toByteArray(Charsets.UTF_8)
        } catch (e: Throwable) {
            Log.w(TAG, "protect_path injection skipped: ${e.message}")
            configBytes
        }
    }

    /** A leftover child (OS killed the app process while the exec'd sing-box
     *  survived) holds the SOCKS port and poisons the next connect. Kill any
     *  sibling instance of the engine binary before spawning a new one. */
    private fun killStaleChildren(binary: File) {
        var killed = killByPidFile()
        try {
            val self = android.os.Process.myPid()
            for (entry in File("/proc").listFiles() ?: emptyArray()) {
                val pid = entry.name.toIntOrNull() ?: continue
                if (pid == self) continue
                val cmdline = try {
                    File(entry, "cmdline").readBytes().toString(Charsets.UTF_8)
                } catch (_: Throwable) {
                    continue
                }
                if (cmdline.contains(binary.name)) {
                    try {
                        Runtime.getRuntime().exec(arrayOf("kill", "-9", pid.toString())).waitFor()
                        killed += 1
                    } catch (_: Throwable) {}
                }
            }
        } catch (e: Throwable) {
            Log.w(TAG, "stale child scan failed: ${e.message}")
        }
        if (killed > 0) Log.i(TAG, "killed $killed stale sing-box child process(es)")
    }

    companion object {
        private const val TAG = "ZagrosCoreDaemon"
    }
}
