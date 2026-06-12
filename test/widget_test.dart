import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:coolcast/main.dart';

void main() {
  testWidgets('shows receiver home screen', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const CoolCastApp());

    expect(find.text('当前连接网络'), findsOneWidget);
    expect(find.text('可用投屏方式'), findsOneWidget);
    expect(find.text('设备名称'), findsOneWidget);
    expect(find.text('正在等待投屏连接'), findsOneWidget);
    expect(find.text('DLNA / UPnP'), findsOneWidget);
    expect(find.text('发现状态'), findsOneWidget);
    expect(find.text('未收到搜索'), findsOneWidget);
  });

  testWidgets('opens playing preview from debug home screen',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const CoolCastApp());
    await tester.tap(find.text('预览播放界面'));
    await tester.pump();

    expect(find.text('返回'), findsOneWidget);
    expect(find.text('投屏来源'), findsOneWidget);
    expect(find.text('正在播放投屏内容'), findsOneWidget);
    expect(find.text('4K HDR'), findsOneWidget);

    await tester.tap(find.byTooltip('快进'));
    await tester.pump();
    expect(find.text('18:52'), findsOneWidget);

    await tester.tap(find.byTooltip('暂停'));
    await tester.pump();
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(find.byIcon(Icons.pause), findsOneWidget);

    await tester.tap(find.byTooltip('静音'));
    await tester.pump();
    expect(find.byTooltip('取消静音'), findsOneWidget);

    await tester.tap(find.byTooltip('后退 30 秒'));
    await tester.pump();
    expect(find.text('18:22'), findsOneWidget);

    await tester.tap(find.text('返回'));
    await tester.pump();
    expect(find.text('当前连接网络'), findsOneWidget);
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
    <res protocolInfo="http-get:*:video/mp4:DLNA.ORG_OP=01">
      http://example.com/video.mp4
    </res>
  </item>
</DIDL-Lite>
''');

    expect(info.title, '测试视频 & 片段');
    expect(info.mimeType, 'video/mp4');
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
    expect(headers['EXT'], '');
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
    final responseParsed = coolCastNvaFrameForTest(response!);
    expect(responseParsed, isNotNull);
    expect(responseParsed!['op'], 0xe004);
    expect(responseParsed['seq'], 42);
    expect(responseParsed['isRequest'], isFalse);
    expect(responseParsed['attributes'], isEmpty);
    expect(responseParsed['body'], isEmpty);
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
    expect(parsedTvInfoResponse!['op'], 0xe004);
    expect(parsedTvInfoResponse['seq'], 2);
    expect(parsedTvInfoResponse['body'], contains('"tvVipInfo":-1'));

    final volumeResponse = coolCastNirvanaFrameResponseForTest(getVolume);
    final parsedVolumeResponse = coolCastNvaFrameForTest(volumeResponse!);
    expect(parsedVolumeResponse!['op'], 0xe004);
    expect(parsedVolumeResponse['seq'], 3);
    expect(parsedVolumeResponse['body'], contains('"volume":50'));

    final getPlayInfo = coolCastNvaEmptyRequestFrameForTest(
      4,
      {'Command': 'GetPlayInfo'},
    );
    final playInfoResponse = coolCastNirvanaFrameResponseForTest(getPlayInfo);
    final parsedPlayInfoResponse = coolCastNvaFrameForTest(playInfoResponse!);
    expect(parsedPlayInfoResponse!['op'], 0xe004);
    expect(parsedPlayInfoResponse['seq'], 4);
    expect(parsedPlayInfoResponse['attributes'], isEmpty);
    expect(parsedPlayInfoResponse['body'], contains('"playState":'));
    expect(parsedPlayInfoResponse['body'], contains('"duration":'));
    expect(parsedPlayInfoResponse['body'], contains('"volume":50'));
  });

  test('Bilibili play info response follows official nvalink status shape', () {
    final body = jsonDecode(coolCastBiliPlayInfoResponseForTest(
      aid: 116621666555985,
      cid: 26016292374,
      quality: 120,
      timelength: 2665726,
      acceptQuality: const [120, 112, 80, 64],
    )) as Map<String, Object?>;

    expect(body['playState'], 2);
    expect(body['position'], 0);
    expect(body['duration'], 2666);
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
}
