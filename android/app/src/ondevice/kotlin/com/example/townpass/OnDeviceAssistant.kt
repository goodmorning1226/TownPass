package com.example.townpass

import android.content.Context
import android.content.pm.ApplicationInfo
import android.util.Log
import com.chaquo.python.Kwarg
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
 *  - llama-server --embedding (multilingual-e5-small) 127.0.0.1:8774, optional FAQ layer
 *  - Python backend via Chaquopy (device_main.py)   127.0.0.1:8765 and :8770
 *
 * so the Flutter side and the HTTP contract do not change. Model files are not
 * in the APK; scripts/push_assistant_models.ps1 copies them to the app's
 * external files directory (Android/data/<package>/files/models).
 */
object OnDeviceAssistant {
    private const val TAG = "TownPassAssistant"
    const val MODEL_FILE = "Ministral-3-3B-Instruct-2512-Q4_K_M.gguf"
    /** Optional separate Chinese model (e.g. Breeze-ASR-25 q8_0, branch
     *  feat/asr-breeze-q8). Without it the multilingual model serves Chinese too. */
    const val ASR_FILE = "ggml-whisper-chinese.bin"  // push_assistant_models.ps1 -Chinese

    /** Multilingual Whisper (default Whisper small q8_0: 1.4 s a clip) for Chinese
     *  when no separate model is pushed, en/ja/vi/id/th and language detection. */
    const val MULTI_ASR_FILE = "ggml-whisper-multilingual.bin"  // push_assistant_models.ps1 -Multilingual
    /** Optional FAQ layer (docs/AI_FAQ_RAG.md): Microsoft multilingual-e5-small GGUF and
     *  the pre-built index directory, both pushed by push_assistant_models.ps1 (-FaqModel, -FaqIndex).
     *  Without them the assistant runs without FAQ. */
    const val FAQ_MODEL_FILE = "multilingual-e5-small-q8_0.gguf"
    const val FAQ_INDEX_DIR = "faq_rag"
    private const val FAQ_EMBED_PORT = 8774
    private const val MODEL_PORT = 8771
    private const val WHISPER_PORT = 8772
    private const val MULTI_WHISPER_PORT = 8773
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
                // Builds with the phone's own speech recogniser (TOWNPASS_SPEECH=system)
                // do not run Whisper at all.
                val whisper = app.resources.getBoolean(R.bool.assistant_whisper)
                val models = app.getExternalFilesDir("models") ?: File(app.filesDir, "models")
                models.mkdirs()
                // Which speech models were pushed: a separate Chinese one, a
                // multilingual one, or both.
                val chinese = whisper && File(models, ASR_FILE).isFile
                val multilingual = whisper && File(models, MULTI_ASR_FILE).isFile
                val faqIndex = File(models, FAQ_INDEX_DIR)
                val faq = File(models, FAQ_MODEL_FILE).isFile && File(faqIndex, "embeddings.bin").isFile
                val info = Python.getInstance().getModule("device_main")
                    .callAttr("start", MODEL_PORT, WHISPER_PORT, Kwarg("whisper", whisper),
                        Kwarg("multi_port", if (multilingual) MULTI_WHISPER_PORT else null),
                        Kwarg("chinese_model", chinese || !multilingual),
                        Kwarg("faq_port", if (faq) FAQ_EMBED_PORT else null),
                        Kwarg("faq_dir", if (faq) faqIndex.absolutePath else null)).toString()
                Log.i(TAG, "backend: $info")
                // Recent 8-core phone SoCs have 6-8 performance cores; leave two for
                // the UI. Speech and decision run one after the other, never together.
                val threads = (Runtime.getRuntime().availableProcessors() - 2).coerceIn(2, 6).toString()
                // Child processes keep the CPU group they are forked in, and Android
                // only re-groups the App's own process later. Forked during start-up
                // they would stay in "background" (little cores only) for good.
                waitForForeground()
                if (whisper) {
                    if (chinese || !multilingual) {
                        launch(app, "libwhisper_server.so", File(models, ASR_FILE), WHISPER_PORT,
                            listOf("-t", threads, "-l", "zh"))
                    }
                    if (multilingual) {
                        // Same binary; a second instance keeps the Chinese one just started.
                        launch(app, "libwhisper_server.so", File(models, MULTI_ASR_FILE), MULTI_WHISPER_PORT,
                            listOf("-t", threads, "-l", "auto"), stopLeftovers = !chinese)
                    }
                } else {
                    stopStale("libwhisper_server.so")
                }
                launch(app, "libllama_server.so", File(models, MODEL_FILE), MODEL_PORT,
                    // Two slots of 2048 tokens: one keeps the service policy and one the
                    // library policy in the prompt cache (requests are <= ~1000 tokens;
                    // the backend still sends one request at a time).
                    llamaCpuArgs() + listOf("-c", "4096", "-np", "2", "--no-webui"))
                if (faq) {
                    // Same binary, started after the decision model (whose launch stops
                    // leftover copies). Queried only after a decision has finished, one
                    // short query at a time: two threads, one 512-token slot (~130 MB).
                    launch(app, "libllama_server.so", File(models, FAQ_MODEL_FILE), FAQ_EMBED_PORT,
                        listOf("--embedding", "--pooling", "mean", "-c", "512", "-b", "512", "-ub", "512",
                            "-np", "1", "-t", "2", "--no-webui"), stopLeftovers = false)
                }
            } catch (error: Throwable) {
                Log.e(TAG, "on-device assistant failed to start", error)
            }
        }
    }

    private fun launch(app: Context, binary: String, model: File, port: Int, extra: List<String>,
                       stopLeftovers: Boolean = true) {
        if (!model.isFile) {
            Log.w(TAG, "missing model ${model.absolutePath}; run scripts/push_assistant_models.ps1")
            return
        }
        val executable = File(app.applicationInfo.nativeLibraryDir, binary)
        // Servers left by an earlier App process (force-stop or reinstall does not
        // always end them) may sit in the wrong CPU group or point at an old APK.
        if (stopLeftovers) stopStale(binary)
        if (listening(port)) {
            Log.w(TAG, "port $port is in use by another process; not starting $binary")
            return
        }
        val command = listOf(executable.absolutePath, "-m", model.absolutePath,
            "--host", "127.0.0.1", "--port", port.toString()) + extra
        val builder = ProcessBuilder(command).redirectErrorStream(true)
        // Debug builds keep the servers' own log (start-up and timings; requests
        // are not logged at the default verbosity) for diagnosing slow phones.
        val debuggable = app.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
        builder.redirectOutput(File(if (debuggable) "${app.cacheDir}/$binary-$port.log" else "/dev/null"))
        synchronized(processes) { processes += builder.start() }
        Log.i(TAG, "started $binary on $port")
    }

    /**
     * CPU settings for the decision model, measured on a vivo V2511 (Snapdragon
     * 7 Gen 4: 3 little + 4 mid + 1 prime core) with llama-bench:
     * reading the prompt is fastest on all non-little cores (5 threads pinned:
     * 57 tok/s vs 46 unpinned), generating on 3 of them (5.9 tok/s vs 4.4 with 6:
     * generation is limited by memory bandwidth, extra threads only contend).
     * "Little" cores are those with the lowest maximum frequency.
     */
    private fun llamaCpuArgs(): List<String> {
        val count = Runtime.getRuntime().availableProcessors()
        val maxFreq = (0 until count).map { cpu ->
            try {
                File("/sys/devices/system/cpu/cpu$cpu/cpufreq/cpuinfo_max_freq").readText().trim().toLong()
            } catch (_: Exception) {
                0L
            }
        }
        val lowest = maxFreq.filter { it > 0 }.minOrNull()
        val fast = maxFreq.indices.filter { lowest == null || maxFreq[it] > lowest }
            .ifEmpty { maxFreq.indices.toList() }
        val batchCores = fast.takeLast(6)
        // Generation on the fastest cores (highest frequency first).
        val genCores = fast.sortedByDescending { maxFreq[it] }.take(3)
        fun mask(cores: List<Int>) = "0x" + cores.fold(0L) { bits, cpu -> bits or (1L shl cpu) }.toString(16)
        Log.i(TAG, "llama cpu: gen ${genCores.size} threads ${mask(genCores)}, prompt ${batchCores.size} threads ${mask(batchCores)}")
        return listOf("-t", genCores.size.toString(), "-C", mask(genCores),
            "-tb", batchCores.size.toString(), "-Cb", mask(batchCores))
    }

    /** Ends this App's (same user id) leftover copies of [binary] and waits for them to exit. */
    private fun stopStale(binary: String) {
        val self = android.os.Process.myPid()
        val stale = File("/proc").listFiles().orEmpty().mapNotNull { dir ->
            val pid = dir.name.toIntOrNull() ?: return@mapNotNull null
            if (pid == self) return@mapNotNull null
            val command = try {
                File(dir, "cmdline").readText().substringBefore('\u0000')
            } catch (_: Exception) {
                return@mapNotNull null
            }
            pid.takeIf { command.endsWith("/$binary") }
        }
        if (stale.isEmpty()) return
        stale.forEach { android.os.Process.killProcess(it) }
        Log.i(TAG, "stopped leftover $binary: $stale")
        val deadline = System.currentTimeMillis() + 5_000
        while (stale.any { File("/proc/$it").exists() } && System.currentTimeMillis() < deadline) {
            Thread.sleep(100)
        }
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
