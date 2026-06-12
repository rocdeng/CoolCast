import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

const String _defaultReceiverName = 'CoolCast';
const String _receiverNameKey = 'coolcast.receiverName';
const String _biliProjectionManufacturer = 'bilibili';
const String _biliProjectionBrandName = 'bilibili';
const String _biliProjectionFriendlyName = 'CoolCast';
const String _biliProjectionModelName = '云视听小电视';
const String _biliProjectionModelDescription =
    'bilibili official projection receiver';
const String _biliProjectionModelUrl = 'https://www.bilibili.com/';
const String _biliProjectionMobiApp = 'android_bilithings';
const int _biliProjectionBuild = 104800;
const int _biliProjectionFourk = 1;
const int _biliProjectionCapability = 1;
const String _biliProjectionCastService =
    'urn:schemas-upnp-org:service:AVTransport:1';
const String _biliNirvanaControlService =
    'urn:app-bilibili-com:service:NirvanaControl:3';
const String _biliNirvanaSsdpService =
    'urn:schemas-upnp-org:service:NirvanaControl:3';
const bool _biliProjectionSupport4k = true;
const bool _biliProjectionNeedNvaExtra = true;
const bool _biliProjectionIgnoreDirect = true;
const String _biliProjectionChannelName = 'bilibili';
// Stable protocol identity: Bilibili mobile caches and binds this ID to the
// Nirvana session. Keep it stable even if the visible receiver name changes.
const String _biliProjectionAutoPullId = 'coolcast-tv-main';
const String _biliMobileAppKey = '1d8b6e7d45233436';
const String _biliMobileAppSecret = '560c52ccd288fed045859ed18bffd973';
const String _biliMobileMobiApp = 'android';
const String _biliMobileChannel = 'bili';
const int _biliProjectionMaxQn = 120;
const String _biliNvaAesKey = '1pzhA828t4i.6Oq@';
const int _biliNirvanaRequestOp = 0xe003;
const int _biliNirvanaEmptyRequestOp = 0xe002;
const int _biliNirvanaResponseOp = 0xe004;
const int _biliNirvanaBodyResponseOp = 0xc003;
const int _biliNirvanaHeartbeatRequestOp = 0xe400;
const int _biliNirvanaHeartbeatResponseOp = 0xe401;
const int _biliNirvanaShortControlOp = 0xc000;
const int _ottBlinkPort = 8100;
const int _nirvanaControlPort = 9958;
const String _biliDescriptionPath = '/bilibili/description.xml';
const MethodChannel _deviceInfoChannel =
    MethodChannel('com.dengpeng.coolcast/device_info');
const String _upnpServerHeader =
    'Android/14 UPnP/1.0 BiliTV/$_biliProjectionBuild';

void main() {
  runApp(const CoolCastApp());
}

class CoolCastApp extends StatelessWidget {
  const CoolCastApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CoolCast',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4DA3FF),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      home: const ReceiverHomePage(),
    );
  }
}

enum PlaybackState { idle, ready, playing, paused, failed }

enum CoolCastUpnpService {
  avTransport('urn:schemas-upnp-org:service:AVTransport:1'),
  renderingControl('urn:schemas-upnp-org:service:RenderingControl:1'),
  connectionManager('urn:schemas-upnp-org:service:ConnectionManager:1'),
  nirvanaControl(_biliNirvanaControlService);

  const CoolCastUpnpService(this.urn);

  final String urn;
}

@visibleForTesting
class CoolCastDebugAlert {
  const CoolCastDebugAlert(this.level, this.message, {this.timestamp});

  final String level;
  final String message;
  final DateTime? timestamp;

  bool get isHighSeverity => level == 'ERR' || level == 'FATAL';
}

class _BiliNvaLink {
  const _BiliNvaLink({required this.callbackUrl, required this.code});

  final String callbackUrl;
  final String code;

  Map<String, Object?> toJson() => {
        'cb': callbackUrl,
        'cd': code,
      };
}

class _BiliNvaExt {
  const _BiliNvaExt({
    required this.raw,
    required this.qn,
    required this.userDesiredQn,
    required this.ignoreDirect,
    required this.link,
  });

  final Map<String, Object?> raw;
  final int? qn;
  final int? userDesiredQn;
  final bool? ignoreDirect;
  final _BiliNvaLink? link;

  String get summary {
    final parts = <String>[];
    if (qn != null) {
      parts.add('qn=$qn');
    }
    if (userDesiredQn != null) {
      parts.add('userDesireQn=$userDesiredQn');
    }
    if (ignoreDirect != null) {
      parts.add('ignore_direct=$ignoreDirect');
    }
    if (link?.callbackUrl.isNotEmpty ?? false) {
      parts.add('link callback');
    }
    return parts.isEmpty ? 'NVA 扩展' : 'NVA ${parts.join(', ')}';
  }

  Map<String, Object?> toJson() => {
        'qn': qn,
        'userDesireQn': userDesiredQn,
        'ignore_direct': ignoreDirect,
        'nl': link?.toJson(),
      };
}

class _BiliCastStatus {
  const _BiliCastStatus({
    required this.aid,
    required this.cid,
    required this.quality,
    required this.timelength,
    required this.acceptQuality,
  });

  final int? aid;
  final int? cid;
  final int? quality;
  final int? timelength;
  final List<int> acceptQuality;

  Map<String, Object?> toJson() => {
        'aid': aid,
        'cid': cid,
        'quality': quality,
        'timelength': timelength,
        'acceptQuality': acceptQuality,
      };
}

_BiliCastStatus? _latestBiliCastStatus;
_BiliNvaPlayRequest? _latestBiliNvaPlayRequest;
final Set<Socket> _biliNvaSessions = <Socket>{};
final Map<Socket, Future<void>> _biliNvaSessionWrites =
    <Socket, Future<void>>{};
int _biliNvaServerSequence = 1000;
int _biliNvaPlayState = _biliPlayStateIdle;

const int _biliPlayStateIdle = 0;
const int _biliPlayStatePlaying = 4;
const int _biliPlayStatePaused = 5;

@visibleForTesting
class DebugAlertOverlayForTest extends StatelessWidget {
  const DebugAlertOverlayForTest({super.key, required this.alerts});

  final List<CoolCastDebugAlert> alerts;

  @override
  Widget build(BuildContext context) => _DebugAlertOverlay(alerts: alerts);
}

@visibleForTesting
class CoolCastMediaInfo {
  const CoolCastMediaInfo({this.title = '', this.mimeType = ''});

  final String title;
  final String mimeType;
}

@visibleForTesting
CoolCastMediaInfo coolCastMediaInfoFromMetadataForTest(String metadata) =>
    _mediaInfoFromMetadata(metadata);

@visibleForTesting
class PlayingPageForTest extends StatelessWidget {
  const PlayingPageForTest({super.key, required this.showControls});

  final bool showControls;

  @override
  Widget build(BuildContext context) {
    return _PlayingPage(
      player: null,
      state: PlaybackState.playing,
      source: 'DLNA/UPnP',
      fileName: '测试视频.mp4',
      connection: '192.168.1.20',
      mediaChips: const ['1080p', 'MP4'],
      previewPosition: const Duration(minutes: 18, seconds: 42),
      previewDuration: const Duration(hours: 1, minutes: 24, seconds: 16),
      showControls: showControls,
      isMuted: false,
      onBack: () {},
      onShowControls: () {},
      onPlayPause: () {},
      onSeekBackwardLarge: () {},
      onRewind: () {},
      onForward: () {},
      onSeekForwardLarge: () {},
      onToggleMute: () {},
    );
  }
}

class ReceiverHomePage extends StatefulWidget {
  const ReceiverHomePage({super.key});

  @override
  State<ReceiverHomePage> createState() => _ReceiverHomePageState();
}

