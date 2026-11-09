package com.example.townpass

import android.app.ActivityManager
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
 *  - llama.cpp llama-server (ministral-3:3b GGUF, or Gemma 4 E2B when built
 *    with TOWNPASS_DECISION_MODEL=gemma)          127.0.0.1:8771
 *  - whisper.cpp whisper-server (Breeze-ASR-25)     127.0.0.1:8772
 *  - whisper.cpp whisper-server (Taiwanese, Breeze-ASR-26) 127.0.0.1:8776, started on first use
 *  - whisper.cpp whisper-server (Vietnamese, PhoWhisper-small) 127.0.0.1:8777, started on first use
 *  - llama-server --embedding (multilingual-e5-small) 127.0.0.1:8774, optional FAQ layer
 *  - whisper-server (Whisper tiny, language detection only) 127.0.0.1:8775, optional
 *  - Python backend via Chaquopy (device_main.py)   127.0.0.1:8765 and :8770
 *
 * so the Flutter side and the HTTP contract do not change. Model files are not
 * in the APK; scripts/push_assistant_models.ps1 copies them to the app's
 * external files directory (Android/data/<package>/files/models).
 */
object OnDeviceAssistant {
    private const val TAG = "TownPassAssistant"
    const val MODEL_FILE = "Ministral-3-3B-Instruct-2512-Q4_K_M.gguf"
    /** Opt-in decision model (build with TOWNPASS_DECISION_MODEL=gemma; push with
     *  push_assistant_models.ps1 -DecisionModel gemma). The backend then uses its
     *  Gemma prompt variant (decision.py); Ministral stays the default. */
    const val GEMMA_MODEL_FILE = "gemma-4-E2B-it-Q4_0.gguf"
    /** Optional separate Chinese model (e.g. Breeze-ASR-25 q8_0, branch
     *  feat/asr-breeze-q8). Without it the multilingual model serves Chinese too. */
    const val ASR_FILE = "ggml-whisper-chinese.bin"  // push_assistant_models.ps1 -Chinese

    /** Multilingual Whisper (default Whisper small q8_0: 1.4 s a clip) for Chinese
     *  when no separate model is pushed, en/ja/vi/id/th and language detection. */
    const val MULTI_ASR_FILE = "ggml-whisper-multilingual.bin"  // push_assistant_models.ps1 -Multilingual
    /** Optional Taiwanese model (Breeze-ASR-26 q8_0: Taiwanese speech -> Mandarin
     *  characters, docs/AI_TAIWANESE_SPEECH_PLAN.md section 10). Loaded only when
     *  台語 is chosen and a clip arrives ([startTaiwanese]); without it Taiwanese
     *  clips are heard as Chinese and the App says so. */
    const val TAIWANESE_ASR_FILE = "ggml-whisper-taiwanese.bin"  // push_assistant_models.ps1 -Taiwanese
    /** Optional Vietnamese model (VinAI PhoWhisper-small q8_0, BSD-3-Clause, 264 MB;
     *  docs/AI_VIETNAMESE.md). Loaded on the first Vietnamese decode ([startVietnamese]);
     *  without it Whisper small decodes Vietnamese as before. */
    const val VIETNAMESE_ASR_FILE = "ggml-whisper-vietnamese.bin"  // push_assistant_models.ps1 -Vietnamese
    /** Optional language gate (docs/AI_LANGUAGE_GATE.md): Whisper tiny q8_0 (43 MB, ~0.2 s a
     *  clip) only detects the speech language before the multilingual model decodes, so
     *  speech is never decoded (translated) in a language the speaker did not use. Needs
     *  the multilingual model; without the file the backend works as before. */
    const val GATE_ASR_FILE = "ggml-whisper-langid.bin"  // push_assistant_models.ps1 -LanguageGate
    /** Optional FAQ layer (docs/AI_FAQ_RAG.md): Microsoft multilingual-e5-small GGUF and
     *  the pre-built index directory, both pushed by push_assistant_models.ps1 (-FaqModel, -FaqIndex).
     *  Without them the assistant runs without FAQ. */
    const val FAQ_MODEL_FILE = "multilingual-e5-small-q8_0.gguf"
    const val FAQ_INDEX_DIR = "faq_rag"
    private const val FAQ_EMBED_PORT = 8774
    private const val MODEL_PORT = 8771
    private const val WHISPER_PORT = 8772
    private const val MULTI_WHISPER_PORT = 8773
    private const val TAIWANESE_WHISPER_PORT = 8776
    private const val VIETNAMESE_WHISPER_PORT = 8777
    private const val GATE_WHISPER_PORT = 8775
    private val processes = mutableListOf<Process>()

