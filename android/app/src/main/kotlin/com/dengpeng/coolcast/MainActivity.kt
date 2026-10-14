package com.dengpeng.coolcast

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.view.View
import androidx.core.content.FileProvider
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
import java.io.File

@UnstableApi
class MainActivity : FlutterActivity() {
    companion object {
        private const val LOCATION_PERMISSION_REQUEST_CODE = 1001
        private const val NATIVE_PLAYER_TAG = "CoolCastNativePlayer"
        private const val APP_INSTALLER_TAG = "CoolCastAppInstaller"
    }

    private var multicastLock: WifiManager.MulticastLock? = null
    private var nativePlayer: ExoPlayer? = null
    private var nativePlayerView: PlayerView? = null
    private var lastVideoSize: VideoSize = VideoSize.UNKNOWN
    private var pendingInstallApkFile: File? = null

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
                "wifiName" -> result.success(wifiName())
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.dengpeng.coolcast/app_installer"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    val filePath = call.argument<String>("filePath")
                        ?: call.argument<String>("path")
                    if (filePath.isNullOrBlank()) {
                        result.error("invalid_path", "filePath is required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val status = installApk(filePath)
                        result.success(status)
                    } catch (error: Throwable) {
                        Log.e(APP_INSTALLER_TAG, "installApk failed", error)
                        result.error(
                            "install_failed",
                            error.message ?: "Failed to launch APK installer",
                            null
                        )
                    }
                }
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
                "videoBitrate" -> result.success(
                    nativePlayer?.videoFormat?.let { format ->
                        format.averageBitrate.takeIf { it > 0 }
                            ?: format.peakBitrate.takeIf { it > 0 }
                    }?.div(8) ?: 0
                )
                "debugState" -> result.success(nativePlayerDebugState())
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
        window.attributes = window.attributes.apply {
            layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        enterImmersiveMode()
        requestWifiNamePermissionIfNeeded()
        val wifiManager =
            applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        multicastLock = wifiManager?.createMulticastLock("coolcast-dlna-ssdp")?.apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    override fun onResume() {
        super.onResume()
        resumePendingApkInstallIfPermitted()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            enterImmersiveMode()
            resumePendingApkInstallIfPermitted()
        }
    }

    override fun onDestroy() {
        multicastLock?.takeIf { it.isHeld }?.release()
        nativePlayerView?.player = null
        nativePlayer?.release()
        nativePlayer = null
        super.onDestroy()
    }

    private fun installApk(filePath: String): String {
        val sourceFile = File(filePath)
        require(sourceFile.exists() && sourceFile.isFile && sourceFile.length() > 0L) {
            "APK file does not exist or is empty: $filePath"
        }
        val sharedDir = File(cacheDir, "shared_apks").apply { mkdirs() }
        val safeName = sourceFile.name
            .replace(Regex("[^A-Za-z0-9._-]"), "_")
            .let { if (it.endsWith(".apk", ignoreCase = true)) it else "$it.apk" }
        val targetFile = File(sharedDir, safeName)
        if (sourceFile.canonicalPath != targetFile.canonicalPath) {
            sourceFile.copyTo(targetFile, overwrite = true)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            pendingInstallApkFile = targetFile
            val permissionIntent = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName")
            ).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(permissionIntent)
            return "permission_requested"
        }
        pendingInstallApkFile = null
        launchPackageInstaller(targetFile)
        return "launched"
    }

    private fun resumePendingApkInstallIfPermitted() {
        val pendingFile = pendingInstallApkFile ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            return
        }
        pendingInstallApkFile = null
        if (pendingFile.exists()) {
            try {
                launchPackageInstaller(pendingFile)
            } catch (error: Throwable) {
                Log.e(APP_INSTALLER_TAG, "Failed to resume pending APK install", error)
            }
        }
    }

    private fun launchPackageInstaller(apkFile: File) {
        val apkUri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            apkFile
        )
        val installIntent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(apkUri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(installIntent)
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
                60_000,
                7_000,
                7_000
            )
            .build()
        val player = ExoPlayer.Builder(this)
            .setMediaSourceFactory(DefaultMediaSourceFactory(httpFactory))
            .setLoadControl(loadControl)
            .build()
            .apply {
                addListener(object : Player.Listener {
                    override fun onPlaybackStateChanged(playbackState: Int) {
                        logNativePlayerState("state=${playbackStateName(playbackState)}")
                    }

                    override fun onIsPlayingChanged(isPlaying: Boolean) {
                        logNativePlayerState("isPlaying=$isPlaying")
                    }

                    override fun onVideoSizeChanged(videoSize: VideoSize) {
                        lastVideoSize = videoSize
                        logNativePlayerState("videoSize=${videoSize.width}x${videoSize.height}")
                    }

                    override fun onPlayerError(error: PlaybackException) {
                        Log.e(NATIVE_PLAYER_TAG, "playback error", error)
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

    private fun nativePlayerDebugState(): Map<String, Any> {
        val player = nativePlayer
        return mapOf(
            "state" to playbackStateName(player?.playbackState ?: Player.STATE_IDLE),
            "playWhenReady" to (player?.playWhenReady ?: false),
            "isPlaying" to (player?.isPlaying ?: false),
            "positionMs" to (player?.currentPosition ?: 0L),
            "durationMs" to (player?.duration?.takeIf { it > 0 } ?: 0L),
            "bufferedMs" to (player?.bufferedPosition ?: 0L),
            "videoWidth" to lastVideoSize.width,
            "videoHeight" to lastVideoSize.height
        )
    }

    private fun logNativePlayerState(reason: String) {
        val state = nativePlayerDebugState()
        Log.i(
            NATIVE_PLAYER_TAG,
            "$reason state=${state["state"]} playWhenReady=${state["playWhenReady"]} " +
                "isPlaying=${state["isPlaying"]} pos=${state["positionMs"]} " +
                "duration=${state["durationMs"]} buffered=${state["bufferedMs"]} " +
                "size=${state["videoWidth"]}x${state["videoHeight"]}"
        )
    }

    private fun playbackStateName(playbackState: Int): String =
        when (playbackState) {
            Player.STATE_IDLE -> "IDLE"
            Player.STATE_BUFFERING -> "BUFFERING"
            Player.STATE_READY -> "READY"
            Player.STATE_ENDED -> "ENDED"
            else -> playbackState.toString()
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

    private fun wifiName(): String {
        val wifiManager =
            applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        val ssid = wifiManager?.connectionInfo?.ssid
            ?.trim()
            ?.trim('"')
            .orEmpty()
        if (ssid.isEmpty() || ssid.equals("<unknown ssid>", ignoreCase = true)) {
            return "当前局域网"
        }
        return ssid
    }

    private fun requestWifiNamePermissionIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return
        }
        if (
            checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        requestPermissions(
            arrayOf(android.Manifest.permission.ACCESS_FINE_LOCATION),
            LOCATION_PERMISSION_REQUEST_CODE
        )
    }
}
