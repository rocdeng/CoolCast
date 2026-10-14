import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../models/cast_models.dart';
import '../services/http_cast_install.dart';

const MethodChannel deviceInfoChannel =
    MethodChannel('com.dengpeng.coolcast/device_info');
const MethodChannel appInstallerChannel =
    MethodChannel('com.dengpeng.coolcast/app_installer');
const MethodChannel nativePlayerChannel =
    MethodChannel('com.dengpeng.coolcast/native_player');
const String nativePlayerViewType = 'coolcast/native_player';
const String upnpServerHeader =
    'Android/14 UPnP/1.0 BiliTV/$biliProjectionBuild';

abstract class CoolCastPlayer {
  bool get isInitialized;
  Duration get position;
  Duration get duration;
  Size? get size;
  int? get bitrate;

  Future<void> initialize();
  Future<void> play();
  Future<void> pause();
  Future<void> seekTo(Duration position);
  Future<void> setVolume(double volume);
  Future<void> dispose();
}

class FlutterVideoPlayerController implements CoolCastPlayer {
  FlutterVideoPlayerController(
    Uri uri, {
    required Map<String, String> httpHeaders,
  }) : _controller = VideoPlayerController.networkUrl(
          uri,
          httpHeaders: httpHeaders,
        );

  final VideoPlayerController _controller;

  VideoPlayerController get controller => _controller;

  @override
  bool get isInitialized => _controller.value.isInitialized;

  @override
  Duration get position => _controller.value.position;

  @override
  Duration get duration => _controller.value.duration;

  @override
  Size? get size => _controller.value.size;

  @override
  int? get bitrate => null;

  double get aspectRatio => _controller.value.aspectRatio;

  @override
  Future<void> initialize() => _controller.initialize();

  @override
  Future<void> play() => _controller.play();

  @override
  Future<void> pause() => _controller.pause();

  @override
  Future<void> seekTo(Duration position) => _controller.seekTo(position);

  @override
  Future<void> setVolume(double volume) => _controller.setVolume(volume);

  @override
  Future<void> dispose() => _controller.dispose();
}

class NativePlayerController implements CoolCastPlayer {
  NativePlayerController(
    this.url, {
    required this.httpHeaders,
    this.initialPosition = Duration.zero,
  });

  final String url;
  final Map<String, String> httpHeaders;
  final Duration initialPosition;

  bool _isInitialized = false;
  Duration _lastPosition = Duration.zero;
  Duration _lastDuration = Duration.zero;
  Size? _lastSize;
  int? _lastBitrate;

  @override
  bool get isInitialized => _isInitialized;

  @override
  Duration get position => _lastPosition;

  @override
  Duration get duration => _lastDuration;

  @override
  Size? get size => _lastSize;

  @override
  int? get bitrate => _lastBitrate;

  @override
  Future<void> initialize() async {
    await nativePlayerPlay(
      url,
      headers: httpHeaders,
      initialPosition: initialPosition,
    );
    _isInitialized = true;
    await refreshStatus();
  }

  @override
  Future<void> play() async {
    await nativePlayerChannel.invokeMethod<void>('resume');
    await refreshStatus();
  }

  @override
  Future<void> pause() async {
    await nativePlayerChannel.invokeMethod<void>('pause');
    await refreshStatus();
  }

  @override
  Future<void> seekTo(Duration position) async {
    await nativePlayerSeekTo(position);
    await refreshStatus();
  }

  @override
  Future<void> setVolume(double volume) async {
    await nativePlayerChannel.invokeMethod<void>('setVolume', {
      'volume': volume,
    });
  }

  @override
  Future<void> dispose() async {
    await nativePlayerChannel.invokeMethod<void>('stop');
    _isInitialized = false;
    _lastPosition = Duration.zero;
    _lastDuration = Duration.zero;
    _lastSize = null;
    _lastBitrate = null;
  }

  Future<void> refreshStatus() async {
    _lastPosition = await nativePlayerPosition();
    _lastDuration = await nativePlayerDuration();
    _lastSize = await nativePlayerVideoSize();
    _lastBitrate = await nativePlayerVideoBitrate();
  }
}

Future<void> nativePlayerPlay(
  String url, {
  required Map<String, String> headers,
  Duration initialPosition = Duration.zero,
}) =>
    nativePlayerChannel.invokeMethod<void>('play', {
      'url': url,
      'headers': headers,
      'initialPositionMs': initialPosition.inMilliseconds,
    });

Future<void> nativePlayerSeekTo(Duration position) =>
    nativePlayerChannel.invokeMethod<void>('seekTo', {
      'positionMs': position.inMilliseconds,
    });

Future<Duration> nativePlayerPosition() async {
  final value = await nativePlayerChannel.invokeMethod<Object?>('position');
  return Duration(milliseconds: intFromNativeValue(value));
}

Future<Duration> nativePlayerDuration() async {
  final value = await nativePlayerChannel.invokeMethod<Object?>('duration');
  return Duration(milliseconds: intFromNativeValue(value));
}

Future<Size?> nativePlayerVideoSize() async {
  final value = await nativePlayerChannel.invokeMethod<Object?>('videoSize');
  if (value is! Map) {
    return null;
  }
  final width = intFromNativeValue(value['width']);
  final height = intFromNativeValue(value['height']);
  if (width <= 0 || height <= 0) {
    return null;
  }
  return Size(width.toDouble(), height.toDouble());
}

Future<int?> nativePlayerVideoBitrate() async {
  final value =
      await nativePlayerChannel.invokeMethod<Object?>('videoBitrate');
  final bitrate = intFromNativeValue(value);
  return bitrate > 0 ? bitrate : null;
}

int intFromNativeValue(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is double) {
    return value.round();
  }
  return 0;
}

bool get shouldUseNativePlayer =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;


Future<String?> installApkWithNativeBridge(String filePath) =>
    appInstallerChannel.invokeMethod<String>('installApk', {
      'filePath': filePath,
    });


Future<Uint8List> fetchImageBytes(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.headers
      ..set(HttpHeaders.userAgentHeader, upnpServerHeader)
      ..set(HttpHeaders.acceptHeader, 'image/*,*/*;q=0.8');
    final response = await request.close().timeout(const Duration(seconds: 5));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
    }
    final declaredLength = response.contentLength;
    if (declaredLength > maxImageBytes) {
      throw const FormatException('image response too large');
    }
    final contentType = response.headers.contentType?.mimeType ?? '';
    final bytes = await readBytesWithLimit(
      response,
      maxBytes: maxImageBytes,
    );
    debugLog(
      'Image fetch contentType=${contentType.isEmpty ? '-' : contentType} '
      'bytes=${bytes.length}',
    );
    if (bytes.isEmpty) {
      throw const FormatException('empty image response');
    }
    return bytes;
  } finally {
    client.close(force: true);
  }
}