class _ReceiverHomePageState extends State<ReceiverHomePage> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _renameController = TextEditingController();
  final FocusNode _urlFocusNode = FocusNode();
  final FocusNode _remoteFocusNode = FocusNode();
  HttpServer? _server;
  ServerSocket? _nirvanaControlServer;
  RawDatagramSocket? _ssdpSocket;
  RawDatagramSocket? _ottBlinkSocket;
  Timer? _notifyTimer;
  Timer? _controlsTimer;
  VideoPlayerController? _player;
  PlaybackState _state = PlaybackState.idle;
  String _currentUrl = '';
  String _castSource = '等待投屏设备';
  String _currentMediaTitle = '';
  String _currentMimeType = '';
  String _lastMessage = '正在准备接收端';
  String _localIp = 'TV-IP';
  String _receiverName = _defaultReceiverName;
  bool _showPlaybackControls = false;
  bool _renameDialogVisible = false;
  bool _playingPreviewVisible = false;
  bool _isMuted = false;
  double _volume = 1.0;
  DateTime? _lastHomeBackPressedAt;
  final List<CoolCastDebugAlert> _debugAlerts = [];
  int _ssdpSearchCount = 0;
  int _ssdpResponseCount = 0;
  String _lastSsdpRequester = '';
  int _ottBlinkSearchCount = 0;
  int _ottBlinkResponseCount = 0;
  String _lastOttBlinkRequester = '';
  int _nirvanaConnectionCount = 0;
  int _nirvanaSocketSequence = 0;
  String _lastNirvanaRequester = '';
  String _lastNirvanaSummary = '';
  Duration _previewPosition = const Duration(minutes: 18, seconds: 42);
  static const Duration _previewDuration = Duration(
    hours: 1,
    minutes: 24,
    seconds: 16,
  );

  @override
  void initState() {
    super.initState();
    unawaited(_loadReceiverName());
    if (kIsWeb) {
      _startWebDebugMode();
      return;
    }
    _startReceiver();
  }

  Future<void> _loadReceiverName() async {
    final preferences = await SharedPreferences.getInstance();
    final savedName = preferences.getString(_receiverNameKey)?.trim();
    final nextName = savedName == null || savedName.isEmpty
        ? await _defaultReceiverNameForDevice()
        : savedName;
    if (!mounted) {
      return;
    }
    setState(() {
      _receiverName = nextName;
      _renameController.text = _receiverName;
    });
  }

  Future<String> _defaultReceiverNameForDevice() async {
    if (kIsWeb) {
      return _defaultReceiverName;
    }
    try {
      final deviceName =
          await _deviceInfoChannel.invokeMethod<String>('deviceName');
      return _receiverNameForDevice(deviceName);
    } on Object {
      return _defaultReceiverName;
    }
  }

  void _startWebDebugMode() {
    setState(() {
      _lastMessage = '可手动输入 URL 调试播放界面';
      _localIp = 'Browser Preview';
      _state = PlaybackState.idle;
    });

    final url = Uri.base.queryParameters['url']?.trim();
    if (url != null && url.isNotEmpty) {
      unawaited(_acceptUrl(url, source: '浏览器参数'));
    }
  }

  @override
  void dispose() {
    unawaited(_server?.close(force: true));
    unawaited(_nirvanaControlServer?.close());
    _notifyTimer?.cancel();
    _ssdpSocket?.close();
    _ottBlinkSocket?.close();
    _controlsTimer?.cancel();
    _player?.dispose();
    _remoteFocusNode.dispose();
    _urlController.dispose();
    _urlFocusNode.dispose();
    _renameController.dispose();
    super.dispose();
  }

  Future<void> _startReceiver() async {
    try {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 7788);
      _server = server;
      unawaited(_serve(server));
      final address = await _localAddress();
      await _startSsdp(address);
      await _startOttBlink();
      await _startNirvanaControlProbe();
      setState(() {
        _localIp = address;
        _lastMessage = '正在等待投屏请求';
      });
    } on Object catch (error) {
      setState(() {
        _lastMessage = '$error';
        _state = PlaybackState.failed;
      });
      _addDebugAlert('FATAL', '服务启动失败：$error');
    }
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      unawaited(_handleHttpRequest(request));
    }
  }

  Future<void> _handleHttpRequest(HttpRequest request) async {
    final requestId = request.hashCode.toRadixString(16);
    final remoteAddress =
        request.connectionInfo?.remoteAddress.address ?? 'unknown';
    final requestLabel =
        'HTTP#$requestId ${request.method} ${request.uri} from $remoteAddress';
    final stopwatch = Stopwatch()..start();
    try {
      _debugLog(
        '$requestLabel headers=${_httpRequestHeaderSummary(request)}',
      );
      _applyUpnpResponseHeaders(request.response.headers);
      if (request.uri.path == '/description.xml' ||
          request.uri.path == _biliDescriptionPath) {
        await _sendTextResponse(
          request.response,
          _deviceDescription(_localIp, _receiverName),
          contentType: ContentType('text', 'xml', charset: 'utf-8'),
          debugLabel: requestLabel,
          stopwatch: stopwatch,
        );
        return;
      }

      if (request.uri.path == '/AVTransport/scpd.xml') {
        await _sendTextResponse(
          request.response,
          _avTransportScpd(),
          contentType: ContentType('text', 'xml', charset: 'utf-8'),
          debugLabel: requestLabel,
          stopwatch: stopwatch,
        );
        return;
      }

      if (request.uri.path == '/RenderingControl/scpd.xml') {
        await _sendTextResponse(
          request.response,
          _renderingControlScpd(),
          contentType: ContentType('text', 'xml', charset: 'utf-8'),
          debugLabel: requestLabel,
          stopwatch: stopwatch,
        );
        return;
      }

      if (request.uri.path == '/ConnectionManager/scpd.xml') {
        await _sendTextResponse(
          request.response,
          _connectionManagerScpd(),
          contentType: ContentType('text', 'xml', charset: 'utf-8'),
          debugLabel: requestLabel,
          stopwatch: stopwatch,
        );
        return;
      }

      if (request.uri.path == '/NirvanaControl/scpd.xml') {
        await _sendTextResponse(
          request.response,
          _nirvanaControlScpd(),
          contentType: ContentType('text', 'xml', charset: 'utf-8'),
          debugLabel: requestLabel,
          stopwatch: stopwatch,
        );
        return;
      }

      if (_isUpnpEventSubscription(request)) {
        await _handleUpnpEventSubscription(
          request,
          debugLabel: requestLabel,
          stopwatch: stopwatch,
        );
        return;
      }

      if (request.uri.path == '/AVTransport/control') {
        await _handleAvTransport(request);
        return;
      }

      if (request.uri.path == '/RenderingControl/control') {
        await _handleRenderingControl(request);
        return;
      }

      if (request.uri.path == '/ConnectionManager/control') {
        await _handleConnectionManager(request);
        return;
      }

      if (request.uri.path == '/NirvanaControl/control') {
        await _handleNirvanaHttpControl(request);
        return;
      }

      if (request.uri.path == '/cast') {
        final url = request.uri.queryParameters['url']?.trim() ?? '';
        final accepted = _isValidCastUrl(url);
        unawaited(
          _acceptUrl(
            url,
            source: _sourceWithRemoteAddress('HTTP 投送', request),
          ),
        );
        await _sendTextResponse(
          request.response,
          _htmlResponse(url, isAccepted: accepted),
          contentType: ContentType.html,
        );
        return;
      }

      if (request.uri.path == '/') {
        await _sendTextResponse(
          request.response,
          _htmlForm(
            receiverName: _receiverName,
            ipAddress: _localIp,
            message: _lastMessage,
          ),
          contentType: ContentType.html,
        );
        return;
      }

      _addDebugAlert(
        'ERR',
        '未知请求：${request.method} ${_shortPath(request.uri)}',
      );
      await _sendTextResponse(
        request.response,
        'Not found',
        statusCode: HttpStatus.notFound,
        contentType: ContentType.text,
      );
    } on Object catch (error) {
      _debugLog(
        '$requestLabel failed after ${stopwatch.elapsedMilliseconds}ms: '
        '${_shortError(error)}',
      );
      try {
        if (request.response.contentLength == -1) {
          request.response.statusCode = HttpStatus.internalServerError;
          await request.response.close();
        }
      } on Object {
        // Best-effort cleanup after a client-side disconnect.
      }
    }
  }

  Future<void> _handleUpnpEventSubscription(
    HttpRequest request, {
    required String debugLabel,
    required Stopwatch stopwatch,
  }) async {
    final method = request.method.toUpperCase();
    final sid = request.headers.value('sid') ??
        'uuid:$_biliProjectionAutoPullId-${request.uri.path.hashCode.abs()}';
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.set(HttpHeaders.connectionHeader, 'close')
      ..persistentConnection = false
      ..contentLength = 0;
    if (method == 'SUBSCRIBE') {
      request.response.headers
        ..set('SID', sid)
        ..set('TIMEOUT', 'Second-1800');
    }
    await request.response.close();
    _debugLog(
      '$debugLabel done status=${HttpStatus.ok} bytes=0 '
      '${stopwatch.elapsedMilliseconds}ms',
    );
  }

  Future<void> _sendTextResponse(
    HttpResponse response,
    String body, {
    int statusCode = HttpStatus.ok,
    required ContentType contentType,
    String? debugLabel,
    Stopwatch? stopwatch,
  }) async {
    final bytes = utf8.encode(body);
    response
      ..statusCode = statusCode
      ..headers.contentType = contentType
      ..headers.set(HttpHeaders.connectionHeader, 'close')
      ..persistentConnection = false
      ..contentLength = bytes.length
      ..add(bytes);
    await response.close();
    if (debugLabel != null) {
      final elapsed =
          stopwatch == null ? '' : ' ${stopwatch.elapsedMilliseconds}ms';
      _debugLog(
          '$debugLabel done status=$statusCode bytes=${bytes.length}$elapsed');
    }
  }

  Future<void> _startSsdp(String address) async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      1900,
      reuseAddress: true,
      reusePort: true,
    );
    _ssdpSocket = socket;
    socket.multicastHops = 4;
    socket.joinMulticast(InternetAddress('239.255.255.250'));
    socket.listen((event) {
      if (event != RawSocketEvent.read) {
        return;
      }
      final datagram = socket.receive();
      if (datagram == null) {
        return;
      }
      final message = utf8.decode(datagram.data, allowMalformed: true);
      if (!message.toUpperCase().contains('M-SEARCH')) {
        return;
      }
      _recordSsdpSearch(datagram.address.address);
      if (!_matchesSearchTarget(message)) {
        return;
      }
      _sendSsdpSearchResponse(socket, datagram.address, datagram.port, address);
    });
    _notifyTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _sendSsdpNotify(socket, address),
    );
    _sendSsdpNotify(socket, address);
  }

  Future<void> _startOttBlink() async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      _ottBlinkPort,
      reuseAddress: true,
      reusePort: true,
    );
    _ottBlinkSocket = socket;
    socket.broadcastEnabled = true;
    socket.listen((event) {
      if (event != RawSocketEvent.read) {
        return;
      }
      final datagram = socket.receive();
      if (datagram == null || !_isOttBlinkSearch(datagram.data)) {
        return;
      }
      _recordOttBlinkSearch(datagram.address.address);
      socket.send(
        _ottBlinkResponse(_receiverName),
        datagram.address,
        datagram.port,
      );
      _recordOttBlinkResponse();
    });
  }

  Future<void> _startNirvanaControlProbe() async {
    final server = await ServerSocket.bind(
      InternetAddress.anyIPv4,
      _nirvanaControlPort,
      shared: true,
    );
    _nirvanaControlServer = server;
    server.listen((socket) {
      unawaited(_handleNirvanaControlSocket(socket));
    });
  }

  Future<void> _handleNirvanaControlSocket(Socket socket) async {
    final socketId = ++_nirvanaSocketSequence;
    final requester = socket.remoteAddress.address;
    final localAddress = _nvaReplyAddress(socket.address.address);
    final label = 'Nirvana#$socketId';
    final buffer = <int>[];
    var lastCommand = '<none>';
    var nativeResponses = 0;

    try {
      _debugLog('$label connected from $requester local=$localAddress');
      _biliNvaSessions.add(socket);
      _recordNirvanaControl(requester, '9958 长链已连接');

      await for (final chunk in socket.timeout(const Duration(minutes: 2))) {
        _debugLog(
          '$label chunk from $requester bytes=${chunk.length} '
          'bufferBefore=${buffer.length} hex=${_shortHex(chunk)} '
          'text=${_nativeFrameTextSummary(Uint8List.fromList(chunk)) ?? '<none>'}',
        );
        buffer.addAll(chunk);
        while (buffer.isNotEmpty) {
          final isLikelyText = _looksLikeTextNirvanaPayload(buffer);
          final frameLength = isLikelyText
              ? null
              : _nvaFrameLength(buffer) ??
                  _nirvanaShortControlFrameLength(buffer);
          final isCompleteText = _looksLikeCompleteNirvanaPayload(buffer);
          final shouldFlushUnknown = buffer.length >= 4096;
          if (!isCompleteText && frameLength == null && !shouldFlushUnknown) {
            break;
          }
          if (!isCompleteText &&
              frameLength != null &&
              buffer.length < frameLength) {
            break;
          }
          final length = isCompleteText || shouldFlushUnknown
              ? buffer.length
              : frameLength!;
          final frame = Uint8List.fromList(buffer.take(length).toList());
          buffer.removeRange(0, length);
          await _processNirvanaControlData(
            frame,
            requester: requester,
            localAddress: localAddress,
          );
          lastCommand = _nvaCommandForLog(frame) ?? lastCommand;
          if (_shouldSendNirvanaTextAck(frame)) {
            final ack = _nirvanaTextAck(
              frame,
              localAddress: localAddress,
            );
            _debugLog(
                '$label ACK to $requester bytes=${utf8.encode(ack).length} '
                'summary=${_compactSummary(ack)}');
            await _writeBiliNvaSession(socket, utf8.encode(ack));
            _debugLog('$label ACK flushed to $requester');
          } else {
            final didRespond = await _handleNirvanaFrameRequestIfNeeded(
              socket,
              frame,
              label,
              requester,
            );
            if (didRespond) {
              nativeResponses += 1;
            }
          }
        }
      }
      if (buffer.isNotEmpty) {
        final frame = Uint8List.fromList(buffer);
        await _processNirvanaControlData(
          frame,
          requester: requester,
          localAddress: localAddress,
        );
        lastCommand = _nvaCommandForLog(frame) ?? lastCommand;
        if (_shouldSendNirvanaTextAck(frame)) {
          final ack = _nirvanaTextAck(
            frame,
            localAddress: localAddress,
          );
          _debugLog('$label ACK to $requester bytes=${utf8.encode(ack).length} '
              'summary=${_compactSummary(ack)}');
          await _writeBiliNvaSession(socket, utf8.encode(ack));
          _debugLog('$label ACK flushed to $requester');
        } else {
          final didRespond = await _handleNirvanaFrameRequestIfNeeded(
            socket,
            frame,
            label,
            requester,
          );
          if (didRespond) {
            nativeResponses += 1;
          }
        }
      }
      _debugLog(
        '$label read side reached EOF from $requester '
        'lastCommand=$lastCommand nativeResponses=$nativeResponses',
      );
      _recordNirvanaControl(requester, '9958 对端已关闭');
    } on Object catch (error) {
      _debugLog(
        '$label socket error from $requester: ${_shortError(error)} '
        'lastCommand=$lastCommand nativeResponses=$nativeResponses',
      );
      _recordNirvanaControl(requester, '9958 错误：${_shortError(error)}');
    } finally {
      _biliNvaSessions.remove(socket);
      _biliNvaSessionWrites.remove(socket);
      _debugLog(
        '$label socket destroyed for $requester '
        'lastCommand=$lastCommand nativeResponses=$nativeResponses',
      );
      socket.destroy();
    }
  }

  String _nvaReplyAddress(String socketAddress) {
    if (socketAddress == '0.0.0.0' && _localIp != 'TV-IP') {
      return _localIp;
    }
    return socketAddress;
  }

  Future<bool> _handleNirvanaFrameRequestIfNeeded(
    Socket socket,
    Uint8List frame,
    String label,
    String requester,
  ) async {
    final responses = _nirvanaFrameResponses(frame);
    if (responses.isEmpty) {
      return false;
    }
    for (final response in responses) {
      await _writeBiliNvaSession(socket, response);
      _debugLog(
        '$label frame response to $requester '
        'summary=${_nirvanaControlSummary(response)} hex=${_shortHex(response)}',
      );
    }
    return true;
  }

  Future<void> _writeBiliNvaSession(Socket socket, List<int> data) {
    final previous = _biliNvaSessionWrites[socket] ?? Future<void>.value();
    final next = previous.catchError((Object _) {}).then((_) async {
      socket.add(data);
      await socket.flush();
    });
    _biliNvaSessionWrites[socket] = next;
    return next;
  }

  Future<void> _processNirvanaControlData(
    Uint8List data, {
    required String requester,
    required String localAddress,
  }) async {
    final summary = _nirvanaControlSummary(data);
    _debugLog(
      'Nirvana from $requester local=$localAddress bytes=${data.length} '
      'summary=$summary hex=${_shortHex(data)}',
    );
    _recordNirvanaControl(requester, summary);
    final nvaFrame = _parseNvaFrame(data);
    if (nvaFrame != null) {
      _debugLog(
        'Nirvana frame from $requester: '
        'op=0x${nvaFrame.op.toRadixString(16)} seq=${nvaFrame.sequence} '
        'attrs=${nvaFrame.attributes} body=${_compactSummary(nvaFrame.bodyText)}',
      );
      _recordNirvanaControl(requester, nvaFrame.summary);
      if (nvaFrame.isRequest) {
        if (nvaFrame.attributes['Command'] == 'Play') {
          if (_BiliNvaPlayRequest.fromBody(nvaFrame.bodyText) != null) {
            _latestBiliCastStatus = null;
            _latestBiliNvaPlayRequest = null;
            _biliNvaPlayState = _biliPlayStatePlaying;
            _debugLog('B站状态缓存已清空：收到新的 Play');
            unawaited(_acceptBiliNvaPlay(
              nvaFrame.bodyText,
              requester: requester,
            ));
          } else {
            _handleBiliNvaPlaybackCommand(
              nvaFrame.attributes['Command'],
              nvaFrame.bodyText,
              requester: requester,
            );
          }
        } else if (nvaFrame.attributes['Command'] == 'SwitchQn') {
          unawaited(_switchBiliNvaQn(
            nvaFrame.bodyText,
            requester: requester,
          ));
        } else {
          _handleBiliNvaPlaybackCommand(
            nvaFrame.attributes['Command'],
            nvaFrame.bodyText,
            requester: requester,
          );
        }
        final url = _extractNirvanaControlUrl(nvaFrame.bodyText);
        if (url != null) {
          _debugLog('Nirvana frame URL from $requester: ${_shortUrl(url)}');
          unawaited(_acceptUrl(url, source: 'B站 NVA $requester'));
        }
      }
    }
    final payload = utf8.decode(data, allowMalformed: true);
    final nvaExt = _extractBiliNvaExt(payload);
    if (nvaExt != null) {
      _debugLog('Nirvana NVA ext from $requester: ${nvaExt.summary}');
      _recordNirvanaControl(requester, nvaExt.summary);
      unawaited(_replyBiliNvaLink(nvaExt, localAddress));
    }
    final url = _extractNirvanaControlUrl(payload);
    if (url != null) {
      _debugLog('Nirvana URL from $requester: ${_shortUrl(url)}');
      unawaited(_acceptUrl(url, source: 'B站 Nirvana $requester'));
    } else {
      _debugLog('Nirvana URL from $requester: <none>');
    }
  }

  Future<void> _replyBiliNvaLink(
    _BiliNvaExt nvaExt,
    String localAddress,
  ) async {
    final error = await _sendBiliNvaLinkReply(nvaExt, localAddress);
    if (error != null && mounted) {
      _addDebugAlert('ERR', error);
    }
  }

  Future<void> _acceptBiliNvaPlay(
    String body, {
    required String requester,
  }) async {
    final play = _BiliNvaPlayRequest.fromBody(body);
    if (play == null) {
      _debugLog('B站 NVA Play from $requester ignored: invalid body');
      _recordNirvanaControl(requester, 'Play 参数不可用');
      if (mounted) {
        _addDebugAlert('ERR', 'B站 Play 参数不可用');
      }
      return;
    }

    _debugLog(
      'B站 NVA Play from $requester: aid=${play.aid ?? '-'} '
      'cid=${play.cid ?? '-'} qn=${play.preferredQn} '
      'contentType=${play.contentType ?? '-'}',
    );
    _recordNirvanaControl(requester, 'Play 换取播放地址');

    final result = await _fetchBiliPlayUrl(play);
    if (result.url == null) {
      final message = result.error ?? 'B站 playurl 未返回可播放地址';
      _debugLog('B站 playurl failed for $requester: $message');
      _recordNirvanaControl(requester, message);
      if (mounted) {
        _addDebugAlert('ERR', message);
      }
      return;
    }

    _debugLog('B站 playurl OK for $requester: ${_shortUrl(result.url!)}');
    _latestBiliNvaPlayRequest = play;
    _latestBiliCastStatus = result.status;
    _biliNvaPlayState = _biliPlayStatePlaying;
    if (result.status != null) {
      _debugLog('B站状态已缓存: ${result.status!.toJson()}');
      unawaited(_sendBiliPlaybackStatusEvents(result.status!));
    }
    _recordNirvanaControl(requester, 'PlayUrl ${_shortUrl(result.url!)}');
    unawaited(
      _acceptUrl(
        result.url!,
        source: 'B站 NVA $requester',
        httpHeaders: _biliPlaybackHeaders(bvid: play.bvid, aid: play.aid),
      ),
    );
  }

  void _handleBiliNvaPlaybackCommand(
    String? command,
    String body, {
    required String requester,
  }) {
    switch (command) {
      case 'Pause':
        _debugLog('B站 Pause from $requester');
        _recordNirvanaControl(requester, 'Pause');
        _biliNvaPlayState = _biliPlayStatePaused;
        unawaited(_pause());
        _sendBiliPlaybackStateEvent(_biliPlayStatePaused);
        break;
      case 'Resume':
      case 'Play':
        _debugLog('B站 Resume from $requester');
        _recordNirvanaControl(requester, command ?? 'Resume');
        _biliNvaPlayState = _biliPlayStatePlaying;
        unawaited(_play());
        _sendBiliPlaybackStateEvent(_biliPlayStatePlaying);
        break;
      case 'Seek':
        final position = _biliSeekPositionFromBody(body);
        _debugLog(
            'B站 Seek from $requester: position=${position?.inSeconds ?? '-'}s');
        _recordNirvanaControl(
          requester,
          position == null ? 'Seek 参数不可用' : 'Seek ${position.inSeconds}s',
        );
        if (position != null) {
          unawaited(_seekTo(position));
          _sendBiliProgressEvent(position);
        }
        break;
      case 'Stop':
        _debugLog('B站 Stop from $requester: ACK only');
        _recordNirvanaControl(requester, 'Stop ACK');
        break;
    }
  }

  Future<void> _switchBiliNvaQn(
    String body, {
    required String requester,
  }) async {
    final qn = _biliSwitchQnFromBody(body);
    final latestPlay = _latestBiliNvaPlayRequest;
    if (qn == null || latestPlay == null) {
      _debugLog(
        'B站 SwitchQn from $requester ignored: qn=${qn ?? '-'} '
        'hasPlay=${latestPlay != null}',
      );
      return;
    }

    final player = _player;
    final position = player?.value.isInitialized == true
        ? player!.value.position
        : Duration.zero;
    final play = latestPlay.copyWith(
      qn: qn,
      userDesireQn: qn,
      seekTs: position.inSeconds,
    );
    _debugLog(
      'B站 SwitchQn from $requester: qn=$qn '
      'position=${position.inSeconds}s',
    );
    _recordNirvanaControl(requester, 'SwitchQn $qn');

    final result = await _fetchBiliPlayUrl(play);
    if (result.url == null) {
      final message = result.error ?? 'B站 SwitchQn 未返回可播放地址';
      _debugLog('B站 SwitchQn failed for $requester: $message');
      _recordNirvanaControl(requester, message);
      if (mounted) {
        _addDebugAlert('ERR', message);
      }
      return;
    }

    _latestBiliNvaPlayRequest = play;
    _latestBiliCastStatus = result.status;
    _biliNvaPlayState = _biliPlayStatePlaying;
    final status = result.status;
    if (status != null) {
      _debugLog('B站 SwitchQn 状态已缓存: ${status.toJson()}');
      unawaited(_sendBiliPlaybackStatusEvents(status, position: position));
    }
    _recordNirvanaControl(requester, 'SwitchQn ${_shortUrl(result.url!)}');
    unawaited(
      _acceptUrl(
        result.url!,
        source: 'B站 NVA $requester',
        httpHeaders: _biliPlaybackHeaders(bvid: play.bvid, aid: play.aid),
        initialPosition: position,
      ),
    );
  }

  Future<void> _sendBiliPlaybackStatusEvents(
    _BiliCastStatus status, {
    Duration position = Duration.zero,
  }) async {
    final durationSeconds = ((status.timelength ?? 0) / 1000).round();
    final positionSeconds = position.inSeconds;
    final events = <Uint8List>[
      _nvaServerEventFrame(
        command: 'OnPlayState',
        body: jsonEncode({'playState': _biliPlayStatePlaying}),
      ),
      _nvaServerEventFrame(
        command: 'OnProgress',
        body: jsonEncode({
          'position': positionSeconds,
          'duration': durationSeconds,
        }),
      ),
    ];
    if (status.quality != null) {
      events.add(_nvaServerEventFrame(
        command: 'OnQnSwitch',
        body: jsonEncode(_biliQnDescriptionBody(status)),
      ));
    }

    final sessions = _biliNvaSessions.toList(growable: false);
    _debugLog(
      'B站主动状态事件: sessions=${sessions.length} '
      'position=$positionSeconds duration=$durationSeconds '
      'quality=${status.quality ?? '-'}',
    );
    for (final session in sessions) {
      try {
        for (final event in events) {
          await _writeBiliNvaSession(session, event);
        }
      } on Object catch (error) {
        _debugLog('B站主动状态事件发送失败: ${_shortError(error)}');
      }
    }
  }

  void _sendBiliPlaybackStateEvent(int playState) {
    unawaited(Future<void>.delayed(
      const Duration(milliseconds: 800),
      () => _sendBiliNvaEvent(
        command: 'OnPlayState',
        body: jsonEncode({'playState': playState}),
      ),
    ));
  }

  void _sendBiliProgressEvent(Duration position) {
    final durationSeconds =
        ((_latestBiliCastStatus?.timelength ?? 0) / 1000).round();
    unawaited(Future<void>.delayed(
      const Duration(milliseconds: 800),
      () => _sendBiliNvaEvent(
        command: 'OnProgress',
        body: jsonEncode({
          'position': position.inSeconds,
          'duration': durationSeconds,
        }),
      ),
    ));
  }

  void _sendBiliNvaEvent({
    required String command,
    required String body,
  }) {
    final sessions = _biliNvaSessions.toList(growable: false);
    _debugLog('B站主动事件: command=$command sessions=${sessions.length}');
    for (final session in sessions) {
      try {
        unawaited(_writeBiliNvaSession(
          session,
          _nvaServerEventFrame(command: command, body: body),
        ));
      } on Object catch (error) {
        _debugLog('B站主动事件发送失败: ${_shortError(error)}');
      }
    }
  }

  bool _matchesSearchTarget(String message) {
    final upper = message.toUpperCase();
    return upper.contains('SSDP:ALL') ||
        upper.contains('MEDIASERVER') ||
        upper.contains('MEDIARENDERER') ||
        upper.contains('AVTRANSPORT') ||
        upper.contains('RENDERINGCONTROL') ||
        upper.contains('CONNECTIONMANAGER') ||
        upper.contains('UPNP:ROOTDEVICE');
  }

  void _sendSsdpSearchResponse(
    RawDatagramSocket socket,
    InternetAddress address,
    int port,
    String localIp,
  ) {
    for (final target in _ssdpTargets) {
      final response = _ssdpSearchResponse(localIp, target);
      socket.send(utf8.encode(response), address, port);
    }
    _recordSsdpResponse(_ssdpTargets.length);
  }

  void _sendSsdpNotify(RawDatagramSocket socket, String localIp) {
    for (final target in _ssdpTargets) {
      final notify = _ssdpNotify(localIp, target);
      socket.send(
        utf8.encode(notify),
        InternetAddress('239.255.255.250'),
        1900,
      );
    }
  }

  Future<void> _handleAvTransport(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    _debugLog(
      'AVTransport from ${request.connectionInfo?.remoteAddress.address}: '
      '${_soapActionSummary(body)}',
    );
    Future<void> sendXml(String responseBody) => _sendTextResponse(
          request.response,
          responseBody,
          contentType: ContentType('text', 'xml', charset: 'utf-8'),
        );
    if (body.contains('SetAVTransportURI') ||
        body.contains('SetNextAVTransportURI')) {
      final isNextUri = body.contains('SetNextAVTransportURI');
      final url = _extractCurrentUri(body);
      final nvaExt = _extractBiliNvaExt(url);
      if (nvaExt != null) {
        _recordNirvanaControl(
          request.connectionInfo?.remoteAddress.address ?? '',
          nvaExt.summary,
        );
        unawaited(_replyBiliNvaLink(nvaExt, _localIp));
      }
      final metadata = _mediaInfoFromMetadata(
        _extractSoapValue(body, 'CurrentURIMetaData'),
      );
      if (!isNextUri) {
        unawaited(
          _acceptUrl(
            url,
            source: _sourceWithRemoteAddress('DLNA/UPnP', request),
            mediaInfo: metadata,
          ),
        );
      }
      await sendXml(
        _soapResponse(
          isNextUri
              ? 'SetNextAVTransportURIResponse'
              : 'SetAVTransportURIResponse',
        ),
      );
      return;
    }

    if (body.contains('<u:Play') || body.contains(':Play')) {
      unawaited(_play());
      await sendXml(_soapResponse('PlayResponse'));
      return;
    }

    if (body.contains('<u:Pause') || body.contains(':Pause')) {
      unawaited(_pause());
      await sendXml(_soapResponse('PauseResponse'));
      return;
    }

    if (body.contains('<u:Stop') || body.contains(':Stop')) {
      unawaited(_returnToHome());
      await sendXml(_soapResponse('StopResponse'));
      return;
    }

    if (body.contains('GetTransportInfo')) {
      await sendXml(_transportInfoResponse(_state));
      return;
    }

    if (body.contains('GetPositionInfo')) {
      await sendXml(_positionInfoResponse(_player));
      return;
    }

    if (body.contains('GetMediaInfo')) {
      await sendXml(_mediaInfoResponse(_player, _currentUrl));
      return;
    }

    if (body.contains('GetTransportSettings')) {
      await sendXml(_transportSettingsResponse());
      return;
    }

    if (body.contains('GetDeviceCapabilities')) {
      await sendXml(_deviceCapabilitiesResponse());
      return;
    }

    if (body.contains('GetCurrentTransportActions')) {
      await sendXml(_currentTransportActionsResponse(_state));
      return;
    }

    if (body.contains('<u:Seek') || body.contains(':Seek')) {
      final target = _parseDlnaDuration(_extractSoapValue(body, 'Target'));
      if (target != null) {
        unawaited(_seekTo(target));
      }
      await sendXml(_soapResponse('SeekResponse'));
      return;
    }

    _addDebugAlert('ERR', '未知 AVTransport：${_soapActionSummary(body)}');
    await sendXml(_soapResponse('AVTransportResponse'));
  }

  Future<void> _handleRenderingControl(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    _debugLog(
      'RenderingControl from ${request.connectionInfo?.remoteAddress.address}: '
      '${_soapActionSummary(body)}',
    );
    var response = _soapResponse(
      'RenderingControlResponse',
      service: CoolCastUpnpService.renderingControl,
    );
    if (body.contains('GetVolume')) {
      response = _soapResponse(
        'GetVolumeResponse',
        service: CoolCastUpnpService.renderingControl,
        body: '<CurrentVolume>${(_volume * 100).round()}</CurrentVolume>',
      );
    } else if (body.contains('SetVolume')) {
      final desiredVolume =
          int.tryParse(_extractSoapValue(body, 'DesiredVolume'));
      if (desiredVolume != null) {
        unawaited(_setVolume(desiredVolume.clamp(0, 100) / 100));
      }
      response = _soapResponse(
        'SetVolumeResponse',
        service: CoolCastUpnpService.renderingControl,
      );
    } else if (body.contains('GetMute')) {
      response = _soapResponse(
        'GetMuteResponse',
        service: CoolCastUpnpService.renderingControl,
        body: '<CurrentMute>${_isMuted ? 1 : 0}</CurrentMute>',
      );
    } else if (body.contains('SetMute')) {
      final desiredMute = _extractSoapValue(body, 'DesiredMute');
      if (desiredMute.isNotEmpty) {
        unawaited(_setMuted(desiredMute == '1' || desiredMute == 'true'));
      }
      response = _soapResponse(
        'SetMuteResponse',
        service: CoolCastUpnpService.renderingControl,
      );
    }
    await _sendTextResponse(
      request.response,
      response,
      contentType: ContentType('text', 'xml', charset: 'utf-8'),
    );
  }

  Future<void> _handleConnectionManager(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    _debugLog(
      'ConnectionManager from ${request.connectionInfo?.remoteAddress.address}: '
      '${_soapActionSummary(body)}',
    );
    var response = _soapResponse(
      'ConnectionManagerResponse',
      service: CoolCastUpnpService.connectionManager,
    );
    if (body.contains('GetProtocolInfo')) {
      response = _protocolInfoResponse();
    } else if (body.contains('GetCurrentConnectionIDs')) {
      response = _soapResponse(
        'GetCurrentConnectionIDsResponse',
        service: CoolCastUpnpService.connectionManager,
        body: '<ConnectionIDs>0</ConnectionIDs>',
      );
    } else if (body.contains('GetCurrentConnectionInfo')) {
      response = _soapResponse(
        'GetCurrentConnectionInfoResponse',
        service: CoolCastUpnpService.connectionManager,
        body: '''
<RcsID>0</RcsID>
<AVTransportID>0</AVTransportID>
<ProtocolInfo></ProtocolInfo>
<PeerConnectionManager></PeerConnectionManager>
<PeerConnectionID>-1</PeerConnectionID>
<Direction>Input</Direction>
<Status>OK</Status>''',
      );
    }
    await _sendTextResponse(
      request.response,
      response,
      contentType: ContentType('text', 'xml', charset: 'utf-8'),
    );
  }

  Future<void> _handleNirvanaHttpControl(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final localAddress = _nvaReplyAddress(_localIp);
    _debugLog(
      'NirvanaControl HTTP from ${request.connectionInfo?.remoteAddress.address}: '
      '${_soapActionSummary(body)}',
    );
    if (body.contains('GetNvaLinkAddress')) {
      await _sendTextResponse(
        request.response,
        _soapResponse(
          'GetNvaLinkAddressResponse',
          service: CoolCastUpnpService.nirvanaControl,
          body:
              '<NvaLinkAddress>${xmlEscape(_biliNvaLinkAddress(localAddress))}</NvaLinkAddress>',
        ),
        contentType: ContentType('text', 'xml', charset: 'utf-8'),
      );
      return;
    }
    await _sendTextResponse(
      request.response,
      _soapResponse(
        'NirvanaControlResponse',
        service: CoolCastUpnpService.nirvanaControl,
      ),
      contentType: ContentType('text', 'xml', charset: 'utf-8'),
    );
  }

  String _extractCurrentUri(String body) {
    return _extractSoapValue(body, 'CurrentURI');
  }

  Future<String> _localAddress() async {
    final interfaces = await NetworkInterface.list(
      includeLinkLocal: false,
      type: InternetAddressType.IPv4,
    );
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (!address.isLoopback) {
          return address.address;
        }
      }
    }
    return 'TV-IP';
  }

  Future<void> _acceptUrl(
    String value, {
    required String source,
    CoolCastMediaInfo mediaInfo = const CoolCastMediaInfo(),
    Map<String, String> httpHeaders = const {},
    Duration initialPosition = Duration.zero,
  }) async {
    if (!_isValidCastUrl(value)) {
      setState(() {
        _currentUrl = value;
        _urlController.text = value;
        _currentMediaTitle = '';
        _currentMimeType = '';
        _state = PlaybackState.failed;
        _lastMessage = value.isEmpty ? '$source 未提供地址' : '$source 地址不可用';
      });
      _addDebugAlert(
        'ERR',
        value.isEmpty ? '$source 未提供地址' : '$source 地址不可用：${_shortUrl(value)}',
      );
      return;
    }

    final parsed = Uri.parse(value);
    final oldPlayer = _player;
    final player = VideoPlayerController.networkUrl(
      parsed,
      httpHeaders: httpHeaders,
    );
    setState(() {
      _currentUrl = value;
      _urlController.text = value;
      _castSource = source;
      _currentMediaTitle = mediaInfo.title;
      _currentMimeType = mediaInfo.mimeType;
      _state = PlaybackState.ready;
      _lastMessage = '$source 正在载入';
    });

    try {
      await player.initialize();
      await player.setVolume(_isMuted ? 0 : _volume);
      if (initialPosition > Duration.zero) {
        await player.seekTo(initialPosition);
      }
      final urlQuality = _qualityLabelFromUrl(value);
      _debugLog(
        '$source 播放器已初始化: url=${_shortUrl(value)} '
        'urlQuality=${urlQuality.isEmpty ? '-' : urlQuality} '
        'videoSize=${_videoSizeSummary(player.value.size)} '
        'biliQuality=${_latestBiliCastStatus?.quality ?? '-'}',
      );
      await oldPlayer?.dispose();
      await player.play();
      setState(() {
        _player = player;
        _state = PlaybackState.playing;
        _lastMessage = '$source 已开始播放';
      });
    } on Object catch (error) {
      await player.dispose();
      setState(() {
        _state = PlaybackState.failed;
        _lastMessage = '播放失败：$error';
      });
      _addDebugAlert('ERR', '播放失败：${_shortError(error)}');
    }
  }

  void _loadUrl() {
    unawaited(_acceptUrl(_urlController.text.trim(), source: '浏览器调试'));
  }

  Future<void> _play() async {
    if (_currentUrl.isEmpty) {
      _loadUrl();
      return;
    }
    await _player?.play();
    setState(() => _state = PlaybackState.playing);
  }

  Future<void> _pause() async {
    if (_state == PlaybackState.playing) {
      await _player?.pause();
      setState(() => _state = PlaybackState.paused);
    }
  }

  Future<void> _toggleMute() async {
    await _setMuted(!_isMuted);
    _revealControls();
  }

  Future<void> _setMuted(bool muted) async {
    await _player?.setVolume(muted ? 0 : _volume);
    setState(() => _isMuted = muted);
  }

  Future<void> _setVolume(double volume) async {
    final nextVolume = volume.clamp(0, 1).toDouble();
    _volume = nextVolume;
    if (nextVolume > 0) {
      _isMuted = false;
    }
    await _player?.setVolume(_isMuted ? 0 : nextVolume);
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _returnToHome() async {
    await _player?.pause();
    await _player?.dispose();
    _controlsTimer?.cancel();
    setState(() {
      _player = null;
      _playingPreviewVisible = false;
      _previewPosition = const Duration(minutes: 18, seconds: 42);
      _state = PlaybackState.idle;
      _currentUrl = '';
      _castSource = '等待投屏设备';
      _currentMediaTitle = '';
      _currentMimeType = '';
      _showPlaybackControls = false;
      _lastMessage = kIsWeb ? '可手动输入 URL 调试播放界面' : '正在等待投屏请求';
    });
  }

  Future<void> _seekBy(Duration offset) async {
    final player = _player;
    if (player == null || !player.value.isInitialized) {
      if (_playingPreviewVisible) {
        setState(() {
          final next = _previewPosition + offset;
          if (next < Duration.zero) {
            _previewPosition = Duration.zero;
          } else if (next > _previewDuration) {
            _previewPosition = _previewDuration;
          } else {
            _previewPosition = next;
          }
        });
      }
      return;
    }
    final duration = player.value.duration;
    final current = player.value.position;
    var target = current + offset;
    if (target < Duration.zero) {
      target = Duration.zero;
    }
    if (duration > Duration.zero && target > duration) {
      target = duration;
    }
    await player.seekTo(target);
    _revealControls();
  }

  Future<void> _seekTo(Duration target) async {
    final player = _player;
    if (player == null || !player.value.isInitialized) {
      if (_playingPreviewVisible) {
        setState(() {
          if (target < Duration.zero) {
            _previewPosition = Duration.zero;
          } else if (target > _previewDuration) {
            _previewPosition = _previewDuration;
          } else {
            _previewPosition = target;
          }
        });
      }
      return;
    }
    final duration = player.value.duration;
    var next = target;
    if (next < Duration.zero) {
      next = Duration.zero;
    }
    if (duration > Duration.zero && next > duration) {
      next = duration;
    }
    await player.seekTo(next);
    _revealControls();
  }

  void _revealControls() {
    _controlsTimer?.cancel();
    setState(() => _showPlaybackControls = true);
    _controlsTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) {
        setState(() => _showPlaybackControls = false);
      }
    });
  }

  void _openRenameDialog() {
    setState(() {
      _renameController.text = _receiverName;
      _renameDialogVisible = true;
    });
  }

  void _openPlayingPreview() {
    setState(() {
      _playingPreviewVisible = true;
      _state = PlaybackState.playing;
      _castSource = 'iPhone 15 Pro · AirPlay';
      _currentUrl = 'https://preview.local/Planet.Earth.III.E04.4K.HDR.mkv';
      _currentMediaTitle = 'Planet Earth III E04';
      _currentMimeType = 'video/x-matroska';
      _previewPosition = const Duration(minutes: 18, seconds: 42);
      _showPlaybackControls = true;
    });
  }

  void _closeRenameDialog() {
    setState(() => _renameDialogVisible = false);
  }

  void _addDebugAlert(String level, String message) {
    setState(() {
      _debugAlerts.add(
        CoolCastDebugAlert(level, message, timestamp: DateTime.now()),
      );
      if (_debugAlerts.length > 6) {
        _debugAlerts.removeRange(0, _debugAlerts.length - 6);
      }
    });
  }

  Future<void> _saveReceiverName() async {
    final nextName = _renameController.text.trim();
    if (nextName.isEmpty) {
      return;
    }
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_receiverNameKey, nextName);
    if (!mounted) {
      return;
    }
    setState(() {
      _receiverName = nextName;
      _renameDialogVisible = false;
    });
  }

  Future<bool> _handleBack() async {
    if (_renameDialogVisible) {
      _closeRenameDialog();
      return false;
    }
    if (_player != null || _playingPreviewVisible) {
      await _returnToHome();
      return false;
    }
    final now = DateTime.now();
    final previous = _lastHomeBackPressedAt;
    if (previous != null &&
        now.difference(previous) < const Duration(seconds: 2)) {
      await SystemNavigator.pop();
      return false;
    }
    _lastHomeBackPressedAt = now;
    setState(() => _lastMessage = '再次按返回退出 CoolCast');
    return false;
  }

  KeyEventResult _handleRemoteKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space) {
      if (_player != null) {
        _revealControls();
        return KeyEventResult.handled;
      }
    }

    if (key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      if (_state == PlaybackState.playing) {
        unawaited(_pause());
      } else {
        unawaited(_play());
      }
      _revealControls();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowLeft) {
      unawaited(_seekBy(const Duration(seconds: -10)));
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowRight) {
      unawaited(_seekBy(const Duration(seconds: 10)));
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final playerValue = _player?.value;
    final isShowingVideo =
        _player != null && playerValue != null && playerValue.isInitialized;
    final isShowingPlayingPage = isShowingVideo || _playingPreviewVisible;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          unawaited(_handleBack());
        }
      },
      child: Focus(
        focusNode: _remoteFocusNode,
        canRequestFocus: false,
        onKeyEvent: _handleRemoteKey,
        child: Scaffold(
          backgroundColor: const Color(0xFFEAF6FF),
          body: isShowingPlayingPage
              ? Stack(
                  fit: StackFit.expand,
                  children: [
                    _PlayingPage(
                      player: isShowingVideo ? _player : null,
                      state: _state,
                      source: _castSource,
                      fileName: _currentDisplayTitle,
                      connection: _connectionSummary,
                      mediaChips: _currentMediaChips(playerValue),
                      previewPosition: _previewPosition,
                      previewDuration: _previewDuration,
                      showControls:
                          _showPlaybackControls || _playingPreviewVisible,
                      isMuted: _isMuted,
                      onBack: _returnToHome,
                      onShowControls: _revealControls,
                      onPlayPause:
                          _state == PlaybackState.playing ? _pause : _play,
                      onSeekBackwardLarge: () =>
                          _seekBy(const Duration(seconds: -30)),
                      onRewind: () => _seekBy(const Duration(seconds: -10)),
                      onForward: () => _seekBy(const Duration(seconds: 10)),
                      onSeekForwardLarge: () =>
                          _seekBy(const Duration(seconds: 30)),
                      onToggleMute: _toggleMute,
                    ),
                    _DebugAlertOverlay(alerts: _debugAlerts),
                  ],
                )
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    _HomePage(
                      receiverName: _receiverName,
                      ipAddress: _localIp,
                      status: _homeConnectionStatus,
                      discoveryStatus: _discoveryStatus,
                      controller: _urlController,
                      focusNode: _urlFocusNode,
                      showDebugInput: kIsWeb,
                      onLoad: _loadUrl,
                      onRename: _openRenameDialog,
                      showPreviewAction: kDebugMode,
                      onPreviewPlaying: _openPlayingPreview,
                    ),
                    if (_renameDialogVisible)
                      _RenameDialog(
                        controller: _renameController,
                        onCancel: _closeRenameDialog,
                        onSave: _saveReceiverName,
                      ),
                    _DebugAlertOverlay(alerts: _debugAlerts),
                  ],
                ),
        ),
      ),
    );
  }

  String get _connectionSummary {
    if (_localIp == 'TV-IP' || _localIp == 'Browser Preview') {
      return _localIp;
    }
    return _localIp;
  }

  String get _currentDisplayTitle {
    if (_currentMediaTitle.isNotEmpty) {
      return _currentMediaTitle;
    }
    final fileName = _displayFileName(_currentUrl);
    if (fileName.isNotEmpty && fileName != '远端媒体') {
      return fileName;
    }
    if (_playingPreviewVisible) {
      return 'Planet Earth III E04';
    }
    return '远端媒体';
  }

  List<String> _currentMediaChips(VideoPlayerValue? value) =>
      _playingPreviewVisible
          ? const ['4K HDR', 'HEVC', '5.1 Audio']
          : _mediaChipsFor(
              _currentUrl,
              _currentMimeType,
              _state,
              value?.size,
              biliStatus: _latestBiliCastStatus,
            );

  String get _homeConnectionStatus {
    if (_state == PlaybackState.failed) {
      return '连接异常，请检查服务';
    }
    if (_lastMessage.contains('等待') ||
        _lastMessage.contains('准备') ||
        _lastMessage.contains('调试')) {
      return '已连接，网络质量优秀';
    }
    return _lastMessage;
  }

  String get _discoveryStatus {
    if (_nirvanaConnectionCount > 0) {
      final source =
          _lastNirvanaRequester.isEmpty ? '' : '，来源 $_lastNirvanaRequester';
      return 'Nirvana 9958 收到 $_nirvanaConnectionCount 次$source：$_lastNirvanaSummary';
    }
    if (_ottBlinkSearchCount > 0) {
      final source =
          _lastOttBlinkRequester.isEmpty ? '' : '，来源 $_lastOttBlinkRequester';
      return 'B站 Blink 收到 $_ottBlinkSearchCount 次，回复 $_ottBlinkResponseCount 次$source';
    }
    if (_ssdpSearchCount == 0) {
      return '未收到搜索';
    }
    final source = _lastSsdpRequester.isEmpty ? '' : '，来源 $_lastSsdpRequester';
    return 'SSDP 收到 $_ssdpSearchCount 次，回复 $_ssdpResponseCount 次$source';
  }

  void _recordSsdpSearch(String requester) {
    if (!mounted) {
      return;
    }
    setState(() {
      _ssdpSearchCount += 1;
      _lastSsdpRequester = requester;
    });
  }

  void _recordSsdpResponse(int count) {
    if (!mounted) {
      return;
    }
    setState(() => _ssdpResponseCount += count);
  }

  void _recordOttBlinkSearch(String requester) {
    if (!mounted) {
      return;
    }
    setState(() {
      _ottBlinkSearchCount += 1;
      _lastOttBlinkRequester = requester;
    });
  }

  void _recordOttBlinkResponse() {
    if (!mounted) {
      return;
    }
    setState(() => _ottBlinkResponseCount += 1);
  }

  void _recordNirvanaControl(String requester, String summary) {
    if (!mounted) {
      return;
    }
    setState(() {
      _nirvanaConnectionCount += 1;
      _lastNirvanaRequester = requester;
      _lastNirvanaSummary = summary;
    });
  }
}

