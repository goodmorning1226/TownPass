package com.example.townpass

import android.content.Context
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity: FlutterActivity() {
    private var systemSpeech: SystemSpeech? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // On-device assistant builds include OnDeviceAssistant (src/ondevice); other
        // builds do not have the class and this does nothing.
        try {
            Class.forName("com.example.townpass.OnDeviceAssistant")
                .getMethod("start", Context::class.java)
                .invoke(null, applicationContext)
        } catch (_: ClassNotFoundException) {
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The phone's own speech recogniser for the assistant (used only when the
        // App is built with ASSISTANT_SPEECH=system).
        systemSpeech = SystemSpeech(this, flutterEngine.dartExecutor.binaryMessenger)
    }
}
