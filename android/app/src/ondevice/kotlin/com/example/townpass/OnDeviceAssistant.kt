package com.example.townpass

import android.app.Activity
import android.app.ActivityManager
import android.app.Application
import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.chaquo.python.Kwarg
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
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
 *  - llama-server --reranking (decision classifier) 127.0.0.1:8778, instead of the
 *    decision model when built with ASSISTANT_DECISION_MODEL=classifier
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
    /** Opt-in option B' (build with ASSISTANT_DECISION_MODEL=classifier,
     *  docs/AI_DECISION_CLASSIFIER.md): no decision model at all. A cross-encoder
     *  fine-tuned from Microsoft multilingual-e5-small (MIT, 132 MB q8_0) scores the
     *  candidate pages; library and guide decisions follow rules. Downloaded by the
     *  App like the decision model (models.json "classifier"). */
    const val CLASSIFIER_MODEL_FILE = "townpass-decision-e5-ce-v1-q8_0.gguf"
    /** Optional separate Chinese model (e.g. Breeze-ASR-25 q8_0, branch
     *  feat/asr-breeze-q8). Without it the multilingual model serves Chinese too. */
    const val ASR_FILE = "ggml-whisper-chinese.bin"  // push_assistant_models.ps1 -Chinese

    /** Multilingual Whisper (default Whisper small q8_0: 1.4 s a clip) for Chinese
     *  when no separate model is pushed, en/ja/vi/id/tl and language detection. */
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
    private const val CLASSIFIER_PORT = 8778  // device_main.PORTS["classifier"]
    /** The decision model's server arguments (start-up and [ensureServer]): three
     *  slots of 2048 tokens, one each keeps the service, library and guide policy in
     *  the prompt cache (requests are <= ~1000 tokens; the backend sends one request
     *  at a time). --cache-ram 0: llama.cpp's host-RAM prompt cache (8 GiB by default)
     *  grew the server by 1.8-2.4 GB in 40 turns on the PC; with a slot per policy
     *  nothing is evicted, so it gains nothing (docs/SPEED_CACHE_EXPERIMENT.md).
     *  --reasoning off: no thinking block before the answer; with a grammar it could
     *  run to the 180-token limit (~30 s on a phone) and fail. */
    private val DECISION_ARGS = listOf("-c", "6144", "-np", "3", "--cache-ram", "0", "--reasoning", "off", "--no-webui")
    /** e5 for the FAQ and semantic retrieval: queried only after a decision has
     *  finished, one short query at a time: two threads, one 512-token slot (~130 MB). */
    private val EMBEDDING_ARGS = listOf("--embedding", "--pooling", "mean", "-c", "512", "-b", "512", "-ub", "512",
        "-np", "1", "-t", "2", "--no-webui")
    /** The decision classifier (option B'): one score per (request, candidate page)
     *  pair, ~50 tokens each, a decision scores up to ~5 pairs. --pooling rank: the
     *  GGUF does not say its pooling. Four 512-token slots score a decision's pairs in
     *  one batch; two threads, like e5 (it runs only between other steps). */
    private val CLASSIFIER_ARGS = listOf("--reranking", "--pooling", "rank", "-c", "2048", "-np", "4",
        "-b", "512", "-ub", "512", "-t", "2", "--no-webui")
    private val processes = mutableListOf<Process>()
    private val serverLock = Any()
    private const val ASSISTANT_PORT = 8765  // device_main: the backend and the speech endpoint
    private const val ASR_PORT = 8770

    /** A model server this App process launched ([launch] with a name): [status] reports
     *  it and [restartServer] runs it again when it stops answering. */
    private class Running(val name: String, val port: Int, val llama: Boolean, val process: Process) {
        val launchedAt = System.currentTimeMillis()
        /** It answered GET /health at least once since it was launched. */
        @Volatile
        var answered = false
    }
    private val running = ConcurrentHashMap<String, Running>()
    /** First-use servers: listed by [status] but not waited for. */
    private val optionalServers = setOf("taiwanese", "vietnamese")
    private val recovering = AtomicBoolean(false)
    /** The decision model file chosen in [start] (Ministral, or Gemma when built for it and present). */
    @Volatile
    private var decisionFileName = MODEL_FILE
    /** Built with ASSISTANT_DECISION_MODEL=classifier: no decision model is started. */
    @Volatile
    private var classifierMode = false

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
        // Back in the foreground: run again any server that stopped while the App was
        // away (as iOS's recover() does on didBecomeActive).
        (app as? Application)?.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityResumed(activity: Activity) {
                thread(name = "assistant-recover", isDaemon = true) { recover() }
            }
            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
            override fun onActivityStarted(activity: Activity) {}
            override fun onActivityPaused(activity: Activity) {}
            override fun onActivityStopped(activity: Activity) {}
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
            override fun onActivityDestroyed(activity: Activity) {}
        })
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
                // Option B': the classifier instead of a decision model. Not replaced by
                // Ministral when its file is missing: the App downloads it (132 MB).
                classifierMode = decisionModel == "classifier"
                val classifierFile = File(models, CLASSIFIER_MODEL_FILE)
                val decisionFile = File(models, if (decisionModel == "gemma") GEMMA_MODEL_FILE else MODEL_FILE)
                decisionFileName = decisionFile.name
                // The phone's total memory picks which models it downloads (tier,
                // docs/AI_MODEL_DOWNLOAD.md); 12 GB phones report ~11,200 MB.
                val memory = ActivityManager.MemoryInfo()
                (app.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(memory)
                val deviceMain = Python.getInstance().getModule("device_main")
                // A server that stops answering (Android may kill child processes while the
                // App is in the background) is started again: device_main.Restarter calls
                // [restartServer] through device_main.java_server_restarter, as iOS does
                // through its native restarter (2026-11-13).
                val restarter = deviceMain["java_server_restarter"]
                val info = deviceMain
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
                        Kwarg("decision_model", decisionModel),
                        // Missing files are downloaded by the App (models.py); [ensureServer]
                        // then starts their servers.
                        Kwarg("models_dir", models.absolutePath),
                        Kwarg("ram_mb", memory.totalMem shr 20),
                        Kwarg("platform", "android"),
                        Kwarg("server_restarter", restarter)).toString()
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
                            listOf("-t", threads, "-l", "zh"), name = "chinese")
                    }
                    if (multilingual) {
                        // Same binary; a second instance keeps the Chinese one just started.
                        launch(app, "libwhisper_server.so", File(models, MULTI_ASR_FILE), MULTI_WHISPER_PORT,
                            listOf("-t", threads, "-l", "auto"), stopLeftovers = !chinese, name = "multilingual")
                    }
                    if (gate) {
                        // Detection only (encoder + one step, ~130 MB): 4 threads were faster
                        // than 6 for Whisper tiny on a vivo V2511 (0.18 s vs 0.27 s a clip).
                        launch(app, "libwhisper_server.so", File(models, GATE_ASR_FILE), GATE_WHISPER_PORT,
                            listOf("-t", threads.toInt().coerceAtMost(4).toString(), "-l", "auto"),
                            stopLeftovers = false, name = "gate")
                    }
                } else {
                    stopStale("libwhisper_server.so")
                }
                // Same arguments for both decision models (Gemma 4 needs no extra flag:
                // its chat template has a system role, and --reasoning off keeps its
                // thinking channel closed).
                // Stops leftover llama-server copies first, even when the model is not on
                // the phone yet (then nothing starts; ensureServer starts it once downloaded).
                if (classifierMode) {
                    // No decision model in this mode, even if its file is on the phone.
                    if (classifierFile.isFile) {
                        launch(app, "libllama_server.so", classifierFile, CLASSIFIER_PORT, CLASSIFIER_ARGS,
                            name = "classifier")
                    } else {
                        stopStale("libllama_server.so")
                        Log.i(TAG, "no $CLASSIFIER_MODEL_FILE yet; the App downloads it (docs/AI_MODEL_DOWNLOAD.md)")
                    }
                } else if (decisionFile.isFile) {
                    launch(app, "libllama_server.so", decisionFile, MODEL_PORT, llamaCpuArgs() + DECISION_ARGS,
                        name = "decision")
                } else {
                    stopStale("libllama_server.so")
                    Log.i(TAG, "no ${decisionFile.name} yet; the App downloads it (docs/AI_MODEL_DOWNLOAD.md)")
                }
                if (faq) {
                    // Same binary, started after the decision model (whose launch stops
                    // leftover copies).
                    launch(app, "libllama_server.so", File(models, FAQ_MODEL_FILE), FAQ_EMBED_PORT,
                        EMBEDDING_ARGS, stopLeftovers = false, name = "embedding")
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

    /**
     * Starts a model server whose file arrived after start-up: the App downloads the
     * models (docs/AI_MODEL_DOWNLOAD.md) and device_main.Activator calls this on a
     * backend thread once a file is in place. [name]: "decision", "multilingual",
     * "gate", "embedding" or "classifier" (option B' builds only). Waits until the model has loaded. Returns "ready"
     * (also when it was already running), "missing" (no file), "memory" (not enough
     * free memory now; tried again later) or "failed".
     */
    @JvmStatic
    fun ensureServer(name: String): String = synchronized(serverLock) {
        val app = appContext ?: return "failed"
        val models = app.getExternalFilesDir("models") ?: File(app.filesDir, "models")
        val (fileName, port) = when (name) {
            "decision" -> decisionFileName to MODEL_PORT
            "multilingual" -> MULTI_ASR_FILE to MULTI_WHISPER_PORT
            "gate" -> GATE_ASR_FILE to GATE_WHISPER_PORT
            "embedding" -> FAQ_MODEL_FILE to FAQ_EMBED_PORT
            "classifier" -> CLASSIFIER_MODEL_FILE to CLASSIFIER_PORT
            else -> return "failed"
        }
        // One kind of decision server per build: no decision model in classifier mode.
        if ((name == "decision" && classifierMode) || (name == "classifier" && !classifierMode)) return "failed"
        val llama = name == "decision" || name == "embedding" || name == "classifier"
        fun loaded() = if (llama) healthy(port) else listening(port)
        fun waitLoaded(process: Process?): String {
            val deadline = System.currentTimeMillis() + 180_000
            while (System.currentTimeMillis() < deadline) {
                if (process != null && !process.isAlive) return "failed"
                if (loaded()) return "ready"
                Thread.sleep(250)
            }
            return "failed"
        }
        if (loaded()) return "ready"
        // A llama-server that listens but is not healthy yet is still loading.
        if (listening(port)) return waitLoaded(null)
        val model = File(models, fileName)
        if (!model.isFile) return "missing"
        val memory = ActivityManager.MemoryInfo()
        (app.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(memory)
        val needed = model.length() + 300L * 1024 * 1024
        if (memory.availMem < needed) {
            Log.w(TAG, "$name: ${memory.availMem shr 20} MB free, needs ${needed shr 20} MB; next launch")
            return "memory"
        }
        // Forked from the foreground CPU group, like the servers started at launch.
        waitForForeground()
        val started = System.currentTimeMillis()
        val process = launchServer(app, name, model, port) ?: return "failed"
        val state = waitLoaded(process)
        Log.i(TAG, "$name started after download: $state in ${System.currentTimeMillis() - started} ms")
        if (state != "ready") process.destroy()
        state
    }

    /** [ensureServer]'s and [restartServer]'s launch: the same arguments as at start-up. */
    private fun launchServer(app: Context, name: String, model: File, port: Int): Process? = when (name) {
        "decision" -> launch(app, "libllama_server.so", model, port, llamaCpuArgs() + DECISION_ARGS,
            stopLeftovers = false, name = name)
        "embedding" -> launch(app, "libllama_server.so", model, port, EMBEDDING_ARGS, stopLeftovers = false, name = name)
        "classifier" -> launch(app, "libllama_server.so", model, port, CLASSIFIER_ARGS, stopLeftovers = false,
            name = name)
        "gate" -> launch(app, "libwhisper_server.so", model, port,
            listOf("-t", whisperThreads.toInt().coerceAtMost(4).toString(), "-l", "auto"), stopLeftovers = false,
            name = name)
        "chinese" -> launch(app, "libwhisper_server.so", model, port, listOf("-t", whisperThreads, "-l", "zh"),
            stopLeftovers = false, name = name)
        else -> launch(app, "libwhisper_server.so", model, port, listOf("-t", whisperThreads, "-l", "auto"),
            stopLeftovers = false, name = name)
    }

    /** The model file of a server [restartServer] can start again ([ensureServer]'s, and "chinese"). */
    private fun serverFile(name: String): String? = when (name) {
        "decision" -> decisionFileName
        "multilingual" -> MULTI_ASR_FILE
        "gate" -> GATE_ASR_FILE
        "embedding" -> FAQ_MODEL_FILE
        "classifier" -> CLASSIFIER_MODEL_FILE
        "chinese" -> ASR_FILE
        else -> null
    }

    /**
     * The backend's call when a model server stopped answering (device_main.Restarter
     * through device_main.java_server_restarter; iOS: OnDeviceAssistant.swift
     * restartServer). [request]: a server name ("decision", "chinese", "multilingual",
     * "gate", "embedding", "classifier", "taiwanese", "vietnamese"), with ":error" when it
     * answers /health but fails requests (restarted anyway). Asks GET /health first
     * (up to 3 s); one that does not answer is ended if its process is still there (also
     * when stopped with SIGSTOP) and started again like [ensureServer], from the
     * foreground CPU group, one at a time. Returns "ready" (it answers), "restarted",
     * "busy" (still loading after its launch; asked again later), "missing" or "failed"
     * (also while the App is in the background: forked there it would stay on the little
     * cores; the next resume runs it again, [recover]).
     */
    @JvmStatic
    fun restartServer(request: String): String {
        val name = request.substringBefore(':')
        val failing = request.substringAfter(':', "") == "error"
        val server = running[name] ?: return "failed"  // never started: nothing to restart
        if (!failing) {
            val deadline = System.currentTimeMillis() + 3_000
            while (System.currentTimeMillis() < deadline) {
                if (answers(server)) return "ready"
                Thread.sleep(250)
            }
        }
        // A whisper-server listens only once loaded: a live one launched shortly before
        // that never answered is still loading, not stuck.
        if (!failing && server.process.isAlive && !server.answered &&
            System.currentTimeMillis() - server.launchedAt < 120_000) return "busy"
        if (!inForeground()) {
            Log.i(TAG, "$name does not answer; it is started again once the App is in the foreground")
            return "failed"
        }
        if (name in optionalServers) return restartFirstUse(name, server)
        return synchronized(serverLock) {
            val current = running[name] ?: return@synchronized "failed"
            // Restarted by another call meanwhile.
            if (current !== server && answers(current)) return@synchronized "ready"
            val app = appContext ?: return@synchronized "failed"
            val fileName = serverFile(name) ?: return@synchronized "failed"
            val model = File(app.getExternalFilesDir("models") ?: File(app.filesDir, "models"), fileName)
            if (!model.isFile) return@synchronized "missing"
            Log.i(TAG, "$name does not answer${if (failing) " (server errors)" else ""}; starting it again")
            stopServer(current)
            val began = System.currentTimeMillis()
            val process = launchServer(app, name, model, current.port) ?: return@synchronized "failed"
            val restarted = running[name]
            var state = "failed"
            while (System.currentTimeMillis() - began < 180_000) {
                if (!process.isAlive) break
                if (restarted != null && answers(restarted)) {
                    state = "restarted"
                    break
                }
                Thread.sleep(250)
            }
            Log.i(TAG, "$name restart: $state in ${System.currentTimeMillis() - began} ms")
            if (state != "restarted") process.destroy()
            state
        }
    }

    /** The Taiwanese / Vietnamese server: ended, then loaded again by its first-use starter. */
    private fun restartFirstUse(name: String, server: Running): String {
        synchronized(if (name == "taiwanese") taiwaneseLock else vietnameseLock) {
            stopServer(server)
            if (name == "taiwanese") taiwanese = null else vietnamese = null
        }
        val state = if (name == "taiwanese") startTaiwanese() else startVietnamese()
        return if (state == "ready") "restarted" else state
    }

    /** Ends a server's process (SIGKILL when it does not exit, e.g. stopped) and any
     *  other copy still holding its port, then waits until the port is free. */
    private fun stopServer(server: Running) {
        val process = server.process
        if (process.isAlive) {
            process.destroy()
            val deadline = System.currentTimeMillis() + 2_000
            while (process.isAlive && System.currentTimeMillis() < deadline) Thread.sleep(100)
            if (process.isAlive) process.destroyForcibly()
        }
        stopOnPort(if (server.llama) "libllama_server.so" else "libwhisper_server.so", server.port)
        val deadline = System.currentTimeMillis() + 5_000
        while (listening(server.port) && System.currentTimeMillis() < deadline) Thread.sleep(100)
    }

    /** Kills this App's (same user id) copies of [binary] serving [port]. */
    private fun stopOnPort(binary: String, port: Int) {
        val self = android.os.Process.myPid()
        File("/proc").listFiles().orEmpty().forEach { dir ->
            val pid = dir.name.toIntOrNull() ?: return@forEach
            if (pid == self) return@forEach
            val args = try {
                File(dir, "cmdline").readText().split('\u0000')
            } catch (_: Exception) {
                return@forEach
            }
            val at = args.indexOf("--port")
            if (args.firstOrNull()?.endsWith("/$binary") == true && at >= 0 &&
                args.getOrNull(at + 1) == port.toString()) {
                android.os.Process.killProcess(pid)
                Log.i(TAG, "stopped $binary on $port (pid $pid)")
            }
        }
    }

    /** Whether a started server answers now: llama-server GET /health 200 (503: still
     *  loading); whisper-server any HTTP answer. Remembers that it answered. */
    private fun answers(server: Running): Boolean {
        val code = healthCode(server.port)
        val ok = if (server.llama) code == 200 else code > 0
        if (ok) server.answered = true
        return ok
    }

    /** After the App comes back to the foreground: every started server that does not
     *  answer is started again ([restartServer]), one at a time, one recovery at a time.
     *  A first-use server (Taiwanese, Vietnamese) that is gone is left to its next use. */
    private fun recover() {
        if (!recovering.compareAndSet(false, true)) return
        try {
            for (server in running.values.toList()) {
                if (answers(server)) continue
                if (server.name in optionalServers && !server.process.isAlive) continue
                Log.i(TAG, "resume: ${server.name} ${restartServer(server.name)}")
            }
        } catch (error: Exception) {
            Log.w(TAG, "resume recovery failed", error)
        } finally {
            recovering.set(false)
        }
    }

    /**
     * Which servers answer now, for Dart's OnDeviceResume (lib/service/assistant_on_device.dart),
     * which waits for "ready" before the first request after the App comes back. The same
     * shape as iOS (OnDeviceAssistant.swift status): started, python (the backend's two
     * loopback ports), servers (name -> answers GET /health) and ready (python and every
     * start-up server answer; the Taiwanese and Vietnamese servers are listed, not
     * required). Nothing launched (not started yet, no model files) is ready too.
     */
    @JvmStatic
    fun status(): Map<String, Any> {
        val python = listening(ASSISTANT_PORT) && listening(ASR_PORT)
        val servers = running.values.associate { it.name to answers(it) }
        val ready = !started || servers.isEmpty() ||
            (python && servers.all { (name, ok) -> ok || name in optionalServers })
        if (!ready) Log.i(TAG, "status: not ready yet (python $python, servers $servers)")
        return mapOf("started" to started, "python" to python, "servers" to servers, "ready" to ready)
    }

    /** The Dart channel (MainActivity.configureFlutterEngine registers it by reflection):
     *  "status"; "start" answers at once (Android starts the assistant natively, onCreate). */
    @JvmStatic
    fun register(messenger: BinaryMessenger) {
        val main = Handler(Looper.getMainLooper())
        MethodChannel(messenger, "townpass/on_device_assistant").setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> thread(name = "assistant-status", isDaemon = true) {
                    val info = try {
                        status()
                    } catch (error: Exception) {
                        Log.w(TAG, "status failed", error)
                        mapOf("ready" to true)  // nothing known: do not hold requests
                    }
                    main.post { result.success(info) }
                }
                "start" -> result.success("android: started with the App")
                else -> result.notImplemented()
            }
        }
    }

    /** Whether llama-server on [port] has loaded its model (GET /health answers 200). */
    private fun healthy(port: Int) = healthCode(port, readMs = 1000) == 200

    /** GET /health's status code on [port]; -1 when refused or silent (a stopped server). */
    private fun healthCode(port: Int, readMs: Int = 2000): Int = try {
        val connection = java.net.URL("http://127.0.0.1:$port/health").openConnection() as java.net.HttpURLConnection
        connection.connectTimeout = 500
        connection.readTimeout = readMs
        try {
            connection.responseCode
        } finally {
            connection.disconnect()
        }
    } catch (_: Exception) {
        -1
    }

    /** Whether this thread is in the foreground CPU group within 2 s (unknown counts as yes). */
    private fun inForeground(): Boolean {
        val deadline = System.currentTimeMillis() + 2_000
        while (true) {
            val group = cpuGroup()
            if (group == null || group == "/top-app") return true
            if (System.currentTimeMillis() >= deadline) return false
            Thread.sleep(200)
        }
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
            listOf("-t", whisperThreads, "-l", language), stopLeftovers = false, name = label) ?: return "failed" to null
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
                       stopLeftovers: Boolean = true, name: String? = null): Process? {
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
        if (name != null) running[name] = Running(name, port, binary == "libllama_server.so", process)
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