class _HomePage extends StatelessWidget {
  const _HomePage({
    required this.receiverName,
    required this.ipAddress,
    required this.status,
    required this.discoveryStatus,
    required this.controller,
    required this.focusNode,
    required this.showDebugInput,
    required this.onLoad,
    required this.onRename,
    required this.showPreviewAction,
    required this.onPreviewPlaying,
  });

  final String receiverName;
  final String ipAddress;
  final String status;
  final String discoveryStatus;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool showDebugInput;
  final VoidCallback onLoad;
  final VoidCallback onRename;
  final bool showPreviewAction;
  final VoidCallback onPreviewPlaying;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const _HomeBackground(),
        SafeArea(
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: SizedBox(
                width: 1920,
                height: 1080,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(96, 72, 96, 72),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 780,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 26),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _ReceiverHeader(receiverName: receiverName),
                              const SizedBox(height: 14),
                              _NetworkCard(
                                ipAddress: ipAddress,
                                status: status,
                                discoveryStatus: discoveryStatus,
                              ),
                              const SizedBox(height: 14),
                              const _CastMethods(),
                              const SizedBox(height: 14),
                              _WaitingHint(receiverName: receiverName),
                              if (showDebugInput) ...[
                                const SizedBox(height: 14),
                                _DebugUrlInput(
                                  controller: controller,
                                  focusNode: focusNode,
                                  onLoad: onLoad,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 56),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(left: 32),
                          child: _WaitingPanel(
                            receiverName: receiverName,
                            onRename: onRename,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (showPreviewAction)
          Positioned(
            left: 122,
            bottom: 34,
            child: _PreviewPlayingButton(onPressed: onPreviewPlaying),
          ),
      ],
    );
  }
}

class _HomeBackground extends StatelessWidget {
  const _HomeBackground();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [Color(0xFFF7FBFF), Color(0xFFEAF5FF), Colors.white],
          stops: [0, 0.55, 1],
        ),
      ),
      child: Stack(
        children: [
          _AmbientGlow(
            color: Color(0x220A84FF),
            width: 640,
            height: 640,
            left: 1080,
            top: 20,
          ),
          _AmbientGlow(
            color: Color(0x1D30D158),
            width: 520,
            height: 520,
            left: 1360,
            top: 560,
          ),
          _SoftGrid(),
        ],
      ),
    );
  }
}

class _AmbientGlow extends StatelessWidget {
  const _AmbientGlow({
    required this.color,
    required this.width,
    required this.height,
    required this.left,
    required this.top,
  });

  final Color color;
  final double width;
  final double height;
  final double left;
  final double top;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          boxShadow: [
            BoxShadow(color: color, blurRadius: 110, spreadRadius: 80),
          ],
        ),
      ),
    );
  }
}

class _SoftGrid extends StatelessWidget {
  const _SoftGrid();

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.08,
      child: CustomPaint(
        painter: _SoftGridPainter(),
        size: Size.infinite,
      ),
    );
  }
}

class _SoftGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final verticalPaint = Paint()..color = const Color(0x3324435F);
    final horizontalPaint = Paint()..color = const Color(0x2A24435F);
    for (var x = 180.0; x < 1920; x += 210) {
      canvas.drawRect(Rect.fromLTWH(x, 0, 1, size.height), verticalPaint);
    }
    for (var y = 160.0; y < 1080; y += 150) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), horizontalPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _ReceiverHeader extends StatelessWidget {
  const _ReceiverHeader({required this.receiverName});

  final String receiverName;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const _IconChip(
          icon: Icons.cast,
          iconColor: Color(0xFF38BDF8),
          size: 72,
          iconSize: 36,
          cornerRadius: 18,
        ),
        const SizedBox(width: 18),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                receiverName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF102033),
                  fontSize: 42,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                '客厅 Android TV 已准备接收投屏',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Color(0xFF5E7186),
                  fontSize: 22,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _NetworkCard extends StatelessWidget {
  const _NetworkCard({
    required this.ipAddress,
    required this.status,
    required this.discoveryStatus,
  });

  final String ipAddress;
  final String status;
  final String discoveryStatus;

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      cornerRadius: 24,
      padding: const EdgeInsets.all(22),
      child: Column(
        children: [
          const Row(
            children: [
              Icon(Icons.wifi, color: Color(0xFF22C55E), size: 34),
              SizedBox(width: 14),
              Text(
                '当前连接网络',
                style: TextStyle(
                  color: Color(0xFF102033),
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const _NetworkField(label: 'SSID', value: '当前局域网'),
          const SizedBox(height: 10),
          _NetworkField(label: 'IP 地址', value: ipAddress),
          const SizedBox(height: 10),
          _NetworkField(
            label: '连接状态',
            value: status,
            valueColor: status.contains('异常')
                ? const Color(0xFFEF4444)
                : const Color(0xFF22C55E),
          ),
          const SizedBox(height: 10),
          _NetworkField(
            label: '发现状态',
            value: discoveryStatus,
            valueColor: discoveryStatus == '未收到搜索'
                ? const Color(0xFFF59E0B)
                : const Color(0xFF22C55E),
          ),
        ],
      ),
    );
  }
}

class _NetworkField extends StatelessWidget {
  const _NetworkField({
    required this.label,
    required this.value,
    this.valueColor = const Color(0xFF102033),
  });

  final String label;
  final String value;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 180,
          child: Text(
            label,
            style: const TextStyle(
              color: Color(0xFF5E7186),
              fontSize: 22,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(width: 18),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xCCF7FBFF),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFD6E6F5)),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: valueColor,
                  fontSize: 26,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DeviceNameCard extends StatelessWidget {
  const _DeviceNameCard({required this.receiverName, required this.onRename});

  final String receiverName;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      cornerRadius: 26,
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '设备名称',
            style: TextStyle(
              color: Color(0xFF5E7186),
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              const Icon(Icons.tv, color: Color(0xFF22C55E), size: 34),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  receiverName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF102033),
                    fontSize: 40,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              SizedBox(
                width: 48,
                height: 48,
                child: IconButton.filledTonal(
                  onPressed: onRename,
                  icon: const Icon(Icons.edit, size: 22),
                  tooltip: '修改投屏名称',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WaitingHint extends StatelessWidget {
  const _WaitingHint({required this.receiverName});

  final String receiverName;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xB8FFFFFF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFD6E6F5)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Row(
          children: [
            const Icon(Icons.sensors, color: Color(0xFFF59E0B), size: 28),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                '请让手机或电脑与本电视保持在同一网络，然后选择 $receiverName。',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF5E7186),
                  fontSize: 21,
                  fontWeight: FontWeight.w500,
                  height: 1.25,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewPlayingButton extends StatelessWidget {
  const _PreviewPlayingButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 54,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        autofocus: true,
        icon: const Icon(Icons.play_circle_outline, size: 26),
        label: const Text(
          '预览播放界面',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFF0A84FF),
          backgroundColor: const Color(0xB8FFFFFF),
          side: const BorderSide(color: Color(0xFFD6E6F5)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    );
  }
}

class _CastMethods extends StatelessWidget {
  const _CastMethods();

  @override
  Widget build(BuildContext context) {
    const methods = [
      ('AirPlay', Icons.airplay, 'iPhone / iPad / Mac', Color(0xFF38BDF8)),
      ('Miracast', Icons.connected_tv, 'Android / Windows', Color(0xFF94A3B8)),
      ('DLNA / UPnP', Icons.smartphone, '媒体播放器与 NAS', Color(0xFF94A3B8)),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '可用投屏方式',
          style: TextStyle(
            color: Color(0xFF102033),
            fontSize: 26,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 12),
        for (final method in methods) ...[
          _CastMethodRow(
            title: method.$1,
            subtitle: method.$3,
            icon: method.$2,
            iconColor: method.$4,
          ),
          if (method != methods.last) const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _CastMethodRow extends StatelessWidget {
  const _CastMethodRow({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.iconColor,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xCCFFFFFF),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFD6E6F5)),
      ),
      child: SizedBox(
        height: 96,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
          child: Row(
            children: [
              _IconChip(
                icon: icon,
                iconColor: iconColor,
                size: 54,
                iconSize: 28,
                cornerRadius: 15,
                fill: const Color(0xFFEAF5FF),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF102033),
                        fontSize: 25,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF5E7186),
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WaitingPanel extends StatelessWidget {
  const _WaitingPanel({required this.receiverName, required this.onRename});

  final String receiverName;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const _WaitingIllustration(),
        const SizedBox(height: 28),
        _DeviceNameCard(receiverName: receiverName, onRename: onRename),
      ],
    );
  }
}

class _IconChip extends StatelessWidget {
  const _IconChip({
    required this.icon,
    required this.iconColor,
    required this.size,
    required this.iconSize,
    required this.cornerRadius,
    this.fill = const Color(0xD9FFFFFF),
  });

  final IconData icon;
  final Color iconColor;
  final double size;
  final double iconSize;
  final double cornerRadius;
  final Color fill;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(cornerRadius),
        border: Border.all(color: const Color(0xFFD6E6F5)),
        boxShadow: fill == const Color(0xD9FFFFFF)
            ? const [
                BoxShadow(
                  color: Color(0x1F0A3A6B),
                  blurRadius: 24,
                  offset: Offset(0, 8),
                ),
              ]
            : null,
      ),
      child: SizedBox(
        width: size,
        height: size,
        child: Icon(icon, color: iconColor, size: iconSize),
      ),
    );
  }
}

class _SpinningArc extends StatelessWidget {
  const _SpinningArc();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 42,
      height: 42,
      child: CircularProgressIndicator(
        strokeWidth: 5,
        color: Color(0xFF38BDF8),
        backgroundColor: Colors.transparent,
      ),
    );
  }
}

class _SignalRing extends StatelessWidget {
  const _SignalRing({
    required this.width,
    required this.height,
    required this.color,
  });

  final double width;
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius:
            BorderRadius.all(Radius.elliptical(width / 2, height / 2)),
        border: Border.all(
            color: color, width: color == const Color(0x660A84FF) ? 3 : 2),
      ),
      child: SizedBox(width: width, height: height),
    );
  }
}

