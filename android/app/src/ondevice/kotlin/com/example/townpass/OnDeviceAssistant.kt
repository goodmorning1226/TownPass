package com.example.townpass

import android.content.Context
import android.content.pm.ApplicationInfo
import android.util.Log
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket
import kotlin.concurrent.thread

/**
 * Runs the local service assistant on the phone (on-device builds only,
 * docs/AI_ON_DEVICE_PLAN.md). The same loopback endpoints as the computer setup:
 *
 *  - llama.cpp llama-server (ministral-3:3b GGUF)   127.0.0.1:8771
 *  - whisper.cpp whisper-server (Breeze-ASR-25)     127.0.0.1:8772
 *  - Python backend via Chaquopy (device_main.py)   127.0.0.1:8765 and :8770
 *
 * so the Flutter side and the HTTP contract do not change. Model files are not
 * in the APK; scripts/push_assistant_models.ps1 copies them to the app's
 * external files directory (Android/data/<package>/files/models).
 */
object OnDeviceAssistant {
    private const val TAG = "TownPassAssistant"
    const val MODEL_FILE = "Ministral-3-3B-Instruct-2512-Q4_K_M.gguf"
    const val ASR_FILE = "ggml-breeze-asr-25-q5_0.bin"
    private const val MODEL_PORT = 8771
    private const val WHISPER_PORT = 8772
    private val processes = mutableListOf<Process>()

    @Volatile
    private var started = false

    @JvmStatic
    fun start(context: Context) {
        synchronized(this) {
            if (started) return
            started = true
        }
        val app = context.applicationContext
        thread(name = "assistant-start", isDaemon = true) {
            try {
                // The Python servers listen at once; the models load behind them and
                // requests get "not ready yet" replies until they answer.
                if (!Python.isStarted()) Python.start(AndroidPlatform(app))
                val info = Python.getInstance().getModule("device_main")
                    .callAttr("start", MODEL_PORT, WHISPER_PORT).toString()
                Log.i(TAG, "backend: $info")
                val models = app.getExternalFilesDir("models") ?: File(app.filesDir, "models")
                models.mkdirs()
                val threads = (Runtime.getRuntime().availableProcessors() / 2).coerceIn(2, 4).toString()
                // Child processes keep the CPU group they are forked in, and Android
                // only re-groups the App's own process later. Forked during start-up
                // they would stay in "background" (little cores only) for good.
                waitForForeground()
                launch(app, "libwhisper_server.so", File(models, ASR_FILE), WHISPER_PORT,
                    listOf("-t", threads, "-l", "zh"))
                launch(app, "libllama_server.so", File(models, MODEL_FILE), MODEL_PORT,
                    listOf("-t", threads, "-c", "4096", "-np", "1", "--no-webui"))
            } catch (error: Throwable) {
                Log.e(TAG, "on-device assistant failed to start", error)
            }
        }
    }

    private fun launch(app: Context, binary: String, model: File, port: Int, extra: List<String>) {
        if (!model.isFile) {
            Log.w(TAG, "missing model ${model.absolutePath}; run scripts/push_assistant_models.ps1")
            return
        }
        if (listening(port)) {
            Log.i(TAG, "$binary already listening on $port")
            return
        }
        val executable = File(app.applicationInfo.nativeLibraryDir, binary)
        val command = listOf(executable.absolutePath, "-m", model.absolutePath,
            "--host", "127.0.0.1", "--port", port.toString()) + extra
        val builder = ProcessBuilder(command).redirectErrorStream(true)
        // Debug builds keep the servers' own log (start-up and timings; requests
        // are not logged at the default verbosity) for diagnosing slow phones.
        val debuggable = app.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
        builder.redirectOutput(File(if (debuggable) "${app.cacheDir}/$binary.log" else "/dev/null"))
        synchronized(processes) { processes += builder.start() }
        Log.i(TAG, "started $binary on $port")
    }

    /** Waits (up to 30 s) until this thread is in the foreground CPU group ("top-app"). */
    private fun waitForForeground() {
        val deadline = System.currentTimeMillis() + 30_000
        while (System.currentTimeMillis() < deadline) {
            val group = cpuGroup()
            if (group == null || group == "/top-app") {
                Log.i(TAG, "cpu group: ${group ?: "unknown"}")
                return
            }
            Thread.sleep(200)
        }
        Log.w(TAG, "still in cpu group ${cpuGroup()}; model servers may run on little cores only")
    }

    private fun cpuGroup(): String? = try {
        File("/proc/thread-self/cgroup").readLines()
            .firstOrNull { it.contains(":cpuset:") }?.substringAfter(":cpuset:")
    } catch (_: Exception) {
        null
    }

    private fun listening(port: Int) = try {
        Socket().use { it.connect(InetSocketAddress("127.0.0.1", port), 200) }
        true
    } catch (_: Exception) {
        false
    }
}
