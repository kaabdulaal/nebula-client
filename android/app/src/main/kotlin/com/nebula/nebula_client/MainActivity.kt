package com.nebula.nebula_client

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity: FlutterFragmentActivity() {
    companion object {
        init {
            System.loadLibrary("nebula_core")
        }
    }

    override fun onDestroy() {
        // Trigger native cleanup to lock the vault when app is destroyed
        nebulaCleanup()
        super.onDestroy()
    }

    private external fun nebulaCleanup()
}