class _IllustrationShade extends StatelessWidget {
  const _IllustrationShade();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00FFFFFF), Color(0x80FFFFFF), Color(0xE8FFFFFF)],
          stops: [0, 0.7, 1],
        ),
      ),
    );
  }
}

class _WaitingOverlayBadge extends StatelessWidget {
  const _WaitingOverlayBadge();

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xD9FFFFFF),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0xFFD6E6F5)),
          ),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 22, vertical: 18),
            child: Row(
              children: [
                _SpinningArc(),
                SizedBox(width: 18),
                Expanded(
                  child: Text(
                    '正在等待投屏连接',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Color(0xFF102033),
                      fontSize: 30,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WaitingIllustration extends StatelessWidget {
  const _WaitingIllustration();

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(36),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xCCFFFFFF),
          borderRadius: BorderRadius.circular(36),
          border: Border.all(color: const Color(0xFFD6E6F5)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x240A3A6B),
              blurRadius: 34,
              offset: Offset(0, 16),
            ),
          ],
        ),
        child: SizedBox(
          width: 780,
          height: 560,
          child: Stack(
            children: [
              Positioned.fill(
                child: Image.asset(
                  'assets/images/cast_waiting_living_room.png',
                  fit: BoxFit.cover,
                ),
              ),
              const Positioned.fill(child: _IllustrationShade()),
              const Positioned(
                left: 84,
                top: 80,
                child: _SignalRing(
                  width: 612,
                  height: 360,
                  color: Color(0x660A84FF),
                ),
              ),
              const Positioned(
                left: 150,
                top: 126,
                child: _SignalRing(
                  width: 480,
                  height: 266,
                  color: Color(0x6630D158),
                ),
              ),
              const Positioned(
                left: 48,
                right: 48,
                bottom: 30,
                child: SizedBox(height: 92, child: _WaitingOverlayBadge()),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RenameDialog extends StatelessWidget {
  const _RenameDialog({
    required this.controller,
    required this.onCancel,
    required this.onSave,
  });

  final TextEditingController controller;
  final VoidCallback onCancel;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(color: Color(0x66EAF5FF)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: SizedBox(
              width: 1920,
              height: 1080,
              child: Stack(
                children: [
                  Positioned(
                    left: 560,
                    top: 294,
                    width: 800,
                    child: _GlassCard(
                      cornerRadius: 34,
                      padding: const EdgeInsets.all(36),
                      fill: const Color(0xE8FFFFFF),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _RenameIconChip(),
                              SizedBox(width: 18),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '修改投屏名称',
                                      style: TextStyle(
                                        color: Color(0xFF102033),
                                        fontSize: 32,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    SizedBox(height: 8),
                                    Text(
                                      '这个名称会显示在手机、电脑和同一网络下的投屏设备列表中。',
                                      style: TextStyle(
                                        color: Color(0xFF5E7186),
                                        fontSize: 20,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 28),
                          const Text(
                            '新名称',
                            style: TextStyle(
                              color: Color(0xFF5E7186),
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            height: 76,
                            child: TextField(
                              controller: controller,
                              autofocus: true,
                              textInputAction: TextInputAction.done,
                              onSubmitted: (_) => onSave(),
                              style: const TextStyle(
                                color: Color(0xFF102033),
                                fontSize: 30,
                                fontWeight: FontWeight.w500,
                              ),
                              decoration: InputDecoration(
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 22,
                                  vertical: 18,
                                ),
                                filled: true,
                                fillColor: const Color(0xCCF7FBFF),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(18),
                                  borderSide: const BorderSide(
                                    color: Color(0xFFD6E6F5),
                                  ),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(18),
                                  borderSide: const BorderSide(
                                    color: Color(0xFF0A84FF),
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),
                          Row(
                            children: [
                              const Icon(
                                Icons.info_outline,
                                size: 18,
                                color: Color(0xFF5E7186),
                              ),
                              const SizedBox(width: 10),
                              const Expanded(
                                child: Text(
                                  '遥控器确认键进入输入，返回键关闭弹窗。',
                                  style: TextStyle(
                                    color: Color(0xFF5E7186),
                                    fontSize: 17,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 150,
                                height: 58,
                                child: OutlinedButton(
                                  onPressed: onCancel,
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: const Color(0xFF102033),
                                    backgroundColor: const Color(0xFFF2F8FF),
                                    side: const BorderSide(
                                      color: Color(0xFFD6E6F5),
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                  ),
                                  child: const Text(
                                    '取消',
                                    style: TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 16),
                              SizedBox(
                                width: 174,
                                height: 58,
                                child: FilledButton.icon(
                                  onPressed: onSave,
                                  icon: const Icon(Icons.check, size: 24),
                                  style: FilledButton.styleFrom(
                                    backgroundColor: const Color(0xFF0A84FF),
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                  ),
                                  label: const Text(
                                    '保存',
                                    style: TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RenameIconChip extends StatelessWidget {
  const _RenameIconChip();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFEAF5FF),
        borderRadius: BorderRadius.circular(15),
      ),
      child: const SizedBox(
        width: 58,
        height: 58,
        child: Icon(Icons.edit, color: Color(0xFF0A84FF), size: 28),
      ),
    );
  }
}

class _PlayingPage extends StatelessWidget {
  const _PlayingPage({
    required this.player,
    required this.state,
    required this.source,
    required this.fileName,
    required this.connection,
    required this.mediaChips,
    required this.previewPosition,
    required this.previewDuration,
    required this.showControls,
    required this.isMuted,
    required this.onBack,
    required this.onShowControls,
    required this.onPlayPause,
    required this.onSeekBackwardLarge,
    required this.onRewind,
    required this.onForward,
    required this.onSeekForwardLarge,
    required this.onToggleMute,
  });

  final VideoPlayerController? player;
  final PlaybackState state;
  final String source;
  final String fileName;
  final String connection;
  final List<String> mediaChips;
  final Duration previewPosition;
  final Duration previewDuration;
  final bool showControls;
  final bool isMuted;
  final VoidCallback onBack;
  final VoidCallback onShowControls;
  final VoidCallback onPlayPause;
  final VoidCallback onSeekBackwardLarge;
  final VoidCallback onRewind;
  final VoidCallback onForward;
  final VoidCallback onSeekForwardLarge;
  final VoidCallback onToggleMute;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onShowControls,
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            width: 1920,
            height: 1080,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _VideoSurface(player: player),
                if (showControls)
                  Positioned(
                    left: 72,
                    top: 56,
                    child: _BackButton(onPressed: onBack),
                  ),
                if (showControls)
                  Positioned(
                    right: 80,
                    top: 54,
                    child: _PlaybackInfoCard(
                      source: source,
                      fileName: fileName,
                      connection: connection,
                      mediaChips: mediaChips,
                    ),
                  ),
                if (state == PlaybackState.ready)
                  const Center(
                    child: SizedBox(
                      width: 56,
                      height: 56,
                      child: CircularProgressIndicator(strokeWidth: 5),
                    ),
                  ),
                if (showControls)
                  Positioned(
                    left: 470,
                    bottom: 80,
                    child: SizedBox(
                      width: 980,
                      child: _PlaybackControlBar(
                        player: player,
                        state: state,
                        previewPosition: previewPosition,
                        previewDuration: previewDuration,
                        isMuted: isMuted,
                        onPlayPause: onPlayPause,
                        onSeekBackwardLarge: onSeekBackwardLarge,
                        onRewind: onRewind,
                        onForward: onForward,
                        onSeekForwardLarge: onSeekForwardLarge,
                        onToggleMute: onToggleMute,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _VideoSurface extends StatelessWidget {
  const _VideoSurface({required this.player});

  final VideoPlayerController? player;

  @override
  Widget build(BuildContext context) {
    final videoPlayer = player;
    if (videoPlayer != null && videoPlayer.value.isInitialized) {
      final aspectRatio = videoPlayer.value.aspectRatio == 0
          ? 16 / 9
          : videoPlayer.value.aspectRatio;
      return DecoratedBox(
        decoration: const BoxDecoration(color: Colors.black),
        child: Center(
          child: AspectRatio(
            aspectRatio: aspectRatio,
            child: VideoPlayer(videoPlayer),
          ),
        ),
      );
    }

    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [Color(0xFFF6FAFF), Color(0xFFEAF5FF), Colors.white],
          stops: [0, 0.62, 1],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            left: 520,
            top: 210,
            width: 900,
            height: 520,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [Color(0x260A84FF), Color(0x000A84FF)],
                ),
              ),
            ),
          ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.cast, color: Color(0x300A84FF), size: 92),
                SizedBox(height: 24),
                Text(
                  '正在播放投屏内容',
                  style: TextStyle(
                    color: Color(0x26102033),
                    fontSize: 42,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xCCFFFFFF),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: const Color(0xFFD6E6F5)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x1F0A3A6B),
                  blurRadius: 24,
                  offset: Offset(0, 8),
                ),
              ],
            ),
            child: TextButton.icon(
              onPressed: onPressed,
              icon: const Icon(Icons.arrow_back, size: 26),
              label: const Text(
                '返回',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
              ),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF102033),
                padding: const EdgeInsets.symmetric(horizontal: 20),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlaybackInfoCard extends StatelessWidget {
  const _PlaybackInfoCard({
    required this.source,
    required this.fileName,
    required this.connection,
    required this.mediaChips,
  });

  final String source;
  final String fileName;
  final String connection;
  final List<String> mediaChips;

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      cornerRadius: 24,
      padding: const EdgeInsets.all(22),
      fill: const Color(0xDFFFFFFF),
      child: SizedBox(
        width: 516,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SourceLine(source: source),
            const SizedBox(height: 14),
            _MediaFileLine(fileName: fileName),
            const SizedBox(height: 14),
            _MediaChips(chips: mediaChips),
            const SizedBox(height: 14),
            _ConnectionLine(connection: connection),
          ],
        ),
      ),
    );
  }
}

class _SourceLine extends StatelessWidget {
  const _SourceLine({required this.source});

  final String source;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const _PlayingIconTile(icon: Icons.smartphone),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '投屏来源',
                style: TextStyle(
                  color: Color(0xFF5E7186),
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                source,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF102033),
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MediaFileLine extends StatelessWidget {
  const _MediaFileLine({required this.fileName});

  final String fileName;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '播放文件',
          style: TextStyle(
            color: Color(0xFF5E7186),
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Color(0xFF102033),
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _MediaChips extends StatelessWidget {
  const _MediaChips({required this.chips});

  final List<String> chips;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      children: [
        for (final chip in chips) _MediaChip(label: chip),
      ],
    );
  }
}

class _MediaChip extends StatelessWidget {
  const _MediaChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFEAF5FF),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Text(
          label,
          style: const TextStyle(
            color: Color(0xFF102033),
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _ConnectionLine extends StatelessWidget {
  const _ConnectionLine({required this.connection});

  final String connection;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xCCE9FBEF),
        borderRadius: BorderRadius.circular(14),
      ),
      child: SizedBox(
        height: 44,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              const SizedBox(
                width: 10,
                height: 10,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Color(0xFF30D158),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                connection == 'Browser Preview'
                    ? '连接来源  预览模式'
                    : '接收端 IP  $connection',
                style: const TextStyle(
                  color: Color(0xFF102033),
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              const Text(
                '稳定',
                style: TextStyle(
                  color: Color(0xFF5E7186),
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlayingIconTile extends StatelessWidget {
  const _PlayingIconTile({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0x2638BDF8),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SizedBox(
        width: 40,
        height: 40,
        child: Icon(icon, color: const Color(0xFF0A84FF), size: 22),
      ),
    );
  }
}

class _PlaybackControlBar extends StatelessWidget {
  const _PlaybackControlBar({
    required this.player,
    required this.state,
    required this.previewPosition,
    required this.previewDuration,
    required this.isMuted,
    required this.onPlayPause,
    required this.onSeekBackwardLarge,
    required this.onRewind,
    required this.onForward,
    required this.onSeekForwardLarge,
    required this.onToggleMute,
  });

  final VideoPlayerController? player;
  final PlaybackState state;
  final Duration previewPosition;
  final Duration previewDuration;
  final bool isMuted;
  final VoidCallback onPlayPause;
  final VoidCallback onSeekBackwardLarge;
  final VoidCallback onRewind;
  final VoidCallback onForward;
  final VoidCallback onSeekForwardLarge;
  final VoidCallback onToggleMute;

  @override
  Widget build(BuildContext context) {
    final value = player?.value;
    final position = value?.position ?? previewPosition;
    final duration = value?.duration ?? previewDuration;

    return _GlassCard(
      cornerRadius: 34,
      padding: const EdgeInsets.symmetric(horizontal: 34, vertical: 24),
      fill: const Color(0xD9FFFFFF),
      child: Column(
        children: [
          _ProgressBar(position: position, duration: duration),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _PlaybackCircleButton(
                icon: Icons.replay_30,
                label: '后退 30 秒',
                onPressed: onSeekBackwardLarge,
              ),
              const SizedBox(width: 18),
              _PlaybackCircleButton(
                icon: Icons.fast_rewind,
                label: '快退',
                onPressed: onRewind,
              ),
              const SizedBox(width: 18),
              _PlaybackCircleButton(
                icon: state == PlaybackState.playing
                    ? Icons.pause
                    : Icons.play_arrow,
                label: state == PlaybackState.playing ? '暂停' : '播放',
                onPressed: onPlayPause,
                large: true,
                primary: true,
              ),
              const SizedBox(width: 18),
              _PlaybackCircleButton(
                icon: Icons.fast_forward,
                label: '快进',
                onPressed: onForward,
              ),
              const SizedBox(width: 18),
              _PlaybackCircleButton(
                icon: Icons.forward_30,
                label: '前进 30 秒',
                onPressed: onSeekForwardLarge,
              ),
              const SizedBox(width: 18),
              _PlaybackCircleButton(
                icon: isMuted ? Icons.volume_off : Icons.volume_up,
                label: isMuted ? '取消静音' : '静音',
                onPressed: onToggleMute,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DebugAlertOverlay extends StatelessWidget {
  const _DebugAlertOverlay({required this.alerts});

  final List<CoolCastDebugAlert> alerts;

  @override
  Widget build(BuildContext context) {
    final visibleAlerts = alerts
        .where((alert) => alert.isHighSeverity)
        .toList()
        .reversed
        .take(2)
        .toList();
    if (visibleAlerts.isEmpty) {
      return const SizedBox.shrink();
    }

    return Positioned(
      right: 34,
      bottom: 34,
      width: 680,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xEA000000),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFFF6B6B), width: 2),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 28,
              offset: Offset(0, 12),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Row(
                children: [
                  Icon(Icons.error_outline, color: Color(0xFFFF6B6B), size: 28),
                  SizedBox(width: 10),
                  Text(
                    '调试错误',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              for (final alert in visibleAlerts) ...[
                _DebugAlertRow(alert: alert),
                if (alert != visibleAlerts.last) const SizedBox(height: 10),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DebugAlertRow extends StatelessWidget {
  const _DebugAlertRow({required this.alert});

  final CoolCastDebugAlert alert;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '[${alert.level}]',
          style: const TextStyle(
            color: Color(0xFFFFD166),
            fontSize: 20,
            fontWeight: FontWeight.w800,
            fontFamily: 'monospace',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            '${_formatDebugTime(alert.timestamp)} ${alert.message}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w700,
              height: 1.25,
              fontFamily: 'monospace',
            ),
          ),
        ),
      ],
    );
  }
}

class _PlaybackCircleButton extends StatelessWidget {
  const _PlaybackCircleButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.large = false,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool large;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final size = large ? 74.0 : 58.0;
    return SizedBox(
      width: size,
      height: size,
      child: IconButton(
        onPressed: onPressed,
        tooltip: label,
        autofocus: primary,
        icon: Icon(icon, size: large ? 34 : 26),
        color: primary ? const Color(0xFF04111F) : const Color(0xFF102033),
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return primary
                  ? const Color(0xFF38BDF8)
                  : const Color(0xFFE4F4FF);
            }
            return primary ? const Color(0xFF0A84FF) : const Color(0xFFF2F8FF);
          }),
          shape: WidgetStateProperty.all(const CircleBorder()),
          side: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return const BorderSide(color: Color(0xFF0A84FF), width: 3);
            }
            return const BorderSide(color: Color(0xFFD6E6F5));
          }),
          elevation: WidgetStateProperty.resolveWith((states) {
            return states.contains(WidgetState.focused) ? 8 : 0;
          }),
        ),
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.position, required this.duration});

  final Duration position;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final progress = duration.inMilliseconds <= 0
        ? 0.0
        : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(_formatDuration(position), style: _playTimeStyle),
            Text(_formatDuration(duration), style: _playTimeStyle),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 18,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final trackWidth = constraints.maxWidth;
              final filledWidth =
                  (trackWidth * progress).clamp(0.0, trackWidth);
              return Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Container(
                    height: 8,
                    decoration: BoxDecoration(
                      color: const Color(0xFFD8E7F5),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  Container(
                    width: filledWidth,
                    height: 8,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0A84FF),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  Positioned(
                    left: (filledWidth - 9).clamp(0.0, trackWidth - 18),
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        border: Border.all(color: const Color(0xFFB7D8F5)),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _GlassCard extends StatelessWidget {
  const _GlassCard({
    required this.child,
    this.compact = false,
    this.fill = const Color(0xCCFFFFFF),
    this.cornerRadius = 28,
    this.padding,
  });

  final Widget child;
  final bool compact;
  final Color fill;
  final double cornerRadius;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(cornerRadius),
        border: Border.all(color: Colors.white.withValues(alpha: 0.80)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1F4DA3FF),
            blurRadius: 36,
            offset: Offset(0, 18),
          ),
        ],
      ),
      child: Padding(
        padding: padding ?? EdgeInsets.all(compact ? 24 : 30),
        child: child,
      ),
    );
  }
}

class _DebugUrlInput extends StatelessWidget {
  const _DebugUrlInput({
    required this.controller,
    required this.focusNode,
    required this.onLoad,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onLoad;

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      compact: true,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => onLoad(),
              decoration: const InputDecoration(
                hintText: '浏览器调试 URL',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton(onPressed: onLoad, child: const Text('载入')),
        ],
      ),
    );
  }
}

const TextStyle _playTimeStyle = TextStyle(
  color: Color(0xFF5E7186),
  fontSize: 18,
  fontWeight: FontWeight.w600,
);

String coolCastHtmlFormForTest({
  required String receiverName,
  required String ipAddress,
  required String message,
}) =>
    _htmlForm(
        receiverName: receiverName, ipAddress: ipAddress, message: message);

String coolCastHtmlResponseForTest(String url, {required bool isAccepted}) =>
    _htmlResponse(url, isAccepted: isAccepted);

String coolCastDeviceDescriptionForTest(String ip, String receiverName) =>
    _deviceDescription(ip, receiverName);

String coolCastSoapResponseForTest(
  String action, {
  CoolCastUpnpService service = CoolCastUpnpService.avTransport,
  String body = '',
}) =>
    _soapResponse(action, service: service, body: body);

@visibleForTesting
String coolCastAvTransportScpdForTest() => _avTransportScpd();

@visibleForTesting
String coolCastConnectionManagerScpdForTest() => _connectionManagerScpd();

@visibleForTesting
String coolCastProtocolInfoResponseForTest() => _protocolInfoResponse();

@visibleForTesting
Map<String, String> coolCastUpnpResponseHeadersForTest() =>
    _upnpResponseHeaders();

@visibleForTesting
String coolCastSsdpSearchResponseForTest({
  required String localIp,
  required String target,
}) =>
    _ssdpSearchResponse(localIp, target);

@visibleForTesting
String coolCastSsdpNotifyForTest({
  required String localIp,
  required String target,
}) =>
    _ssdpNotify(localIp, target);

@visibleForTesting
bool coolCastIsOttBlinkSearchForTest(Uint8List data) => _isOttBlinkSearch(data);

@visibleForTesting
Uint8List coolCastOttBlinkResponseForTest(String receiverName) =>
    _ottBlinkResponse(receiverName);

@visibleForTesting
String coolCastReceiverNameForDeviceForTest(String? deviceName) =>
    _receiverNameForDevice(deviceName);

@visibleForTesting
String? coolCastNirvanaControlUrlForTest(String payload) =>
    _extractNirvanaControlUrl(payload);

@visibleForTesting
Map<String, Object?>? coolCastBiliNvaPlayForTest(String body) {
  final play = _BiliNvaPlayRequest.fromBody(body);
  if (play == null) {
    return null;
  }
  return {
    'aid': play.aid,
    'cid': play.cid,
    'accessKey': play.accessKey,
    'qn': play.qn,
    'userDesireQn': play.userDesireQn,
    'preferredQn': play.preferredQn,
    'preferredPublicQn': play.preferredPublicQn,
    'contentType': play.contentType,
    'seasonId': play.seasonId,
    'epId': play.epId,
    'seekTs': play.seekTs,
    'mobileVersion': play.mobileVersion,
    'bvid': play.bvid,
  };
}

@visibleForTesting
Map<String, Object?>? coolCastBiliNvaSwitchQnForTest(
  String playBody,
  String switchBody,
) {
  final play = _BiliNvaPlayRequest.fromBody(playBody);
  final qn = _biliSwitchQnFromBody(switchBody);
  if (play == null || qn == null) {
    return null;
  }
  final next = play.copyWith(qn: qn, userDesireQn: qn, seekTs: 42);
  return {
    'qn': next.qn,
    'userDesireQn': next.userDesireQn,
    'preferredQn': next.preferredQn,
    'preferredPublicQn': next.preferredPublicQn,
    'seekTs': next.seekTs,
  };
}

@visibleForTesting
Map<String, Object?>? coolCastBiliNvaControlForTest(
  String command,
  String body,
) {
  return {
    'command': command,
    'seekSeconds': _biliSeekPositionFromBody(body)?.inSeconds,
  };
}

@visibleForTesting
Uri? coolCastBiliTvPlayUrlUriForTest(String body) {
  final play = _BiliNvaPlayRequest.fromBody(body);
  return play == null ? null : _biliTvPlayUrlUri(play);
}

@visibleForTesting
Uri? coolCastBiliSwitchedTvPlayUrlUriForTest(String body, int qn) {
  final play = _BiliNvaPlayRequest.fromBody(body);
  return play == null
      ? null
      : _biliTvPlayUrlUri(play.copyWith(qn: qn, userDesireQn: qn));
}

@visibleForTesting
Uri? coolCastBiliPublicPlayerPlayUrlUriForTest(String body) {
  final play = _BiliNvaPlayRequest.fromBody(body);
  return play == null ? null : _biliPublicPlayerPlayUrlUri(play);
}

@visibleForTesting
Uri? coolCastBiliSwitchedPublicPlayerPlayUrlUriForTest(String body, int qn) {
  final play = _BiliNvaPlayRequest.fromBody(body);
  return play == null
      ? null
      : _biliPublicPlayerPlayUrlUri(
          play.copyWith(qn: qn, userDesireQn: qn),
        );
}

@visibleForTesting
Map<String, String> coolCastBiliPlaybackHeadersForTest({
  String? bvid,
  int? aid,
}) =>
    _biliPlaybackHeaders(bvid: bvid, aid: aid);

@visibleForTesting
String? coolCastBiliPlayUrlFromJsonForTest(String body) =>
    _extractBiliPlayUrl(_tryJsonDecode(body));

@visibleForTesting
Map<String, Object?>? coolCastBiliCastStatusFromJsonForTest(
  String body, {
  int? aid,
  int? cid,
}) =>
    _extractBiliCastStatus(_tryJsonDecode(body), aid: aid, cid: cid)?.toJson();

@visibleForTesting
String coolCastNirvanaControlSummaryForTest(Uint8List data) =>
    _nirvanaControlSummary(data);

@visibleForTesting
String coolCastNirvanaControlScpdForTest() => _nirvanaControlScpd();

@visibleForTesting
bool coolCastLooksLikeTextNirvanaPayloadForTest(Uint8List data) =>
    _looksLikeTextNirvanaPayload(data);

@visibleForTesting
bool coolCastLooksLikeCompleteNirvanaPayloadForTest(Uint8List data) =>
    _looksLikeCompleteNirvanaPayload(data);

@visibleForTesting
bool coolCastShouldSendNirvanaTextAckForTest(Uint8List data) =>
    _shouldSendNirvanaTextAck(data);

@visibleForTesting
String coolCastNirvanaProbeAckForTest() => _nirvanaProbeAck();

@visibleForTesting
String coolCastNirvanaTextAckForTest(
  Uint8List data, {
  String localAddress = '',
}) =>
    _nirvanaTextAck(data, localAddress: localAddress);

@visibleForTesting
Uint8List coolCastNirvanaPingFrameForTest(int sequence) =>
    _nirvanaPingFrame(sequence);

Uint8List? coolCastNirvanaFrameResponseForTest(Uint8List data) {
  final responses = _nirvanaFrameResponses(data);
  return responses.isEmpty ? null : responses.first;
}

@visibleForTesting
Uint8List? coolCastNirvanaFrameResponsesForTest(Uint8List data) {
  final responses = _nirvanaFrameResponses(data);
  if (responses.isEmpty) {
    return null;
  }
  return Uint8List.fromList(responses.expand((response) => response).toList());
}

@visibleForTesting
int? coolCastNirvanaFrameLengthForTest(List<int> data) =>
    _nvaFrameLength(data) ?? _nirvanaShortControlFrameLength(data);

@visibleForTesting
String coolCastBiliPlayInfoResponseForTest({
  int? aid,
  int? cid,
  int? quality,
  int? timelength,
  List<int> acceptQuality = const [],
  int? playState,
}) =>
    _biliPlayInfoResponseBody(
      _BiliCastStatus(
        aid: aid,
        cid: cid,
        quality: quality,
        timelength: timelength,
        acceptQuality: acceptQuality,
      ),
      playState: playState,
    );

@visibleForTesting
Uint8List coolCastNvaServerEventFrameForTest({
  required String command,
  required String body,
}) =>
    _nvaServerEventFrame(command: command, body: body);

@visibleForTesting
Map<String, Object?>? coolCastNvaFrameForTest(Uint8List data) {
  final frame = _parseNvaFrame(data);
  if (frame == null) {
    return null;
  }
  return {
    'op': frame.op,
    'seq': frame.sequence,
    'isRequest': frame.isRequest,
    'attributes': frame.attributes,
    'body': frame.bodyText,
  };
}

@visibleForTesting
Uint8List coolCastNvaRequestFrameForTest(
  int sequence,
  Map<String, String> attributes,
  String body,
) =>
    _nvaFrame(
      op: _biliNirvanaRequestOp,
      sequence: sequence,
      attributes: attributes,
      body: Uint8List.fromList(utf8.encode(body)),
    );

@visibleForTesting
Uint8List coolCastNvaEmptyRequestFrameForTest(
  int sequence,
  Map<String, String> attributes,
) =>
    _nvaEmptyRequestFrame(sequence: sequence, attributes: attributes);

@visibleForTesting
Map<String, Object?>? coolCastBiliNvaExtForTest(String value) =>
    _extractBiliNvaExt(value)?.toJson();

@visibleForTesting
String coolCastEncryptBiliNvaExtForTest(Map<String, Object?> value) =>
    _encryptBiliNvaJson(jsonEncode(value));

@visibleForTesting
String? coolCastDecryptBiliNvaJsonForTest(String hex) =>
    _decryptBiliNvaJson(hex);

@visibleForTesting
String coolCastBiliNvaLinkReplyForTest({
  required String localAddress,
  required String code,
}) =>
    _biliNvaLinkReply(
      localAddress: localAddress,
      code: code,
    );

@visibleForTesting
List<String> coolCastMediaChipsForTest({
  required String currentUrl,
  required String mimeType,
  required PlaybackState state,
  Size? videoSize,
  int? biliQuality,
}) =>
    _mediaChipsFor(
      currentUrl,
      mimeType,
      state,
      videoSize,
      biliStatus: biliQuality == null
          ? null
          : _BiliCastStatus(
              aid: null,
              cid: null,
              quality: biliQuality,
              timelength: null,
              acceptQuality: const [],
            ),
    );

String _htmlForm({
  required String receiverName,
  required String ipAddress,
  required String message,
}) {
  final safeReceiverName = htmlEscape(receiverName);
  final safeIpAddress = htmlEscape(ipAddress);
  final safeMessage = htmlEscape(message);
  final endpoint = ipAddress == 'TV-IP' || ipAddress == 'Browser Preview'
      ? 'http://电视IP:7788/cast?url='
      : 'http://$ipAddress:7788/cast?url=';
  return '''
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>CoolCast</title>
  <style>
    body{font-family:system-ui,-apple-system,sans-serif;margin:0;background:#eaf6ff;color:#102033}
    main{max-width:760px;margin:0 auto;padding:40px 24px}
    section{background:rgba(255,255,255,.72);border:1px solid #d6e6f5;border-radius:24px;padding:24px;box-shadow:0 20px 60px rgba(10,58,107,.12)}
    h1{margin:0 0 8px;font-size:34px}
    p{color:#5e7186;line-height:1.6}
    code{display:block;overflow:auto;background:#f7fbff;border:1px solid #d6e6f5;border-radius:14px;padding:14px;color:#102033}
    input,button{font-size:18px;padding:14px;border-radius:14px;border:1px solid #b9ddfe}
    input{box-sizing:border-box;width:100%;margin:16px 0;background:#fff;color:#102033}
    button{background:#0a84ff;color:white;border:0;font-weight:800;cursor:pointer}
  </style>
</head>
<body>
  <main>
    <section>
      <h1>$safeReceiverName</h1>
      <p>状态：$safeMessage</p>
      <p>HTTP 投送入口</p>
      <code>$endpoint</code>
      <form action="/cast" method="get">
        <input name="url" autofocus placeholder="https://example.com/video.mp4">
        <button type="submit">投送到 CoolCast</button>
      </form>
      <p>电视 IP：$safeIpAddress</p>
    </section>
  </main>
</body>
</html>
''';
}

String _htmlResponse(String url, {required bool isAccepted}) {
  final title = isAccepted ? '已开始投送到 CoolCast' : '视频地址不可用';
  final detail =
      isAccepted ? 'CoolCast 正在尝试载入这个媒体地址。' : '请填写完整的 http 或 https 视频地址后再投送。';
  final safeUrl = htmlEscape(url);
  return '''
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>CoolCast</title>
</head>
<body style="font-family:system-ui,-apple-system,sans-serif;margin:32px;background:#eaf6ff;color:#102033">
  <h1>$title</h1>
  <p>$detail</p>
  <p>${safeUrl.isEmpty ? '未提供视频地址' : safeUrl}</p>
  <p><a href="/">继续投送</a></p>
</body>
</html>
''';
}

String _deviceDescription(String ip, String receiverName) {
  return '''
<?xml version="1.0" encoding="utf-8"?>
<root xmlns="urn:schemas-upnp-org:device-1-0"
      xmlns:dlna="urn:schemas-dlna-org:device-1-0">
  <specVersion>
    <major>1</major>
    <minor>0</minor>
  </specVersion>
  <URLBase>http://$ip:7788/</URLBase>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>${xmlEscape(_biliFriendlyName(receiverName))}</friendlyName>
    <manufacturer>$_biliProjectionManufacturer</manufacturer>
    <manufacturerURL>$_biliProjectionModelUrl</manufacturerURL>
    <modelName>$_biliProjectionModelName</modelName>
    <X_brandName>$_biliProjectionBrandName</X_brandName>
    <modelDescription>$_biliProjectionModelDescription</modelDescription>
    <ottVersion>$_biliProjectionBuild</ottVersion>
    <channelName>$_biliProjectionChannelName</channelName>
    <autoPullId>$_biliProjectionAutoPullId</autoPullId>
    <capability>$_biliProjectionCapability</capability>
    <modelURL>$_biliProjectionModelUrl</modelURL>
    <serialNumber>$_biliProjectionAutoPullId</serialNumber>
    <UDN>uuid:$_biliProjectionAutoPullId</UDN>
    <dlna:X_DLNADOC>DMR-1.50</dlna:X_DLNADOC>
    <presentationURL>http://$ip:7788/</presentationURL>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
        <controlURL>/AVTransport/control</controlURL>
        <eventSubURL>/AVTransport/event</eventSubURL>
        <SCPDURL>/AVTransport/scpd.xml</SCPDURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>
        <controlURL>/RenderingControl/control</controlURL>
        <eventSubURL>/RenderingControl/event</eventSubURL>
        <SCPDURL>/RenderingControl/scpd.xml</SCPDURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>
        <controlURL>/ConnectionManager/control</controlURL>
        <eventSubURL>/ConnectionManager/event</eventSubURL>
        <SCPDURL>/ConnectionManager/scpd.xml</SCPDURL>
      </service>
      <service>
        <serviceType>$_biliNirvanaControlService</serviceType>
        <serviceId>urn:app-bilibili-com:serviceId:NirvanaControl</serviceId>
        <controlURL>/NirvanaControl/control</controlURL>
        <eventSubURL>/NirvanaControl/event</eventSubURL>
        <SCPDURL>/NirvanaControl/scpd.xml</SCPDURL>
      </service>
      <service>
        <serviceType>$_biliNirvanaSsdpService</serviceType>
        <serviceId>urn:schemas-upnp-org:serviceId:NirvanaControl</serviceId>
        <controlURL>/NirvanaControl/control</controlURL>
        <eventSubURL>/NirvanaControl/event</eventSubURL>
        <SCPDURL>/NirvanaControl/scpd.xml</SCPDURL>
      </service>
    </serviceList>
  </device>
</root>
''';
}

String _ssdpSearchResponse(String localIp, String target) {
  return '''
HTTP/1.1 200 OK\r
CACHE-CONTROL: max-age=1800\r
EXT:\r
LOCATION: http://$localIp:7788$_biliDescriptionPath\r
SERVER: $_upnpServerHeader\r
ST: $target\r
USN: uuid:$_biliProjectionAutoPullId::$target\r
\r
''';
}

String _ssdpNotify(String localIp, String target) {
  return '''
NOTIFY * HTTP/1.1\r
HOST: 239.255.255.250:1900\r
CACHE-CONTROL: max-age=1800\r
LOCATION: http://$localIp:7788$_biliDescriptionPath\r
NT: $target\r
NTS: ssdp:alive\r
SERVER: $_upnpServerHeader\r
USN: uuid:$_biliProjectionAutoPullId::$target\r
\r
''';
}

bool _isOttBlinkSearch(Uint8List data) {
  return data.length >= 6 && data[0] == 0x24 && data[1] == 0x10;
}

Uint8List _ottBlinkResponse(String receiverName) {
  final payload = utf8.encode(jsonEncode(_ottBlinkDeviceMsg(receiverName)));
  final response = Uint8List(6 + payload.length);
  response[0] = 0x24;
  response[1] = 0x11;
  response[2] = payload.length & 0xff;
  response[3] = (payload.length >> 8) & 0xff;
  response[4] = (payload.length >> 16) & 0xff;
  response[5] = (payload.length >> 24) & 0xff;
  response.setRange(6, response.length, payload);
  return response;
}

Map<String, Object> _ottBlinkDeviceMsg(String receiverName) {
  return {
    'address': _biliProjectionMobiApp,
    'uuid': _biliProjectionAutoPullId,
    'friendlyName': _biliFriendlyName(receiverName),
    'model_name': _biliProjectionModelName,
    'brand_name': _biliProjectionBrandName,
    'manufacture': _biliProjectionManufacturer,
    'brandName': _biliProjectionBrandName,
    'manufacturer': _biliProjectionManufacturer,
    'channelName': _biliProjectionChannelName,
    'mobiApp': _biliProjectionMobiApp,
    'build': _biliProjectionBuild,
    'version': _biliProjectionBuild,
    'ottVersion': _biliProjectionBuild,
    'support4k': _biliProjectionSupport4k,
    'fourk': _biliProjectionFourk,
    'capability': _biliProjectionCapability,
    'castService': _biliProjectionCastService,
    'needNvaExtra': _biliProjectionNeedNvaExtra,
    'autoPullId': _biliProjectionAutoPullId,
    'ignoreDirect': _biliProjectionIgnoreDirect,
  };
}

_BiliNvaExt? _extractBiliNvaExt(String value) {
  final text = value.trim();
  if (text.isEmpty) {
    return null;
  }

  final encrypted = _findQueryLikeValue(text, '_nva_ext_');
  if (encrypted != null && encrypted.isNotEmpty) {
    final json = _decryptBiliNvaJson(encrypted);
    if (json != null) {
      return _parseBiliNvaJson(json);
    }
  }

  final plain = _findQueryLikeValue(text, 'nva_ext');
  if (plain != null && plain.isNotEmpty) {
    return _parseBiliNvaJson(plain);
  }

  final parsed = _tryJsonDecode(text);
  final nested = _findBiliNvaExtInJson(parsed);
  if (nested != null) {
    return nested;
  }

  return null;
}

String? _findQueryLikeValue(String value, String key) {
  final uri = Uri.tryParse(value);
  final fromUri = uri?.queryParameters[key];
  if (fromUri != null && fromUri.isNotEmpty) {
    return fromUri;
  }

  final match = RegExp(
    '(?:^|[?&])${RegExp.escape(key)}=([^\\s&]+)',
    caseSensitive: false,
  ).firstMatch(value);
  final raw = match?.group(1);
  if (raw == null || raw.isEmpty) {
    return null;
  }
  return Uri.decodeComponent(raw);
}

_BiliNvaExt? _findBiliNvaExtInJson(Object? value) {
  if (value is String) {
    return _extractBiliNvaExt(value);
  }
  if (value is List) {
    for (final item in value) {
      final ext = _findBiliNvaExtInJson(item);
      if (ext != null) {
        return ext;
      }
    }
  }
  if (value is Map) {
    for (final key in const ['_nva_ext_', 'nva_ext']) {
      final raw = value[key];
      if (raw is String && raw.isNotEmpty) {
        if (key == '_nva_ext_') {
          final json = _decryptBiliNvaJson(raw);
          if (json != null) {
            return _parseBiliNvaJson(json);
          }
        } else {
          return _parseBiliNvaJson(raw);
        }
      }
    }
    for (final item in value.values) {
      final ext = _findBiliNvaExtInJson(item);
      if (ext != null) {
        return ext;
      }
    }
  }
  return null;
}

_BiliNvaExt? _parseBiliNvaJson(String json) {
  final parsed = _tryJsonDecode(json);
  if (parsed is! Map) {
    return null;
  }

  final content = parsed['content'];
  final raw = <String, Object?>{
    for (final entry in (content is Map ? content : parsed).entries)
      if (entry.key is String) entry.key as String: entry.value,
  };
  final link = raw['nl'];
  _BiliNvaLink? nvaLink;
  if (link is Map) {
    nvaLink = _BiliNvaLink(
      callbackUrl: (link['cb'] as String?)?.trim() ?? '',
      code: (link['cd'] as String?)?.trim() ?? '',
    );
  }

  return _BiliNvaExt(
    raw: raw,
    qn: _jsonInt(raw['qn']),
    userDesiredQn: _jsonInt(raw['userDesireQn']),
    ignoreDirect: _jsonBool(raw['ignore_direct'] ?? raw['ignoreDirect']),
    link: nvaLink,
  );
}

int? _jsonInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.round();
  }
  if (value is String) {
    return int.tryParse(value);
  }
  return null;
}

bool? _jsonBool(Object? value) {
  if (value is bool) {
    return value;
  }
  if (value is String) {
    if (value == 'true' || value == '1') {
      return true;
    }
    if (value == 'false' || value == '0') {
      return false;
    }
  }
  return null;
}

String? _decryptBiliNvaJson(String hex) {
  try {
    final encrypted = _hexToBytes(hex);
    final decrypted = _biliNvaAesProcess(encrypted, forEncryption: false);
    return utf8.decode(decrypted, allowMalformed: false);
  } on Object {
    return null;
  }
}

String _encryptBiliNvaJson(String json) {
  final encrypted = _biliNvaAesProcess(
    Uint8List.fromList(utf8.encode(json)),
    forEncryption: true,
  );
  return _bytesToHex(encrypted);
}

Uint8List _biliNvaAesProcess(
  Uint8List input, {
  required bool forEncryption,
}) {
  final key = Uint8List.fromList(utf8.encode(_biliNvaAesKey));
  final cipher = pc.PaddedBlockCipherImpl(
    pc.PKCS7Padding(),
    pc.CBCBlockCipher(pc.AESEngine()),
  )..init(
      forEncryption,
      pc.PaddedBlockCipherParameters<pc.ParametersWithIV<pc.KeyParameter>,
          pc.CipherParameters?>(
        pc.ParametersWithIV(pc.KeyParameter(key), key),
        null,
      ),
    );
  return cipher.process(input);
}

Uint8List _hexToBytes(String hex) {
  final normalized = hex.trim();
  if (normalized.length.isOdd) {
    throw const FormatException('Odd-length hex string');
  }
  final bytes = Uint8List(normalized.length ~/ 2);
  for (var i = 0; i < normalized.length; i += 2) {
    bytes[i ~/ 2] = int.parse(normalized.substring(i, i + 2), radix: 16);
  }
  return bytes;
}

String _bytesToHex(Uint8List bytes) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

Future<String?> _sendBiliNvaLinkReply(
  _BiliNvaExt nvaExt,
  String localAddress,
) async {
  final callbackUrl = nvaExt.link?.callbackUrl.trim() ?? '';
  if (callbackUrl.isEmpty) {
    return null;
  }
  final callback = Uri.tryParse(callbackUrl);
  if (callback == null || !callback.hasScheme || callback.host.isEmpty) {
    return 'B站 NVA callback 不可用：${_shortUrl(callbackUrl)}';
  }

  final reply = _biliNvaLinkReply(
    localAddress: localAddress,
    code: nvaExt.link?.code ?? '',
  );
  final uri = callback.replace(
    queryParameters: {
      ...callback.queryParameters,
      'link_reply': reply,
    },
  );
  final client = HttpClient();
  try {
    final request =
        await client.getUrl(uri).timeout(const Duration(seconds: 2));
    final response = await request.close().timeout(const Duration(seconds: 2));
    await response.drain<void>();
    return null;
  } on Object catch (error) {
    return 'B站 link_reply 回调失败：${_shortError(error)}';
  } finally {
    client.close(force: true);
  }
}

String _biliNvaLinkReply({
  required String localAddress,
  required String code,
}) {
  return _encryptBiliNvaJson(jsonEncode({
    'code': code,
    'from': 'coolcast',
    'buvid': _biliProjectionAutoPullId,
    'nvaLinkAddress': _biliNvaLinkAddress(localAddress),
    'friendlyName': _biliProjectionFriendlyName,
    'modelName': _biliProjectionModelName,
    'brandName': _biliProjectionBrandName,
    'manufacturer': _biliProjectionManufacturer,
    'ottVersion': _biliProjectionBuild,
    'ignoreDirect': _biliProjectionIgnoreDirect,
    'autoPullId': _biliProjectionAutoPullId,
  }));
}

String _biliNvaLinkAddress(String localAddress) {
  final address = localAddress.trim();
  if (address.isEmpty || address == '0.0.0.0') {
    return '$_biliProjectionAutoPullId:$_nirvanaControlPort';
  }
  return '$address:$_nirvanaControlPort';
}

bool _looksLikeCompleteNirvanaPayload(List<int> data) {
  if (data.isEmpty) {
    return false;
  }
  final text = utf8.decode(data, allowMalformed: true).trim();
  if (text.startsWith('SETUP ') || text.startsWith('RESTORE ')) {
    return _hasNirvanaHeader(text, 'Session') &&
        _hasNirvanaHeader(text, 'NvaVersion') &&
        _hasNirvanaHeader(text, 'UUID');
  }
  if (text.startsWith('{') && text.endsWith('}')) {
    return true;
  }
  return text.contains('\r\n\r\n');
}

bool _hasNirvanaHeader(String text, String name) {
  return RegExp(
    '^$name\\s*:',
    caseSensitive: false,
    multiLine: true,
  ).hasMatch(text);
}

bool _looksLikeTextNirvanaPayload(List<int> data) {
  if (data.isEmpty) {
    return true;
  }
  final text = utf8.decode(data, allowMalformed: true).trimLeft();
  if (text.isEmpty) {
    return true;
  }
  return text.startsWith('{') ||
      text.startsWith('[') ||
      text.startsWith('SETUP ') ||
      text.startsWith('RESTORE ') ||
      text.startsWith('GET ') ||
      text.startsWith('POST ') ||
      text.startsWith('HTTP/');
}

bool _shouldSendNirvanaTextAck(List<int> data) {
  if (data.isEmpty || !_looksLikeTextNirvanaPayload(data)) {
    return false;
  }
  final text = utf8.decode(data, allowMalformed: true).trimLeft();
  return text.startsWith('{') ||
      text.startsWith('[') ||
      text.startsWith('SETUP ') ||
      text.startsWith('RESTORE ') ||
      text.startsWith('GET ') ||
      text.startsWith('POST ') ||
      text.startsWith('HTTP/');
}

String? _extractNirvanaControlUrl(String payload) {
  final parsed = _tryJsonDecode(payload);
  final fromJson = parsed == null ? null : _findUrlInJson(parsed);
  if (_isValidCastUrl(fromJson ?? '')) {
    return fromJson;
  }

  final urlMatch = RegExp(
    r'https?://[^\s"<>\\]+',
    caseSensitive: false,
  ).firstMatch(payload);
  final rawUrl = urlMatch?.group(0);
  if (_isValidCastUrl(rawUrl ?? '')) {
    return rawUrl;
  }
  return null;
}

Object? _tryJsonDecode(String payload) {
  try {
    return jsonDecode(payload.trim());
  } on Object {
    return null;
  }
}

String? _findUrlInJson(Object? value) {
  if (value is String) {
    if (_isValidCastUrl(value)) {
      return value;
    }
    final nested = _tryJsonDecode(value);
    if (nested != null) {
      return _findUrlInJson(nested);
    }
    return null;
  }
  if (value is List) {
    for (final item in value) {
      final url = _findUrlInJson(item);
      if (url != null) {
        return url;
      }
    }
    return null;
  }
  if (value is Map) {
    for (final key in const ['url', 'playUrl', 'play_url']) {
      final url = _findUrlInJson(value[key]);
      if (url != null) {
        return url;
      }
    }
    for (final item in value.values) {
      final url = _findUrlInJson(item);
      if (url != null) {
        return url;
      }
    }
  }
  return null;
}

class _BiliNvaPlayRequest {
  const _BiliNvaPlayRequest({
    required this.raw,
    required this.aid,
    required this.cid,
    required this.accessKey,
    required this.qn,
    required this.userDesireQn,
    required this.contentType,
    required this.seasonId,
    required this.epId,
    required this.seekTs,
    required this.mobileVersion,
    required this.bvid,
  });

  final Map<String, Object?> raw;
  final int? aid;
  final int? cid;
  final String accessKey;
  final int? qn;
  final int? userDesireQn;
  final int? contentType;
  final int? seasonId;
  final int? epId;
  final int? seekTs;
  final int? mobileVersion;
  final String? bvid;

  int get preferredQn {
    final desired = userDesireQn;
    if (desired != null && desired > 0) {
      return desired;
    }
    final current = qn;
    if (current != null && current > 0) {
      return current;
    }
    return 80;
  }

  int get preferredPublicQn {
    final desired = userDesireQn;
    if (desired != null && desired > 0) {
      return desired;
    }
    return accessKey.isEmpty ? preferredQn : _biliProjectionMaxQn;
  }

  _BiliNvaPlayRequest copyWith({
    int? qn,
    int? userDesireQn,
    int? seekTs,
  }) {
    return _BiliNvaPlayRequest(
      raw: {
        ...raw,
        if (qn != null) 'qn': qn,
        if (userDesireQn != null) 'userDesireQn': userDesireQn,
        if (seekTs != null) 'seekTs': seekTs,
      },
      aid: aid,
      cid: cid,
      accessKey: accessKey,
      qn: qn ?? this.qn,
      userDesireQn: userDesireQn ?? this.userDesireQn,
      contentType: contentType,
      seasonId: seasonId,
      epId: epId,
      seekTs: seekTs ?? this.seekTs,
      mobileVersion: mobileVersion,
      bvid: bvid,
    );
  }

  static _BiliNvaPlayRequest? fromBody(String body) {
    final decoded = _tryJsonDecode(body);
    if (decoded is! Map) {
      return null;
    }
    final raw = decoded.cast<String, Object?>();
    final aid = _jsonInt(raw['aid']) ?? _jsonInt(raw['avid']);
    final cid = _jsonInt(raw['cid']);
    final accessKey = _jsonString(raw['accessKey']) ??
        _jsonString(raw['access_key']) ??
        _jsonString(raw['mobile_access_key']) ??
        '';
    if (cid == null || accessKey.isEmpty) {
      return null;
    }
    return _BiliNvaPlayRequest(
      raw: raw,
      aid: aid,
      cid: cid,
      accessKey: accessKey,
      qn: _jsonInt(raw['qn']),
      userDesireQn:
          _jsonInt(raw['userDesireQn']) ?? _jsonInt(raw['userDesiredQn']),
      contentType: _jsonInt(raw['contentType']),
      seasonId: _jsonInt(raw['seasonId']),
      epId: _jsonInt(raw['epId']),
      seekTs: _jsonInt(raw['seekTs']),
      mobileVersion: _jsonInt(raw['mobileVersion']),
      bvid: _findBvidInJson(raw),
    );
  }
}

int? _biliSwitchQnFromBody(String body) {
  final decoded = _tryJsonDecode(body);
  if (decoded is! Map) {
    return null;
  }
  return _jsonInt(decoded['qn']) ??
      _jsonInt(decoded['quality']) ??
      _jsonInt(decoded['userDesireQn']);
}

Duration? _biliSeekPositionFromBody(String body) {
  final decoded = _tryJsonDecode(body);
  if (decoded is! Map) {
    return null;
  }
  final seconds = _jsonInt(decoded['position']) ??
      _jsonInt(decoded['progress']) ??
      _jsonInt(decoded['seekTs']) ??
      _jsonInt(decoded['pos']);
  return seconds == null ? null : Duration(seconds: seconds);
}

class _BiliPlayUrlResult {
  const _BiliPlayUrlResult.url(this.url, {this.status}) : error = null;
  const _BiliPlayUrlResult.error(this.error)
      : url = null,
        status = null;

  final String? url;
  final String? error;
  final _BiliCastStatus? status;
}

Future<_BiliPlayUrlResult> _fetchBiliPlayUrl(_BiliNvaPlayRequest play) async {
  final tvResult = await _fetchBiliPlayUrlFromUri(
    _biliTvPlayUrlUri(play),
    label: 'B站 tv playurl',
    refererBvid: play.bvid,
    aid: play.aid,
    cid: play.cid,
  );
  if (tvResult.url != null) {
    return tvResult;
  }
  final publicUri = _biliPublicPlayerPlayUrlUri(play);
  if (publicUri == null) {
    return tvResult;
  }
  _debugLog('B站 tv playurl failed, fallback to player playurl');
  final publicResult = await _fetchBiliPlayUrlFromUri(
    publicUri,
    label: 'B站 player playurl',
    refererBvid: play.bvid,
    aid: play.aid,
    cid: play.cid,
  );
  if (publicResult.url != null) {
    return publicResult;
  }
  return _BiliPlayUrlResult.error(
    '${tvResult.error ?? 'tv playurl failed'}; '
    '${publicResult.error ?? 'player playurl failed'}',
  );
}

Future<_BiliPlayUrlResult> _fetchBiliPlayUrlFromUri(
  Uri uri, {
  required String label,
  required String? refererBvid,
  required int? aid,
  required int? cid,
}) async {
  _debugLog('$label request: ${_shortUrl(uri.toString())}');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final request = await client.getUrl(uri);
    request.headers
      ..set(HttpHeaders.userAgentHeader, 'Mozilla/5.0 BiliDroid')
      ..set(HttpHeaders.acceptHeader, 'application/json');
    if (refererBvid != null && refererBvid.isNotEmpty) {
      request.headers.set(
        HttpHeaders.refererHeader,
        'https://www.bilibili.com/video/$refererBvid',
      );
    }
    final response = await request.close().timeout(const Duration(seconds: 12));
    final body = await response.transform(utf8.decoder).join();
    _debugLog(
      '$label response status=${response.statusCode} '
      'bytes=${body.length} body=${_compactSummary(body)}',
    );
    if (response.statusCode != HttpStatus.ok) {
      return _BiliPlayUrlResult.error('$label HTTP ${response.statusCode}');
    }
    final decoded = _tryJsonDecode(body);
    final apiCode = _biliApiCode(decoded);
    if (apiCode != null && apiCode != 0) {
      return _BiliPlayUrlResult.error(
        '$label code=$apiCode ${_biliApiMessage(decoded)}'.trim(),
      );
    }
    final url = _extractBiliPlayUrl(decoded);
    if (url == null) {
      return _BiliPlayUrlResult.error('$label 无 durl/url');
    }
    return _BiliPlayUrlResult.url(
      url,
      status: _extractBiliCastStatus(
        decoded,
        aid: aid,
        cid: cid,
      ),
    );
  } on Object catch (error) {
    return _BiliPlayUrlResult.error('$label 异常：${_shortError(error)}');
  } finally {
    client.close(force: true);
  }
}

Uri _biliTvPlayUrlUri(_BiliNvaPlayRequest play) {
  final objectId = play.aid ?? play.epId ?? play.seasonId ?? 0;
  final query = <String, String>{
    'video_type': '${play.contentType ?? 0}',
    'protocol': '0',
    'mobile_access_key': play.accessKey,
    'is_proj': '1',
    'playurl_type': '1',
    'object_id': '$objectId',
    'cid': '${play.cid}',
    'qn': '${play.preferredQn}',
    'is_h265': '0',
    'is_dolby': '0',
    'live_extra': play.contentType == 4
        ? '{need_hdr=0, ott_build=$_biliProjectionBuild}'
        : '',
    'fnver': '0',
    'fnval': '0',
    'fourk': '$_biliProjectionFourk',
    'sys_ver': '${play.mobileVersion ?? _biliProjectionBuild}',
    'buvid': _biliProjectionAutoPullId,
    'access_key': play.accessKey,
    'ogv_aid': '${play.aid ?? 0}',
    'language': 'zh-CN',
    'device_type': '1',
    'from_outside': '1',
  };
  _addBiliSignedCommonParams(query, build: play.mobileVersion);
  return Uri.https('api.bilibili.com', '/x/tv/playurl', query);
}

Uri? _biliPublicPlayerPlayUrlUri(_BiliNvaPlayRequest play) {
  if (play.cid == null) {
    return null;
  }
  final query = <String, String>{
    'cid': '${play.cid}',
    'qn': '${play.preferredPublicQn}',
    'fnver': '0',
    'fnval': play.accessKey.isEmpty ? '0' : '4048',
    'fourk': '$_biliProjectionFourk',
  };
  if (play.accessKey.isNotEmpty) {
    query['access_key'] = play.accessKey;
  }
  final bvid = play.bvid;
  if (bvid != null && bvid.isNotEmpty) {
    query['bvid'] = bvid;
  } else if (play.aid != null) {
    query['avid'] = '${play.aid}';
  } else {
    return null;
  }
  return Uri.https('api.bilibili.com', '/x/player/playurl', query);
}

Map<String, String> _biliPlaybackHeaders({String? bvid, int? aid}) {
  final headers = <String, String>{
    HttpHeaders.userAgentHeader: 'Mozilla/5.0 BiliDroid',
  };
  if (bvid != null && bvid.isNotEmpty) {
    headers[HttpHeaders.refererHeader] = 'https://www.bilibili.com/video/$bvid';
  } else if (aid != null) {
    headers[HttpHeaders.refererHeader] =
        'https://www.bilibili.com/video/av$aid';
  }
  return headers;
}

String? _extractBiliPlayUrl(Object? decoded) {
  final data = _jsonMap(decoded)?['data'] ?? _jsonMap(decoded)?['result'];
  return _findUrlInBiliPlayUrl(data) ?? _findUrlInBiliPlayUrl(decoded);
}

_BiliCastStatus? _extractBiliCastStatus(
  Object? decoded, {
  required int? aid,
  required int? cid,
}) {
  final data = _jsonMap(decoded)?['data'] ?? _jsonMap(decoded)?['result'];
  final map = _jsonMap(data);
  if (map == null) {
    return null;
  }
  final quality = _jsonInt(map['quality']);
  final timelength = _jsonInt(map['timelength']);
  final acceptQuality = _jsonIntList(map['accept_quality']);
  if (quality == null && timelength == null && acceptQuality.isEmpty) {
    return null;
  }
  return _BiliCastStatus(
    aid: aid,
    cid: cid,
    quality: quality,
    timelength: timelength,
    acceptQuality: acceptQuality,
  );
}

String? _findUrlInBiliPlayUrl(Object? value) {
  if (value is String) {
    return _isValidCastUrl(value) ? value : null;
  }
  if (value is List) {
    for (final item in value) {
      final url = _findUrlInBiliPlayUrl(item);
      if (url != null) {
        return url;
      }
    }
    return null;
  }
  final map = _jsonMap(value);
  if (map == null) {
    return null;
  }
  final directUrl = _findDirectBiliPlayUrl(map);
  if (directUrl != null) {
    return directUrl;
  }
  final dashUrl = _findBiliDashUrl(map['dash'], _jsonInt(map['quality']));
  if (dashUrl != null) {
    return dashUrl;
  }
  for (final item in map.values) {
    final url = _findUrlInBiliPlayUrl(item);
    if (url != null) {
      return url;
    }
  }
  return null;
}

String? _findDirectBiliPlayUrl(Map<String, Object?> map) {
  for (final key in const ['durl', 'url', 'baseUrl', 'base_url']) {
    final url = _findUrlInBiliPlayUrl(map[key]);
    if (url != null) {
      return url;
    }
  }
  return null;
}

String? _findBiliDashUrl(Object? value, int? quality) {
  final dash = _jsonMap(value);
  if (dash == null) {
    return null;
  }
  final videos = dash['video'];
  if (videos is List) {
    if (quality != null) {
      for (final item in videos) {
        final map = _jsonMap(item);
        if (map != null && _jsonInt(map['id']) == quality) {
          final url = _findDirectBiliPlayUrl(map);
          if (url != null) {
            return url;
          }
        }
      }
    }
    for (final item in videos) {
      final map = _jsonMap(item);
      if (map != null) {
        final url = _findDirectBiliPlayUrl(map);
        if (url != null) {
          return url;
        }
      }
    }
  }
  return _findDirectBiliPlayUrl(dash);
}

int? _biliApiCode(Object? decoded) => _jsonInt(_jsonMap(decoded)?['code']);

List<int> _jsonIntList(Object? value) {
  if (value is! List) {
    return const [];
  }
  return value.map(_jsonInt).whereType<int>().toList(growable: false);
}

String _biliApiMessage(Object? decoded) {
  final map = _jsonMap(decoded);
  return (_jsonString(map?['message']) ?? _jsonString(map?['msg']) ?? '')
      .trim();
}

Map<String, Object?>? _jsonMap(Object? value) {
  if (value is! Map) {
    return null;
  }
  return value.cast<String, Object?>();
}

String? _jsonString(Object? value) {
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  return null;
}

String? _findBvidInJson(Object? value) {
  if (value is String) {
    final direct = RegExp(r'BV[0-9A-Za-z]+').firstMatch(value)?.group(0);
    if (direct != null) {
      return direct;
    }
    final nested = _tryJsonDecode(value);
    return nested == null ? null : _findBvidInJson(nested);
  }
  if (value is List) {
    for (final item in value) {
      final bvid = _findBvidInJson(item);
      if (bvid != null) {
        return bvid;
      }
    }
    return null;
  }
  final map = _jsonMap(value);
  if (map == null) {
    return null;
  }
  final direct = _jsonString(map['bvid']);
  if (direct != null && direct.startsWith('BV')) {
    return direct;
  }
  for (final item in map.values) {
    final bvid = _findBvidInJson(item);
    if (bvid != null) {
      return bvid;
    }
  }
  return null;
}

void _addBiliSignedCommonParams(
  Map<String, String> query, {
  required int? build,
}) {
  query
    ..putIfAbsent('platform', () => 'android')
    ..putIfAbsent('mobi_app', () => _biliMobileMobiApp)
    ..putIfAbsent('appkey', () => _biliMobileAppKey)
    ..putIfAbsent('build', () => '${build ?? _biliProjectionBuild}')
    ..putIfAbsent('channel', () => _biliMobileChannel)
    ..putIfAbsent('c_locale', () => 'zh_CN')
    ..putIfAbsent('s_locale', () => 'zh_CN');
  query.remove('sign');
  query['sign'] = _biliSignQuery(query);
}

String _biliSignQuery(Map<String, String> query) {
  final canonical = query.entries.where((entry) => entry.key != 'sign').toList()
    ..sort((left, right) => left.key.compareTo(right.key));
  final source = canonical
      .map((entry) =>
          '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}')
      .join('&');
  return _md5Hex('$source$_biliMobileAppSecret');
}

String _md5Hex(String value) {
  final digest =
      pc.Digest('MD5').process(Uint8List.fromList(utf8.encode(value)));
  return digest.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

String _nirvanaControlSummary(Uint8List data) {
  if (data.isEmpty) {
    return '空包';
  }
  final text = utf8.decode(data, allowMalformed: true).trim();
  final printable = text.runes.every((rune) {
    return rune == 0x09 || rune == 0x0a || rune == 0x0d || rune >= 0x20;
  });
  if (printable && text.isNotEmpty) {
    return _compactSummary(text);
  }
  final nvaFrame = _parseNvaFrame(data);
  if (nvaFrame != null) {
    return nvaFrame.summary;
  }
  final nativeSummary = _nativeFrameTextSummary(data);
  if (nativeSummary != null) {
    return nativeSummary;
  }
  final heartbeatSummary = _nirvanaHeartbeatFrameSummary(data);
  if (heartbeatSummary != null) {
    return heartbeatSummary;
  }
  final shortControlSummary = _nirvanaShortControlFrameSummary(data);
  if (shortControlSummary != null) {
    return shortControlSummary;
  }
  return 'hex ${data.take(32).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(' ')}';
}

String? _nvaCommandForLog(Uint8List data) {
  final frame = _parseNvaFrame(data);
  return frame?.attributes['Command'];
}

class _NvaFrame {
  const _NvaFrame({
    required this.op,
    required this.sequence,
    required this.attributes,
    required this.body,
  });

  final int op;
  final int sequence;
  final Map<String, String> attributes;
  final Uint8List body;

  bool get isRequest =>
      op == _biliNirvanaRequestOp || op == _biliNirvanaEmptyRequestOp;

  String get bodyText => utf8.decode(body, allowMalformed: true);

  String get summary {
    final command = attributes['Command'];
    final pieces = <String>[
      isRequest ? 'request' : 'response',
      'seq=$sequence',
      'op=0x${op.toRadixString(16)}',
      if (command != null) 'Command=$command',
      if (body.isNotEmpty) _compactSummary(bodyText),
    ];
    return 'native ${pieces.join(' ')}';
  }
}

int? _nvaFrameLength(List<int> data) {
  if (data.length < 7) {
    return null;
  }
  final op = _readUint16(data, 0);
  if (op != _biliNirvanaRequestOp &&
      op != _biliNirvanaEmptyRequestOp &&
      op != _biliNirvanaBodyResponseOp &&
      op != _biliNirvanaResponseOp) {
    return null;
  }
  var offset = 6;
  final attrCount = data[offset];
  offset += 1;
  for (var i = 0; i < attrCount; i++) {
    final keyLength = _nvaStringLength(data, offset);
    if (keyLength == null) {
      return null;
    }
    offset += 1 + keyLength;
    final valueLength = _nvaStringLength(data, offset);
    if (valueLength == null) {
      return null;
    }
    offset += 1 + valueLength;
  }
  if (op == _biliNirvanaEmptyRequestOp) {
    return offset;
  }
  if (data.length < offset + 4) {
    return null;
  }
  final bodyLength = _readUint32(data, offset);
  if (bodyLength == null) {
    return null;
  }
  return offset + 4 + bodyLength;
}

int? _nirvanaShortControlFrameLength(List<int> data) {
  if (data.length < 6) {
    return null;
  }
  final op = _readUint16(data, 0);
  return op == _biliNirvanaShortControlOp ? 6 : null;
}

int? _nvaStringLength(List<int> data, int offset) {
  if (data.length < offset + 1) {
    return null;
  }
  final length = data[offset];
  if (data.length < offset + 1 + length) {
    return null;
  }
  return length;
}

_NvaFrame? _parseNvaFrame(Uint8List data) {
  final frameLength = _nvaFrameLength(data);
  if (frameLength != data.length || data.length < 7) {
    return null;
  }
  final op = _readUint16(data, 0);
  final sequence = _readUint32(data, 2);
  if (op == null || sequence == null) {
    return null;
  }
  if (op != _biliNirvanaRequestOp &&
      op != _biliNirvanaEmptyRequestOp &&
      op != _biliNirvanaBodyResponseOp &&
      op != _biliNirvanaResponseOp) {
    return null;
  }
  var offset = 6;
  final attrCount = data[offset];
  offset += 1;
  final attributes = <String, String>{};
  for (var i = 0; i < attrCount; i++) {
    final key = _readNvaString(data, offset);
    if (key == null) {
      return null;
    }
    offset += 1 + key.lengthInBytes;
    final value = _readNvaString(data, offset);
    if (value == null) {
      return null;
    }
    offset += 1 + value.lengthInBytes;
    attributes[key.value] = value.value;
  }
  var body = Uint8List(0);
  if (op != _biliNirvanaEmptyRequestOp && offset < data.length) {
    final bodyLength = _readUint32(data, offset);
    if (bodyLength == null || data.length < offset + 4 + bodyLength) {
      return null;
    }
    offset += 4;
    body = Uint8List.sublistView(data, offset, offset + bodyLength);
  }
  return _NvaFrame(
    op: op,
    sequence: sequence,
    attributes: attributes,
    body: body,
  );
}

class _NvaString {
  const _NvaString(this.value, this.lengthInBytes);

  final String value;
  final int lengthInBytes;
}

_NvaString? _readNvaString(List<int> data, int offset) {
  final length = _nvaStringLength(data, offset);
  if (length == null) {
    return null;
  }
  final start = offset + 1;
  return _NvaString(
    utf8.decode(data.sublist(start, start + length), allowMalformed: true),
    length,
  );
}

int? _readUint16(List<int> data, int offset) {
  if (data.length < offset + 2) {
    return null;
  }
  return ByteData.sublistView(Uint8List.fromList(data), offset, offset + 2)
      .getUint16(0);
}

int? _readUint32(List<int> data, int offset) {
  if (data.length < offset + 4) {
    return null;
  }
  return ByteData.sublistView(Uint8List.fromList(data), offset, offset + 4)
      .getUint32(0);
}

Uint8List _nvaFrame({
  required int op,
  required int sequence,
  required Map<String, String> attributes,
  required Uint8List body,
}) {
  final bytes = BytesBuilder();
  final header = ByteData(7);
  header.setUint16(0, op);
  header.setUint32(2, sequence);
  header.setUint8(6, attributes.length);
  bytes.add(header.buffer.asUint8List());
  for (final entry in attributes.entries) {
    _addNvaString(bytes, entry.key);
    _addNvaString(bytes, entry.value);
  }
  final bodyHeader = ByteData(4)..setUint32(0, body.length);
  bytes.add(bodyHeader.buffer.asUint8List());
  bytes.add(body);
  return bytes.toBytes();
}

Uint8List _nvaEmptyRequestFrame({
  required int sequence,
  required Map<String, String> attributes,
}) {
  final bytes = BytesBuilder();
  final header = ByteData(7);
  header.setUint16(0, _biliNirvanaEmptyRequestOp);
  header.setUint32(2, sequence);
  header.setUint8(6, attributes.length);
  bytes.add(header.buffer.asUint8List());
  for (final entry in attributes.entries) {
    _addNvaString(bytes, entry.key);
    _addNvaString(bytes, entry.value);
  }
  return bytes.toBytes();
}

void _addNvaString(BytesBuilder bytes, String value) {
  final encoded = utf8.encode(value);
  bytes.addByte(encoded.length);
  bytes.add(encoded);
}

String? _nirvanaHeartbeatFrameSummary(Uint8List data) {
  if (data.length != 11) {
    return null;
  }
  final view = ByteData.view(data.buffer, data.offsetInBytes, data.length);
  final op = view.getUint16(0);
  if (op != _biliNirvanaHeartbeatRequestOp &&
      op != _biliNirvanaHeartbeatResponseOp) {
    return null;
  }
  final seq = view.getUint32(2);
  final length = view.getUint32(7);
  final name =
      op == _biliNirvanaHeartbeatRequestOp ? 'heartbeat request' : 'heartbeat';
  return 'native $name seq=$seq op=0x${op.toRadixString(16)} len=$length';
}

String? _nirvanaShortControlFrameSummary(Uint8List data) {
  if (_nirvanaShortControlFrameLength(data) != data.length) {
    return null;
  }
  final sequence = _readUint32(data, 2);
  if (sequence == null) {
    return null;
  }
  return 'native control seq=$sequence op=0xc000';
}

String? _nativeFrameTextSummary(Uint8List data) {
  final fragments = _printableAsciiFragments(data)
      .where((fragment) => fragment.length >= 4)
      .toList();
  if (fragments.isEmpty) {
    return null;
  }
  final important = fragments
      .where(
        (fragment) =>
            fragment.contains('Command') ||
            fragment.contains('PlayUrl') ||
            fragment == 'Play' ||
            fragment == 'Pause' ||
            fragment == 'Seek' ||
            fragment == 'Stop' ||
            fragment.contains('url') ||
            fragment.contains('qn'),
      )
      .toList();
  final selected = important.isEmpty ? fragments.take(4).toList() : important;
  return _compactSummary('native ${selected.join(' | ')}');
}

List<String> _printableAsciiFragments(Uint8List data) {
  final fragments = <String>[];
  final buffer = StringBuffer();
  for (final byte in data) {
    if (byte >= 0x20 && byte <= 0x7e) {
      buffer.writeCharCode(byte);
    } else if (buffer.isNotEmpty) {
      fragments.add(buffer.toString());
      buffer.clear();
    }
  }
  if (buffer.isNotEmpty) {
    fragments.add(buffer.toString());
  }
  return fragments;
}

String _compactSummary(String value) {
  final singleLine = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (singleLine.length <= 180) {
    return singleLine;
  }
  return '${singleLine.substring(0, 177)}...';
}

String _httpRequestHeaderSummary(HttpRequest request) {
  final headers = <String>[];
  for (final name in const [
    HttpHeaders.hostHeader,
    HttpHeaders.connectionHeader,
    HttpHeaders.userAgentHeader,
  ]) {
    final value = request.headers.value(name);
    if (value != null && value.isNotEmpty) {
      headers.add('$name=$value');
    }
  }
  return headers.isEmpty ? '<none>' : headers.join('; ');
}

String _shortHex(Uint8List data) {
  return data
      .take(64)
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join(' ');
}

void _debugLog(String message) {
  if (kDebugMode) {
    debugPrint('CoolCast: $message');
  }
}

Map<String, String> _upnpResponseHeaders() => const {
      'SERVER': _upnpServerHeader,
      'EXT': '',
      'CACHE-CONTROL': 'max-age=1800',
      'X-User-Agent': _upnpServerHeader,
    };

void _applyUpnpResponseHeaders(HttpHeaders headers) {
  for (final entry in _upnpResponseHeaders().entries) {
    headers.set(entry.key, entry.value);
  }
}

String _nirvanaProbeAck({String localAddress = ''}) {
  return jsonEncode({
    'code': 0,
    'status': 'ok',
    'message': 'success',
    'receiver': _biliProjectionModelName,
    'from': 'coolcast',
    'buvid': _biliProjectionAutoPullId,
    'nvaLinkAddress': _biliNvaLinkAddress(localAddress),
    'friendlyName': _biliProjectionFriendlyName,
    'modelName': _biliProjectionModelName,
    'brandName': _biliProjectionBrandName,
    'manufacturer': _biliProjectionManufacturer,
    'ottVersion': _biliProjectionBuild,
    'device': _ottBlinkDeviceMsg(_biliProjectionFriendlyName),
    'support4k': _biliProjectionSupport4k,
    'capability': _biliProjectionCapability,
    'castService': _biliProjectionCastService,
    'needNvaExtra': _biliProjectionNeedNvaExtra,
    'ignoreDirect': _biliProjectionIgnoreDirect,
    'autoPullId': _biliProjectionAutoPullId,
  });
}

String _nirvanaTextAck(Uint8List data, {String localAddress = ''}) {
  final text = utf8.decode(data, allowMalformed: true).trimLeft();
  if (text.startsWith('SETUP ') || text.startsWith('RESTORE ')) {
    final session = RegExp(
      r'^Session:\s*([^\r\n]+)',
      caseSensitive: false,
      multiLine: true,
    ).firstMatch(text)?.group(1)?.trim();
    final nvaVersion = RegExp(
      r'^NvaVersion:\s*([^\r\n]+)',
      caseSensitive: false,
      multiLine: true,
    ).firstMatch(text)?.group(1)?.trim();
    final uuid = RegExp(
      r'^UUID:\s*([^\r\n]+)',
      caseSensitive: false,
      multiLine: true,
    ).firstMatch(text)?.group(1)?.trim();
    final headers = <String>[
      'NVA/1.0 200 OK',
      if (session != null && session.isNotEmpty) 'Session: $session',
      'NvaVersion: ${nvaVersion?.isNotEmpty == true ? nvaVersion : '1'}',
      if (uuid != null && uuid.isNotEmpty) 'UUID: $uuid',
      'Date: ${HttpDate.format(DateTime.now().toUtc())}',
      'Server: $_upnpServerHeader',
      'Connection: Keep-Alive',
      'Content-Length: 0',
      '',
      '',
    ];
    return headers.join('\r\n');
  }
  return _nirvanaProbeAck(localAddress: localAddress);
}

Uint8List _nirvanaPingFrame(int sequence) {
  final frame = Uint8List(11);
  ByteData.view(frame.buffer).setUint16(0, _biliNirvanaHeartbeatResponseOp);
  ByteData.view(frame.buffer).setUint32(2, sequence);
  frame[6] = 0x00;
  ByteData.view(frame.buffer).setUint32(7, 0);
  return frame;
}

Uint8List _nirvanaShortControlFrame(int sequence) {
  final frame = Uint8List(6);
  ByteData.view(frame.buffer).setUint16(0, _biliNirvanaShortControlOp);
  ByteData.view(frame.buffer).setUint32(2, sequence);
  return frame;
}

List<Uint8List> _nirvanaFrameResponses(Uint8List data) {
  final nvaFrame = _parseNvaFrame(data);
  if (nvaFrame != null && nvaFrame.isRequest) {
    final responseBody = _defaultNirvanaResponseBodyForCommand(
      nvaFrame.attributes['Command'],
    );
    if (responseBody.isEmpty) {
      return [_nirvanaShortControlFrame(nvaFrame.sequence)];
    }
    return [
      _nvaFrame(
        op: _biliNirvanaBodyResponseOp,
        sequence: nvaFrame.sequence,
        attributes: const {},
        body: Uint8List.fromList(utf8.encode(responseBody)),
      ),
    ];
  }
  if (data.length != 11) {
    return const [];
  }
  final view = ByteData.view(data.buffer, data.offsetInBytes, data.length);
  final op = view.getUint16(0);
  if (op != _biliNirvanaHeartbeatRequestOp) {
    return const [];
  }
  final sequence = view.getUint32(2);
  return [_nirvanaPingFrame(sequence)];
}

String _defaultNirvanaResponseBodyForCommand(String? command) {
  switch (command) {
    case 'GetVolume':
      return jsonEncode({'volume': 50});
    case 'GetTvInfo':
      return _biliTvInfoResponseBody(_latestBiliCastStatus);
    case 'GetPlayInfo':
      return _biliPlayInfoResponseBody(
        _latestBiliCastStatus,
        playState: _biliNvaPlayState,
      );
    default:
      return '';
  }
}

String _biliTvInfoResponseBody(_BiliCastStatus? status) {
  final body = <String, Object?>{
    'tvVipInfo': -1,
    'tvMid': null,
  };
  if (status != null) {
    if (status.aid != null) {
      body['aid'] = status.aid;
    }
    if (status.cid != null) {
      body['cid'] = status.cid;
    }
    if (status.quality != null) {
      body['quality'] = status.quality;
    }
    if (status.timelength != null) {
      body['duration'] = status.timelength;
      body['durationMs'] = status.timelength;
      body['timelength'] = status.timelength;
    }
    if (status.acceptQuality.isNotEmpty) {
      body['acceptQuality'] = status.acceptQuality;
      body['accept_quality'] = status.acceptQuality;
    }
  }
  return jsonEncode(body);
}

String _biliPlayInfoResponseBody(
  _BiliCastStatus? status, {
  int? playState,
}) {
  final durationSeconds = ((status?.timelength ?? 0) / 1000).round();
  final currentPlayState =
      status == null ? _biliPlayStateIdle : playState ?? _biliPlayStatePlaying;
  return jsonEncode({
    'playState': currentPlayState,
    'position': 0,
    'duration': durationSeconds,
    'danmakuState': true,
    'playItem': {
      'aid': status?.aid ?? 0,
      'cid': status?.cid ?? 0,
      'epId': 0,
      'seasonId': 0,
      'roomId': 0,
      'biz': 0,
    },
    'listInfo': null,
    'qn': _biliQnDescriptionBody(status),
    'title': '',
    'volume': 50,
    'speedInfo': {
      'supportSpeedList': [0.5, 0.75, 1.0, 1.25, 1.5, 2.0],
      'currSpeed': 1.0,
    },
  });
}

Map<String, Object?>? _biliQnDescriptionBody(_BiliCastStatus? status) {
  if (status?.quality == null && (status?.acceptQuality.isEmpty ?? true)) {
    return null;
  }
  final qualities = status!.acceptQuality.isEmpty
      ? <int>[status.quality!]
      : status.acceptQuality;
  return {
    'supportQnList': [
      for (final quality in qualities)
        {
          'quality': quality,
          'description': _biliQualityDescription(quality),
          'displayDesc': _biliQualityDescription(quality),
          'superscript': '',
          'needLogin': false,
          'needVip': false,
        },
    ],
    'curQn': status.quality ?? qualities.first,
    'userDesireQn': status.quality ?? qualities.first,
  };
}

String _biliQualityDescription(int quality) {
  switch (quality) {
    case 126:
      return '杜比视界';
    case 120:
      return '4K 超清';
    case 116:
      return '1080P 60帧';
    case 112:
      return '1080P 高码率';
    case 80:
      return '1080P 高清';
    case 64:
      return '720P 高清';
    case 32:
      return '480P 清晰';
    case 16:
      return '360P 流畅';
    default:
      return 'QN $quality';
  }
}

Uint8List _nvaServerEventFrame({
  required String command,
  required String body,
}) =>
    _nvaFrame(
      op: _biliNirvanaRequestOp,
      sequence: ++_biliNvaServerSequence,
      attributes: {'Command': command},
      body: Uint8List.fromList(utf8.encode(body)),
    );

bool _isUpnpEventSubscription(HttpRequest request) {
  final method = request.method.toUpperCase();
  if (method != 'SUBSCRIBE' && method != 'UNSUBSCRIBE') {
    return false;
  }
  return _upnpEventPaths.contains(request.uri.path);
}

const Set<String> _upnpEventPaths = {
  '/AVTransport/event',
  '/RenderingControl/event',
  '/ConnectionManager/event',
  '/NirvanaControl/event',
};

String _biliFriendlyName(String receiverName) {
  final name = receiverName.trim();
  return name.isEmpty ? _biliProjectionFriendlyName : name;
}

String _receiverNameForDevice(String? deviceName) {
  final normalized = deviceName?.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (normalized == null ||
      normalized.isEmpty ||
      normalized.toLowerCase() == 'unknown') {
    return _defaultReceiverName;
  }
  if (normalized.toLowerCase().startsWith('coolcast')) {
    return normalized;
  }
  return '$_defaultReceiverName - $normalized';
}

String _soapResponse(
  String action, {
  CoolCastUpnpService service = CoolCastUpnpService.avTransport,
  String body = '',
}) {
  return '''
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
  s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:$action xmlns:u="${service.urn}">
      $body
    </u:$action>
  </s:Body>
</s:Envelope>
''';
}

String _transportInfoResponse(PlaybackState state) {
  final transportState = switch (state) {
    PlaybackState.playing => 'PLAYING',
    PlaybackState.paused => 'PAUSED_PLAYBACK',
    PlaybackState.ready => 'STOPPED',
    PlaybackState.idle => 'STOPPED',
    PlaybackState.failed => 'NO_MEDIA_PRESENT',
  };
  return '''
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
  s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:GetTransportInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <CurrentTransportState>$transportState</CurrentTransportState>
      <CurrentTransportStatus>OK</CurrentTransportStatus>
      <CurrentSpeed>1</CurrentSpeed>
    </u:GetTransportInfoResponse>
  </s:Body>
</s:Envelope>
''';
}

String _positionInfoResponse(VideoPlayerController? player) {
  final value = player?.value;
  final position = value?.position ?? Duration.zero;
  final duration = value?.duration ?? Duration.zero;
  return '''
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
  s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:GetPositionInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <Track>1</Track>
      <TrackDuration>${_dlnaDuration(duration)}</TrackDuration>
      <TrackMetaData></TrackMetaData>
      <TrackURI></TrackURI>
      <RelTime>${_dlnaDuration(position)}</RelTime>
      <AbsTime>${_dlnaDuration(position)}</AbsTime>
      <RelCount>2147483647</RelCount>
      <AbsCount>2147483647</AbsCount>
    </u:GetPositionInfoResponse>
  </s:Body>
</s:Envelope>
''';
}

String _mediaInfoResponse(VideoPlayerController? player, String currentUrl) {
  final duration = player?.value.duration ?? Duration.zero;
  return _soapResponse(
    'GetMediaInfoResponse',
    body: '''
<NrTracks>${currentUrl.isEmpty ? 0 : 1}</NrTracks>
<MediaDuration>${_dlnaDuration(duration)}</MediaDuration>
<CurrentURI>${xmlEscape(currentUrl)}</CurrentURI>
<CurrentURIMetaData></CurrentURIMetaData>
<NextURI></NextURI>
<NextURIMetaData></NextURIMetaData>
<PlayMedium>NETWORK</PlayMedium>
<RecordMedium>NOT_IMPLEMENTED</RecordMedium>
<WriteStatus>NOT_IMPLEMENTED</WriteStatus>''',
  );
}

String _transportSettingsResponse() {
  return _soapResponse(
    'GetTransportSettingsResponse',
    body: '''
<PlayMode>NORMAL</PlayMode>
<RecQualityMode>NOT_IMPLEMENTED</RecQualityMode>''',
  );
}

String _deviceCapabilitiesResponse() {
  return _soapResponse(
    'GetDeviceCapabilitiesResponse',
    body: '''
<PlayMedia>NETWORK</PlayMedia>
<RecMedia>NOT_IMPLEMENTED</RecMedia>
<RecQualityModes>NOT_IMPLEMENTED</RecQualityModes>''',
  );
}

String _currentTransportActionsResponse(PlaybackState state) {
  final actions = switch (state) {
    PlaybackState.playing => 'Pause,Stop,Seek',
    PlaybackState.paused => 'Play,Stop,Seek',
    PlaybackState.ready => 'Play,Stop',
    PlaybackState.idle => 'Play',
    PlaybackState.failed => 'Play',
  };
  return _soapResponse(
    'GetCurrentTransportActionsResponse',
    body: '<Actions>$actions</Actions>',
  );
}

String _protocolInfoResponse() {
  const sink = [
    'http-get:*:video/mp4:DLNA.ORG_OP=01',
    'http-get:*:video/mp4:*',
    'http-get:*:video/x-m4s:*',
    'http-get:*:video/mpeg:DLNA.ORG_OP=01',
    'http-get:*:video/mpeg:*',
    'http-get:*:video/flv:*',
    'http-get:*:video/x-flv:*',
    'http-get:*:video/vnd.dlna.mpeg-tts:*',
    'http-get:*:video/MP2T:*',
    'http-get:*:video/x-matroska:*',
    'http-get:*:video/webm:*',
    'http-get:*:video/quicktime:*',
    'http-get:*:application/vnd.apple.mpegurl:*',
    'http-get:*:application/x-mpegURL:*',
    'http-get:*:application/dash+xml:*',
    'http-get:*:application/octet-stream:*',
    'http-get:*:audio/mpeg:*',
    'http-get:*:audio/mp4:*',
    'http-get:*:image/jpeg:*',
    'http-get:*:*:*',
  ];
  return _soapResponse(
    'GetProtocolInfoResponse',
    service: CoolCastUpnpService.connectionManager,
    body: '<Source></Source><Sink>${sink.join(',')}</Sink>',
  );
}

String _dlnaDuration(Duration duration) {
  final hours = duration.inHours.toString().padLeft(2, '0');
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$hours:$minutes:$seconds';
}

Duration? _parseDlnaDuration(String value) {
  final parts = value.trim().split(':');
  if (parts.length != 3) {
    return null;
  }
  final hours = int.tryParse(parts[0]);
  final minutes = int.tryParse(parts[1]);
  final seconds = double.tryParse(parts[2]);
  if (hours == null || minutes == null || seconds == null) {
    return null;
  }
  return Duration(
    hours: hours,
    minutes: minutes,
    milliseconds: (seconds * 1000).round(),
  );
}

String _formatDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:$minutes:$seconds';
  }
  return '$minutes:$seconds';
}

String _formatDebugTime(DateTime? timestamp) {
  if (timestamp == null) {
    return '--:--:--';
  }
  final hour = timestamp.hour.toString().padLeft(2, '0');
  final minute = timestamp.minute.toString().padLeft(2, '0');
  final second = timestamp.second.toString().padLeft(2, '0');
  return '$hour:$minute:$second';
}

String _sourceWithRemoteAddress(String label, HttpRequest request) {
  final address = request.connectionInfo?.remoteAddress.address;
  if (address == null || address.isEmpty) {
    return label;
  }
  return '$label · $address';
}

CoolCastMediaInfo _mediaInfoFromMetadata(String metadata) {
  if (metadata.trim().isEmpty) {
    return const CoolCastMediaInfo();
  }
  final title = _extractXmlValue(metadata, 'title');
  final protocolInfo = RegExp(
    r'''protocolInfo\s*=\s*["']([^"']+)["']''',
    caseSensitive: false,
  ).firstMatch(metadata)?.group(1);
  var mimeType = '';
  if (protocolInfo != null) {
    final parts = protocolInfo.split(':');
    if (parts.length >= 3 && parts[2].contains('/')) {
      mimeType = parts[2].trim();
    }
  }
  return CoolCastMediaInfo(title: title, mimeType: mimeType);
}

String _extractXmlValue(String body, String localName) {
  final match = RegExp(
    '<(?:[^:>]+:)?$localName(?:\\s[^>]*)?>(.*?)</(?:[^:>]+:)?$localName>',
    dotAll: true,
    caseSensitive: false,
  ).firstMatch(body);
  if (match == null) {
    return '';
  }
  return htmlUnescape(match.group(1) ?? '').trim();
}

String _resolutionLabel(Size size) {
  final width = size.width.round();
  final height = size.height.round();
  if (width >= 3800 || height >= 2100) {
    return '4K';
  }
  if (height >= 1400) {
    return '1440p';
  }
  if (height >= 1000) {
    return '1080p';
  }
  if (height >= 700) {
    return '720p';
  }
  return '${width}x$height';
}

List<String> _mediaChipsFor(
  String currentUrl,
  String mimeType,
  PlaybackState state,
  Size? videoSize, {
  _BiliCastStatus? biliStatus,
}) {
  final chips = <String>[];
  final biliQuality = biliStatus?.quality;
  if (biliQuality != null) {
    chips.add('B站 ${_biliQualityDescription(biliQuality)}');
  }
  if (videoSize != null && videoSize.width > 0 && videoSize.height > 0) {
    chips.add(_resolutionLabel(videoSize));
  }
  final quality = _qualityLabelFromUrl(currentUrl);
  if (quality.isNotEmpty && !chips.contains(quality)) {
    chips.add(quality);
  }
  final mediaType = _mediaTypeLabel(mimeType, currentUrl);
  if (mediaType.isNotEmpty) {
    chips.add(mediaType);
  }
  if (state == PlaybackState.paused) {
    chips.add('已暂停');
  } else if (state == PlaybackState.playing) {
    chips.add('播放中');
  }
  return chips.isEmpty ? const ['媒体已连接'] : chips.take(3).toList();
}

String _videoSizeSummary(Size size) {
  if (size.width <= 0 || size.height <= 0) {
    return '-';
  }
  return '${size.width.round()}x${size.height.round()}';
}

String _qualityLabelFromUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) {
    return '';
  }
  for (final key in const ['qn', 'quality', 'resolution']) {
    final value = uri.queryParameters[key]?.trim();
    if (value != null && value.isNotEmpty) {
      return '${key.toUpperCase()} $value';
    }
  }
  return '';
}

String _mediaTypeLabel(String mimeType, String url) {
  if (mimeType.isNotEmpty) {
    final subtype = mimeType.split('/').last.toUpperCase();
    if (subtype == 'VND.APPLE.MPEGURL') {
      return 'HLS';
    }
    if (subtype == 'DASH+XML') {
      return 'DASH';
    }
    if (subtype == 'VND.DLNA.MPEG-TTS') {
      return 'MPEG-TS';
    }
    return subtype == 'X-MATROSKA' ? 'MKV' : subtype;
  }
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
  final extension = path.split('.').lastOrNull;
  if (extension == null || extension == path || extension.isEmpty) {
    return '';
  }
  return extension.toUpperCase();
}

String _shortError(Object error) {
  final text = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.length <= 96) {
    return text;
  }
  return '${text.substring(0, 96)}...';
}

String _shortUrl(String value) {
  final text = value.trim();
  if (text.length <= 72) {
    return text;
  }
  return '${text.substring(0, 42)}...${text.substring(text.length - 18)}';
}

String _shortPath(Uri uri) {
  final text = uri.toString();
  if (text.length <= 80) {
    return text;
  }
  return '${text.substring(0, 56)}...${text.substring(text.length - 18)}';
}

String _soapActionSummary(String body) {
  final tags = RegExp(
    r'<(?:[A-Za-z0-9_]+:)?([A-Za-z0-9_]+)\b',
    caseSensitive: false,
  ).allMatches(body);
  for (final tag in tags) {
    final name = tag.group(1) ?? '';
    if (name != 'Envelope' && name != 'Body') {
      return name;
    }
  }
  return body.trim().isEmpty ? '空请求' : _shortUrl(body.replaceAll('\n', ' '));
}

String _displayFileName(String url) {
  final uri = Uri.tryParse(url);
  final segment = uri?.pathSegments.where((item) => item.isNotEmpty).lastOrNull;
  if (segment == null || segment.isEmpty) {
    return '远端媒体';
  }
  return Uri.decodeComponent(segment);
}

String _avTransportScpd() {
  return '''
<?xml version="1.0" encoding="utf-8"?>
<scpd xmlns="urn:schemas-upnp-org:service-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <actionList>
    <action>
      <name>SetAVTransportURI</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        <argument><name>CurrentURI</name><direction>in</direction><relatedStateVariable>AVTransportURI</relatedStateVariable></argument>
        <argument><name>CurrentURIMetaData</name><direction>in</direction><relatedStateVariable>AVTransportURIMetaData</relatedStateVariable></argument>
        <argument><name>SourceId</name><direction>in</direction><relatedStateVariable>AVTransportSourceId</relatedStateVariable></argument>
        <argument><name>ExtendData</name><direction>in</direction><relatedStateVariable>AVTransportExtendData</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action>
      <name>SetNextAVTransportURI</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        <argument><name>NextURI</name><direction>in</direction><relatedStateVariable>NextAVTransportURI</relatedStateVariable></argument>
        <argument><name>NextURIMetaData</name><direction>in</direction><relatedStateVariable>NextAVTransportURIMetaData</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action>
      <name>Play</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        <argument><name>Speed</name><direction>in</direction><relatedStateVariable>TransportPlaySpeed</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action>
      <name>Pause</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action>
      <name>Stop</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action>
      <name>Seek</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        <argument><name>Unit</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_SeekMode</relatedStateVariable></argument>
        <argument><name>Target</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_SeekTarget</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action>
      <name>GetCurrentTransportActions</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        <argument><name>Actions</name><direction>out</direction><relatedStateVariable>CurrentTransportActions</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action>
      <name>GetDeviceCapabilities</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        <argument><name>PlayMedia</name><direction>out</direction><relatedStateVariable>PossiblePlaybackStorageMedia</relatedStateVariable></argument>
        <argument><name>RecMedia</name><direction>out</direction><relatedStateVariable>PossibleRecordStorageMedia</relatedStateVariable></argument>
        <argument><name>RecQualityModes</name><direction>out</direction><relatedStateVariable>PossibleRecordQualityModes</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action>
      <name>GetTransportSettings</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        <argument><name>PlayMode</name><direction>out</direction><relatedStateVariable>CurrentPlayMode</relatedStateVariable></argument>
        <argument><name>RecQualityMode</name><direction>out</direction><relatedStateVariable>CurrentRecordQualityMode</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action>
      <name>Next</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action>
      <name>Previous</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action>
      <name>SetPlayMode</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        <argument><name>NewPlayMode</name><direction>in</direction><relatedStateVariable>CurrentPlayMode</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action>
      <name>GetTransportInfo</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        <argument><name>CurrentTransportState</name><direction>out</direction><relatedStateVariable>TransportState</relatedStateVariable></argument>
        <argument><name>CurrentTransportStatus</name><direction>out</direction><relatedStateVariable>TransportStatus</relatedStateVariable></argument>
        <argument><name>CurrentSpeed</name><direction>out</direction><relatedStateVariable>TransportPlaySpeed</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action>
      <name>GetPositionInfo</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        <argument><name>Track</name><direction>out</direction><relatedStateVariable>CurrentTrack</relatedStateVariable></argument>
        <argument><name>TrackDuration</name><direction>out</direction><relatedStateVariable>CurrentTrackDuration</relatedStateVariable></argument>
        <argument><name>TrackMetaData</name><direction>out</direction><relatedStateVariable>CurrentTrackMetaData</relatedStateVariable></argument>
        <argument><name>TrackURI</name><direction>out</direction><relatedStateVariable>CurrentTrackURI</relatedStateVariable></argument>
        <argument><name>RelTime</name><direction>out</direction><relatedStateVariable>RelativeTimePosition</relatedStateVariable></argument>
        <argument><name>AbsTime</name><direction>out</direction><relatedStateVariable>AbsoluteTimePosition</relatedStateVariable></argument>
        <argument><name>RelCount</name><direction>out</direction><relatedStateVariable>RelativeCounterPosition</relatedStateVariable></argument>
        <argument><name>AbsCount</name><direction>out</direction><relatedStateVariable>AbsoluteCounterPosition</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action>
      <name>GetMediaInfo</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        <argument><name>NrTracks</name><direction>out</direction><relatedStateVariable>NumberOfTracks</relatedStateVariable></argument>
        <argument><name>MediaDuration</name><direction>out</direction><relatedStateVariable>CurrentMediaDuration</relatedStateVariable></argument>
        <argument><name>CurrentURI</name><direction>out</direction><relatedStateVariable>AVTransportURI</relatedStateVariable></argument>
        <argument><name>CurrentURIMetaData</name><direction>out</direction><relatedStateVariable>AVTransportURIMetaData</relatedStateVariable></argument>
        <argument><name>NextURI</name><direction>out</direction><relatedStateVariable>NextAVTransportURI</relatedStateVariable></argument>
        <argument><name>NextURIMetaData</name><direction>out</direction><relatedStateVariable>NextAVTransportURIMetaData</relatedStateVariable></argument>
        <argument><name>PlayMedium</name><direction>out</direction><relatedStateVariable>PlaybackStorageMedium</relatedStateVariable></argument>
        <argument><name>RecordMedium</name><direction>out</direction><relatedStateVariable>RecordStorageMedium</relatedStateVariable></argument>
        <argument><name>WriteStatus</name><direction>out</direction><relatedStateVariable>RecordMediumWriteStatus</relatedStateVariable></argument>
      </argumentList>
    </action>
  </actionList>
  <serviceStateTable>
    <stateVariable sendEvents="no"><name>TransportState</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>TransportStatus</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>TransportPlaySpeed</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>AVTransportURI</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>AVTransportURIMetaData</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>NextAVTransportURI</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>NextAVTransportURIMetaData</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>NumberOfTracks</name><dataType>ui4</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>CurrentMediaDuration</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>CurrentTrack</name><dataType>ui4</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>CurrentTrackDuration</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>CurrentTrackMetaData</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>CurrentTrackURI</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>RelativeTimePosition</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>AbsoluteTimePosition</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>RelativeCounterPosition</name><dataType>i4</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>AbsoluteCounterPosition</name><dataType>i4</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>A_ARG_TYPE_InstanceID</name><dataType>ui4</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>A_ARG_TYPE_String</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>A_ARG_TYPE_SeekMode</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>A_ARG_TYPE_SeekTarget</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>CurrentPlayMode</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>CurrentRecordQualityMode</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>CurrentTransportActions</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>PlaybackStorageMedium</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>RecordStorageMedium</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>PossiblePlaybackStorageMedia</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>PossibleRecordStorageMedia</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>PossibleRecordQualityModes</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>RecordMediumWriteStatus</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>AVTransportSourceId</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>AVTransportExtendData</name><dataType>string</dataType></stateVariable>
  </serviceStateTable>
</scpd>
''';
}

String _renderingControlScpd() {
  return '''
<?xml version="1.0" encoding="utf-8"?>
<scpd xmlns="urn:schemas-upnp-org:service-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <actionList>
    <action><name>GetVolume</name></action>
    <action><name>SetVolume</name></action>
    <action><name>GetMute</name></action>
    <action><name>SetMute</name></action>
  </actionList>
  <serviceStateTable>
    <stateVariable sendEvents="no"><name>Volume</name><dataType>ui2</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>Mute</name><dataType>boolean</dataType></stateVariable>
  </serviceStateTable>
</scpd>
''';
}

String _connectionManagerScpd() {
  return '''
<?xml version="1.0" encoding="utf-8"?>
<scpd xmlns="urn:schemas-upnp-org:service-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <actionList>
    <action>
      <name>GetProtocolInfo</name>
      <argumentList>
        <argument><name>Source</name><direction>out</direction><relatedStateVariable>SourceProtocolInfo</relatedStateVariable></argument>
        <argument><name>Sink</name><direction>out</direction><relatedStateVariable>SinkProtocolInfo</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action>
      <name>GetCurrentConnectionIDs</name>
      <argumentList>
        <argument><name>ConnectionIDs</name><direction>out</direction><relatedStateVariable>CurrentConnectionIDs</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action>
      <name>GetCurrentConnectionInfo</name>
      <argumentList>
        <argument><name>ConnectionID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_ConnectionID</relatedStateVariable></argument>
        <argument><name>RcsID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_RcsID</relatedStateVariable></argument>
        <argument><name>AVTransportID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_AVTransportID</relatedStateVariable></argument>
        <argument><name>ProtocolInfo</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ProtocolInfo</relatedStateVariable></argument>
        <argument><name>PeerConnectionManager</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ConnectionManager</relatedStateVariable></argument>
        <argument><name>PeerConnectionID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ConnectionID</relatedStateVariable></argument>
        <argument><name>Direction</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_Direction</relatedStateVariable></argument>
        <argument><name>Status</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ConnectionStatus</relatedStateVariable></argument>
      </argumentList>
    </action>
  </actionList>
  <serviceStateTable>
    <stateVariable sendEvents="no"><name>SourceProtocolInfo</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>SinkProtocolInfo</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>CurrentConnectionIDs</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>A_ARG_TYPE_ConnectionStatus</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>A_ARG_TYPE_ConnectionManager</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>A_ARG_TYPE_Direction</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>A_ARG_TYPE_ProtocolInfo</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>A_ARG_TYPE_ConnectionID</name><dataType>i4</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>A_ARG_TYPE_AVTransportID</name><dataType>i4</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>A_ARG_TYPE_RcsID</name><dataType>i4</dataType></stateVariable>
  </serviceStateTable>
</scpd>
''';
}

String _nirvanaControlScpd() {
  return '''
<?xml version="1.0" encoding="utf-8"?>
<scpd xmlns="urn:schemas-upnp-org:service-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <actionList>
    <action>
      <name>GetNvaLinkAddress</name>
      <argumentList>
        <argument><name>NvaLinkAddress</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_NvaLinkAddress</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action>
      <name>GetAppInfo</name>
      <argumentList>
        <argument><name>PackageName</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_UnlimitedString</relatedStateVariable></argument>
        <argument><name>AppKey</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_UnlimitedString</relatedStateVariable></argument>
        <argument><name>Signature</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_UnlimitedString</relatedStateVariable></argument>
        <argument><name>CurrentSignedIn</name><direction>out</direction><relatedStateVariable>SignedIn</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action>
      <name>LoginWithCode</name>
      <argumentList>
        <argument><name>Code</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_UnlimitedString</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action>
      <name>PrepareForMirrorProjection</name>
      <argumentList>
        <argument><name>ScreenWidth</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ScreenResolution</relatedStateVariable></argument>
        <argument><name>ScreenHeight</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ScreenResolution</relatedStateVariable></argument>
        <argument><name>PushUrl</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_UnlimitedString</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action>
      <name>SetDanmakuSwitch</name>
      <argumentList>
        <argument><name>DesiredSwitch</name><direction>in</direction><relatedStateVariable>DanmakuSwitch</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action>
      <name>AppendDanmaku</name>
      <argumentList>
        <argument><name>Content</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_UnlimitedString</relatedStateVariable></argument>
        <argument><name>Size</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_UnlimitedInt</relatedStateVariable></argument>
        <argument><name>Type</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_UnlimitedInt</relatedStateVariable></argument>
        <argument><name>Color</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_UnlimitedInt</relatedStateVariable></argument>
        <argument><name>DanmakuId</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_UnlimitedString</relatedStateVariable></argument>
        <argument><name>Action</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_UnlimitedString</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action>
      <name>GetPlayInfo</name>
      <argumentList>
        <argument><name>Params</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_UnlimitedString</relatedStateVariable></argument>
        <argument><name>Content</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_UnlimitedString</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action>
      <name>GetAccountInfo</name>
      <argumentList>
        <argument><name>VipInfo</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_UnlimitedInt</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action>
      <name>SwitchQuality</name>
      <argumentList>
        <argument><name>Qn</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_UnlimitedInt</relatedStateVariable></argument>
      </argumentList>
    </action>
  </actionList>
  <serviceStateTable>
    <stateVariable sendEvents="no"><name>A_ARG_TYPE_NvaLinkAddress</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>A_ARG_TYPE_UnlimitedString</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>A_ARG_TYPE_UnlimitedInt</name><dataType>i4</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>A_ARG_TYPE_ScreenResolution</name><dataType>ui4</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>SignedIn</name><dataType>boolean</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>DanmakuSwitch</name><dataType>boolean</dataType></stateVariable>
  </serviceStateTable>
</scpd>
''';
}

bool _isValidCastUrl(String value) {
  final parsed = Uri.tryParse(value);
  return parsed != null &&
      parsed.hasScheme &&
      parsed.host.isNotEmpty &&
      (parsed.scheme == 'http' || parsed.scheme == 'https');
}

String _extractSoapValue(String body, String tagName) {
  final match = RegExp(
    '<(?:[^:>]+:)?$tagName>(.*?)</(?:[^:>]+:)?$tagName>',
    dotAll: true,
    caseSensitive: false,
  ).firstMatch(body);
  if (match == null) {
    return '';
  }
  return htmlUnescape(match.group(1) ?? '').trim();
}

String htmlUnescape(String value) {
  return value
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'");
}

String htmlEscape(String value) {
  return value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');
}

String xmlEscape(String value) {
  return value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

const List<String> _ssdpTargets = [
  'upnp:rootdevice',
  'urn:schemas-upnp-org:device:MediaRenderer:1',
  'urn:schemas-upnp-org:service:AVTransport:1',
  'urn:schemas-upnp-org:service:RenderingControl:1',
  'urn:schemas-upnp-org:service:ConnectionManager:1',
  _biliNirvanaSsdpService,
  _biliNirvanaControlService,
];
