package com.dengpeng.coolcast

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
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
}