    /** Set by [start]; [startTaiwanese] launches the Taiwanese server with them. */
    @Volatile
    private var appContext: Context? = null
    @Volatile
    private var whisperThreads = "4"
    private val taiwaneseLock = Any()
    private var taiwanese: Process? = null
    private val vietnameseLock = Any()
    private var vietnamese: Process? = null

    @Volatile
    private var started = false

    @JvmStatic
    fun start(context: Context) {
        synchronized(this) {
            if (started) return
            started = true
        }
        val app = context.applicationContext
        appContext = app
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
                val gate = multilingual && File(models, GATE_ASR_FILE).isFile
                val faqIndex = File(models, FAQ_INDEX_DIR)
                val faq = File(models, FAQ_MODEL_FILE).isFile && File(faqIndex, "embeddings.bin").isFile
                // The decision model this build asks for; without its file the default
                // (Ministral) is used, with the matching prompts.
                var decisionModel = app.getString(R.string.assistant_decision_model)
                if (decisionModel == "gemma" && !File(models, GEMMA_MODEL_FILE).isFile) {
                    Log.w(TAG, "missing $GEMMA_MODEL_FILE; using $MODEL_FILE " +
                        "(run scripts/push_assistant_models.ps1 -DecisionModel gemma)")
                    decisionModel = "ministral"
                }
                val decisionFile = File(models, if (decisionModel == "gemma") GEMMA_MODEL_FILE else MODEL_FILE)
                val info = Python.getInstance().getModule("device_main")
                    .callAttr("start", MODEL_PORT, WHISPER_PORT, Kwarg("whisper", whisper),
                        Kwarg("multi_port", if (multilingual) MULTI_WHISPER_PORT else null),
                        Kwarg("chinese_model", chinese || !multilingual),
                        Kwarg("faq_port", if (faq) FAQ_EMBED_PORT else null),
                        Kwarg("faq_dir", if (faq) faqIndex.absolutePath else null),
                        Kwarg("gate_port", if (gate) GATE_WHISPER_PORT else null),
                        // Always offered with Whisper: the file is looked for on first use.
                        Kwarg("taiwanese_port", if (whisper) TAIWANESE_WHISPER_PORT else null),
                        // Offered with the multilingual model: the file is looked for on first use.
                        Kwarg("vietnamese_port", if (whisper && multilingual) VIETNAMESE_WHISPER_PORT else null),
                        Kwarg("decision_model", decisionModel)).toString()
                Log.i(TAG, "backend: $info")
                // Recent 8-core phone SoCs have 6-8 performance cores; leave two for
                // the UI. Speech and decision run one after the other, never together.
                val threads = (Runtime.getRuntime().availableProcessors() - 2).coerceIn(2, 6).toString()
                whisperThreads = threads
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
                    if (gate) {
                        // Detection only (encoder + one step, ~130 MB): 4 threads were faster
                        // than 6 for Whisper tiny on a vivo V2511 (0.18 s vs 0.27 s a clip).
                        launch(app, "libwhisper_server.so", File(models, GATE_ASR_FILE), GATE_WHISPER_PORT,
                            listOf("-t", threads.toInt().coerceAtMost(4).toString(), "-l", "auto"),
                            stopLeftovers = false)
                    }
                } else {
                    stopStale("libwhisper_server.so")
                }
                // Same arguments for both decision models (Gemma 4 needs no extra flag:
                // its chat template has a system role, and --reasoning off keeps its
                // thinking channel closed).
                launch(app, "libllama_server.so", decisionFile, MODEL_PORT,
                    // Three slots of 2048 tokens: one each keeps the service, library and
                    // guide policy in the prompt cache (requests are <= ~1000 tokens; the
                    // backend sends one request at a time). --cache-ram 0: llama.cpp's
                    // host-RAM prompt cache (8 GiB by default) grew the server by 1.8-2.4 GB
                    // in 40 turns on the PC; with a slot per policy nothing is evicted,
                    // so it gains nothing (docs/SPEED_CACHE_EXPERIMENT.md, exp/speed-cache).
                    llamaCpuArgs() + listOf("-c", "6144", "-np", "3", "--cache-ram", "0",
                        // No thinking block before the answer: with a grammar it could
                        // run to the 180-token limit (~30 s on a phone) and fail.
                        "--reasoning", "off", "--no-webui"))
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

