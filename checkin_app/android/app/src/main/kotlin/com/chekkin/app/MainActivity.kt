package com.chekkin.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "chekkin/dev").setMethodCallHandler { call, result ->
            when (call.method) {
                "appCheckDebugSecret" -> result.success(appCheckDebugSecret())
                else -> result.notImplemented()
            }
        }
    }

    /**
     * The App Check debug provider's secret for this install, or null if it
     * hasn't made one (only DEV_TOOLS builds use that provider). The SDK only
     * logs it, so the dev screen reads it from the SDK's preferences file to
     * show it for adding in the Firebase console.
     */
    private fun appCheckDebugSecret(): String? {
        val stores = File(applicationInfo.dataDir, "shared_prefs")
            .listFiles { file -> file.name.startsWith(DEBUG_STORE_PREFIX) } ?: return null
        for (store in stores) {
            val prefs = getSharedPreferences(store.name.removeSuffix(".xml"), MODE_PRIVATE)
            prefs.getString(DEBUG_SECRET_KEY, null)?.let { return it }
        }
        return null
    }

    private companion object {
        // From firebase-appcheck-debug's StorageHelper.
        const val DEBUG_STORE_PREFIX = "com.google.firebase.appcheck.debug.store."
        const val DEBUG_SECRET_KEY = "com.google.firebase.appcheck.debug.DEBUG_SECRET"
    }
}
