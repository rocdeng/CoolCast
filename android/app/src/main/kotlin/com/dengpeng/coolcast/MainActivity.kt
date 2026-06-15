package com.dengpeng.coolcast

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.view.View
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

@UnstableApi
class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null
    private var nativePlayer: ExoPlayer? = null
    private var nativePlayerView: PlayerView? = null
    private var lastVideoSize: VideoSize = VideoSize.UNKNOWN

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "coolcast/native_player",
            NativePlayerViewFactory(this)
        )
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.dengpeng.coolcast/device_info"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "deviceName" -> result.success(deviceName())
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.dengpeng.coolcast/native_player"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "play" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrBlank()) {
                        result.error("invalid_url", "url is required", null)
                        return@setMethodCallHandler
                    }
                    val headers = call.argument<Map<String, String>>("headers").orEmpty()
                    val initialPositionMs =
                        (call.argument<Number>("initialPositionMs") ?: 0).toLong()
                    playNative(url, headers, initialPositionMs)
                    result.success(null)
                }
                "resume" -> {
                    nativePlayer?.play()
                    result.success(null)
                }
                "pause" -> {
                    nativePlayer?.pause()
                    result.success(null)
                }
                "seekTo" -> {
                    nativePlayer?.seekTo((call.argument<Number>("positionMs") ?: 0).toLong())
                    result.success(null)
                }
                "setVolume" -> {
                    nativePlayer?.volume =
                        (call.argument<Number>("volume") ?: 1.0).toFloat().coerceIn(0f, 1f)
                    result.success(null)
                }
                "position" -> result.success(nativePlayer?.currentPosition ?: 0L)
                "duration" -> result.success(
                    nativePlayer?.duration?.takeIf { it > 0 } ?: 0L
                )
                "videoSize" -> result.success(
                    mapOf(
                        "width" to lastVideoSize.width,
                        "height" to lastVideoSize.height
                    )
                )
                "stop" -> {
                    nativePlayer?.stop()
                    nativePlayer?.clearMediaItems()
                    lastVideoSize = VideoSize.UNKNOWN
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        enterImmersiveMode()
        val wifiManager =
            applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        multicastLock = wifiManager?.createMulticastLock("coolcast-dlna-ssdp")?.apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            enterImmersiveMode()
        }
    }

    override fun onDestroy() {
        multicastLock?.takeIf { it.isHeld }?.release()
        nativePlayerView?.player = null
        nativePlayer?.release()
        nativePlayer = null
        super.onDestroy()
    }

    private fun enterImmersiveMode() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.let { controller ->
                controller.hide(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
                controller.systemBarsBehavior =
                    WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility =
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                    View.SYSTEM_UI_FLAG_FULLSCREEN or
                    View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                    View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                    View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                    View.SYSTEM_UI_FLAG_LAYOUT_STABLE
        }
    }

    private fun player(): ExoPlayer {
        nativePlayer?.let { return it }
        val httpFactory = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                15_000,
                90_000,
                2_500,
                5_000
            )
            .build()
        val player = ExoPlayer.Builder(this)
            .setMediaSourceFactory(DefaultMediaSourceFactory(httpFactory))
            .setLoadControl(loadControl)
            .build()
            .apply {
                addListener(object : Player.Listener {
                    override fun onVideoSizeChanged(videoSize: VideoSize) {
                        lastVideoSize = videoSize
                    }

                    override fun onPlayerError(error: PlaybackException) {
                        android.util.Log.e("CoolCastNativePlayer", "playback error", error)
                    }
                })
                playWhenReady = true
            }
        nativePlayer = player
        nativePlayerView?.player = player
        return player
    }

    private fun playNative(
        url: String,
        headers: Map<String, String>,
        initialPositionMs: Long
    ) {
        val mediaItem = MediaItem.Builder()
            .setUri(url)
            .setRequestMetadata(
                MediaItem.RequestMetadata.Builder()
                    .setExtras(Bundle().apply {
                        headers.forEach { (key, value) -> putString(key, value) }
                    })
                    .build()
            )
            .build()
        val httpFactory = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
            .setDefaultRequestProperties(headers)
        val mediaSource = DefaultMediaSourceFactory(httpFactory).createMediaSource(mediaItem)
        player().apply {
            setMediaSource(mediaSource)
            prepare()
            if (initialPositionMs > 0) {
                seekTo(initialPositionMs)
            }
            play()
        }
    }

    private fun attachNativePlayerView(view: PlayerView) {
        nativePlayerView = view
        view.useController = false
        view.resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
        view.setKeepContentOnPlayerReset(true)
        view.player = player()
    }

    private inner class NativePlayerViewFactory(
        private val context: Context
    ) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
        override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
            val view = PlayerView(this.context)
            attachNativePlayerView(view)
            return object : PlatformView {
                override fun getView(): View = view

                override fun dispose() {
                    if (nativePlayerView == view) {
                        nativePlayerView = null
                    }
                    view.player = null
                }
            }
        }
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
