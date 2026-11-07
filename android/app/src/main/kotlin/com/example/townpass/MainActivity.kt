package com.example.townpass

import android.content.Context
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity: FlutterActivity() {
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
}
