package com.dengpeng.coolcast

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.dengpeng.coolcast/device_info"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "deviceName" -> result.success(deviceName())
                else -> result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val wifiManager =
            applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        multicastLock = wifiManager?.createMulticastLock("coolcast-dlna-ssdp")?.apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    override fun onDestroy() {
        multicastLock?.takeIf { it.isHeld }?.release()
        super.onDestroy()
    }

    private fun deviceName(): String {
        val settingName = Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME)
            ?.trim()
        if (!settingName.isNullOrEmpty()) {
            return settingName
        }

        val model = Build.MODEL?.trim().orEmpty()
        val manufacturer = Build.MANUFACTURER?.trim().orEmpty()
        if (model.isEmpty()) {
            return manufacturer
        }
        if (manufacturer.isEmpty() || model.startsWith(manufacturer, ignoreCase = true)) {
            return model
        }
        return "$manufacturer $model"
    }
}
