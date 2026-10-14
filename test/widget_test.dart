import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:coolcast/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final transparentPng = Uint8List.fromList(const [
    0x89,
    0x50,
    0x4e,
    0x47,
    0x0d,
    0x0a,
    0x1a,
    0x0a,
    0x00,
    0x00,
    0x00,
    0x0d,
    0x49,
    0x48,
    0x44,
    0x52,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    0x01,
    0x08,
    0x06,
    0x00,
    0x00,
    0x00,
    0x1f,
    0x15,
    0xc4,
    0x89,
    0x00,
    0x00,
    0x00,
    0x0a,
    0x49,
    0x44,
    0x41,
    0x54,
    0x78,
    0x9c,
    0x63,
    0x00,
    0x01,
    0x00,
    0x00,
    0x05,
    0x00,
    0x01,
    0x0d,
    0x0a,
    0x2d,
    0xb4,
    0x00,
    0x00,
    0x00,
    0x00,
    0x49,
    0x45,
    0x4e,
    0x44,
    0xae,
    0x42,
    0x60,
    0x82,
  ]);

  testWidgets('shows receiver home screen', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const CoolCastApp());

    final designImage = tester.widget<Image>(
      find.byKey(const ValueKey('waiting-design-background')),
    );
    expect(
      designImage.image,
      isA<AssetImage>().having(
        (image) => image.assetName,
        'asset name',
        'assets/images/coolcast_waiting_16x9_base.png',
      ),
    );
    expect(find.text('CoolCast'), findsOneWidget);
    final receiverNameText = tester.widget<Text>(
      find.byKey(const ValueKey('receiver-name-text')),
    );
    expect(receiverNameText.style?.fontSize, 50);
    expect(find.text('Wi-Fi：当前局域网'), findsOneWidget);
    expect(find.text('IP：TV-IP'), findsOneWidget);
    expect(find.text('发现：未收到搜索'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('waiting-floating-bubbles')), findsOneWidget);
    expect(find.byTooltip('修改投屏名称'), findsOneWidget);
    expect(find.text('预览播放界面'), findsNothing);
  });

  testWidgets('debug preview button is hidden on receiver home screen',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const CoolCastApp());

    expect(find.text('预览播放界面'), findsNothing);
  });

  test('floating bubbles use varied random starting positions', () {
    final first = coolCastRandomBubbleStartsForTest(1);
    final second = coolCastRandomBubbleStartsForTest(2);

    expect(first, isNot(equals(second)));
    expect(first.toSet(), hasLength(first.length));
    for (final position in first) {
      expect(position.dx, inInclusiveRange(420, 1400));
      expect(position.dy, inInclusiveRange(400, 820));
    }
  });

  testWidgets('playing chrome hides with controls',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PlayingPageForTest(showControls: false),
        ),
      ),
    );

    expect(find.text('返回'), findsNothing);
    expect(find.text('投屏来源'), findsNothing);
    expect(find.byTooltip('暂停'), findsNothing);
  });

  testWidgets('playing controls use the simplified toolbar',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PlayingPageForTest(showControls: true),
        ),
      ),
    );

    expect(find.byTooltip('后退 10 秒'), findsOneWidget);
    expect(find.byTooltip('暂停'), findsOneWidget);
    expect(find.byTooltip('前进 10 秒'), findsOneWidget);
    expect(find.byTooltip('后退 30 秒'), findsNothing);
    expect(find.byTooltip('前进 30 秒'), findsNothing);
    expect(find.byTooltip('静音'), findsNothing);
    expect(find.text('1080p'), findsNothing);
    expect(find.text('MP4'), findsNothing);
  });

  testWidgets('playing info card shows DLNA video information',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PlayingPageForTest(
            showControls: true,
            mediaChips: ['1080p', 'MP4', '8.0 Mbps'],
          ),
        ),
      ),
    );

    expect(find.text('1080p'), findsOneWidget);
    expect(find.text('MP4'), findsOneWidget);
    expect(find.text('8.0 Mbps'), findsOneWidget);
  });

  testWidgets('playing page exposes a tap layer for controls',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var taps = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayingPageForTest(
            showControls: false,
            onShowControls: () => taps += 1,
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('playing-page-tap-layer')));
    expect(taps, 1);
  });

  testWidgets('playing page renders cast images', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayingPageForTest(
            showControls: false,
            imageUrl: 'http://example.com/photo.jpg',
            imageBytes: transparentPng,
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('cast-image-surface')), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('返回'), findsNothing);
    expect(find.text('投屏来源'), findsNothing);
    expect(find.byTooltip('暂停'), findsNothing);
  });

  test('image state opens the playing page', () {
    expect(
      coolCastShouldShowPlayingPageForTest(
        isShowingVideo: false,
        isPlayingPreviewVisible: false,
        imageUrl: 'http://example.com/photo.jpg',
      ),
      isTrue,
    );
    expect(
      coolCastShouldShowPlayingPageForTest(
        isShowingVideo: false,
        isPlayingPreviewVisible: false,
        imageBytes: transparentPng,
      ),
      isTrue,
    );
  });

  test('DLNA stop keeps image casts on the playing page', () {
    expect(
      coolCastShouldClearPlayingPageOnDlnaStopForTest(
        imageUrl: 'http://example.com/photo.jpg',
      ),
      isFalse,
    );
    expect(
      coolCastShouldClearPlayingPageOnDlnaStopForTest(
        imageBytes: transparentPng,
      ),
      isFalse,
    );
    expect(coolCastShouldClearPlayingPageOnDlnaStopForTest(), isTrue);
  });

  test('DLNA stop immediately after set URI is deferred', () {
    final now = DateTime(2026, 6, 16, 14, 1, 37, 900);
    expect(
      coolCastShouldDeferDlnaStopAfterSetUriForTest(
        lastSetUriAt: now.subtract(const Duration(milliseconds: 200)),
        now: now,
        currentUrl: '',
        pendingUrl: 'http://192.168.3.172:8197/push-video-item-1000016146',
      ),
      isTrue,
    );
    expect(
      coolCastShouldDeferDlnaStopAfterSetUriForTest(
        lastSetUriAt: now.subtract(const Duration(seconds: 4)),
        now: now,
        currentUrl: '',
        pendingUrl: 'http://192.168.3.172:8197/push-video-item-1000016146',
      ),
      isFalse,
    );
    expect(
      coolCastShouldDeferDlnaStopAfterSetUriForTest(
        lastSetUriAt: now.subtract(const Duration(milliseconds: 200)),
        now: now,
        currentUrl: 'http://example.com/other.mp4',
        pendingUrl: 'http://192.168.3.172:8197/push-video-item-1000016146',
      ),
      isFalse,
    );
  });

  test('image cache failure reporting ignores stale requests', () {
    expect(
      coolCastShouldReportImageLoadFailureForTest(
        requestId: 3,
        activeRequestId: 3,
        requestUrl: 'http://example.com/latest.jpg',
        currentImageUrl: 'http://example.com/latest.jpg',
      ),
      isTrue,
    );
    expect(
      coolCastShouldReportImageLoadFailureForTest(
        requestId: 2,
        activeRequestId: 3,
        requestUrl: 'http://example.com/old.jpg',
        currentImageUrl: 'http://example.com/latest.jpg',
      ),
      isFalse,
    );
  });

  testWidgets('first back on home asks for a second back',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const CoolCastApp());
    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(find.text('再次按返回退出 CoolCast'), findsOneWidget);
  });

  test('default receiver name includes Android device name', () {
    expect(coolCastReceiverNameForDeviceForTest('Mi 10'), 'CoolCast - Mi 10');
    expect(
      coolCastReceiverNameForDeviceForTest('  Mi   Pad 4  '),
      'CoolCast - Mi Pad 4',
    );
    expect(
        coolCastReceiverNameForDeviceForTest('CoolCast - 客厅'), 'CoolCast - 客厅');
    expect(coolCastReceiverNameForDeviceForTest('unknown'), 'CoolCast');
    expect(coolCastReceiverNameForDeviceForTest(null), 'CoolCast');
  });

  test('native playback channel sends URL, headers, and controls', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(coolCastNativePlayerChannelForTest, (call) {
      calls.add(call);
      if (call.method == 'position') {
        return Future<Object?>.value(12 * 1000);
      }
      if (call.method == 'duration') {
        return Future<Object?>.value(98 * 1000);
      }
      if (call.method == 'videoSize') {
        return Future<Object?>.value({'width': 1920, 'height': 1080});
      }
      if (call.method == 'videoBitrate') {
        return Future<Object?>.value(500000);
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(coolCastNativePlayerChannelForTest, null);
    });

    await coolCastNativePlayerPlayForTest(
      'https://example.com/video.mp4',
      headers: {'Referer': 'https://www.bilibili.com'},
      initialPosition: const Duration(seconds: 7),
    );
    await coolCastNativePlayerPauseForTest();
    await coolCastNativePlayerSeekToForTest(const Duration(seconds: 34));

    expect(calls[0].method, 'play');
    expect(calls[0].arguments, {
      'url': 'https://example.com/video.mp4',
      'headers': {'Referer': 'https://www.bilibili.com'},
      'initialPositionMs': 7000,
    });
    expect(calls[1].method, 'pause');
    expect(calls[2].method, 'seekTo');
    expect(calls[2].arguments, {'positionMs': 34000});
    expect(await coolCastNativePlayerPositionForTest(),
        const Duration(seconds: 12));
    expect(await coolCastNativePlayerDurationForTest(),
        const Duration(seconds: 98));
    expect(
        await coolCastNativePlayerVideoSizeForTest(), const Size(1920, 1080));
    expect(await coolCastNativePlayerVideoBitrateForTest(), 500000);
  });

  test('playing page can render native Android video surface', () {
    final widget = coolCastNativeVideoSurfaceForTest();

    expect(widget.viewType, 'coolcast/native_player');
  });

  test('DLNA position response reports current video progress and URI', () {
    final response = coolCastPositionInfoResponseForTest(
      position: const Duration(seconds: 7),
      duration: const Duration(seconds: 98),
      currentUrl: 'http://192.168.3.172:8197/push-video-item-1000016146',
    );

    expect(response, contains('<TrackDuration>00:01:38</TrackDuration>'));
    expect(response, contains('<RelTime>00:00:07</RelTime>'));
    expect(response, contains('<AbsTime>00:00:07</AbsTime>'));
    expect(
      response,
      contains(
        '<TrackURI>http://192.168.3.172:8197/'
        'push-video-item-1000016146</TrackURI>',
      ),
    );
  });

  test('DLNA description exposes required renderer services', () {
    final description = coolCastDeviceDescriptionForTest(
      '192.168.1.18',
      '客厅电视 & CoolCast',
    );

    expect(
        description, contains('urn:schemas-upnp-org:device:MediaRenderer:1'));
    expect(description, contains('客厅电视 &amp; CoolCast'));
    expect(description, contains('urn:schemas-upnp-org:service:AVTransport:1'));
    expect(description,
        isNot(contains('urn:schemas-upnp-org:service:AVTransport:*')));
    expect(
      description,
      contains('urn:app-bilibili-com:service:NirvanaControl:3'),
    );
    expect(
      description,
      contains('urn:schemas-upnp-org:service:NirvanaControl:3'),
    );
    expect(
      description,
      isNot(contains('urn:app-bilibili-com:service:NirvanaControl:*')),
    );
    expect(
      description,
      contains('urn:app-bilibili-com:serviceId:NirvanaControl'),
    );
    expect(description, contains('/NirvanaControl/scpd.xml'));
    expect(
      description,
      contains('urn:schemas-upnp-org:service:RenderingControl:1'),
    );
    expect(
      description,
      contains('urn:schemas-upnp-org:service:ConnectionManager:1'),
    );
    expect(description, contains('/ConnectionManager/control'));
    expect(description, contains('/ConnectionManager/scpd.xml'));
  });

  test('DLNA description exposes Bilibili official projection identity', () {
    final description = coolCastDeviceDescriptionForTest(
      '192.168.1.18',
      '客厅电视 & CoolCast',
    );

    expect(
      description,
      contains('<friendlyName>客厅电视 &amp; CoolCast</friendlyName>'),
    );
    expect(description, contains('<manufacturer>bilibili</manufacturer>'));
    expect(description, contains('<X_brandName>bilibili</X_brandName>'));
    expect(description, contains('<modelName>云视听小电视</modelName>'));
    expect(description, contains('<ottVersion>104800</ottVersion>'));
    expect(description, contains('<channelName>bilibili</channelName>'));
    expect(
      description,
      contains('<autoPullId>coolcast-tv-main</autoPullId>'),
    );
    expect(description, contains('<capability>1</capability>'));
    expect(description, isNot(contains('<brandName>')));
    expect(description, isNot(contains('<hostVersion>')));
    expect(description, isNot(contains('<needNvaExtra>')));
    expect(description, isNot(contains('<bili:')));
  });

  test('HTTP cast pages distinguish success from invalid URLs', () {
    final form = coolCastHtmlFormForTest(
      receiverName: '客厅电视',
      ipAddress: '192.168.1.18',
      message: '正在等待投屏请求',
    );
    final success = coolCastHtmlResponseForTest(
      'https://example.com/movie.mp4',
      isAccepted: true,
    );
    final failure = coolCastHtmlResponseForTest('', isAccepted: false);

    expect(form, contains('客厅电视'));
    expect(form, contains('http://192.168.1.18:7788/cast?url='));
    expect(form, contains('正在等待投屏请求'));
    expect(success, contains('已开始投送到 CoolCast'));
    expect(success, contains('https://example.com/movie.mp4'));
    expect(failure, contains('视频地址不可用'));
    expect(failure, contains('继续投送'));
  });

  test('SOAP helpers use the matching service namespace', () {
    final rendering = coolCastSoapResponseForTest(
      'GetVolumeResponse',
      service: CoolCastUpnpService.renderingControl,
      body: '<CurrentVolume>50</CurrentVolume>',
    );
    final connection = coolCastSoapResponseForTest(
      'GetProtocolInfoResponse',
      service: CoolCastUpnpService.connectionManager,
      body: '<Source></Source><Sink>http-get:*:video/mp4:*</Sink>',
    );

    expect(
      rendering,
      contains('urn:schemas-upnp-org:service:RenderingControl:1'),
    );
    expect(rendering, contains('<CurrentVolume>50</CurrentVolume>'));
    expect(
      connection,
      contains('urn:schemas-upnp-org:service:ConnectionManager:1'),
    );
    expect(connection, contains('http-get:*:video/mp4:*'));
  });

  test('AVTransport SCPD declares Bilibili Nirvana set URI arguments', () {
    final scpd = coolCastAvTransportScpdForTest();

    expect(scpd, contains('<name>SetAVTransportURI</name>'));
    expect(scpd, contains('<name>CurrentURI</name>'));
    expect(scpd, contains('<name>CurrentURIMetaData</name>'));
    expect(scpd, contains('<name>SourceId</name>'));
    expect(scpd, contains('<name>ExtendData</name>'));
    expect(scpd, contains('<name>GetDeviceCapabilities</name>'));
    expect(scpd, contains('<name>GetTransportSettings</name>'));
    expect(scpd, contains('<name>GetCurrentTransportActions</name>'));
    expect(scpd, contains('<name>SetPlayMode</name>'));
    expect(scpd, contains('<name>Next</name>'));
    expect(scpd, contains('<name>Previous</name>'));
    expect(
        scpd,
        contains(
            '<relatedStateVariable>AVTransportURI</relatedStateVariable>'));
    expect(
        scpd,
        contains(
            '<relatedStateVariable>AVTransportURIMetaData</relatedStateVariable>'));
  });

  test('NirvanaControl SCPD declares NVA link address action', () {
    final scpd = coolCastNirvanaControlScpdForTest();

    expect(scpd, contains('<name>GetNvaLinkAddress</name>'));
    expect(scpd, contains('<name>NvaLinkAddress</name>'));
    expect(scpd, contains('<direction>out</direction>'));
    expect(scpd, contains('<name>A_ARG_TYPE_NvaLinkAddress</name>'));
    expect(scpd, contains('<name>GetAppInfo</name>'));
    expect(scpd, contains('<name>GetPlayInfo</name>'));
    expect(scpd, contains('<name>GetAccountInfo</name>'));
    expect(scpd, contains('<name>PrepareForMirrorProjection</name>'));
    expect(scpd, contains('<name>A_ARG_TYPE_UnlimitedString</name>'));
  });

  test('ConnectionManager SCPD declares protocol info arguments', () {
    final scpd = coolCastConnectionManagerScpdForTest();

    expect(scpd, contains('<name>GetProtocolInfo</name>'));
    expect(scpd, contains('<name>Source</name>'));
    expect(scpd, contains('<name>Sink</name>'));
    expect(
      scpd,
      contains(
          '<relatedStateVariable>SourceProtocolInfo</relatedStateVariable>'),
    );
    expect(
      scpd,
      contains('<relatedStateVariable>SinkProtocolInfo</relatedStateVariable>'),
    );
  });

  test('DLNA metadata parser extracts title and MIME type', () {
    final info = coolCastMediaInfoFromMetadataForTest('''
<DIDL-Lite>
  <item>
    <dc:title>测试视频 &amp; 片段</dc:title>
    <res protocolInfo="http-get:*:video/mp4:DLNA.ORG_OP=01"
         resolution="1920x1080" bitrate="1000000">
      http://example.com/video.mp4
    </res>
  </item>
</DIDL-Lite>
''');

    expect(info.title, '测试视频 & 片段');
    expect(info.mimeType, 'video/mp4');
    expect(info.resolution, '1920x1080');
    expect(info.bitrate, 1000000);
    expect(info.isImage, isFalse);
  });

  test('DLNA metadata parser identifies images', () {
    final info = coolCastMediaInfoFromMetadataForTest('''
<DIDL-Lite>
  <item>
    <dc:title>测试图片</dc:title>
    <res protocolInfo="http-get:*:image/jpeg:*">
      http://example.com/photo.jpg
    </res>
  </item>
</DIDL-Lite>
''');

    expect(info.title, '测试图片');
    expect(info.mimeType, 'image/jpeg');
    expect(info.isImage, isTrue);
  });

  test('duplicate DLNA SetURI for the active URL should not reload player', () {
    const url = 'http://192.168.3.172:8197/push-video-item-1000016146';

    expect(
      coolCastShouldReloadDlnaSetUriForTest(
        incomingUrl: url,
        currentUrl: url,
        pendingUrl: url,
        isLoadingUrl: false,
        hasActivePlayer: true,
      ),
      isFalse,
    );
    expect(
      coolCastShouldReloadDlnaSetUriForTest(
        incomingUrl: url,
        currentUrl: '',
        pendingUrl: url,
        isLoadingUrl: true,
        hasActivePlayer: false,
      ),
      isFalse,
    );
    expect(
      coolCastShouldReloadDlnaSetUriForTest(
        incomingUrl: 'http://192.168.3.172:8197/push-video-item-1000016147',
        currentUrl: url,
        pendingUrl: url,
        isLoadingUrl: false,
        hasActivePlayer: true,
      ),
      isTrue,
    );
  });

  test('image metadata identifies extensionless push URLs', () {
    final info = coolCastMediaInfoFromMetadataForTest('''
<DIDL-Lite>
  <item>
    <res protocolInfo="http-get:*:image/jpeg:*">
      http://192.168.3.172:8197/push-image-item-1000001310
    </res>
  </item>
</DIDL-Lite>
''');
    final chips = coolCastMediaChipsForTest(
      currentUrl: 'http://192.168.3.172:8197/push-image-item-1000001310',
      mimeType: info.mimeType,
      state: PlaybackState.playing,
    );

    expect(info.isImage, isTrue);
    expect(chips, contains('JPEG'));
  });

  test('media chips expose useful cast diagnostics without fake quality', () {
    final chips = coolCastMediaChipsForTest(
      currentUrl: 'https://upos-sz-mirror.bilivideo.com/video.m4s?qn=80',
      mimeType: 'video/mp4',
      state: PlaybackState.playing,
    );

    expect(chips, contains('QN 80'));
    expect(chips, contains('MP4'));
    expect(chips, contains('播放中'));
    expect(chips, isNot(contains('4K HDR')));
  });

  test('media chips use DLNA resolution and bitrate metadata', () {
    final chips = coolCastMediaChipsForTest(
      currentUrl: 'http://example.com/video',
      mimeType: 'video/mp4',
      state: PlaybackState.playing,
      metadataResolution: '1920x1080',
      metadataBitrate: 1000000,
    );

    expect(chips, contains('1080p'));
    expect(chips, contains('MP4'));
    expect(chips, contains('8.0 Mbps'));
    expect(chips, contains('播放中'));
  });

  test('media chips show Bilibili qn separately from decoded resolution', () {
    final chips = coolCastMediaChipsForTest(
      currentUrl: 'https://upos-sz-mirror.bilivideo.com/video.m4s',
      mimeType: 'video/mp4',
      state: PlaybackState.playing,
      videoSize: const Size(3840, 2160),
      biliQuality: 32,
    );

    expect(chips.first, 'B站 480P 清晰');
    expect(chips, contains('4K'));
    expect(chips, contains('MP4'));
  });

  test('ConnectionManager announces common DLNA video sinks', () {
    final response = coolCastProtocolInfoResponseForTest();

    expect(response, contains('http-get:*:video/mp4:DLNA.ORG_OP=01'));
    expect(response, contains('http-get:*:video/x-flv:*'));
    expect(response, contains('http-get:*:application/octet-stream:*'));
    expect(response, contains('http-get:*:application/vnd.apple.mpegurl:*'));
    expect(response, contains('http-get:*:video/vnd.dlna.mpeg-tts:*'));
    expect(response, contains('http-get:*:application/dash+xml:*'));
  });

  test('UPnP HTTP responses expose receiver server headers', () {
    final headers = coolCastUpnpResponseHeadersForTest();

    expect(headers['SERVER'], contains('UPnP/1.0'));
    expect(headers['SERVER'], contains('BiliTV'));
    expect(headers['CACHE-CONTROL'], 'max-age=900');
    expect(headers['EXT'], '');
  });

  test('DLNA renderer extra probe path is handled as a normal descriptor', () {
    expect(coolCastNormalizeHttpPathForTest('//dlna/Render/dmr_extra.xml'),
        '/dlna/Render/dmr_extra.xml');
    expect(coolCastNormalizeHttpUriPathForTest('//dlna/Render/dmr_extra.xml'),
        '/dlna/Render/dmr_extra.xml');
    expect(
        coolCastIsDlnaRendererExtraPathForTest('//dlna/Render/dmr_extra.xml'),
        isTrue);

    final extra = coolCastDlnaRendererExtraXmlForTest();
    expect(extra, startsWith('<?xml'));
    expect(extra, contains('<friendlyName>CoolCast</friendlyName>'));
  });

  test('SSDP packets start with strict HTTPU request lines', () {
    final searchResponse = coolCastSsdpSearchResponseForTest(
      localIp: '192.168.1.18',
      target: 'urn:schemas-upnp-org:device:MediaRenderer:1',
    );
    final notify = coolCastSsdpNotifyForTest(
      localIp: '192.168.1.18',
      target: 'urn:schemas-upnp-org:device:MediaRenderer:1',
    );

    expect(searchResponse, startsWith('HTTP/1.1 200 OK\r\n'));
    expect(notify, startsWith('NOTIFY * HTTP/1.1\r\n'));
    expect(
      searchResponse,
      contains('LOCATION: http://192.168.1.18:7788/bilibili/description.xml'),
    );
    expect(
      notify,
      contains('LOCATION: http://192.168.1.18:7788/bilibili/description.xml'),
    );
    expect(searchResponse, endsWith('\r\n\r\n'));
    expect(notify, endsWith('\r\n\r\n'));
    expect(searchResponse, contains('CACHE-CONTROL: max-age=900\r\n'));
    expect(notify, contains('CACHE-CONTROL: max-age=900\r\n'));
    expect(coolCastSsdpStartupNotifyBurstSecondsForTest(),
        [0, 1, 2, 3, 5, 8, 12, 18, 25, 35, 50, 70]);
    expect(coolCastSsdpNotifyIntervalSecondsForTest(), 5);
  });

  test('SSDP search responses match requested ST without flooding clients', () {
    final rendererResponses = coolCastSsdpSearchResponsesForTest(
      localIp: '192.168.1.18',
      searchMessage: '''
M-SEARCH * HTTP/1.1
HOST: 239.255.255.250:1900
MAN: "ssdp:discover"
MX: 1
ST: urn:schemas-upnp-org:device:MediaRenderer:1

''',
    );
    final allResponses = coolCastSsdpSearchResponsesForTest(
      localIp: '192.168.1.18',
      searchMessage: '''
M-SEARCH * HTTP/1.1
HOST: 239.255.255.250:1900
MAN: "ssdp:discover"
MX: 1
ST: ssdp:all

''',
    );

    expect(rendererResponses, hasLength(1));
    expect(rendererResponses.single,
        contains('ST: urn:schemas-upnp-org:device:MediaRenderer:1'));
    expect(rendererResponses.single,
        isNot(contains('ST: urn:schemas-upnp-org:service:AVTransport:1')));
    expect(allResponses.length, greaterThan(rendererResponses.length));
  });

  test('SSDP advertises Bilibili NirvanaControl target', () {
    for (final target in const [
      'urn:schemas-upnp-org:service:NirvanaControl:3',
      'urn:app-bilibili-com:service:NirvanaControl:3',
    ]) {
      final response = coolCastSsdpSearchResponseForTest(
        localIp: '192.168.1.18',
        target: target,
      );

      expect(response, contains('ST: $target'));
      expect(response, contains('USN: uuid:coolcast-tv-main::$target'));
    }
  });

  test('OttBlink search packets are recognized by their binary header', () {
    expect(
      coolCastIsOttBlinkSearchForTest(
        Uint8List.fromList([0x24, 0x10, 0x01, 0x00, 0x00, 0x00]),
      ),
      isTrue,
    );
    expect(
      coolCastIsOttBlinkSearchForTest(
        Uint8List.fromList([0x24, 0x11, 0x01, 0x00, 0x00, 0x00]),
      ),
      isFalse,
    );
    expect(
      coolCastIsOttBlinkSearchForTest(Uint8List.fromList([0x24, 0x10])),
      isFalse,
    );
  });

  test('OttBlink response exposes Bilibili official projection identity', () {
    final response = coolCastOttBlinkResponseForTest('客厅电视 & CoolCast');

    expect(response[0], 0x24);
    expect(response[1], 0x11);

    final jsonLength =
        response[2] | response[3] << 8 | response[4] << 16 | response[5] << 24;
    final payload = response.sublist(6);
    final json = jsonDecode(utf8.decode(payload)) as Map<String, Object?>;

    expect(jsonLength, payload.length);
    expect(json['address'], 'android_bilithings');
    expect(json['uuid'], 'coolcast-tv-main');
    expect(json['friendlyName'], '客厅电视 & CoolCast');
    expect(json['model_name'], '云视听小电视');
    expect(json['brand_name'], 'bilibili');
    expect(json['manufacture'], 'bilibili');
    expect(json['brandName'], 'bilibili');
    expect(json['manufacturer'], 'bilibili');
    expect(json['channelName'], 'bilibili');
    expect(json['mobiApp'], 'android_bilithings');
    expect(json['build'], 104800);
    expect(json['version'], 104800);
    expect(json['ottVersion'], 104800);
    expect(json['support4k'], isTrue);
    expect(json['fourk'], 1);
    expect(json['capability'], 1);
    expect(json['castService'], 'urn:schemas-upnp-org:service:AVTransport:1');
    expect(json['needNvaExtra'], isTrue);
    expect(json['ignoreDirect'], isTrue);
    expect(json['autoPullId'], 'coolcast-tv-main');
  });

  test('Nirvana control payload extracts playable URL from JSON', () {
    final playUrl = coolCastNirvanaControlUrlForTest('''
{"action":"PlayUrl","payload":{"url":"https://upos.example.com/video.m4s?qn=120","title":"测试片段"}}
''');
    final nestedUrl = coolCastNirvanaControlUrlForTest('''
{"url":"{\\"url\\":\\"https://upos.example.com/nested.mp4\\"}"}
''');

    expect(playUrl, 'https://upos.example.com/video.m4s?qn=120');
    expect(nestedUrl, 'https://upos.example.com/nested.mp4');
    expect(coolCastNirvanaControlUrlForTest('{"action":"Pause"}'), isNull);
  });

  test('Bilibili NVA extension parser supports plain and encrypted payloads',
      () {
    final nva = <String, Object?>{
      'qn': 120,
      'userDesireQn': 120,
      'ignore_direct': true,
      'nl': {
        'cb': 'http://127.0.0.1:7788/link-callback',
        'cd': 'link-code-1',
      },
    };
    final plainUri = Uri(
      scheme: 'https',
      host: 'example.com',
      path: '/play',
      queryParameters: {
        'nva_ext': jsonEncode({'content': nva}),
      },
    ).toString();
    final encryptedUri = Uri(
      scheme: 'https',
      host: 'example.com',
      path: '/play',
      queryParameters: {
        '_nva_ext_': coolCastEncryptBiliNvaExtForTest(nva),
      },
    ).toString();

    final plain = coolCastBiliNvaExtForTest(plainUri);
    final encrypted = coolCastBiliNvaExtForTest(encryptedUri);

    for (final parsed in [plain, encrypted]) {
      expect(parsed, isNotNull);
      expect(parsed!['qn'], 120);
      expect(parsed['userDesireQn'], 120);
      expect(parsed['ignore_direct'], isTrue);
      expect(parsed['nl'], {
        'cb': 'http://127.0.0.1:7788/link-callback',
        'cd': 'link-code-1',
      });
    }
  });

  test('Bilibili NVA link reply exposes callback device fields', () {
    final encryptedReply = coolCastBiliNvaLinkReplyForTest(
      localAddress: '192.168.50.8',
      code: 'link-code-1',
    );
    final reply = jsonDecode(
      coolCastDecryptBiliNvaJsonForTest(encryptedReply)!,
    ) as Map<String, Object?>;

    expect(reply['code'], 'link-code-1');
    expect(reply['from'], 'coolcast');
    expect(reply['buvid'], 'coolcast-tv-main');
    expect(reply['nvaLinkAddress'], '192.168.50.8:9958');
    expect(reply['friendlyName'], 'CoolCast');
    expect(reply['modelName'], '云视听小电视');
    expect(reply['brandName'], 'bilibili');
    expect(reply['manufacturer'], 'bilibili');
    expect(reply['ottVersion'], 104800);
    expect(reply['ignoreDirect'], isTrue);
    expect(reply['autoPullId'], 'coolcast-tv-main');
  });

  test('Nirvana probe acknowledgement echoes official projection features', () {
    final ack =
        jsonDecode(coolCastNirvanaProbeAckForTest()) as Map<String, Object?>;
    final device = ack['device'] as Map<String, Object?>;

    expect(ack['code'], 0);
    expect(ack['status'], 'ok');
    expect(ack['from'], 'coolcast');
    expect(ack['buvid'], 'coolcast-tv-main');
    expect(ack['nvaLinkAddress'], 'coolcast-tv-main:9958');
    expect(ack['modelName'], '云视听小电视');
    expect(ack['brandName'], 'bilibili');
    expect(ack['manufacturer'], 'bilibili');
    expect(ack['ottVersion'], 104800);
    expect(ack['support4k'], isTrue);
    expect(ack['capability'], 1);
    expect(ack['castService'], 'urn:schemas-upnp-org:service:AVTransport:1');
    expect(ack['needNvaExtra'], isTrue);
    expect(ack['ignoreDirect'], isTrue);
    expect(ack['autoPullId'], 'coolcast-tv-main');
    expect(device['friendlyName'], 'CoolCast');
    expect(device['model_name'], '云视听小电视');
    expect(device['brandName'], 'bilibili');
    expect(device['manufacturer'], 'bilibili');
    expect(device['support4k'], isTrue);
    expect(device['needNvaExtra'], isTrue);
  });

  test('Nirvana control summary keeps TCP diagnostics compact', () {
    final summary = coolCastNirvanaControlSummaryForTest(
      Uint8List.fromList(utf8
          .encode('{"action":"PlayUrl","url":"https://example.com/a.mp4"}')),
    );
    final binary = coolCastNirvanaControlSummaryForTest(
      Uint8List.fromList([0x00, 0x01, 0xff, 0x24]),
    );
    final nativePlayUrl = coolCastNirvanaControlSummaryForTest(
      Uint8List.fromList([
        0x00,
        ...utf8.encode('Command'),
        0x00,
        ...utf8.encode('PlayUrl'),
        0x00,
        ...utf8.encode('{"url":"https://example.com/b.m4s","qn":120}'),
      ]),
    );

    expect(summary, contains('PlayUrl'));
    expect(summary.length, lessThanOrEqualTo(180));
    expect(binary, startsWith('hex '));
    expect(nativePlayUrl, contains('native'));
    expect(nativePlayUrl, contains('Command'));
    expect(nativePlayUrl, contains('PlayUrl'));
    expect(nativePlayUrl, contains('qn'));
  });

  test('Nirvana long-link parser distinguishes text and native frames', () {
    expect(
      coolCastLooksLikeTextNirvanaPayloadForTest(
        Uint8List.fromList(utf8.encode('{"action":"Play"}')),
      ),
      isTrue,
    );
    expect(
      coolCastLooksLikeTextNirvanaPayloadForTest(
        Uint8List.fromList(utf8.encode('SETUP /projection NVA/1.0\r\n\r\n')),
      ),
      isTrue,
    );
    expect(
      coolCastLooksLikeTextNirvanaPayloadForTest(
        Uint8List.fromList(
          utf8.encode('RESTORE /projection NVA/1.0\r\n\r\n'),
        ),
      ),
      isTrue,
    );
    expect(
      coolCastLooksLikeTextNirvanaPayloadForTest(
        Uint8List.fromList([0x00, 0x01, 0xff, 0x24]),
      ),
      isFalse,
    );
  });

  test('Nirvana long-link only sends JSON ack for text probes', () {
    expect(
      coolCastShouldSendNirvanaTextAckForTest(
        Uint8List.fromList(utf8.encode('{"action":"Probe"}')),
      ),
      isTrue,
    );
    expect(
      coolCastShouldSendNirvanaTextAckForTest(
        Uint8List.fromList(utf8.encode('GET / HTTP/1.1\r\n\r\n')),
      ),
      isTrue,
    );
    expect(
      coolCastShouldSendNirvanaTextAckForTest(
        Uint8List.fromList(utf8.encode('SETUP /projection NVA/1.0\r\n\r\n')),
      ),
      isTrue,
    );
    expect(
      coolCastLooksLikeCompleteNirvanaPayloadForTest(
        Uint8List.fromList(utf8.encode(
          'SETUP /projection NVA/1.0\r\n'
          'Session: abc\r\n'
          'NvaVersion: 1\r\n'
          'UUID: Y123\r\n',
        )),
      ),
      isTrue,
    );
    final setupAck = coolCastNirvanaTextAckForTest(
      Uint8List.fromList(utf8.encode(
        'SETUP /projection NVA/1.0\r\nSession: abc\r\nUUID: Y123\r\n\r\n',
      )),
      localAddress: '192.168.50.8',
    );
    expect(
      setupAck,
      allOf(
        startsWith('NVA/1.0 200 OK\r\n'),
        contains('NvaVersion: 1'),
        contains('UUID: Y123'),
        contains('Connection: Keep-Alive'),
        contains('Content-Length: 0'),
        isNot(contains('Content-Type: application/json')),
        isNot(contains('"nvaLinkAddress":"192.168.50.8:9958"')),
      ),
    );
    expect(setupAck, contains('Date: '));
    expect(setupAck, contains('Server: Android/14 UPnP/1.0 BiliTV/104800'));
    expect(setupAck, isNot(contains('Device-ID')));
    expect(
      coolCastNirvanaTextAckForTest(
        Uint8List.fromList(utf8.encode(
          'RESTORE /projection NVA/1.0\r\nSession: abc\r\nUUID: Y123\r\n\r\n',
        )),
      ),
      startsWith('NVA/1.0 200 OK\r\n'),
    );
    final ping = coolCastNirvanaPingFrameForTest(7);
    expect(ping, hasLength(11));
    expect(ping[0], 0xe4);
    expect(ping[1], 0x01);
    expect(ByteData.view(ping.buffer).getUint32(2), 7);
    expect(ping[6], 0x00);
    expect(ByteData.view(ping.buffer).getUint32(7), 0);
    expect(
      coolCastNirvanaControlSummaryForTest(ping),
      contains('native heartbeat seq=7 op=0xe401 len=0'),
    );
    final shortControl =
        Uint8List.fromList([0xc0, 0x00, 0x00, 0x00, 0x03, 0xec]);
    expect(coolCastNirvanaFrameLengthForTest(shortControl), 6);
    expect(
      coolCastNirvanaControlSummaryForTest(shortControl),
      'native control seq=1004 op=0xc000',
    );
    final heartbeatRequest = Uint8List(11);
    ByteData.view(heartbeatRequest.buffer).setUint16(0, 0xe400);
    ByteData.view(heartbeatRequest.buffer).setUint32(2, 8);
    final heartbeatResponse =
        coolCastNirvanaFrameResponseForTest(heartbeatRequest);
    expect(heartbeatResponse, isNotNull);
    expect(ByteData.view(heartbeatResponse!.buffer).getUint16(0), 0xe401);
    expect(ByteData.view(heartbeatResponse.buffer).getUint32(2), 8);
    expect(coolCastNirvanaFrameResponseForTest(ping), isNull);
    expect(coolCastShouldSendNirvanaTextAckForTest(Uint8List(0)), isFalse);
    expect(
      coolCastShouldSendNirvanaTextAckForTest(
        Uint8List.fromList([
          0x00,
          ...utf8.encode('Command'),
          0x00,
          ...utf8.encode('PlayUrl'),
        ]),
      ),
      isFalse,
    );
  });

  test('Nirvana parser consumes short control frames before SwitchQn', () {
    final control = Uint8List.fromList([0xc0, 0x00, 0x00, 0x00, 0x03, 0xec]);
    final switchQn = coolCastNvaRequestFrameForTest(
      4,
      {'Command': 'SwitchQn'},
      '{"qn":80}',
    );
    final combined = Uint8List.fromList([...control, ...switchQn]);

    final firstLength = coolCastNirvanaFrameLengthForTest(combined);
    expect(firstLength, 6);
    final secondLength = coolCastNirvanaFrameLengthForTest(
      Uint8List.sublistView(combined, firstLength!),
    );
    expect(secondLength, switchQn.length);

    final parsed = coolCastNvaFrameForTest(
      Uint8List.sublistView(combined, firstLength),
    );
    expect(parsed, isNotNull);
    expect(parsed!['attributes'], {'Command': 'SwitchQn'});
    expect(parsed['body'], '{"qn":80}');

    final response = coolCastNirvanaFrameResponseForTest(
      Uint8List.sublistView(combined, firstLength),
    );
    expect(response, Uint8List.fromList([0xc0, 0x00, 0x00, 0x00, 0x00, 0x04]));
    expect(
      coolCastNirvanaControlSummaryForTest(response!),
      'native control seq=4 op=0xc000',
    );
  });

  test('Nirvana native frame parser reads command attributes and replies', () {
    final request = coolCastNvaRequestFrameForTest(
      42,
      {'Command': 'PlayUrl'},
      '{"url":"https://upos.example.com/video.m4s","title":"片段"}',
    );
    final parsed = coolCastNvaFrameForTest(request);

    expect(parsed, isNotNull);
    expect(parsed!['op'], 0xe003);
    expect(parsed['seq'], 42);
    expect(parsed['isRequest'], isTrue);
    expect(parsed['attributes'], {'Command': 'PlayUrl'});
    expect(parsed['body'], contains('upos.example.com/video.m4s'));
    expect(
      coolCastNirvanaControlSummaryForTest(request),
      contains('Command=PlayUrl'),
    );

    final response = coolCastNirvanaFrameResponseForTest(request);
    expect(
      response,
      Uint8List.fromList([0xc0, 0x00, 0x00, 0x00, 0x00, 0x2a]),
    );
    expect(
      coolCastNirvanaControlSummaryForTest(response!),
      'native control seq=42 op=0xc000',
    );
  });

  test('Nirvana native frame parser matches captured Play frame format', () {
    final play = coolCastNvaRequestFrameForTest(
      1,
      {'Command': 'Play'},
      '{"aid":116621666555985,"cid":26016292374}',
    );
    final getTvInfo = coolCastNvaEmptyRequestFrameForTest(
      2,
      {'Command': 'GetTvInfo'},
    );
    final getVolume = coolCastNvaEmptyRequestFrameForTest(
      3,
      {'Command': 'GetVolume'},
    );
    final combined = Uint8List.fromList([...play, ...getTvInfo, ...getVolume]);

    expect(ByteData.view(play.buffer).getUint16(0), 0xe003);
    expect(play[6], 1);
    expect(play[7], 'Command'.length);
    expect(play[15], 'Play'.length);
    expect(ByteData.view(getTvInfo.buffer).getUint16(0), 0xe002);
    expect(getTvInfo.length, 25);
    expect(ByteData.view(getVolume.buffer).getUint16(0), 0xe002);
    expect(getVolume.length, 25);

    final parsedPlay = coolCastNvaFrameForTest(
      Uint8List.sublistView(combined, 0, play.length),
    );
    final parsedTvInfo = coolCastNvaFrameForTest(
      Uint8List.sublistView(
          combined, play.length, play.length + getTvInfo.length),
    );
    final parsedVolume = coolCastNvaFrameForTest(
      Uint8List.sublistView(combined, play.length + getTvInfo.length),
    );

    expect(parsedPlay, isNotNull);
    expect(parsedPlay!['op'], 0xe003);
    expect(parsedPlay['attributes'], {'Command': 'Play'});
    expect(parsedPlay['body'], contains('116621666555985'));
    expect(parsedTvInfo, isNotNull);
    expect(parsedTvInfo!['op'], 0xe002);
    expect(parsedTvInfo['seq'], 2);
    expect(parsedTvInfo['isRequest'], isTrue);
    expect(parsedTvInfo['attributes'], {'Command': 'GetTvInfo'});
    expect(parsedTvInfo['body'], isEmpty);
    expect(parsedVolume, isNotNull);
    expect(parsedVolume!['op'], 0xe002);
    expect(parsedVolume['seq'], 3);
    expect(parsedVolume['attributes'], {'Command': 'GetVolume'});
    expect(parsedVolume['body'], isEmpty);

    final tvInfoResponse = coolCastNirvanaFrameResponseForTest(getTvInfo);
    final parsedTvInfoResponse = coolCastNvaFrameForTest(tvInfoResponse!);
    expect(parsedTvInfoResponse!['op'], 0xc003);
    expect(parsedTvInfoResponse['seq'], 2);
    expect(parsedTvInfoResponse['attributes'], {'Command': 'GetTvInfo'});
    expect(parsedTvInfoResponse['body'], contains('"tvVipInfo":-1'));
    expect(coolCastNirvanaFrameResponsesForTest(getTvInfo), tvInfoResponse);

    final volumeResponse = coolCastNirvanaFrameResponseForTest(getVolume);
    final parsedVolumeResponse = coolCastNvaFrameForTest(volumeResponse!);
    expect(parsedVolumeResponse!['op'], 0xc003);
    expect(parsedVolumeResponse['seq'], 3);
    expect(parsedVolumeResponse['attributes'], {'Command': 'GetVolume'});
    expect(parsedVolumeResponse['body'], contains('"volume":50'));
    expect(coolCastNirvanaFrameResponsesForTest(getVolume), volumeResponse);

    final getPlayInfo = coolCastNvaEmptyRequestFrameForTest(
      4,
      {'Command': 'GetPlayInfo'},
    );
    final playInfoResponse = coolCastNirvanaFrameResponseForTest(getPlayInfo);
    final parsedPlayInfoResponse = coolCastNvaFrameForTest(playInfoResponse!);
    expect(parsedPlayInfoResponse!['op'], 0xc003);
    expect(parsedPlayInfoResponse['seq'], 4);
    expect(parsedPlayInfoResponse['attributes'], {'Command': 'GetPlayInfo'});
    expect(parsedPlayInfoResponse['body'], contains('"playState":'));
    expect(parsedPlayInfoResponse['body'], contains('"duration":'));
    expect(parsedPlayInfoResponse['body'], contains('"volume":50'));
    expect(coolCastNirvanaFrameResponsesForTest(getPlayInfo), playInfoResponse);
  });

  test('Bilibili play info response follows official nvalink status shape', () {
    final body = jsonDecode(coolCastBiliPlayInfoResponseForTest(
      aid: 116621666555985,
      cid: 26016292374,
      quality: 120,
      timelength: 2665726,
      acceptQuality: const [120, 112, 80, 64],
    )) as Map<String, Object?>;

    expect(body['playState'], 4);
    expect(body['position'], 0);
    expect(body['duration'], 2666);
    expect(body, isNot(contains('positionMs')));
    expect(body, isNot(contains('durationMs')));
    expect(body, isNot(contains('timelength')));
    expect(body['danmakuState'], isTrue);
    expect(body['volume'], 50);
    expect(body['title'], '');
    expect(body['playItem'], {
      'aid': 116621666555985,
      'cid': 26016292374,
      'epId': 0,
      'seasonId': 0,
      'roomId': 0,
      'biz': 0,
    });
    final qn = body['qn'] as Map<String, Object?>;
    expect(qn['curQn'], 120);
    expect(qn['userDesireQn'], 120);
    final supportQnList = qn['supportQnList'] as List<Object?>;
    expect(supportQnList, hasLength(4));
    expect(supportQnList.first, {
      'quality': 120,
      'description': '4K 超清',
      'displayDesc': '4K 超清',
      'superscript': '',
      'needLogin': false,
      'needVip': false,
    });
    final speedInfo = body['speedInfo'] as Map<String, Object?>;
    expect(speedInfo['currSpeed'], 1.0);
    expect(speedInfo['supportSpeedList'], contains(2.0));

    final pausedBody = jsonDecode(coolCastBiliPlayInfoResponseForTest(
      aid: 116621666555985,
      cid: 26016292374,
      quality: 120,
      timelength: 2665726,
      acceptQuality: const [120, 112, 80, 64],
      playState: 5,
    )) as Map<String, Object?>;
    expect(pausedBody['playState'], 5);
  });

  test('Bilibili active status events use native request command frames', () {
    final event = coolCastNvaServerEventFrameForTest(
      command: 'OnProgress',
      body: '{"position":0,"duration":2666}',
    );
    final parsed = coolCastNvaFrameForTest(event);

    expect(parsed, isNotNull);
    expect(parsed!['op'], 0xe003);
    expect(parsed['isRequest'], isTrue);
    expect(parsed['attributes'], {'Command': 'OnProgress'});
    expect(parsed['body'], contains('"duration":2666'));
    expect(parsed['body'], isNot(contains('durationMs')));

    final pausedEvent = coolCastNvaServerEventFrameForTest(
      command: 'OnPlayState',
      body: '{"playState":5}',
    );
    final parsedPausedEvent = coolCastNvaFrameForTest(pausedEvent);
    expect(parsedPausedEvent!['attributes'], {'Command': 'OnPlayState'});
    expect(parsedPausedEvent['body'], '{"playState":5}');
  });

  test('Bilibili native playback control frames parse and ack', () {
    final pause = coolCastNvaEmptyRequestFrameForTest(
      10,
      {'Command': 'Pause'},
    );
    final resume = coolCastNvaEmptyRequestFrameForTest(
      11,
      {'Command': 'Resume'},
    );
    final play = coolCastNvaEmptyRequestFrameForTest(
      14,
      {'Command': 'Play'},
    );
    final seek = coolCastNvaRequestFrameForTest(
      12,
      {'Command': 'Seek'},
      '{"position":88}',
    );
    final stop = coolCastNvaEmptyRequestFrameForTest(
      13,
      {'Command': 'Stop'},
    );

    expect(coolCastNvaFrameForTest(pause)!['attributes'], {'Command': 'Pause'});
    expect(coolCastNvaFrameForTest(resume)!['attributes'], {
      'Command': 'Resume',
    });
    expect(coolCastNvaFrameForTest(play)!['attributes'], {'Command': 'Play'});
    expect(coolCastNvaFrameForTest(seek)!['body'], '{"position":88}');
    expect(coolCastNvaFrameForTest(stop)!['attributes'], {'Command': 'Stop'});
    expect(coolCastBiliNvaControlForTest('Seek', '{"position":88}'), {
      'command': 'Seek',
      'shouldStopPlayback': false,
      'seekSeconds': 88,
    });
    expect(coolCastBiliNvaControlForTest('Stop', ''), {
      'command': 'Stop',
      'shouldStopPlayback': true,
      'seekSeconds': null,
    });

    final pauseResponse = coolCastNirvanaFrameResponseForTest(pause);
    final playResponse = coolCastNirvanaFrameResponseForTest(play);
    final seekResponse = coolCastNirvanaFrameResponseForTest(seek);
    final parsedPauseResponse = coolCastNvaFrameForTest(pauseResponse!);
    final parsedPlayResponse = coolCastNvaFrameForTest(playResponse!);
    final parsedSeekResponse = coolCastNvaFrameForTest(seekResponse!);
    expect(pauseResponse,
        Uint8List.fromList([0xc0, 0x00, 0x00, 0x00, 0x00, 0x0a]));
    expect(
        playResponse, Uint8List.fromList([0xc0, 0x00, 0x00, 0x00, 0x00, 0x0e]));
    expect(
        seekResponse, Uint8List.fromList([0xc0, 0x00, 0x00, 0x00, 0x00, 0x0c]));
    expect(parsedPauseResponse, isNull);
    expect(parsedPlayResponse, isNull);
    expect(parsedSeekResponse, isNull);
  });

  test('Bilibili NVA Play body builds tv playurl request', () {
    final body = jsonEncode({
      'seekTs': 126,
      'isOpen': false,
      'aid': 116621666555985,
      'cid': 26016292374,
      'qn': 80,
      'userDesireQn': -1,
      'contentType': 4,
      'seasonId': 0,
      'epId': 0,
      'accessKey': 'mobile-token-1',
      'mobileVersion': 8450300,
      'sessionId': 'projection-session',
      'projection_buried_extra': jsonEncode({
        'content_id': jsonEncode({
          'bvid': 'BV1R4Gv6REBG',
          'avid': '116621666555985',
          'cid': '26016292374',
        }),
      }),
    });

    final play = coolCastBiliNvaPlayForTest(body);
    final uri = coolCastBiliTvPlayUrlUriForTest(body);
    final fallbackUri = coolCastBiliPublicPlayerPlayUrlUriForTest(body);

    expect(play, isNotNull);
    expect(play!['aid'], 116621666555985);
    expect(play['cid'], 26016292374);
    expect(play['accessKey'], 'mobile-token-1');
    expect(play['preferredQn'], 80);
    expect(play['preferredPublicQn'], 120);
    expect(play['seekTs'], 126);
    expect(play['mobileVersion'], 8450300);
    expect(play['bvid'], 'BV1R4Gv6REBG');
    expect(uri, isNotNull);
    expect(uri!.scheme, 'https');
    expect(uri.host, 'api.bilibili.com');
    expect(uri.path, '/x/tv/playurl');
    expect(uri.queryParameters['object_id'], '116621666555985');
    expect(uri.queryParameters['cid'], '26016292374');
    expect(uri.queryParameters['qn'], '80');
    expect(uri.queryParameters['mobile_access_key'], 'mobile-token-1');
    expect(uri.queryParameters['access_key'], 'mobile-token-1');
    expect(uri.queryParameters['is_proj'], '1');
    expect(uri.queryParameters['playurl_type'], '1');
    expect(uri.queryParameters['fourk'], '1');
    expect(uri.queryParameters['sys_ver'], '8450300');
    expect(uri.queryParameters['build'], '8450300');
    expect(uri.queryParameters['platform'], 'android');
    expect(uri.queryParameters['mobi_app'], 'android');
    expect(uri.queryParameters['appkey'], '1d8b6e7d45233436');
    expect(uri.queryParameters['device_type'], '1');
    expect(uri.queryParameters['from_outside'], '1');
    expect(
      uri.queryParameters['live_extra'],
      '{need_hdr=0, ott_build=104800}',
    );
    expect(uri.queryParameters['sign'], matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(fallbackUri, isNotNull);
    expect(fallbackUri!.path, '/x/player/playurl');
    expect(fallbackUri.queryParameters['bvid'], 'BV1R4Gv6REBG');
    expect(fallbackUri.queryParameters['cid'], '26016292374');
    expect(fallbackUri.queryParameters['qn'], '120');
    expect(fallbackUri.queryParameters['fnval'], '4048');
    expect(fallbackUri.queryParameters['access_key'], 'mobile-token-1');

    final headers = coolCastBiliPlaybackHeadersForTest(
      bvid: 'BV1R4Gv6REBG',
    );
    expect(headers['user-agent'], 'Mozilla/5.0 BiliDroid');
    expect(
      headers['referer'],
      'https://www.bilibili.com/video/BV1R4Gv6REBG',
    );

    final noBvidBody = jsonEncode({
      'aid': 116577005475345,
      'cid': 38343344355,
      'qn': 80,
      'accessKey': 'mobile-token-1',
      'projection_buried_extra': jsonEncode({
        'content_id': jsonEncode({
          'bvid': '',
          'avid': '116577005475345',
          'cid': '38343344355',
        }),
      }),
    });
    final aidFallbackUri = coolCastBiliPublicPlayerPlayUrlUriForTest(
      noBvidBody,
    );
    expect(aidFallbackUri, isNotNull);
    expect(aidFallbackUri!.queryParameters['avid'], '116577005475345');
    expect(aidFallbackUri.queryParameters['bvid'], isNull);
    expect(aidFallbackUri.queryParameters['cid'], '38343344355');
    expect(aidFallbackUri.queryParameters['qn'], '120');
    expect(aidFallbackUri.queryParameters['fnval'], '4048');
    expect(aidFallbackUri.queryParameters['access_key'], 'mobile-token-1');

    final aidHeaders = coolCastBiliPlaybackHeadersForTest(
      aid: 116577005475345,
    );
    expect(
      aidHeaders['referer'],
      'https://www.bilibili.com/video/av116577005475345',
    );
  });

  test('Bilibili SwitchQn reuses latest Play request with requested qn', () {
    final body = jsonEncode({
      'seekTs': 126,
      'aid': 116621666555985,
      'cid': 26016292374,
      'qn': 80,
      'userDesireQn': -1,
      'contentType': 4,
      'accessKey': 'mobile-token-1',
      'mobileVersion': 8450300,
      'projection_buried_extra': jsonEncode({
        'content_id': jsonEncode({
          'bvid': 'BV1R4Gv6REBG',
          'avid': '116621666555985',
          'cid': '26016292374',
        }),
      }),
    });

    final switchQn = coolCastBiliNvaSwitchQnForTest(body, '{"qn":80}');
    final tvUri = coolCastBiliSwitchedTvPlayUrlUriForTest(body, 80);
    final fallbackUri = coolCastBiliSwitchedPublicPlayerPlayUrlUriForTest(
      body,
      80,
    );

    expect(switchQn, {
      'qn': 80,
      'userDesireQn': 80,
      'preferredQn': 80,
      'preferredPublicQn': 80,
      'seekTs': 42,
    });
    expect(tvUri, isNotNull);
    expect(tvUri!.queryParameters['qn'], '80');
    expect(fallbackUri, isNotNull);
    expect(fallbackUri!.queryParameters['qn'], '80');
  });

  test('debug summaries redact playback credentials and signed URLs', () {
    const token = 'mobile-token-1';
    final url = coolCastSafeUrlForLogForTest(
      'https://api.bilibili.com/x/player/playurl?cid=2&access_key=$token&sign=abc123',
    );
    final body = coolCastSafeTextForLogForTest(
      '{"accessKey":"$token","url":"https://example.com/a?access_key=$token"}',
    );

    expect(url, contains('api.bilibili.com/x/player/playurl'));
    expect(url, isNot(contains(token)));
    expect(url, isNot(contains('abc123')));
    expect(body, isNot(contains(token)));
    expect(body, contains('<redacted>'));
  });

  test('bounded UTF-8 reader rejects oversized control bodies', () async {
    expect(
      coolCastReadUtf8WithLimitForTest(
        Stream<List<int>>.fromIterable([
          utf8.encode('1234'),
          utf8.encode('56'),
        ]),
        maxBytes: 5,
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      await coolCastReadUtf8WithLimitForTest(
        Stream<List<int>>.value(utf8.encode('12345')),
        maxBytes: 5,
      ),
      '12345',
    );
  });

  test('Bilibili playurl response extracts durl URL', () {
    final response = jsonEncode({
      'code': 0,
      'message': '0',
      'data': {
        'quality': 120,
        'timelength': 2665726,
        'accept_quality': [120, 112, 80],
        'durl': [
          {
            'order': 1,
            'url': 'https://upos.example.com/video.m4s?qn=120',
          },
        ],
      },
    });
    final resultResponse = jsonEncode({
      'code': 0,
      'result': {
        'durl': [
          {'url': 'https://upos.example.com/result.mp4'},
        ],
      },
    });

    expect(
      coolCastBiliPlayUrlFromJsonForTest(response),
      'https://upos.example.com/video.m4s?qn=120',
    );
    expect(coolCastBiliCastStatusFromJsonForTest(response, aid: 1, cid: 2), {
      'aid': 1,
      'cid': 2,
      'quality': 120,
      'timelength': 2665726,
      'acceptQuality': [120, 112, 80],
    });
    expect(
      coolCastBiliPlayUrlFromJsonForTest(resultResponse),
      'https://upos.example.com/result.mp4',
    );
    final mixedResponse = jsonEncode({
      'code': 0,
      'data': {
        'quality': 32,
        'dash': {
          'video': [
            {'id': 120, 'baseUrl': 'https://upos.example.com/4k.m4s'},
          ],
        },
        'durl': [
          {'url': 'https://upos.example.com/480p.flv'},
        ],
      },
    });
    expect(
      coolCastBiliPlayUrlFromJsonForTest(mixedResponse),
      'https://upos.example.com/480p.flv',
    );
    expect(
      coolCastBiliPlayUrlFromJsonForTest('{"code":0,"data":{"durl":[]}}'),
      isNull,
    );
  });

  testWidgets('debug overlay only shows high severity alerts',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              DebugAlertOverlayForTest(alerts: []),
            ],
          ),
        ),
      ),
    );

    expect(find.text('调试错误'), findsNothing);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              DebugAlertOverlayForTest(
                alerts: [
                  CoolCastDebugAlert('WARN', 'HTTP 地址不可用'),
                  CoolCastDebugAlert('ERR', '播放失败：Source error'),
                  CoolCastDebugAlert('FATAL', '服务启动失败：port busy'),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('调试错误'), findsOneWidget);
    expect(find.textContaining('HTTP 地址不可用'), findsNothing);
    expect(find.textContaining('播放失败：Source error'), findsOneWidget);
    expect(find.textContaining('服务启动失败：port busy'), findsOneWidget);
  });

  testWidgets('bottom-left remote install button opens QR dialog and closes on back',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const CoolCastApp());

    final entryButton = find.byKey(const ValueKey('remote-install-entry-button'));
    expect(entryButton, findsOneWidget);
    expect(find.text('远程安装'), findsOneWidget);
    expect(find.byKey(const ValueKey('remote-install-dialog')), findsNothing);

    await tester.tap(entryButton);
    await tester.pump();

    expect(find.byKey(const ValueKey('remote-install-dialog')), findsOneWidget);
    expect(find.text('远程安装应用'), findsOneWidget);
    expect(find.byKey(const ValueKey('remote-install-qr-code')), findsOneWidget);
    expect(find.text('http://TV-IP:7788/install'), findsOneWidget);
    expect(find.text('等待手机扫码上传 APK 安装包'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(find.byKey(const ValueKey('remote-install-dialog')), findsNothing);
  });

  testWidgets('pressing remote arrow down on home screen opens remote install dialog',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const CoolCastApp());
    await tester.pump();

    expect(find.byKey(const ValueKey('remote-install-dialog')), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    expect(find.byKey(const ValueKey('remote-install-dialog')), findsOneWidget);
    expect(find.byKey(const ValueKey('remote-install-qr-code')), findsOneWidget);
  });

  test('CoolCastQrCode generates valid ISO 18004 matrix for install URL', () {
    final qr = CoolCastQrCode.fromText('http://192.168.1.114:7788/install');

    expect(qr.version, 3);
    expect(qr.size, 29);
    // Top-left, top-right, and bottom-left finder centers must be dark.
    expect(qr.isDark(3, 3), isTrue);
    expect(qr.isDark(3, qr.size - 4), isTrue);
    expect(qr.isDark(qr.size - 4, 3), isTrue);
    // Dark module at (4 * version + 9, 8) must be dark.
    expect(qr.isDark(4 * qr.version + 9, 8), isTrue);
  });

  test('remote install HTML pages render upload form and status feedback', () {
    final form = coolCastInstallHtmlFormForTest(
      receiverName: '客厅电视',
      ipAddress: '192.168.1.18',
      statusMessage: '等待手机扫码上传 APK 安装包',
    );
    final success = coolCastInstallUploadHtmlResponseForTest(
      fileName: 'demo.apk',
      isAccepted: true,
      detail: '安装包已上传至 CoolCast，电视端正在自动拉起安装界面。',
    );
    final failure = coolCastInstallUploadHtmlResponseForTest(
      fileName: '',
      isAccepted: false,
      detail: '未检测到有效的 .apk 安装包，请重新选择文件上传。',
    );

    expect(form, contains('远程安装到 客厅电视'));
    expect(form, contains('action="/install/upload"'));
    expect(form, contains('accept=".apk,application/vnd.android.package-archive"'));
    expect(success, contains('APK 上传成功，正在安装'));
    expect(success, contains('文件：demo.apk'));
    expect(failure, contains('APK 上传失败'));
  });

  test('APK upload parser extracts valid APK from multipart and raw bodies', () {
    final fakeApkBytes = Uint8List.fromList([0x50, 0x4B, 0x03, 0x04, 1, 2, 3, 4]);
    const boundary = '----CoolCastBoundary12345';
    final multipartHeader = utf8.encode(
      '--$boundary\r\n'
      'Content-Disposition: form-data; name="apk"; filename="tv_helper.apk"\r\n'
      'Content-Type: application/vnd.android.package-archive\r\n\r\n',
    );
    final multipartFooter = utf8.encode('\r\n--$boundary--\r\n');
    final multipartBody = Uint8List.fromList([
      ...multipartHeader,
      ...fakeApkBytes,
      ...multipartFooter,
    ]);

    final parsedMultipart = coolCastExtractUploadedApkForTest(
      multipartBody,
      contentTypeHeader: 'multipart/form-data; boundary=$boundary',
    );
    expect(parsedMultipart, isNotNull);
    expect(parsedMultipart!['fileName'], 'tv_helper.apk');
    expect(parsedMultipart['bytes'], fakeApkBytes);

    final parsedRaw = coolCastExtractUploadedApkForTest(
      fakeApkBytes,
      contentTypeHeader: 'application/vnd.android.package-archive',
      queryFileName: 'kodi_arm64.apk',
    );
    expect(parsedRaw, isNotNull);
    expect(parsedRaw!['fileName'], 'kodi_arm64.apk');
    expect(parsedRaw['bytes'], fakeApkBytes);

    final rejectedTxt = coolCastExtractUploadedApkForTest(
      fakeApkBytes,
      contentTypeHeader: 'application/octet-stream',
      queryFileName: 'notes.txt',
    );
    expect(rejectedTxt, isNull);

    final rejectedMagic = coolCastExtractUploadedApkForTest(
      Uint8List.fromList([0x00, 0x01, 0x02, 0x03]),
      contentTypeHeader: 'application/vnd.android.package-archive',
      queryFileName: 'broken.apk',
    );
    expect(rejectedMagic, isNull);
  });

  test('app installer channel sends filePath to Android native bridge', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(coolCastAppInstallerChannelForTest, (call) {
      calls.add(call);
      if (call.method == 'installApk') {
        return Future<Object?>.value('launched');
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(coolCastAppInstallerChannelForTest, null);
    });

    final status = await coolCastInstallApkForTest('/tmp/coolcast_apk/demo.apk');

    expect(status, 'launched');
    expect(calls, hasLength(1));
    expect(calls.single.method, 'installApk');
    expect(calls.single.arguments, {'filePath': '/tmp/coolcast_apk/demo.apk'});
  });
}
