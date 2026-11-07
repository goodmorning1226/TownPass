package com.example.townpass

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.speech.ModelDownloadListener
import android.speech.RecognitionListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.concurrent.LinkedBlockingQueue
import kotlin.concurrent.thread
import kotlin.math.sqrt

/**
 * Hold-to-talk with the phone's own speech recogniser, on the device only
 * (docs/AI_ASR_ABLATION.md, option C1): no audio leaves the phone and no
 * Whisper model is needed. Used only when the App is built with
 * ASSISTANT_SPEECH=system.
 *
 * The App records the microphone itself from the moment the button is pressed
 * and streams the audio to the recogniser (Android 13+ EXTRA_AUDIO_SOURCE), so
 * the start of an utterance is not lost while the recogniser starts, the
 * level bar works (the on-device recogniser reports no loudness), and
 * releasing the button ends the audio stream. Audio stays in memory.
 *
 * Dart calls start (language, biasing words), then stop, which answers with
 * {"texts": [...], "confidences": [...]} or {"error": code}. Events to Dart:
 * "level" (RMS 0-1) and "download" ({"percent"} / {"state"}) while a missing
 * language pack downloads.
 */
class SystemSpeech(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, RecognitionListener {

    private val channel = MethodChannel(messenger, "townpass/system_speech")
    private val main = Handler(Looper.getMainLooper())
    private var recognizer: SpeechRecognizer? = null
    private var waiting: MethodChannel.Result? = null
    private var finished: Map<String, Any?>? = null
    private var capture: Capture? = null
    private var timeout: Runnable? = null

    /** The language tag that worked, checked once per App run. */
    private var language: String? = null

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> start(call.argument<String>("language") ?: "zh-TW",
                call.argument<List<String>>("biasing") ?: emptyList(), result)
            "stop" -> stop(result)
            "cancel" -> {
                release()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun start(requested: String, biasing: List<String>, result: MethodChannel.Result) {
        release()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            !SpeechRecognizer.isOnDeviceRecognitionAvailable(context)) {
            result.success("on_device_unavailable")
            return
        }
        // Record at once; the language check (first time only) runs meanwhile.
        val recording = try {
            Capture { level -> main.post { channel.invokeMethod("level", level) } }.also { capture = it }
        } catch (error: Exception) {
            Log.w(TAG, "microphone failed: ${error.javaClass.simpleName}")
            result.success("microphone")
            return
        }
        val known = language
        if (known != null) {
            result.success(listen(known, biasing, recording))
            return
        }
        chooseLanguage(requested) { tag, problem ->
            if (problem != null) {
                if (capture === recording) release()
                result.success(problem)
            } else {
                language = tag
                result.success(if (capture === recording) listen(tag, biasing, recording) else null)
            }
        }
    }

    /** Starts the recogniser on the recorded stream; null or an error code. */
    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun listen(tag: String, biasing: List<String>, recording: Capture): String? {
        val speech = SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        val request = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, tag)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 5)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, false)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, recording.source)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, Capture.RATE)
            if (biasing.isNotEmpty()) {
                putStringArrayListExtra(RecognizerIntent.EXTRA_BIASING_STRINGS, ArrayList(biasing))
            }
        }
        speech.setRecognitionListener(this)
        recognizer = speech
        finished = null
        speech.startListening(request)
        return null
    }

    /** Ends the audio stream; answers when the recogniser delivers its result. */
    private fun stop(result: MethodChannel.Result) {
        capture?.finish()  // end of audio: the recogniser transcribes what it got
        val done = finished
        if (done != null) {
            release()
            result.success(done)
            return
        }
        if (recognizer == null) {
            release()
            result.success(mapOf("error" to "not_listening"))
            return
        }
        waiting = result
        val giveUp = Runnable { finish(mapOf("error" to "timeout")) }
        timeout = giveUp
        main.postDelayed(giveUp, 10_000)
    }

    private fun finish(outcome: Map<String, Any?>) {
        val answer = waiting
        if (answer != null) {
            waiting = null
            release()
            answer.success(outcome)
        } else {
            finished = outcome  // ended before the button was released
        }
    }

    private fun release() {
        timeout?.let { main.removeCallbacks(it) }
        timeout = null
        capture?.close()
        capture = null
        recognizer?.setRecognitionListener(null)
        recognizer?.destroy()
        recognizer = null
        waiting?.success(mapOf("error" to "cancelled"))
        waiting = null
    }

    /**
     * Picks the tag the on-device recogniser knows for Taiwanese Mandarin
     * (Google's is cmn-Hant-TW; others use zh-TW). A missing pack is downloaded
     * with progress reported to Dart, and "language_unavailable" returned.
     * Only language tags are logged.
     */
    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun chooseLanguage(requested: String, done: (String, String?) -> Unit) {
        val wanted = listOf(requested, "cmn-Hant-TW", "zh-Hant-TW", "zh-TW")
        val probe = SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        val ask = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        probe.checkRecognitionSupport(ask, { main.post(it) }, object : RecognitionSupportCallback {
            override fun onSupportResult(support: RecognitionSupport) {
                val installed = support.installedOnDeviceLanguages
                val pending = support.pendingOnDeviceLanguages
                Log.i(TAG, "speech languages installed=$installed pending=$pending " +
                    "supported=${support.supportedOnDeviceLanguages.size}")
                fun match(pool: List<String>) = wanted.firstNotNullOfOrNull { tag ->
                    pool.firstOrNull { it.equals(tag, ignoreCase = true) }
                }
                val ready = match(installed)
                val missing = match(support.supportedOnDeviceLanguages + pending)
                when {
                    ready != null -> {
                        probe.destroy()
                        done(ready, null)
                    }
                    missing == null -> {  // nothing useful listed: just try
                        probe.destroy()
                        done(requested, null)
                    }
                    else -> {
                        download(probe, Intent(ask).putExtra(RecognizerIntent.EXTRA_LANGUAGE, missing))
                        done(missing, "language_unavailable")
                    }
                }
            }

            override fun onError(error: Int) {
                Log.i(TAG, "speech language check failed: $error")
                probe.destroy()
                done(requested, null)
            }
        })
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun download(probe: SpeechRecognizer, request: Intent) {
        fun send(event: Map<String, Any>) {
            main.post { channel.invokeMethod("download", event) }
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            probe.triggerModelDownload(request)
            probe.destroy()
            send(mapOf("state" to "started"))
            return
        }
        send(mapOf("percent" to 0))
        probe.triggerModelDownload(request, { main.post(it) }, object : ModelDownloadListener {
            override fun onProgress(completedPercent: Int) {
                send(mapOf("percent" to completedPercent))
            }
            override fun onSuccess() {
                send(mapOf("state" to "done"))
                probe.destroy()
            }
            override fun onScheduled() {
                send(mapOf("state" to "scheduled"))  // e.g. waits for Wi-Fi
                probe.destroy()
            }
            override fun onError(error: Int) {
                send(mapOf("state" to "error"))
                probe.destroy()
            }
        })
    }

    override fun onResults(results: Bundle?) {
        val texts = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION).orEmpty()
        val confidences = results?.getFloatArray(SpeechRecognizer.CONFIDENCE_SCORES)
        if (texts.isEmpty()) {
            finish(mapOf("error" to "no_match"))
        } else {
            finish(mapOf("texts" to texts.take(5),
                "confidences" to (confidences?.take(5)?.map { it.toDouble() } ?: emptyList())))
        }
    }

    override fun onError(error: Int) {
        Log.i(TAG, "speech recognition error $error")
        val code = when (error) {
            SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "no_match"
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "permission"
            SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED, SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> {
                language = null  // check again next time
                "language_unavailable"
            }
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "busy"
            else -> "error_$error"
        }
        finish(mapOf("error" to code))
    }

    override fun onReadyForSpeech(params: Bundle?) {}
    override fun onBeginningOfSpeech() {}
    override fun onRmsChanged(rmsdB: Float) {}
    override fun onBufferReceived(buffer: ByteArray?) {}
    override fun onEndOfSpeech() {}
    override fun onPartialResults(partialResults: Bundle?) {}
    override fun onEvent(eventType: Int, params: Bundle?) {}

    /**
     * Microphone capture (16 kHz mono PCM16) streamed through a pipe to the
     * recogniser. Recording starts at once; chunks wait in memory until the
     * recogniser reads them, so nothing is lost while it starts up.
     */
    @SuppressLint("MissingPermission")  // Dart checks the permission before start
    private class Capture(private val onLevel: (Double) -> Unit) {
        companion object {
            const val RATE = 16000
        }

        private val pipe = ParcelFileDescriptor.createPipe()
        val source: ParcelFileDescriptor = pipe[0]
        private val output = ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])
        private val queue = LinkedBlockingQueue<ByteArray>()
        private val end = ByteArray(0)
        @Volatile private var recording = true
        private val record: AudioRecord

        init {
            val size = maxOf(AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT), RATE / 5 * 2)
            record = AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, RATE,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, size)
            if (record.state != AudioRecord.STATE_INITIALIZED) {
                record.release()
                throw IOException("AudioRecord not initialised")
            }
            record.startRecording()
            thread(name = "speech-capture", isDaemon = true) {
                val buffer = ByteArray(RATE / 10 * 2)  // 100 ms
                while (recording) {
                    val read = record.read(buffer, 0, buffer.size)
                    if (read > 0) {
                        queue.put(buffer.copyOf(read))
                        onLevel(rms(buffer, read))
                    }
                }
                record.release()
                queue.put(end)
            }
            thread(name = "speech-feed", isDaemon = true) {
                try {
                    while (true) {
                        val chunk = queue.take()
                        if (chunk === end) break
                        output.write(chunk)
                    }
                } catch (_: Exception) {
                } finally {
                    try { output.close() } catch (_: IOException) {}
                }
            }
        }

        /** Stops recording; the stream ends after the buffered audio. */
        fun finish() {
            if (!recording) return
            recording = false
            try { record.stop() } catch (_: Exception) {}
        }

        fun close() {
            finish()
            queue.clear()
            queue.put(end)
            try { source.close() } catch (_: IOException) {}
        }

        private fun rms(pcm: ByteArray, length: Int): Double {
            var sum = 0.0
            var i = 0
            while (i + 1 < length) {
                val sample = ((pcm[i + 1].toInt() shl 8) or (pcm[i].toInt() and 0xff)).toShort() / 32768.0
                sum += sample * sample
                i += 2
            }
            return sqrt(sum / maxOf(1, length / 2))
        }
    }

    private companion object {
        const val TAG = "TownPassAssistant"
    }
}
