package com.wordnest.app

import android.content.Intent
import android.os.Build
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.wordnest.app/speech_models",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "installedOnDeviceLanguages" -> installedOnDeviceLanguages(result)
                else -> result.notImplemented()
            }
        }
    }

    private fun installedOnDeviceLanguages(result: MethodChannel.Result) {
        // RecognitionSupport's installed/supported distinction arrived in API
        // 33. On older Android versions an empty list deliberately sends the
        // app through the default phone recogniser rather than falsely forcing
        // a model that may not exist.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            !SpeechRecognizer.isOnDeviceRecognitionAvailable(this)
        ) {
            result.success(emptyList<String>())
            return
        }

        try {
            val recognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(this)
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(
                    RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                    RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
                )
            }

            recognizer.checkRecognitionSupport(
                intent,
                mainExecutor,
                object : RecognitionSupportCallback {
                    override fun onSupportResult(support: RecognitionSupport) {
                        result.success(support.installedOnDeviceLanguages)
                        recognizer.destroy()
                    }

                    override fun onError(error: Int) {
                        // Unknown is handled like no installed model. The default
                        // recogniser can still use its on-device or online route.
                        result.success(emptyList<String>())
                        recognizer.destroy()
                    }
                },
            )
        } catch (_: RuntimeException) {
            // Availability can change between the check and recogniser creation.
            result.success(emptyList<String>())
        }
    }
}