    /**
     * Starts the Taiwanese whisper-server if it is not running yet and waits until
     * it has loaded (called by asr_server through device_main.taiwanese_provider,
     * on a backend thread, only for clips spoken with 台語 chosen). Returns
     * "ready", "missing" (file not pushed), "memory" (not enough free memory;
     * nothing else is stopped) or "failed". The other speech servers keep running.
     */
    @JvmStatic
    fun startTaiwanese(): String = synchronized(taiwaneseLock) {
        val (state, process) = startOnFirstUse("taiwanese", TAIWANESE_ASR_FILE, TAIWANESE_WHISPER_PORT, "zh", taiwanese)
        taiwanese = process
        state
    }

    /**
     * Same as [startTaiwanese] for the Vietnamese model (device_main.vietnamese_provider),
     * called on the first clip decoded in Vietnamese (chosen or detected).
     */
    @JvmStatic
    fun startVietnamese(): String = synchronized(vietnameseLock) {
        val (state, process) = startOnFirstUse("vietnamese", VIETNAMESE_ASR_FILE, VIETNAMESE_WHISPER_PORT, "vi",
            vietnamese)
        vietnamese = process
        state
    }

    /** Starts (or keeps) a whisper-server loaded on first use; returns the state and its process. */
    private fun startOnFirstUse(label: String, fileName: String, port: Int, language: String,
                                current: Process?): Pair<String, Process?> {
        val app = appContext ?: return "failed" to current
        current?.let { if (it.isAlive && listening(port)) return "ready" to it }
        val models = app.getExternalFilesDir("models") ?: File(app.filesDir, "models")
        val model = File(models, fileName)
        if (!model.isFile) return "missing" to current
        // Breeze-ASR-26 q8_0 peaked at 1.28x its file size on the phone (2.0 GB for 1.58 GB).
        val memory = ActivityManager.MemoryInfo()
        (app.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(memory)
        val needed = model.length() * 13 / 10 + 300L * 1024 * 1024
        if (memory.availMem < needed) {
            Log.w(TAG, "$label speech: ${memory.availMem shr 20} MB free, needs ${needed shr 20} MB")
            return "memory" to current
        }
        current?.destroy()
        val started = System.currentTimeMillis()
        val process = launch(app, "libwhisper_server.so", model, port,
            listOf("-t", whisperThreads, "-l", language), stopLeftovers = false) ?: return "failed" to null
        // whisper-server listens only after the model has loaded.
        while (System.currentTimeMillis() - started < 60_000) {
            if (!process.isAlive) return "failed" to null
            if (listening(port)) {
                Log.i(TAG, "$label speech loaded in ${System.currentTimeMillis() - started} ms")
                return "ready" to process
            }
            Thread.sleep(200)
        }
        process.destroy()
        return "failed" to null
    }

    private fun launch(app: Context, binary: String, model: File, port: Int, extra: List<String>,
                       stopLeftovers: Boolean = true): Process? {
        if (!model.isFile) {
            Log.w(TAG, "missing model ${model.absolutePath}; run scripts/push_assistant_models.ps1")
            return null
        }
        val executable = File(app.applicationInfo.nativeLibraryDir, binary)
        // Servers left by an earlier App process (force-stop or reinstall does not
        // always end them) may sit in the wrong CPU group or point at an old APK.
        if (stopLeftovers) stopStale(binary)
        if (listening(port)) {
            Log.w(TAG, "port $port is in use by another process; not starting $binary")
            return null
        }
        val command = listOf(executable.absolutePath, "-m", model.absolutePath,
            "--host", "127.0.0.1", "--port", port.toString()) + extra
        val builder = ProcessBuilder(command).redirectErrorStream(true)
        // Debug builds keep the servers' own log (start-up and timings; requests
        // are not logged at the default verbosity) for diagnosing slow phones.
        val debuggable = app.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
        builder.redirectOutput(File(if (debuggable) "${app.cacheDir}/$binary-$port.log" else "/dev/null"))
        val process = builder.start()
        synchronized(processes) { processes += process }
        Log.i(TAG, "started $binary on $port")
        return process
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
