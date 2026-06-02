import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

const String _defaultReceiverName = 'CoolCast Receiver';
const String _receiverNameKey = 'coolcast.receiverName';

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
  RawDatagramSocket? _ssdpSocket;
  Timer? _notifyTimer;
  Timer? _controlsTimer;
  VideoPlayerController? _player;
  PlaybackState _state = PlaybackState.idle;
  String _currentUrl = '';
  String _castSource = '等待投屏设备';
  String _receiverAddress = '正在启动接收服务...';
  String _lastMessage = '正在准备接收端';
  String _localIp = 'TV-IP';
  String _receiverName = _defaultReceiverName;
  bool _showPlaybackControls = false;
  bool _renameDialogVisible = false;

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
    if (!mounted) {
      return;
    }
    setState(() {
      _receiverName = savedName == null || savedName.isEmpty
          ? _defaultReceiverName
          : savedName;
      _renameController.text = _receiverName;
    });
  }

  void _startWebDebugMode() {
    setState(() {
      _receiverAddress = '浏览器调试模式：HTTP/DLNA 接收服务不可用';
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
    _notifyTimer?.cancel();
    _ssdpSocket?.close();
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
      setState(() {
        _localIp = address;
        _receiverAddress = 'http://$address:7788/';
        _lastMessage = '正在等待投屏请求';
      });
    } on Object catch (error) {
      setState(() {
        _receiverAddress = '接收服务启动失败';
        _lastMessage = '$error';
        _state = PlaybackState.failed;
      });
    }
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      if (request.uri.path == '/description.xml') {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('text', 'xml', charset: 'utf-8')
          ..write(_deviceDescription(_localIp, _receiverName));
        await request.response.close();
        continue;
      }

      if (request.uri.path == '/AVTransport/scpd.xml') {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('text', 'xml', charset: 'utf-8')
          ..write(_avTransportScpd());
        await request.response.close();
        continue;
      }

      if (request.uri.path == '/RenderingControl/scpd.xml') {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('text', 'xml', charset: 'utf-8')
          ..write(_renderingControlScpd());
        await request.response.close();
        continue;
      }

      if (request.uri.path == '/AVTransport/control') {
        await _handleAvTransport(request);
        continue;
      }

      if (request.uri.path == '/RenderingControl/control') {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('text', 'xml', charset: 'utf-8')
          ..write(_soapResponse('RenderingControlResponse'));
        await request.response.close();
        continue;
      }

      if (request.uri.path == '/cast') {
        final url = request.uri.queryParameters['url']?.trim() ?? '';
        unawaited(_acceptUrl(url, source: 'HTTP 投送'));
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.html
          ..write(_htmlResponse(url));
        await request.response.close();
        continue;
      }

      if (request.uri.path == '/') {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.html
          ..write(_htmlForm(_receiverName));
        await request.response.close();
        continue;
      }

      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
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

  bool _matchesSearchTarget(String message) {
    final upper = message.toUpperCase();
    return upper.contains('SSDP:ALL') ||
        upper.contains('MEDIASERVER') ||
        upper.contains('MEDIARENDERER') ||
        upper.contains('AVTRANSPORT') ||
        upper.contains('UPNP:ROOTDEVICE');
  }

  void _sendSsdpSearchResponse(
    RawDatagramSocket socket,
    InternetAddress address,
    int port,
    String localIp,
  ) {
    for (final target in _ssdpTargets) {
      final response = '''
HTTP/1.1 200 OK\r
CACHE-CONTROL: max-age=1800\r
EXT:\r
LOCATION: http://$localIp:7788/description.xml\r
SERVER: Android/14 UPnP/1.0 CoolCast/0.1\r
ST: $target\r
USN: uuid:coolcast-renderer::$target\r
\r
''';
      socket.send(utf8.encode(response), address, port);
    }
  }

  void _sendSsdpNotify(RawDatagramSocket socket, String localIp) {
    for (final target in _ssdpTargets) {
      final notify = '''
NOTIFY * HTTP/1.1\r
HOST: 239.255.255.250:1900\r
CACHE-CONTROL: max-age=1800\r
LOCATION: http://$localIp:7788/description.xml\r
NT: $target\r
NTS: ssdp:alive\r
SERVER: Android/14 UPnP/1.0 CoolCast/0.1\r
USN: uuid:coolcast-renderer::$target\r
\r
''';
      socket.send(
        utf8.encode(notify),
        InternetAddress('239.255.255.250'),
        1900,
      );
    }
  }

  Future<void> _handleAvTransport(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    if (body.contains('SetAVTransportURI')) {
      final url = _extractCurrentUri(body);
      unawaited(_acceptUrl(url, source: 'DLNA/UPnP'));
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('text', 'xml', charset: 'utf-8')
        ..write(_soapResponse('SetAVTransportURIResponse'));
      await request.response.close();
      return;
    }

    if (body.contains('<u:Play') || body.contains(':Play')) {
      unawaited(_play());
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('text', 'xml', charset: 'utf-8')
        ..write(_soapResponse('PlayResponse'));
      await request.response.close();
      return;
    }

    if (body.contains('<u:Pause') || body.contains(':Pause')) {
      unawaited(_pause());
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('text', 'xml', charset: 'utf-8')
        ..write(_soapResponse('PauseResponse'));
      await request.response.close();
      return;
    }

    if (body.contains('<u:Stop') || body.contains(':Stop')) {
      unawaited(_returnToHome());
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('text', 'xml', charset: 'utf-8')
        ..write(_soapResponse('StopResponse'));
      await request.response.close();
      return;
    }

    if (body.contains('GetTransportInfo')) {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('text', 'xml', charset: 'utf-8')
        ..write(_transportInfoResponse(_state));
      await request.response.close();
      return;
    }

    if (body.contains('GetPositionInfo')) {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('text', 'xml', charset: 'utf-8')
        ..write(_positionInfoResponse(_player));
      await request.response.close();
      return;
    }

    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType('text', 'xml', charset: 'utf-8')
      ..write(_soapResponse('AVTransportResponse'));
    await request.response.close();
  }

  String _extractCurrentUri(String body) {
    final match = RegExp(
      r'<CurrentURI>(.*?)</CurrentURI>',
      dotAll: true,
      caseSensitive: false,
    ).firstMatch(body);
    if (match == null) {
      return '';
    }
    return htmlUnescape(match.group(1) ?? '').trim();
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

  Future<void> _acceptUrl(String value, {required String source}) async {
    final parsed = Uri.tryParse(value);
    if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
      setState(() {
        _currentUrl = value;
        _urlController.text = value;
        _state = PlaybackState.failed;
        _lastMessage = value.isEmpty ? '$source 未提供地址' : '$source 地址不可用';
      });
      return;
    }

    final oldPlayer = _player;
    final player = VideoPlayerController.networkUrl(parsed);
    setState(() {
      _currentUrl = value;
      _urlController.text = value;
      _castSource = source;
      _state = PlaybackState.ready;
      _lastMessage = '$source 正在载入';
    });

    try {
      await player.initialize();
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

  Future<void> _returnToHome() async {
    await _player?.pause();
    await _player?.dispose();
    _controlsTimer?.cancel();
    setState(() {
      _player = null;
      _state = PlaybackState.idle;
      _currentUrl = '';
      _castSource = '等待投屏设备';
      _showPlaybackControls = false;
      _lastMessage = kIsWeb ? '可手动输入 URL 调试播放界面' : '正在等待投屏请求';
    });
  }

  Future<void> _seekBy(Duration offset) async {
    final player = _player;
    if (player == null || !player.value.isInitialized) {
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

  void _closeRenameDialog() {
    setState(() => _renameDialogVisible = false);
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
    if (_player != null) {
      await _returnToHome();
      return false;
    }
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

    if (key == LogicalKeyboardKey.arrowLeft && _player != null) {
      unawaited(_seekBy(const Duration(seconds: -10)));
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowRight && _player != null) {
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

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          unawaited(_handleBack());
        }
      },
      child: Focus(
        autofocus: true,
        focusNode: _remoteFocusNode,
        onKeyEvent: _handleRemoteKey,
        child: Scaffold(
          backgroundColor: const Color(0xFFEAF6FF),
          body: isShowingVideo
              ? _PlayingPage(
                  player: _player!,
                  state: _state,
                  source: _castSource,
                  fileName: _displayFileName(_currentUrl),
                  connection: _connectionSummary,
                  showControls: _showPlaybackControls,
                  onBack: _returnToHome,
                  onPlayPause: _state == PlaybackState.playing ? _pause : _play,
                  onRewind: () => _seekBy(const Duration(seconds: -10)),
                  onForward: () => _seekBy(const Duration(seconds: 10)),
                )
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    _HomePage(
                      receiverName: _receiverName,
                      ipAddress: _localIp,
                      receiverAddress: _receiverAddress,
                      status: _lastMessage,
                      controller: _urlController,
                      focusNode: _urlFocusNode,
                      showDebugInput: kIsWeb,
                      onLoad: _loadUrl,
                      onRename: _openRenameDialog,
                    ),
                    if (_renameDialogVisible)
                      _RenameDialog(
                        controller: _renameController,
                        onCancel: _closeRenameDialog,
                        onSave: _saveReceiverName,
                      ),
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
    return 'LAN $_localIp';
  }
}

class _HomePage extends StatelessWidget {
  const _HomePage({
    required this.receiverName,
    required this.ipAddress,
    required this.receiverAddress,
    required this.status,
    required this.controller,
    required this.focusNode,
    required this.showDebugInput,
    required this.onLoad,
    required this.onRename,
  });

  final String receiverName;
  final String ipAddress;
  final String receiverAddress;
  final String status;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool showDebugInput;
  final VoidCallback onLoad;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(44),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            width: 1832,
            height: 992,
            child: Row(
              children: [
                Expanded(
                  flex: 11,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'CoolCast Receiver',
                        style: TextStyle(
                          color: Color(0xFF102033),
                          fontSize: 64,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0,
                        ),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        'Android TV 投屏接收端，保持在线即可自动发现和接收。',
                        style: TextStyle(
                          color: Color(0xFF5B708A),
                          fontSize: 25,
                        ),
                      ),
                      const SizedBox(height: 34),
                      _NetworkCard(ipAddress: ipAddress, status: status),
                      const SizedBox(height: 24),
                      _DeviceNameCard(
                        receiverName: receiverName,
                        onRename: onRename,
                      ),
                      const SizedBox(height: 24),
                      const _CastMethods(),
                      if (showDebugInput) ...[
                        const SizedBox(height: 22),
                        _DebugUrlInput(
                          controller: controller,
                          focusNode: focusNode,
                          onLoad: onLoad,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 44),
                Expanded(
                  flex: 10,
                  child: _WaitingPanel(
                    receiverName: receiverName,
                    receiverAddress: receiverAddress,
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

class _NetworkCard extends StatelessWidget {
  const _NetworkCard({required this.ipAddress, required this.status});

  final String ipAddress;
  final String status;

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      child: Row(
        children: [
          const _SoftIcon(icon: Icons.wifi),
          const SizedBox(width: 22),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '网络连接',
                  style: TextStyle(
                    color: Color(0xFF304761),
                    fontSize: 23,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'SSID: 当前局域网    IP: $ipAddress',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(color: Color(0xFF64748B), fontSize: 20),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          _StatusBadge(text: status),
        ],
      ),
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
      child: Row(
        children: [
          const _SoftIcon(icon: Icons.tv),
          const SizedBox(width: 22),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '设备名称',
                  style: TextStyle(
                    color: Color(0xFF64748B),
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  receiverName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF102033),
                    fontSize: 34,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          FocusableActionDetector(
            child: IconButton.filledTonal(
              onPressed: onRename,
              icon: const Icon(Icons.edit, size: 25),
              tooltip: '修改投屏名称',
            ),
          ),
        ],
      ),
    );
  }
}

class _CastMethods extends StatelessWidget {
  const _CastMethods();

  @override
  Widget build(BuildContext context) {
    const methods = [
      ('AirPlay', Icons.airplay, '媒体投送兼容实验'),
      ('Miracast', Icons.connected_tv, '系统镜像能力预留'),
      ('DLNA / UPnP', Icons.cast_connected, '当前已启用'),
    ];

    return Row(
      children: [
        for (final method in methods) ...[
          Expanded(
            child: _GlassCard(
              compact: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SoftIcon(icon: method.$2, size: 48),
                  const SizedBox(height: 16),
                  Text(
                    method.$1,
                    style: const TextStyle(
                      color: Color(0xFF102033),
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    method.$3,
                    style: const TextStyle(
                      color: Color(0xFF64748B),
                      fontSize: 17,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (method != methods.last) const SizedBox(width: 16),
        ],
      ],
    );
  }
}

class _WaitingPanel extends StatelessWidget {
  const _WaitingPanel(
      {required this.receiverName, required this.receiverAddress});

  final String receiverName;
  final String receiverAddress;

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      fill: const Color(0xDFFFFFFF),
      child: SizedBox.expand(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const _WaitingIllustration(),
            const SizedBox(height: 40),
            Text(
              receiverName,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF102033),
                fontSize: 36,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 18),
            const _WaitingBadge(),
            const SizedBox(height: 26),
            Text(
              receiverAddress,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF3B82F6),
                fontSize: 20,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WaitingIllustration extends StatelessWidget {
  const _WaitingIllustration();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 300,
      height: 230,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 250,
            height: 160,
            decoration: BoxDecoration(
              color: const Color(0xFFFFFFFF),
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: const Color(0xFFB9DDFE), width: 3),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x221E88E5),
                  blurRadius: 34,
                  offset: Offset(0, 16),
                ),
              ],
            ),
            child: const Icon(Icons.tv, color: Color(0xFF4DA3FF), size: 82),
          ),
          Positioned(
            left: 20,
            bottom: 24,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFF4DA3FF),
                borderRadius: BorderRadius.circular(999),
              ),
              child: const Padding(
                padding: EdgeInsets.all(16),
                child: Icon(Icons.cast, color: Colors.white, size: 42),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WaitingBadge extends StatelessWidget {
  const _WaitingBadge();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFE4F4FF),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFB9DDFE)),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 24, vertical: 13),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 11,
              height: 11,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Color(0xFF22C55E),
                  shape: BoxShape.circle,
                ),
              ),
            ),
            SizedBox(width: 12),
            Text(
              '正在等待投屏请求',
              style: TextStyle(
                color: Color(0xFF2563EB),
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
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
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.34)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Center(
          child: SizedBox(
            width: 620,
            child: _GlassCard(
              fill: const Color(0xF7FFFFFF),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '修改投屏名称',
                    style: TextStyle(
                      color: Color(0xFF102033),
                      fontSize: 34,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '这个名称会显示给手机、电脑或其他投屏设备。',
                    style: TextStyle(color: Color(0xFF64748B), fontSize: 20),
                  ),
                  const SizedBox(height: 26),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => onSave(),
                    style: const TextStyle(fontSize: 24),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: '客厅电视',
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '遥控器确认键进入输入，返回键关闭弹窗。',
                    style: TextStyle(color: Color(0xFF94A3B8), fontSize: 16),
                  ),
                  const SizedBox(height: 26),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton(
                        onPressed: onCancel,
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 14),
                      FilledButton(
                        onPressed: onSave,
                        child: const Text('保存'),
                      ),
                    ],
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

class _PlayingPage extends StatelessWidget {
  const _PlayingPage({
    required this.player,
    required this.state,
    required this.source,
    required this.fileName,
    required this.connection,
    required this.showControls,
    required this.onBack,
    required this.onPlayPause,
    required this.onRewind,
    required this.onForward,
  });

  final VideoPlayerController player;
  final PlaybackState state;
  final String source;
  final String fileName;
  final String connection;
  final bool showControls;
  final VoidCallback onBack;
  final VoidCallback onPlayPause;
  final VoidCallback onRewind;
  final VoidCallback onForward;

  @override
  Widget build(BuildContext context) {
    final aspectRatio =
        player.value.aspectRatio == 0 ? 16 / 9 : player.value.aspectRatio;

    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: Colors.black),
        Center(
          child: AspectRatio(
            aspectRatio: aspectRatio,
            child: VideoPlayer(player),
          ),
        ),
        Positioned(
          left: 42,
          top: 38,
          child: _FloatingIconButton(icon: Icons.arrow_back, onPressed: onBack),
        ),
        Positioned(
          right: 42,
          top: 38,
          child: _PlaybackInfoCard(
            source: source,
            fileName: fileName,
            connection: connection,
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
        Positioned.fill(
          child: AnimatedOpacity(
            opacity: showControls ? 1 : 0,
            duration: const Duration(milliseconds: 170),
            child: IgnorePointer(
              ignoring: !showControls,
              child: _PlaybackControlBar(
                player: player,
                state: state,
                onPlayPause: onPlayPause,
                onRewind: onRewind,
                onForward: onForward,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PlaybackInfoCard extends StatelessWidget {
  const _PlaybackInfoCard({
    required this.source,
    required this.fileName,
    required this.connection,
  });

  final String source;
  final String fileName;
  final String connection;

  @override
  Widget build(BuildContext context) {
    return _GlassCard(
      compact: true,
      fill: const Color(0xDFFFFFFF),
      child: SizedBox(
        width: 430,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _InfoLine(label: '投屏来源', value: source),
            const SizedBox(height: 12),
            _InfoLine(label: '播放文件', value: fileName),
            const SizedBox(height: 12),
            _InfoLine(label: '连接速度', value: connection),
          ],
        ),
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 92,
          child: Text(
            label,
            style: const TextStyle(color: Color(0xFF64748B), fontSize: 16),
          ),
        ),
        Expanded(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFF102033),
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _PlaybackControlBar extends StatelessWidget {
  const _PlaybackControlBar({
    required this.player,
    required this.state,
    required this.onPlayPause,
    required this.onRewind,
    required this.onForward,
  });

  final VideoPlayerController player;
  final PlaybackState state;
  final VoidCallback onPlayPause;
  final VoidCallback onRewind;
  final VoidCallback onForward;

  @override
  Widget build(BuildContext context) {
    final value = player.value;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.black.withValues(alpha: 0.68),
          ],
        ),
      ),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(72, 0, 72, 54),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ProgressBar(position: value.position, duration: value.duration),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _FloatingIconButton(
                      icon: Icons.replay_10, onPressed: onRewind),
                  const SizedBox(width: 18),
                  _FloatingIconButton(
                    icon: state == PlaybackState.playing
                        ? Icons.pause
                        : Icons.play_arrow,
                    onPressed: onPlayPause,
                    large: true,
                  ),
                  const SizedBox(width: 18),
                  _FloatingIconButton(
                      icon: Icons.forward_10, onPressed: onForward),
                  const SizedBox(width: 18),
                  _FloatingIconButton(icon: Icons.volume_up, onPressed: () {}),
                  const SizedBox(width: 18),
                  _FloatingIconButton(icon: Icons.more_horiz, onPressed: () {}),
                ],
              ),
            ],
          ),
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
        LinearProgressIndicator(
          value: progress,
          minHeight: 6,
          color: const Color(0xFF73B7FF),
          backgroundColor: Colors.white.withValues(alpha: 0.34),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(_formatDuration(position), style: _playTimeStyle),
            Text(_formatDuration(duration), style: _playTimeStyle),
          ],
        ),
      ],
    );
  }
}

class _FloatingIconButton extends StatelessWidget {
  const _FloatingIconButton({
    required this.icon,
    required this.onPressed,
    this.large = false,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final size = large ? 78.0 : 58.0;
    return SizedBox(
      width: size,
      height: size,
      child: IconButton.filledTonal(
        onPressed: onPressed,
        icon: Icon(icon, size: large ? 36 : 28),
      ),
    );
  }
}

class _GlassCard extends StatelessWidget {
  const _GlassCard({
    required this.child,
    this.compact = false,
    this.fill = const Color(0xCCFFFFFF),
  });

  final Widget child;
  final bool compact;
  final Color fill;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(28),
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
        padding: EdgeInsets.all(compact ? 24 : 30),
        child: child,
      ),
    );
  }
}

class _SoftIcon extends StatelessWidget {
  const _SoftIcon({required this.icon, this.size = 56});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFE4F4FF),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Icon(icon, size: size * 0.54, color: const Color(0xFF2D8CFF)),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFE8FBEF),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Color(0xFF16A34A),
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
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

const TextStyle _playTimeStyle = TextStyle(color: Colors.white, fontSize: 15);

String _htmlForm(String receiverName) {
  return '''
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>CoolCast</title>
  <style>
    body{font-family:system-ui,-apple-system,sans-serif;margin:32px;background:#eaf6ff;color:#102033}
    input,button{font-size:18px;padding:12px;border-radius:12px;border:1px solid #b9ddfe}
    input{box-sizing:border-box;width:100%;margin:16px 0;background:#fff;color:#102033}
    button{background:#4da3ff;color:white;border:0;font-weight:700}
  </style>
</head>
<body>
  <h1>$receiverName</h1>
  <form action="/cast" method="get">
    <input name="url" autofocus placeholder="https://example.com/video.mp4">
    <button type="submit">投送到 CoolCast</button>
  </form>
</body>
</html>
''';
}

String _htmlResponse(String url) {
  return '''
<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"></head>
<body style="font-family:system-ui;margin:32px">
  <h1>已投送到 CoolCast</h1>
  <p>${url.isEmpty ? '未提供视频地址' : url}</p>
  <p><a href="/">继续投送</a></p>
</body>
</html>
''';
}

String _deviceDescription(String ip, String receiverName) {
  return '''
<?xml version="1.0" encoding="utf-8"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion>
    <major>1</major>
    <minor>0</minor>
  </specVersion>
  <URLBase>http://$ip:7788/</URLBase>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>${xmlEscape(receiverName)}</friendlyName>
    <manufacturer>CoolCast</manufacturer>
    <modelName>CoolCast Receiver</modelName>
    <UDN>uuid:coolcast-renderer</UDN>
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
    </serviceList>
  </device>
</root>
''';
}

String _soapResponse(String action) {
  return '''
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
  s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:$action xmlns:u="urn:schemas-upnp-org:service:AVTransport:1" />
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

String _dlnaDuration(Duration duration) {
  final hours = duration.inHours.toString().padLeft(2, '0');
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$hours:$minutes:$seconds';
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
    <action><name>SetAVTransportURI</name></action>
    <action><name>Play</name></action>
    <action><name>Pause</name></action>
    <action><name>Stop</name></action>
    <action><name>Seek</name></action>
    <action><name>GetTransportInfo</name></action>
    <action><name>GetPositionInfo</name></action>
  </actionList>
  <serviceStateTable>
    <stateVariable sendEvents="no"><name>TransportState</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>CurrentURI</name><dataType>string</dataType></stateVariable>
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

String htmlUnescape(String value) {
  return value
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'");
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
];
