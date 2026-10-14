import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/cast_models.dart';
import '../platform/player_bridge.dart';
import '../protocols/bilibili_cast.dart';
import '../protocols/dlna_upnp.dart';
import '../qr_code.dart';
import '../services/http_cast_install.dart';
import '../ui/playing_page.dart';

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
  final List<Timer> _startupNotifyTimers = [];
  Timer? _wifiNameRefreshTimer;
  int _wifiNameRefreshAttempts = 0;
  Timer? _controlsTimer;
  Timer? _mediaInfoTimer;
  Timer? _biliProgressTimer;
  Timer? _pendingDlnaStopTimer;
  CoolCastPlayer? _player;
  PlaybackState _state = PlaybackState.idle;
  String _currentUrl = '';
  String _loadingUrl = '';
  String _currentImageUrl = '';
  Uint8List? _currentImageBytes;
  int _imageLoadRequestId = 0;
  String _pendingDlnaUrl = '';
  String _pendingDlnaSource = '';
  CoolCastMediaInfo _pendingDlnaMediaInfo = const CoolCastMediaInfo();
  DateTime? _lastDlnaSetUriAt;
  String _castSource = '等待投屏设备';
  String _currentMediaTitle = '';
  String _currentMimeType = '';
  String _currentMediaResolution = '';
  int? _currentMediaBitrate;
  String _lastMessage = '正在准备接收端';
  String _localIp = 'TV-IP';
  String _wifiName = '当前局域网';
  String _receiverName = defaultReceiverName;
  bool _showPlaybackControls = false;
  bool _renameDialogVisible = false;
  bool _installDialogVisible = false;
  String _installStatusMessage = '等待手机扫码上传 APK 安装包';
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
    _wifiNameRefreshTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_refreshWifiNameAfterPermissionPrompt()),
    );
  }

  Future<void> _loadReceiverName() async {
    final preferences = await SharedPreferences.getInstance();
    final savedName = preferences.getString(receiverNameKey)?.trim();
    final nextName = savedName == null || savedName.isEmpty
        ? await _defaultReceiverNameForDevice()
        : savedName;
    final nextWifiName = await _currentWifiName();
    if (!mounted) {
      return;
    }
    setState(() {
      _receiverName = nextName;
      _wifiName = nextWifiName;
      _renameController.text = _receiverName;
    });
  }

  Future<String> _defaultReceiverNameForDevice() async {
    if (kIsWeb) {
      return defaultReceiverName;
    }
    try {
      final deviceName =
          await deviceInfoChannel.invokeMethod<String>('deviceName');
      return receiverNameForDevice(deviceName);
    } on Object {
      return defaultReceiverName;
    }
  }

  Future<String> _currentWifiName() async {
    if (kIsWeb) {
      return '当前局域网';
    }
    try {
      final wifiName =
          await deviceInfoChannel.invokeMethod<String>('wifiName');
      final normalized = wifiName?.trim();
      return normalized == null || normalized.isEmpty ? '当前局域网' : normalized;
    } on Object {
      return '当前局域网';
    }
  }

  Future<void> _refreshWifiNameAfterPermissionPrompt() async {
    _wifiNameRefreshAttempts += 1;
    final nextWifiName = await _currentWifiName();
    if (!mounted) {
      _wifiNameRefreshTimer?.cancel();
      return;
    }
    if (nextWifiName != _wifiName) {
      setState(() {
        _wifiName = nextWifiName;
      });
    }
    if (nextWifiName != '当前局域网' || _wifiNameRefreshAttempts >= 8) {
      _wifiNameRefreshTimer?.cancel();
      _wifiNameRefreshTimer = null;
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
    _wifiNameRefreshTimer?.cancel();
    for (final timer in _startupNotifyTimers) {
      timer.cancel();
    }
    _startupNotifyTimers.clear();
    _ssdpSocket?.close();
    _ottBlinkSocket?.close();
    _controlsTimer?.cancel();
    _mediaInfoTimer?.cancel();
    _biliProgressTimer?.cancel();
    _pendingDlnaStopTimer?.cancel();
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
      debugLog(
        '$requestLabel headers=${httpRequestHeaderSummary(request)}',
      );
      applyUpnpResponseHeaders(request.response.headers);
      final normalizedPath = normalizeHttpUriPath(request.uri);
      if (normalizedPath == '/description.xml' ||
          normalizedPath == biliDescriptionPath) {
        await _sendTextResponse(
          request.response,
          deviceDescription(_localIp, _receiverName),
          contentType: ContentType('text', 'xml', charset: 'utf-8'),
          debugLabel: requestLabel,
          stopwatch: stopwatch,
        );
        return;
      }

      if (isDlnaRendererExtraPath(normalizedPath)) {
        await _sendTextResponse(
          request.response,
          dlnaRendererExtraXml(_receiverName),
          contentType: ContentType('text', 'xml', charset: 'utf-8'),
          debugLabel: requestLabel,
          stopwatch: stopwatch,
        );
        return;
      }

      if (normalizedPath == '/AVTransport/scpd.xml') {
        await _sendTextResponse(
          request.response,
          avTransportScpd(),
          contentType: ContentType('text', 'xml', charset: 'utf-8'),
          debugLabel: requestLabel,
          stopwatch: stopwatch,
        );
        return;
      }

      if (normalizedPath == '/RenderingControl/scpd.xml') {
        await _sendTextResponse(
          request.response,
          renderingControlScpd(),
          contentType: ContentType('text', 'xml', charset: 'utf-8'),
          debugLabel: requestLabel,
          stopwatch: stopwatch,
        );
        return;
      }

      if (normalizedPath == '/ConnectionManager/scpd.xml') {
        await _sendTextResponse(
          request.response,
          connectionManagerScpd(),
          contentType: ContentType('text', 'xml', charset: 'utf-8'),
          debugLabel: requestLabel,
          stopwatch: stopwatch,
        );
        return;
      }

      if (normalizedPath == '/NirvanaControl/scpd.xml') {
        await _sendTextResponse(
          request.response,
          nirvanaControlScpd(),
          contentType: ContentType('text', 'xml', charset: 'utf-8'),
          debugLabel: requestLabel,
          stopwatch: stopwatch,
        );
        return;
      }

      if (isUpnpEventSubscription(request)) {
        await _handleUpnpEventSubscription(
          request,
          debugLabel: requestLabel,
          stopwatch: stopwatch,
        );
        return;
      }

      if (normalizedPath == '/AVTransport/control') {
        await _handleAvTransport(request);
        return;
      }

      if (normalizedPath == '/RenderingControl/control') {
        await _handleRenderingControl(request);
        return;
      }

      if (normalizedPath == '/ConnectionManager/control') {
        await _handleConnectionManager(request);
        return;
      }

      if (normalizedPath == '/NirvanaControl/control') {
        await _handleNirvanaHttpControl(request);
        return;
      }

      if (normalizedPath == '/cast') {
        final url = request.uri.queryParameters['url']?.trim() ?? '';
        final accepted = isValidCastUrl(url);
        unawaited(
          _acceptUrl(
            url,
            source: sourceWithRemoteAddress('HTTP 投送', request),
          ),
        );
        await _sendTextResponse(
          request.response,
          htmlResponse(url, isAccepted: accepted),
          contentType: ContentType.html,
        );
        return;
      }

      if (normalizedPath == '/install') {
        await _sendTextResponse(
          request.response,
          installHtmlForm(
            receiverName: _receiverName,
            ipAddress: _localIp,
            statusMessage: _installStatusMessage,
          ),
          contentType: ContentType.html,
          debugLabel: requestLabel,
          stopwatch: stopwatch,
        );
        return;
      }

      if (normalizedPath == '/install/upload') {
        await _handleApkUploadRequest(
          request,
          debugLabel: requestLabel,
          stopwatch: stopwatch,
        );
        return;
      }

      if (normalizedPath == '/') {
        await _sendTextResponse(
          request.response,
          htmlForm(
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
        '未知请求：${request.method} ${shortText(normalizedPath)}',
      );
      await _sendTextResponse(
        request.response,
        'Not found',
        statusCode: HttpStatus.notFound,
        contentType: ContentType.text,
      );
    } on Object catch (error) {
      debugLog(
        '$requestLabel failed after ${stopwatch.elapsedMilliseconds}ms: '
        '${shortError(error)}',
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
        'uuid:$biliProjectionAutoPullId-${request.uri.path.hashCode.abs()}';
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
    debugLog(
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
      debugLog(
          '$debugLabel done status=$statusCode bytes=${bytes.length}$elapsed');
    }
  }

  Future<void> _startSsdp(String address) async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      1900,
      reuseAddress: true,
    );
    _ssdpSocket = socket;
    socket.multicastHops = 8;
    socket.broadcastEnabled = true;
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
      final responses = ssdpSearchResponses(address, message);
      debugLog(
        'SSDP M-SEARCH from ${datagram.address.address}:${datagram.port} '
        'st=${ssdpSearchTarget(message) ?? '<none>'} '
        'responses=${responses.length}',
      );
      if (responses.isEmpty) {
        return;
      }
      // Add random delay (0-100ms) to avoid response collision
      final delayMs = (DateTime.now().microsecondsSinceEpoch % 100);
      Future<void>.delayed(Duration(milliseconds: delayMs), () {
        _sendSsdpSearchResponse(
            socket, datagram.address, datagram.port, responses);
      });
    });
    _notifyTimer = Timer.periodic(
      const Duration(seconds: ssdpNotifyIntervalSeconds),
      (_) => _sendSsdpNotify(socket, address),
    );
    _sendSsdpNotify(socket, address);
    _scheduleStartupSsdpNotifyBurst(socket, address);
  }

  void _scheduleStartupSsdpNotifyBurst(
    RawDatagramSocket socket,
    String address,
  ) {
    for (final timer in _startupNotifyTimers) {
      timer.cancel();
    }
    _startupNotifyTimers
      ..clear()
      ..addAll([
        for (final seconds in ssdpStartupNotifyBurstSeconds)
          Timer(Duration(seconds: seconds), () {
            if (_ssdpSocket == socket) {
              _sendSsdpNotify(socket, address);
            }
          }),
      ]);
  }

  Future<void> _startOttBlink() async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      ottBlinkPort,
      reuseAddress: true,
    );
    _ottBlinkSocket = socket;
    socket.broadcastEnabled = true;
    socket.listen((event) {
      if (event != RawSocketEvent.read) {
        return;
      }
      final datagram = socket.receive();
      if (datagram == null || !isOttBlinkSearch(datagram.data)) {
        return;
      }
      _recordOttBlinkSearch(datagram.address.address);
      socket.send(
        ottBlinkResponse(_receiverName),
        datagram.address,
        datagram.port,
      );
      _recordOttBlinkResponse();
    });
  }

  Future<void> _startNirvanaControlProbe() async {
    final server = await ServerSocket.bind(
      InternetAddress.anyIPv4,
      nirvanaControlPort,
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
      debugLog('$label connected from $requester local=$localAddress');
      biliNvaSessions.add(socket);
      _recordNirvanaControl(requester, '9958 长链已连接');

      await for (final chunk in socket.timeout(const Duration(minutes: 2))) {
        debugLog(
          '$label chunk from $requester bytes=${chunk.length} '
          'bufferBefore=${buffer.length} hex=${shortHex(chunk)} '
          'text=${nativeFrameTextSummary(Uint8List.fromList(chunk)) ?? '<none>'}',
        );
        buffer.addAll(chunk);
        while (buffer.isNotEmpty) {
          final isLikelyText = looksLikeTextNirvanaPayload(buffer);
          final frameLength = isLikelyText
              ? null
              : nvaFrameLength(buffer) ??
                  nirvanaShortControlFrameLength(buffer);
          final isCompleteText = looksLikeCompleteNirvanaPayload(buffer);
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
          lastCommand = nvaCommandForLog(frame) ?? lastCommand;
          if (shouldSendNirvanaTextAck(frame)) {
            final ack = nirvanaTextAck(
              frame,
              localAddress: localAddress,
            );
            debugLog(
                '$label ACK to $requester bytes=${utf8.encode(ack).length} '
                'summary=${compactSummary(ack)}');
            await _writeBiliNvaSession(socket, utf8.encode(ack));
            debugLog('$label ACK flushed to $requester');
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
        lastCommand = nvaCommandForLog(frame) ?? lastCommand;
        if (shouldSendNirvanaTextAck(frame)) {
          final ack = nirvanaTextAck(
            frame,
            localAddress: localAddress,
          );
          debugLog('$label ACK to $requester bytes=${utf8.encode(ack).length} '
              'summary=${compactSummary(ack)}');
          await _writeBiliNvaSession(socket, utf8.encode(ack));
          debugLog('$label ACK flushed to $requester');
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
      debugLog(
        '$label read side reached EOF from $requester '
        'lastCommand=$lastCommand nativeResponses=$nativeResponses',
      );
      _recordNirvanaControl(requester, '9958 对端已关闭');
    } on Object catch (error) {
      debugLog(
        '$label socket error from $requester: ${shortError(error)} '
        'lastCommand=$lastCommand nativeResponses=$nativeResponses',
      );
      _recordNirvanaControl(requester, '9958 错误：${shortError(error)}');
    } finally {
      biliNvaSessions.remove(socket);
      biliNvaSessionWrites.remove(socket);
      debugLog(
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
    final responses = nirvanaFrameResponses(frame);
    if (responses.isEmpty) {
      return false;
    }
    for (final response in responses) {
      await _writeBiliNvaSession(socket, response);
      debugLog(
        '$label frame response to $requester '
        'summary=${nirvanaControlSummary(response)} hex=${shortHex(response)}',
      );
    }
    return true;
  }

  Future<void> _writeBiliNvaSession(Socket socket, List<int> data) {
    final previous = biliNvaSessionWrites[socket] ?? Future<void>.value();
    final next = previous.catchError((Object _) {}).then((_) async {
      socket.add(data);
      await socket.flush();
    });
    biliNvaSessionWrites[socket] = next;
    return next;
  }

  Future<void> _processNirvanaControlData(
    Uint8List data, {
    required String requester,
    required String localAddress,
  }) async {
    final summary = nirvanaControlSummary(data);
    debugLog(
      'Nirvana from $requester local=$localAddress bytes=${data.length} '
      'summary=$summary hex=${shortHex(data)}',
    );
    _recordNirvanaControl(requester, summary);
    final nvaFrame = parseNvaFrame(data);
    if (nvaFrame != null) {
      debugLog(
        'Nirvana frame from $requester: '
        'op=0x${nvaFrame.op.toRadixString(16)} seq=${nvaFrame.sequence} '
        'attrs=${nvaFrame.attributes} body=${safeTextForLog(nvaFrame.bodyText)}',
      );
      _recordNirvanaControl(requester, nvaFrame.summary);
      if (nvaFrame.isRequest) {
        if (nvaFrame.attributes['Command'] == 'Play') {
          if (BiliNvaPlayRequest.fromBody(nvaFrame.bodyText) != null) {
            latestBiliCastStatus = null;
            latestBiliNvaPlayRequest = null;
            biliNvaPlayState = biliPlayStatePlaying;
            debugLog('B站状态缓存已清空：收到新的 Play');
            unawaited(_acceptBiliNvaPlay(
              nvaFrame.bodyText,
              requester: requester,
            ));
          } else {
            await _handleBiliNvaPlaybackCommand(
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
          await _handleBiliNvaPlaybackCommand(
            nvaFrame.attributes['Command'],
            nvaFrame.bodyText,
            requester: requester,
          );
        }
        final url = extractNirvanaControlUrl(nvaFrame.bodyText);
        if (url != null) {
          debugLog(
              'Nirvana frame URL from $requester: ${safeUrlForLog(url)}');
          unawaited(_acceptUrl(url, source: 'B站 NVA $requester'));
        }
      }
    }
    final payload = utf8.decode(data, allowMalformed: true);
    final nvaExt = extractBiliNvaExt(payload);
    if (nvaExt != null) {
      debugLog('Nirvana NVA ext from $requester: ${nvaExt.summary}');
      _recordNirvanaControl(requester, nvaExt.summary);
      unawaited(_replyBiliNvaLink(nvaExt, localAddress));
    }
    final url = extractNirvanaControlUrl(payload);
    if (url != null) {
      debugLog('Nirvana URL from $requester: ${safeUrlForLog(url)}');
      unawaited(_acceptUrl(url, source: 'B站 Nirvana $requester'));
    } else {
      debugLog('Nirvana URL from $requester: <none>');
    }
  }

  Future<void> _replyBiliNvaLink(
    BiliNvaExt nvaExt,
    String localAddress,
  ) async {
    final error = await sendBiliNvaLinkReply(nvaExt, localAddress);
    if (error != null && mounted) {
      _addDebugAlert('ERR', error);
    }
  }

  Future<void> _acceptBiliNvaPlay(
    String body, {
    required String requester,
  }) async {
    final play = BiliNvaPlayRequest.fromBody(body);
    if (play == null) {
      debugLog('B站 NVA Play from $requester ignored: invalid body');
      _recordNirvanaControl(requester, 'Play 参数不可用');
      if (mounted) {
        _addDebugAlert('ERR', 'B站 Play 参数不可用');
      }
      return;
    }

    debugLog(
      'B站 NVA Play from $requester: aid=${play.aid ?? '-'} '
      'cid=${play.cid ?? '-'} qn=${play.preferredQn} '
      'contentType=${play.contentType ?? '-'}',
    );
    _recordNirvanaControl(requester, 'Play 换取播放地址');

    final result = await fetchBiliPlayUrl(play);
    if (result.url == null) {
      final message = result.error ?? 'B站 playurl 未返回可播放地址';
      debugLog('B站 playurl failed for $requester: $message');
      _recordNirvanaControl(requester, message);
      if (mounted) {
        _addDebugAlert('ERR', message);
      }
      return;
    }

    debugLog('B站 playurl OK for $requester: ${safeUrlForLog(result.url!)}');
    latestBiliNvaPlayRequest = play;
    latestBiliCastStatus = result.status;
    biliNvaPlayState = biliPlayStatePlaying;
    if (result.status != null) {
      debugLog('B站状态已缓存: ${result.status!.toJson()}');
      unawaited(_sendBiliPlaybackStatusEvents(result.status!));
    }
    _recordNirvanaControl(requester, 'PlayUrl ${safeUrlForLog(result.url!)}');
    unawaited(
      _acceptUrl(
        result.url!,
        source: 'B站 NVA $requester',
        httpHeaders: biliPlaybackHeaders(bvid: play.bvid, aid: play.aid),
      ),
    );
  }

  Future<void> _handleBiliNvaPlaybackCommand(
    String? command,
    String body, {
    required String requester,
  }) async {
    switch (command) {
      case 'Pause':
        debugLog('B站 Pause from $requester');
        _recordNirvanaControl(requester, 'Pause');
        biliNvaPlayState = biliPlayStatePaused;
        await _pause();
        _sendBiliPlaybackStateEvent(biliPlayStatePaused);
        break;
      case 'Resume':
      case 'Play':
        debugLog('B站 Resume from $requester');
        _recordNirvanaControl(requester, command ?? 'Resume');
        biliNvaPlayState = biliPlayStatePlaying;
        await _play();
        _sendBiliPlaybackStateEvent(biliPlayStatePlaying);
        break;
      case 'Seek':
        final position = biliSeekPositionFromBody(body);
        debugLog(
            'B站 Seek from $requester: position=${position?.inSeconds ?? '-'}s');
        _recordNirvanaControl(
          requester,
          position == null ? 'Seek 参数不可用' : 'Seek ${position.inSeconds}s',
        );
        if (position != null) {
          await _seekTo(position);
          _sendBiliProgressEvent(position);
        }
        break;
      case 'Stop':
        debugLog('B站 Stop from $requester: stopping playback');
        _recordNirvanaControl(requester, 'Stop');
        await _returnToHome();
        break;
    }
  }

  Future<void> _switchBiliNvaQn(
    String body, {
    required String requester,
  }) async {
    final qn = biliSwitchQnFromBody(body);
    final latestPlay = latestBiliNvaPlayRequest;
    if (qn == null || latestPlay == null) {
      debugLog(
        'B站 SwitchQn from $requester ignored: qn=${qn ?? '-'} '
        'hasPlay=${latestPlay != null}',
      );
      return;
    }

    final player = _player;
    final position = player != null && player.isInitialized
        ? await _playerPosition(player)
        : Duration.zero;
    final play = latestPlay.copyWith(
      qn: qn,
      userDesireQn: qn,
      seekTs: position.inSeconds,
    );
    debugLog(
      'B站 SwitchQn from $requester: qn=$qn '
      'position=${position.inSeconds}s',
    );
    _recordNirvanaControl(requester, 'SwitchQn $qn');

    final result = await fetchBiliPlayUrl(play);
    if (result.url == null) {
      final message = result.error ?? 'B站 SwitchQn 未返回可播放地址';
      debugLog('B站 SwitchQn failed for $requester: $message');
      _recordNirvanaControl(requester, message);
      if (mounted) {
        _addDebugAlert('ERR', message);
      }
      return;
    }

    latestBiliNvaPlayRequest = play;
    latestBiliCastStatus = result.status;
    biliNvaPlayState = biliPlayStatePlaying;
    final status = result.status;
    if (status != null) {
      debugLog('B站 SwitchQn 状态已缓存: ${status.toJson()}');
      unawaited(_sendBiliPlaybackStatusEvents(status, position: position));
    }
    _recordNirvanaControl(requester, 'SwitchQn ${safeUrlForLog(result.url!)}');
    unawaited(
      _acceptUrl(
        result.url!,
        source: 'B站 NVA $requester',
        httpHeaders: biliPlaybackHeaders(bvid: play.bvid, aid: play.aid),
        initialPosition: position,
      ),
    );
  }

  Future<void> _sendBiliPlaybackStatusEvents(
    BiliCastStatus status, {
    Duration position = Duration.zero,
  }) async {
    final durationMs = status.timelength ?? 0;
    final durationSeconds = biliSecondsFromMilliseconds(durationMs);
    final positionSeconds = position.inSeconds;
    final positionMs = position.inMilliseconds;
    final events = <Uint8List>[
      nvaServerEventFrame(
        command: 'OnPlayState',
        body: jsonEncode({'playState': biliPlayStatePlaying}),
      ),
      nvaServerEventFrame(
        command: 'OnProgress',
        body: jsonEncode({
          'position': positionSeconds,
          'duration': durationSeconds,
        }),
      ),
    ];
    if (status.quality != null) {
      events.add(nvaServerEventFrame(
        command: 'OnQnSwitch',
        body: jsonEncode(biliQnDescriptionBody(status)),
      ));
    }

    final sessions = biliNvaSessions.toList(growable: false);
    debugLog(
      'B站主动状态事件: sessions=${sessions.length} '
      'position=$positionSeconds duration=$durationSeconds '
      'positionMs=$positionMs durationMs=$durationMs '
      'quality=${status.quality ?? '-'}',
    );
    for (final session in sessions) {
      try {
        for (final event in events) {
          await _writeBiliNvaSession(session, event);
        }
      } on Object catch (error) {
        debugLog('B站主动状态事件发送失败: ${shortError(error)}');
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
    final durationMs = latestBiliCastStatus?.timelength ?? 0;
    final durationSeconds = biliSecondsFromMilliseconds(durationMs);
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

  void _startBiliProgressUpdates() {
    _biliProgressTimer?.cancel();
    _biliProgressTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final player = _player;
      if (player == null || !player.isInitialized) {
        return;
      }
      unawaited(_sendCurrentBiliProgressEvent(player));
    });
    final player = _player;
    if (player != null && player.isInitialized) {
      unawaited(_sendCurrentBiliProgressEvent(player));
    }
  }

  Future<void> _sendCurrentBiliProgressEvent(CoolCastPlayer player) async {
    _sendBiliProgressEvent(await _playerPosition(player));
  }

  void _stopBiliProgressUpdates() {
    _biliProgressTimer?.cancel();
    _biliProgressTimer = null;
  }

  void _sendBiliNvaEvent({
    required String command,
    required String body,
  }) {
    final sessions = biliNvaSessions.toList(growable: false);
    debugLog('B站主动事件: command=$command sessions=${sessions.length}');
    for (final session in sessions) {
      try {
        unawaited(_writeBiliNvaSession(
          session,
          nvaServerEventFrame(command: command, body: body),
        ));
      } on Object catch (error) {
        debugLog('B站主动事件发送失败: ${shortError(error)}');
      }
    }
  }

  void _sendSsdpSearchResponse(
    RawDatagramSocket socket,
    InternetAddress address,
    int port,
    List<String> responses,
  ) {
    for (final response in responses) {
      socket.send(utf8.encode(response), address, port);
    }
    _recordSsdpResponse(responses.length);
  }

  void _sendSsdpNotify(RawDatagramSocket socket, String localIp) {
    for (final target in ssdpTargets) {
      final notify = ssdpNotify(localIp, target);
      socket.send(
        utf8.encode(notify),
        InternetAddress('239.255.255.250'),
        1900,
      );
    }
  }

  Future<void> _handleAvTransport(HttpRequest request) async {
    final body = await readUtf8WithLimit(
      request,
      maxBytes: maxControlRequestBodyBytes,
    );
    debugLog(
      'AVTransport from ${request.connectionInfo?.remoteAddress.address}: '
      '${soapActionSummary(body)}',
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
      final nvaExt = extractBiliNvaExt(url);
      if (nvaExt != null) {
        _recordNirvanaControl(
          request.connectionInfo?.remoteAddress.address ?? '',
          nvaExt.summary,
        );
        unawaited(_replyBiliNvaLink(nvaExt, _localIp));
      }
      final metadata = mediaInfoFromMetadata(
        extractSoapValue(body, 'CurrentURIMetaData'),
      );
      if (!isNextUri) {
        final source = sourceWithRemoteAddress('DLNA/UPnP', request);
        _pendingDlnaUrl = url;
        _pendingDlnaSource = source;
        _pendingDlnaMediaInfo = metadata;
        _lastDlnaSetUriAt = DateTime.now();
        _pendingDlnaStopTimer?.cancel();
        _pendingDlnaStopTimer = null;
        debugLog(
          'DLNA SetURI url=${safeUrlForLog(url)} '
          'mime=${metadata.mimeType.isEmpty ? '-' : metadata.mimeType}',
        );
        if (shouldReloadDlnaSetUri(
          incomingUrl: url,
          currentUrl: _currentUrl,
          pendingUrl: _pendingDlnaUrl,
          isLoadingUrl: _loadingUrl == url,
          hasActivePlayer: _player?.isInitialized ?? false,
        )) {
          unawaited(
            _acceptUrl(
              url,
              source: source,
              mediaInfo: metadata,
            ),
          );
        } else {
          debugLog(
              'DLNA duplicate SetURI ignored: url=${safeUrlForLog(url)}');
        }
      }
      await sendXml(
        soapResponse(
          isNextUri
              ? 'SetNextAVTransportURIResponse'
              : 'SetAVTransportURIResponse',
        ),
      );
      return;
    }

    if (body.contains('<u:Play') || body.contains(':Play')) {
      _pendingDlnaStopTimer?.cancel();
      _pendingDlnaStopTimer = null;
      unawaited(_play(source: sourceWithRemoteAddress('DLNA/UPnP', request)));
      await sendXml(soapResponse('PlayResponse'));
      return;
    }

    if (body.contains('<u:Pause') || body.contains(':Pause')) {
      unawaited(_pause());
      await sendXml(soapResponse('PauseResponse'));
      return;
    }

    if (body.contains('<u:Stop') || body.contains(':Stop')) {
      _handleDlnaStop();
      await sendXml(soapResponse('StopResponse'));
      return;
    }

    if (body.contains('GetTransportInfo')) {
      await sendXml(transportInfoResponse(_state));
      return;
    }

    if (body.contains('GetPositionInfo')) {
      final player = _player;
      final position = player != null && player.isInitialized
          ? await _playerPosition(player)
          : Duration.zero;
      final duration = player != null && player.isInitialized
          ? await _playerDuration(player)
          : Duration.zero;
      await sendXml(
        positionInfoResponse(
          position: position,
          duration: duration,
          currentUrl: _currentUrl,
        ),
      );
      return;
    }

    if (body.contains('GetMediaInfo')) {
      await sendXml(mediaInfoResponse(_player, _currentUrl));
      return;
    }

    if (body.contains('GetTransportSettings')) {
      await sendXml(transportSettingsResponse());
      return;
    }

    if (body.contains('GetDeviceCapabilities')) {
      await sendXml(deviceCapabilitiesResponse());
      return;
    }

    if (body.contains('GetCurrentTransportActions')) {
      await sendXml(currentTransportActionsResponse(_state));
      return;
    }

    if (body.contains('<u:Seek') || body.contains(':Seek')) {
      final target = parseDlnaDuration(extractSoapValue(body, 'Target'));
      if (target != null) {
        unawaited(_seekTo(target));
      }
      await sendXml(soapResponse('SeekResponse'));
      return;
    }

    _addDebugAlert('ERR', '未知 AVTransport：${soapActionSummary(body)}');
    await sendXml(soapResponse('AVTransportResponse'));
  }

  Future<void> _handleRenderingControl(HttpRequest request) async {
    final body = await readUtf8WithLimit(
      request,
      maxBytes: maxControlRequestBodyBytes,
    );
    debugLog(
      'RenderingControl from ${request.connectionInfo?.remoteAddress.address}: '
      '${soapActionSummary(body)}',
    );
    var response = soapResponse(
      'RenderingControlResponse',
      service: CoolCastUpnpService.renderingControl,
    );
    if (body.contains('GetVolume')) {
      response = soapResponse(
        'GetVolumeResponse',
        service: CoolCastUpnpService.renderingControl,
        body: '<CurrentVolume>${(_volume * 100).round()}</CurrentVolume>',
      );
    } else if (body.contains('SetVolume')) {
      final desiredVolume =
          int.tryParse(extractSoapValue(body, 'DesiredVolume'));
      if (desiredVolume != null) {
        unawaited(_setVolume(desiredVolume.clamp(0, 100) / 100));
      }
      response = soapResponse(
        'SetVolumeResponse',
        service: CoolCastUpnpService.renderingControl,
      );
    } else if (body.contains('GetMute')) {
      response = soapResponse(
        'GetMuteResponse',
        service: CoolCastUpnpService.renderingControl,
        body: '<CurrentMute>${_isMuted ? 1 : 0}</CurrentMute>',
      );
    } else if (body.contains('SetMute')) {
      final desiredMute = extractSoapValue(body, 'DesiredMute');
      if (desiredMute.isNotEmpty) {
        unawaited(_setMuted(desiredMute == '1' || desiredMute == 'true'));
      }
      response = soapResponse(
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
    final body = await readUtf8WithLimit(
      request,
      maxBytes: maxControlRequestBodyBytes,
    );
    debugLog(
      'ConnectionManager from ${request.connectionInfo?.remoteAddress.address}: '
      '${soapActionSummary(body)}',
    );
    var response = soapResponse(
      'ConnectionManagerResponse',
      service: CoolCastUpnpService.connectionManager,
    );
    if (body.contains('GetProtocolInfo')) {
      response = protocolInfoResponse();
    } else if (body.contains('GetCurrentConnectionIDs')) {
      response = soapResponse(
        'GetCurrentConnectionIDsResponse',
        service: CoolCastUpnpService.connectionManager,
        body: '<ConnectionIDs>0</ConnectionIDs>',
      );
    } else if (body.contains('GetCurrentConnectionInfo')) {
      response = soapResponse(
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
    final body = await readUtf8WithLimit(
      request,
      maxBytes: maxControlRequestBodyBytes,
    );
    final localAddress = _nvaReplyAddress(_localIp);
    debugLog(
      'NirvanaControl HTTP from ${request.connectionInfo?.remoteAddress.address}: '
      '${soapActionSummary(body)}',
    );
    if (body.contains('GetNvaLinkAddress')) {
      await _sendTextResponse(
        request.response,
        soapResponse(
          'GetNvaLinkAddressResponse',
          service: CoolCastUpnpService.nirvanaControl,
          body:
              '<NvaLinkAddress>${xmlEscape(biliNvaLinkAddress(localAddress))}</NvaLinkAddress>',
        ),
        contentType: ContentType('text', 'xml', charset: 'utf-8'),
      );
      return;
    }
    await _sendTextResponse(
      request.response,
      soapResponse(
        'NirvanaControlResponse',
        service: CoolCastUpnpService.nirvanaControl,
      ),
      contentType: ContentType('text', 'xml', charset: 'utf-8'),
    );
  }

  String _extractCurrentUri(String body) {
    return extractSoapValue(body, 'CurrentURI');
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
    if (!isValidCastUrl(value)) {
      setState(() {
        _currentUrl = value;
        _urlController.text = value;
        _currentMediaTitle = '';
        _currentMimeType = '';
        _currentMediaResolution = '';
        _currentMediaBitrate = null;
        _state = PlaybackState.failed;
        _lastMessage = value.isEmpty ? '$source 未提供地址' : '$source 地址不可用';
      });
      _addDebugAlert(
        'ERR',
        value.isEmpty
            ? '$source 未提供地址'
            : '$source 地址不可用：${safeUrlForLog(value)}',
      );
      return;
    }
    if (mediaInfo.isImage || isImageUrl(value)) {
      await _acceptImageUrl(value, source: source, mediaInfo: mediaInfo);
      return;
    }

    _loadingUrl = value;
    final oldPlayer = _player;
    final player = shouldUseNativePlayer
        ? NativePlayerController(
            value,
            httpHeaders: httpHeaders,
            initialPosition: initialPosition,
          )
        : FlutterVideoPlayerController(
            Uri.parse(value),
            httpHeaders: httpHeaders,
          );
    setState(() {
      _currentUrl = value;
      _currentImageUrl = '';
      _currentImageBytes = null;
      _imageLoadRequestId += 1;
      _urlController.text = value;
      _castSource = source;
      _currentMediaTitle = mediaInfo.title;
      _currentMimeType = mediaInfo.mimeType;
      _currentMediaResolution = mediaInfo.resolution;
      _currentMediaBitrate = mediaInfo.bitrate;
      _state = PlaybackState.ready;
      _lastMessage = '$source 正在载入';
    });

    try {
      if (shouldUseNativePlayer) {
        // Android 端控制器共用同一个 ExoPlayer，必须先停止旧媒体。
        await oldPlayer?.dispose();
      }
      await player.initialize();
      await player.setVolume(_isMuted ? 0 : _volume);
      if (!shouldUseNativePlayer && initialPosition > Duration.zero) {
        await player.seekTo(initialPosition);
      }
      final urlQuality = qualityLabelFromUrl(value);
      debugLog(
        '$source 播放器已初始化: url=${safeUrlForLog(value)} '
        'urlQuality=${urlQuality.isEmpty ? '-' : urlQuality} '
        'videoSize=${videoSizeSummary(player.size)} '
        'biliQuality=${latestBiliCastStatus?.quality ?? '-'}',
      );
      if (!shouldUseNativePlayer) {
        await oldPlayer?.dispose();
      }
      await player.play();
      setState(() {
        _player = player;
        _state = PlaybackState.playing;
        _lastMessage = '$source 已开始播放';
      });
      _startMediaInfoUpdates(player);
      _startBiliProgressUpdates();
    } on Object catch (error) {
      await player.dispose();
      _stopBiliProgressUpdates();
      setState(() {
        _state = PlaybackState.failed;
        _lastMessage = '播放失败：$error';
      });
      _addDebugAlert('ERR', '播放失败：${shortError(error)}');
    } finally {
      if (_loadingUrl == value) {
        _loadingUrl = '';
      }
    }
  }

  Future<void> _acceptImageUrl(
    String value, {
    required String source,
    required CoolCastMediaInfo mediaInfo,
  }) async {
    debugLog(
      '$source 显示图片: url=${safeUrlForLog(value)} '
      'mime=${mediaInfo.mimeType.isEmpty ? '-' : mediaInfo.mimeType}',
    );
    final requestId = _imageLoadRequestId + 1;
    final oldPlayer = _player;
    await oldPlayer?.dispose();
    _stopMediaInfoUpdates();
    _stopBiliProgressUpdates();
    setState(() {
      _imageLoadRequestId = requestId;
      _player = null;
      _currentUrl = value;
      _currentImageUrl = value;
      _urlController.text = value;
      _castSource = source;
      _currentMediaTitle = mediaInfo.title;
      _currentMimeType = mediaInfo.mimeType;
      _currentMediaResolution = mediaInfo.resolution;
      _currentMediaBitrate = mediaInfo.bitrate;
      _state = PlaybackState.playing;
      _lastMessage = '$source 已显示图片';
      _showPlaybackControls = false;
    });
    Uint8List? imageBytes;
    try {
      imageBytes = await fetchImageBytes(value);
      debugLog(
        '$source 图片已缓存: bytes=${imageBytes.length} '
        'head=${shortHex(imageBytes)}',
      );
    } on Object catch (error) {
      debugLog('$source 图片缓存失败: ${shortError(error)}');
    }
    if (!mounted ||
        !shouldReportImageLoadFailure(
          requestId: requestId,
          activeRequestId: _imageLoadRequestId,
          requestUrl: value,
          currentImageUrl: _currentImageUrl,
        )) {
      return;
    }
    setState(() => _currentImageBytes = imageBytes);
  }

  void _loadUrl() {
    unawaited(_acceptUrl(_urlController.text.trim(), source: '浏览器调试'));
  }

  Future<void> _play({String source = '浏览器调试'}) async {
    if (_currentUrl.isEmpty) {
      if (_pendingDlnaUrl.isNotEmpty) {
        await _acceptUrl(
          _pendingDlnaUrl,
          source: _pendingDlnaSource.isNotEmpty ? _pendingDlnaSource : source,
          mediaInfo: _pendingDlnaMediaInfo,
        );
        return;
      }
      _loadUrl();
      return;
    }
    if (_currentImageUrl.isNotEmpty) {
      setState(() => _state = PlaybackState.playing);
      return;
    }
    await _player?.play();
    setState(() => _state = PlaybackState.playing);
    _startBiliProgressUpdates();
  }

  Future<void> _pause() async {
    if (_state == PlaybackState.playing) {
      await _player?.pause();
      setState(() => _state = PlaybackState.paused);
      _stopBiliProgressUpdates();
    }
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
    await _stopCurrentPlayback(keepPendingDlnaUrl: false);
  }

  void _handleDlnaStop({bool force = false}) {
    if (!force &&
        shouldDeferDlnaStopAfterSetUri(
          lastSetUriAt: _lastDlnaSetUriAt,
          now: DateTime.now(),
          currentUrl: _currentUrl,
          pendingUrl: _pendingDlnaUrl,
        )) {
      debugLog('DLNA Stop deferred after SetURI');
      _pendingDlnaStopTimer?.cancel();
      _pendingDlnaStopTimer = Timer(dlnaSetUriStopGracePeriod, () {
        _pendingDlnaStopTimer = null;
        _handleDlnaStop(force: true);
      });
      return;
    }
    if (!shouldClearPlayingPageOnDlnaStop(
      imageUrl: _currentImageUrl,
      imageBytes: _currentImageBytes,
    )) {
      debugLog('DLNA Stop ignored for active image cast');
      setState(() {
        _state = PlaybackState.paused;
        _lastMessage = '图片投屏已暂停，等待下一张图片';
      });
      return;
    }
    unawaited(_stopCurrentPlayback(keepPendingDlnaUrl: true));
  }

  Future<void> _stopCurrentPlayback({required bool keepPendingDlnaUrl}) async {
    _pendingDlnaStopTimer?.cancel();
    _pendingDlnaStopTimer = null;
    await _player?.pause();
    await _player?.dispose();
    _controlsTimer?.cancel();
    _stopMediaInfoUpdates();
    _stopBiliProgressUpdates();
    latestBiliCastStatus = null;
    latestBiliNvaPlayRequest = null;
    biliNvaPlayState = biliPlayStateIdle;
    setState(() {
      _player = null;
      _currentImageUrl = '';
      _currentImageBytes = null;
      _imageLoadRequestId += 1;
      _playingPreviewVisible = false;
      _previewPosition = const Duration(minutes: 18, seconds: 42);
      _state = PlaybackState.idle;
      _currentUrl = '';
      if (!keepPendingDlnaUrl) {
        _pendingDlnaUrl = '';
        _pendingDlnaSource = '';
        _pendingDlnaMediaInfo = const CoolCastMediaInfo();
        _lastDlnaSetUriAt = null;
      }
      _castSource = '等待投屏设备';
      _currentMediaTitle = '';
      _currentMimeType = '';
      _currentMediaResolution = '';
      _currentMediaBitrate = null;
      _showPlaybackControls = false;
      _lastMessage = kIsWeb ? '可手动输入 URL 调试播放界面' : '正在等待投屏请求';
    });
  }

  Future<void> _seekBy(Duration offset) async {
    final player = _player;
    if (player == null || !player.isInitialized) {
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
    final duration = await _playerDuration(player);
    final current = await _playerPosition(player);
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
    if (player == null || !player.isInitialized) {
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
    final duration = await _playerDuration(player);
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

  Future<Duration> _playerPosition(CoolCastPlayer player) async {
    if (player is NativePlayerController) {
      return nativePlayerPosition();
    }
    return player.position;
  }

  Future<Duration> _playerDuration(CoolCastPlayer player) async {
    if (player is NativePlayerController) {
      return nativePlayerDuration();
    }
    return player.duration;
  }

  void _startMediaInfoUpdates(CoolCastPlayer player) {
    _mediaInfoTimer?.cancel();
    if (player is! NativePlayerController) {
      return;
    }
    _mediaInfoTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final currentPlayer = _player;
      if (!mounted || !identical(currentPlayer, player)) {
        _stopMediaInfoUpdates();
        return;
      }
      final previousSize = player.size;
      final previousBitrate = player.bitrate;
      await player.refreshStatus();
      if ((player.size != previousSize || player.bitrate != previousBitrate) &&
          mounted) {
        setState(() {});
      }
      if (player.size != null && player.bitrate != null) {
        _stopMediaInfoUpdates();
      }
    });
  }

  void _stopMediaInfoUpdates() {
    _mediaInfoTimer?.cancel();
    _mediaInfoTimer = null;
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
      _installDialogVisible = false;
      _renameDialogVisible = true;
    });
  }

  void _closeRenameDialog() {
    setState(() => _renameDialogVisible = false);
  }

  void _openInstallDialog() {
    setState(() {
      _renameDialogVisible = false;
      _installDialogVisible = true;
    });
  }

  void _closeInstallDialog() {
    setState(() => _installDialogVisible = false);
  }

  Future<void> _handleApkUploadRequest(
    HttpRequest request, {
    required String debugLabel,
    required Stopwatch stopwatch,
  }) async {
    final method = request.method.toUpperCase();
    if (method != 'POST' && method != 'PUT') {
      await _sendTextResponse(
        request.response,
        'Method not allowed',
        statusCode: HttpStatus.methodNotAllowed,
        contentType: ContentType.text,
        debugLabel: debugLabel,
        stopwatch: stopwatch,
      );
      return;
    }

    if (request.contentLength > maxApkUploadBytes) {
      await _sendTextResponse(
        request.response,
        installUploadHtmlResponse(
          fileName: '',
          isAccepted: false,
          detail: '安装包体积超过 512 MB 限制。',
        ),
        statusCode: HttpStatus.requestEntityTooLarge,
        contentType: ContentType.html,
        debugLabel: debugLabel,
        stopwatch: stopwatch,
      );
      return;
    }

    if (mounted) {
      setState(() {
        _installStatusMessage = '正在接收手机上传的 APK 安装包...';
      });
    }

    final rawBytes = await readBytesWithLimit(
      request,
      maxBytes: maxApkUploadBytes,
    );
    final extracted = extractUploadedApk(
      rawBytes,
      contentTypeHeader: request.headers.value(HttpHeaders.contentTypeHeader),
      queryFileName: request.uri.queryParameters['filename'] ??
          request.headers.value('x-file-name'),
    );
    if (extracted == null) {
      if (mounted) {
        setState(() {
          _installStatusMessage = '上传失败：请选择有效的 .apk 安装包';
        });
      }
      _addDebugAlert('ERR', 'APK 上传失败：文件格式无效');
      await _sendTextResponse(
        request.response,
        installUploadHtmlResponse(
          fileName: '',
          isAccepted: false,
          detail: '未检测到有效的 .apk 安装包，请重新选择文件上传。',
        ),
        statusCode: HttpStatus.badRequest,
        contentType: ContentType.html,
        debugLabel: debugLabel,
        stopwatch: stopwatch,
      );
      return;
    }

    final tempDir = await Directory.systemTemp.createTemp('coolcast_apk_');
    final safeFileName = sanitizeApkFileName(extracted.fileName);
    final apkFile = File('${tempDir.path}/$safeFileName');
    await apkFile.writeAsBytes(extracted.bytes, flush: true);
    debugLog(
      'APK uploaded from ${request.connectionInfo?.remoteAddress.address}: '
      'name=$safeFileName bytes=${extracted.bytes.length} path=${apkFile.path}',
    );

    if (mounted) {
      setState(() {
        _installStatusMessage = '已接收 $safeFileName，正在调起系统安装...';
        _lastMessage = '正在安装 $safeFileName';
      });
    }
    unawaited(_triggerNativeApkInstall(apkFile.path, fileName: safeFileName));

    await _sendTextResponse(
      request.response,
      installUploadHtmlResponse(
        fileName: safeFileName,
        isAccepted: true,
        detail: '安装包已上传至 CoolCast，电视端正在自动拉起安装界面。',
      ),
      contentType: ContentType.html,
      debugLabel: debugLabel,
      stopwatch: stopwatch,
    );
  }

  Future<void> _triggerNativeApkInstall(
    String filePath, {
    required String fileName,
  }) async {
    try {
      final status = await installApkWithNativeBridge(filePath);
      if (!mounted) {
        return;
      }
      setState(() {
        if (status == 'permission_requested') {
          _installStatusMessage =
              '请在电视端授予“安装未知应用”权限，返回后将自动安装 $fileName';
          _lastMessage = '请授权安装未知应用：$fileName';
        } else {
          _installStatusMessage = '已调起系统安装：$fileName';
          _lastMessage = '已启动安装：$fileName';
        }
      });
    } on Object catch (error) {
      debugLog('APK install failed: ${shortError(error)}');
      if (!mounted) {
        return;
      }
      setState(() {
        _installStatusMessage = '安装调起失败：${shortError(error)}';
        _lastMessage = '安装失败：${shortError(error)}';
      });
      _addDebugAlert('ERR', 'APK 安装失败：${shortError(error)}');
    }
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
    await preferences.setString(receiverNameKey, nextName);
    if (!mounted) {
      return;
    }
    setState(() {
      _receiverName = nextName;
      _renameDialogVisible = false;
    });
  }

  Future<bool> _handleBack() async {
    if (_installDialogVisible) {
      _closeInstallDialog();
      return false;
    }
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
    final player = _player;
    final isShowingVideo = player != null && player.isInitialized;
    final isShowingPlayingPage = shouldShowPlayingPage(
      isShowingVideo: isShowingVideo,
      isPlayingPreviewVisible: _playingPreviewVisible,
      imageUrl: _currentImageUrl,
      imageBytes: _currentImageBytes,
    );
    final isOnHomeScreen = !isShowingPlayingPage &&
        !_renameDialogVisible &&
        !_installDialogVisible;

    if (isOnHomeScreen && key == LogicalKeyboardKey.arrowDown) {
      _openInstallDialog();
      return KeyEventResult.handled;
    }

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

    if (_player != null && key == LogicalKeyboardKey.arrowLeft) {
      unawaited(_seekBy(const Duration(seconds: -10)));
      return KeyEventResult.handled;
    }

    if (_player != null && key == LogicalKeyboardKey.arrowRight) {
      unawaited(_seekBy(const Duration(seconds: 10)));
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    final isShowingVideo = player != null && player.isInitialized;
    final isShowingPlayingPage = shouldShowPlayingPage(
      isShowingVideo: isShowingVideo,
      isPlayingPreviewVisible: _playingPreviewVisible,
      imageUrl: _currentImageUrl,
      imageBytes: _currentImageBytes,
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          unawaited(_handleBack());
        }
      },
      child: Focus(
        focusNode: _remoteFocusNode,
        autofocus: true,
        onKeyEvent: _handleRemoteKey,
        child: Scaffold(
          backgroundColor: const Color(0xFFEAF6FF),
          body: isShowingPlayingPage
              ? Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(
                      key: const ValueKey('playing-page-background'),
                      color: Colors.black,
                      child: PlayingPage(
                        player: isShowingVideo ? player : null,
                        imageUrl: _currentImageUrl,
                        imageBytes: _currentImageBytes,
                        state: _state,
                        source: _castSource,
                        fileName: _currentDisplayTitle,
                        connection: _connectionSummary,
                        mediaChips: _currentMediaChips(player),
                        previewPosition: _previewPosition,
                        previewDuration: _previewDuration,
                        showControls:
                            _showPlaybackControls || _playingPreviewVisible,
                        onBack: _returnToHome,
                        onShowControls: _revealControls,
                        onPlayPause:
                            _state == PlaybackState.playing ? _pause : _play,
                        onRewind: () => _seekBy(const Duration(seconds: -10)),
                        onForward: () => _seekBy(const Duration(seconds: 10)),
                      ),
                    ),
                    DebugAlertOverlay(alerts: _debugAlerts),
                  ],
                )
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    _HomePage(
                      receiverName: _receiverName,
                      ipAddress: _localIp,
                      wifiName: _wifiName,
                      status: _lastMessage,
                      discoveryStatus: _discoveryStatus,
                      controller: _urlController,
                      focusNode: _urlFocusNode,
                      showDebugInput: kIsWeb,
                      onLoad: _loadUrl,
                      onRename: _openRenameDialog,
                      onOpenInstall: _openInstallDialog,
                    ),
                    if (_renameDialogVisible)
                      _RenameDialog(
                        controller: _renameController,
                        onCancel: _closeRenameDialog,
                        onSave: _saveReceiverName,
                      ),
                    if (_installDialogVisible)
                      _RemoteInstallDialog(
                        ipAddress: _localIp,
                        wifiName: _wifiName,
                        statusMessage: _installStatusMessage,
                        onClose: _closeInstallDialog,
                      ),
                    DebugAlertOverlay(alerts: _debugAlerts),
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
    final fileName = displayFileName(_currentUrl);
    if (fileName.isNotEmpty && fileName != '远端媒体') {
      return fileName;
    }
    if (_playingPreviewVisible) {
      return 'Planet Earth III E04';
    }
    return '远端媒体';
  }

  List<String> _currentMediaChips(CoolCastPlayer? player) => mediaChipsFor(
        _currentUrl,
        _currentMimeType,
        _state,
        player?.size,
        metadataResolution: _currentMediaResolution,
        metadataBitrate: player?.bitrate ?? _currentMediaBitrate,
        biliStatus: latestBiliCastStatus,
      );

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
    required this.wifiName,
    required this.status,
    required this.discoveryStatus,
    required this.controller,
    required this.focusNode,
    required this.showDebugInput,
    required this.onLoad,
    required this.onRename,
    required this.onOpenInstall,
  });

  final String receiverName;
  final String ipAddress;
  final String wifiName;
  final String status;
  final String discoveryStatus;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool showDebugInput;
  final VoidCallback onLoad;
  final VoidCallback onRename;
  final VoidCallback onOpenInstall;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const Positioned.fill(
          child: Image(
            key: ValueKey('waiting-design-background'),
            image: AssetImage('assets/images/coolcast_waiting_16x9_base.png'),
            fit: BoxFit.cover,
          ),
        ),
        SafeArea(
          child: _DesignOverlayFrame(
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  top: 330,
                  height: 68,
                  child: _ReceiverNameOverlay(
                    receiverName: receiverName,
                    onRename: onRename,
                  ),
                ),
                const Positioned.fill(
                  child: _WaitingFloatingBubbles(),
                ),
                Positioned(
                  right: 10,
                  top: 58,
                  child: _WaitingStatusPanel(
                    wifiName: wifiName,
                    ipAddress: ipAddress,
                    discoveryStatus: discoveryStatus,
                  ),
                ),
                Positioned(
                  left: 36,
                  bottom: 36,
                  child: _RemoteInstallEntryButton(
                    onPressed: onOpenInstall,
                  ),
                ),
                if (status.contains('退出') || status.contains('异常'))
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 122,
                    child: _TransientHomeStatus(status: status),
                  ),
                if (showDebugInput)
                  Positioned(
                    left: 368,
                    right: 368,
                    bottom: 32,
                    child: DebugUrlInput(
                      controller: controller,
                      focusNode: focusNode,
                      onLoad: onLoad,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _DesignOverlayFrame extends StatelessWidget {
  const _DesignOverlayFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Center(
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: FittedBox(
              fit: BoxFit.fill,
              child: SizedBox(
                width: 1820,
                height: 1024,
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _WaitingStatusPanel extends StatelessWidget {
  const _WaitingStatusPanel({
    required this.wifiName,
    required this.ipAddress,
    required this.discoveryStatus,
  });

  final String wifiName;
  final String ipAddress;
  final String discoveryStatus;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        _StatusPanelLine(text: 'Wi-Fi：$wifiName'),
        const SizedBox(height: 9),
        _StatusPanelLine(text: 'IP：$ipAddress'),
        const SizedBox(height: 9),
        _StatusPanelLine(text: '发现：$discoveryStatus'),
      ],
    );
  }
}

class _StatusPanelLine extends StatelessWidget {
  const _StatusPanelLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 320,
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.right,
        style: const TextStyle(
          color: Color(0xFF31516F),
          fontSize: 22,
          fontWeight: FontWeight.w700,
          height: 1.12,
        ),
      ),
    );
  }
}

class _WaitingFloatingBubbles extends StatefulWidget {
  const _WaitingFloatingBubbles();

  @override
  State<_WaitingFloatingBubbles> createState() =>
      _WaitingFloatingBubblesState();
}

class _WaitingFloatingBubblesState extends State<_WaitingFloatingBubbles>
    with SingleTickerProviderStateMixin {
  static const _bubbleStyles = [
    BubbleStyle(
      color: Color(0xFF5EEAD4),
      size: 20,
      delay: 0.00,
    ),
    BubbleStyle(
      color: Color(0xFF93C5FD),
      size: 18,
      delay: 0.20,
    ),
    BubbleStyle(
      color: Color(0xFF6EE7B7),
      size: 22,
      delay: 0.36,
    ),
    BubbleStyle(
      color: Color(0xFF60A5FA),
      size: 18,
      delay: 0.54,
    ),
    BubbleStyle(
      color: Color(0xFFFDE68A),
      size: 22,
      delay: 0.72,
    ),
  ];

  late final AnimationController _controller;
  final math.Random _random = math.Random();
  late final List<BubblePath> _bubbles;
  late final List<double> _previousProgress;

  @override
  void initState() {
    super.initState();
    _bubbles = randomBubblePaths(_random);
    _previousProgress = [for (final style in _bubbleStyles) style.delay];
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3600),
    )
      ..addListener(_refreshBubblePaths)
      ..repeat();
  }

  void _refreshBubblePaths() {
    for (var index = 0; index < _bubbles.length; index++) {
      final progress = (_controller.value + _bubbles[index].delay) % 1.0;
      if (progress < _previousProgress[index]) {
        _bubbles[index] = randomBubblePath(_random, _bubbleStyles[index]);
      }
      _previousProgress[index] = progress;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        key: const ValueKey('waiting-floating-bubbles'),
        animation: _controller,
        builder: (context, child) {
          return CustomPaint(
            painter: FloatingBubblePainter(_controller.value, _bubbles),
            size: Size.infinite,
          );
        },
      ),
    );
  }
}

class BubblePath {
  const BubblePath({
    required this.start,
    required this.end,
    required this.color,
    required this.size,
    required this.delay,
  });

  final Offset start;
  final Offset end;
  final Color color;
  final double size;
  final double delay;
}

class BubbleStyle {
  const BubbleStyle({
    required this.color,
    required this.size,
    required this.delay,
  });

  final Color color;
  final double size;
  final double delay;
}

List<BubblePath> randomBubblePaths(math.Random random) => [
      for (final style in _WaitingFloatingBubblesState._bubbleStyles)
        randomBubblePath(random, style),
    ];

BubblePath randomBubblePath(math.Random random, BubbleStyle style) {
  final start = Offset(
    420 + random.nextDouble() * 980,
    400 + random.nextDouble() * 420,
  );
  final end = Offset(
    (start.dx + random.nextDouble() * 240 - 120).clamp(360, 1460),
    (start.dy - 55 - random.nextDouble() * 105).clamp(260, 780),
  );
  return BubblePath(
    start: start,
    end: end,
    color: style.color,
    size: style.size,
    delay: style.delay,
  );
}

class FloatingBubblePainter extends CustomPainter {
  const FloatingBubblePainter(this.progress, this.bubbles);

  final double progress;
  final List<BubblePath> bubbles;

  @override
  void paint(Canvas canvas, Size size) {
    for (final bubble in bubbles) {
      final t = ((progress + bubble.delay) % 1.0).clamp(0.0, 1.0);
      final eased = Curves.easeOut.transform(t);
      final center = Offset.lerp(bubble.start, bubble.end, eased)!;
      final opacity = (1 - eased).clamp(0.0, 1.0);
      final paint = Paint()
        ..color = bubble.color.withValues(alpha: opacity * 0.72)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.6);
      canvas.drawCircle(center, bubble.size / 2, paint);
    }
  }

  @override
  bool shouldRepaint(covariant FloatingBubblePainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.bubbles != bubbles;
  }
}

class _ReceiverNameOverlay extends StatelessWidget {
  const _ReceiverNameOverlay({
    required this.receiverName,
    required this.onRename,
  });

  final String receiverName;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 68,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Center(
            child: Transform.translate(
              offset: const Offset(-34, -6),
              child: SizedBox(
                width: 530,
                child: Text(
                  receiverName,
                  key: const ValueKey('receiver-name-text'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF132846),
                    fontSize: 50,
                    fontWeight: FontWeight.w900,
                    height: 1.0,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 1130,
            top: -6,
            width: 76,
            height: 76,
            child: IconButton(
              onPressed: onRename,
              icon: const SizedBox.shrink(),
              tooltip: '修改投屏名称',
            ),
          ),
        ],
      ),
    );
  }
}

class _TransientHomeStatus extends StatelessWidget {
  const _TransientHomeStatus({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    return Text(
      status,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: const TextStyle(
        color: Color(0xFF31516F),
        fontSize: 27,
        fontWeight: FontWeight.w800,
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
                    child: GlassCard(
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

class _RemoteInstallEntryButton extends StatefulWidget {
  const _RemoteInstallEntryButton({
    required this.onPressed,
  });

  final VoidCallback onPressed;

  @override
  State<_RemoteInstallEntryButton> createState() =>
      _RemoteInstallEntryButtonState();
}

class _RemoteInstallEntryButtonState extends State<_RemoteInstallEntryButton> {
  bool _isFocused = false;

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.gameButtonA) {
      widget.onPressed();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '远程安装应用',
      child: Focus(
        onFocusChange: (focused) => setState(() => _isFocused = focused),
        onKeyEvent: _handleKeyEvent,
        child: GestureDetector(
          key: const ValueKey('remote-install-entry-button'),
          onTap: widget.onPressed,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
            decoration: BoxDecoration(
              color: _isFocused
                  ? const Color(0xF5FFFFFF)
                  : const Color(0xD8FFFFFF),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: _isFocused
                    ? const Color(0xFF0A84FF)
                    : const Color(0xFFD6E6F5),
                width: _isFocused ? 3.0 : 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: _isFocused
                      ? const Color(0x400A84FF)
                      : const Color(0x180A3A6B),
                  blurRadius: _isFocused ? 24 : 16,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.install_mobile_rounded,
                  size: 24,
                  color: _isFocused
                      ? const Color(0xFF0A84FF)
                      : const Color(0xFF31516F),
                ),
                const SizedBox(width: 10),
                Text(
                  '远程安装',
                  style: TextStyle(
                    color: _isFocused
                        ? const Color(0xFF0A84FF)
                        : const Color(0xFF132846),
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
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

class _RemoteInstallDialog extends StatelessWidget {
  const _RemoteInstallDialog({
    required this.ipAddress,
    required this.wifiName,
    required this.statusMessage,
    required this.onClose,
  });

  final String ipAddress;
  final String wifiName;
  final String statusMessage;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final installUrl = installPageUrl(ipAddress);
    return DecoratedBox(
      key: const ValueKey('remote-install-dialog'),
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
                    left: 500,
                    top: 210,
                    width: 920,
                    child: GlassCard(
                      cornerRadius: 34,
                      padding: const EdgeInsets.all(36),
                      fill: const Color(0xE8FFFFFF),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  color: const Color(0xFFEAF5FF),
                                  borderRadius: BorderRadius.circular(15),
                                ),
                                child: const SizedBox(
                                  width: 58,
                                  height: 58,
                                  child: Icon(
                                    Icons.install_mobile_rounded,
                                    color: Color(0xFF0A84FF),
                                    size: 30,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 18),
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '远程安装应用',
                                      style: TextStyle(
                                        color: Color(0xFF102033),
                                        fontSize: 32,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    SizedBox(height: 8),
                                    Text(
                                      '使用手机扫描二维码打开上传页面，选择 APK 安装包后自动开始安装。',
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
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(24),
                                  border: Border.all(
                                    color: const Color(0xFFD6E6F5),
                                  ),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: CoolCastQrCodeView(
                                    key: const ValueKey(
                                      'remote-install-qr-code',
                                    ),
                                    data: installUrl,
                                    size: 220,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 28),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      '手机上传地址',
                                      style: TextStyle(
                                        color: Color(0xFF5E7186),
                                        fontSize: 18,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 18,
                                        vertical: 14,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xCCF7FBFF),
                                        borderRadius: BorderRadius.circular(16),
                                        border: Border.all(
                                          color: const Color(0xFFD6E6F5),
                                        ),
                                      ),
                                      child: Text(
                                        installUrl,
                                        key: const ValueKey(
                                          'remote-install-url-text',
                                        ),
                                        style: const TextStyle(
                                          color: Color(0xFF0A84FF),
                                          fontSize: 22,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 18),
                                    const Text(
                                      '安装状态',
                                      style: TextStyle(
                                        color: Color(0xFF5E7186),
                                        fontSize: 18,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 18,
                                        vertical: 14,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFF2F8FF),
                                        borderRadius: BorderRadius.circular(16),
                                        border: Border.all(
                                          color: const Color(0xFFD6E6F5),
                                        ),
                                      ),
                                      child: Text(
                                        statusMessage,
                                        key: const ValueKey(
                                          'remote-install-status-text',
                                        ),
                                        style: const TextStyle(
                                          color: Color(0xFF102033),
                                          fontSize: 20,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 14),
                                    Text(
                                      '请确保手机与电视连接在同一 Wi-Fi（$wifiName），仅支持 .apk 格式文件。',
                                      style: const TextStyle(
                                        color: Color(0xFF5E7186),
                                        fontSize: 17,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 26),
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
                                  '遥控器按确认键或返回键均可关闭弹窗。',
                                  style: TextStyle(
                                    color: Color(0xFF5E7186),
                                    fontSize: 17,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 164,
                                height: 58,
                                child: FilledButton.icon(
                                  key: const ValueKey(
                                    'remote-install-close-button',
                                  ),
                                  autofocus: true,
                                  onPressed: onClose,
                                  icon: const Icon(Icons.close, size: 22),
                                  style: FilledButton.styleFrom(
                                    backgroundColor: const Color(0xFF0A84FF),
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                  ),
                                  label: const Text(
                                    '关闭',
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
