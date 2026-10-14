import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models/cast_models.dart';
import 'platform/player_bridge.dart';
import 'protocols/bilibili_cast.dart';
import 'protocols/dlna_upnp.dart';
import 'services/http_cast_install.dart';
import 'ui/home_page.dart';

export 'models/cast_models.dart';
export 'platform/player_bridge.dart';
export 'protocols/bilibili_cast.dart';
export 'protocols/dlna_upnp.dart';
export 'qr_code.dart' show CoolCastQrCode, CoolCastQrCodeView;
export 'services/http_cast_install.dart';
export 'ui/home_page.dart';
export 'ui/playing_page.dart';

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


String coolCastHtmlFormForTest({
  required String receiverName,
  required String ipAddress,
  required String message,
}) =>
    htmlForm(
        receiverName: receiverName, ipAddress: ipAddress, message: message);

String coolCastHtmlResponseForTest(String url, {required bool isAccepted}) =>
    htmlResponse(url, isAccepted: isAccepted);

@visibleForTesting
String coolCastInstallHtmlFormForTest({
  required String receiverName,
  required String ipAddress,
  required String statusMessage,
}) =>
    installHtmlForm(
      receiverName: receiverName,
      ipAddress: ipAddress,
      statusMessage: statusMessage,
    );

@visibleForTesting
String coolCastInstallUploadHtmlResponseForTest({
  required String fileName,
  required bool isAccepted,
  required String detail,
}) =>
    installUploadHtmlResponse(
      fileName: fileName,
      isAccepted: isAccepted,
      detail: detail,
    );

@visibleForTesting
Map<String, Object?>? coolCastExtractUploadedApkForTest(
  Uint8List bodyBytes, {
  String? contentTypeHeader,
  String? queryFileName,
}) {
  final parsed = extractUploadedApk(
    bodyBytes,
    contentTypeHeader: contentTypeHeader,
    queryFileName: queryFileName,
  );
  if (parsed == null) {
    return null;
  }
  return {
    'fileName': parsed.fileName,
    'bytes': parsed.bytes,
  };
}

@visibleForTesting
MethodChannel get coolCastAppInstallerChannelForTest => appInstallerChannel;

@visibleForTesting
Future<String?> coolCastInstallApkForTest(String filePath) =>
    installApkWithNativeBridge(filePath);

String coolCastDeviceDescriptionForTest(String ip, String receiverName) =>
    deviceDescription(ip, receiverName);

String coolCastNormalizeHttpPathForTest(String path) =>
    normalizeHttpPath(path);

String coolCastNormalizeHttpUriPathForTest(String uri) =>
    normalizeHttpUriPath(Uri.parse(uri));

bool coolCastIsDlnaRendererExtraPathForTest(String path) =>
    isDlnaRendererExtraPath(normalizeHttpPath(path));

String coolCastDlnaRendererExtraXmlForTest(
        {String receiverName = 'CoolCast'}) =>
    dlnaRendererExtraXml(receiverName);

MethodChannel get coolCastNativePlayerChannelForTest => nativePlayerChannel;

Future<void> coolCastNativePlayerPlayForTest(
  String url, {
  Map<String, String> headers = const {},
  Duration initialPosition = Duration.zero,
}) =>
    nativePlayerPlay(
      url,
      headers: headers,
      initialPosition: initialPosition,
    );

Future<void> coolCastNativePlayerPauseForTest() =>
    nativePlayerChannel.invokeMethod<void>('pause');

Future<void> coolCastNativePlayerSeekToForTest(Duration position) =>
    nativePlayerSeekTo(position);

Future<Duration> coolCastNativePlayerPositionForTest() =>
    nativePlayerPosition();

Future<Duration> coolCastNativePlayerDurationForTest() =>
    nativePlayerDuration();

Future<Size?> coolCastNativePlayerVideoSizeForTest() =>
    nativePlayerVideoSize();

Future<int?> coolCastNativePlayerVideoBitrateForTest() =>
    nativePlayerVideoBitrate();

AndroidView coolCastNativeVideoSurfaceForTest() =>
    const AndroidView(viewType: nativePlayerViewType);

String coolCastSoapResponseForTest(
  String action, {
  CoolCastUpnpService service = CoolCastUpnpService.avTransport,
  String body = '',
}) =>
    soapResponse(action, service: service, body: body);

@visibleForTesting
String coolCastPositionInfoResponseForTest({
  required Duration position,
  required Duration duration,
  required String currentUrl,
}) =>
    positionInfoResponse(
      position: position,
      duration: duration,
      currentUrl: currentUrl,
    );

@visibleForTesting
String coolCastAvTransportScpdForTest() => avTransportScpd();

@visibleForTesting
String coolCastConnectionManagerScpdForTest() => connectionManagerScpd();

@visibleForTesting
String coolCastProtocolInfoResponseForTest() => protocolInfoResponse();

@visibleForTesting
Map<String, String> coolCastUpnpResponseHeadersForTest() =>
    upnpResponseHeaders();

@visibleForTesting
List<int> coolCastSsdpStartupNotifyBurstSecondsForTest() =>
    ssdpStartupNotifyBurstSeconds;

@visibleForTesting
int coolCastSsdpNotifyIntervalSecondsForTest() => ssdpNotifyIntervalSeconds;

@visibleForTesting
String coolCastSsdpSearchResponseForTest({
  required String localIp,
  required String target,
}) =>
    ssdpSearchResponse(localIp, target);

@visibleForTesting
List<String> coolCastSsdpSearchResponsesForTest({
  required String localIp,
  required String searchMessage,
}) =>
    ssdpSearchResponses(localIp, searchMessage);

@visibleForTesting
String coolCastSsdpNotifyForTest({
  required String localIp,
  required String target,
}) =>
    ssdpNotify(localIp, target);

@visibleForTesting
bool coolCastIsOttBlinkSearchForTest(Uint8List data) => isOttBlinkSearch(data);

@visibleForTesting
Uint8List coolCastOttBlinkResponseForTest(String receiverName) =>
    ottBlinkResponse(receiverName);

@visibleForTesting
String coolCastReceiverNameForDeviceForTest(String? deviceName) =>
    receiverNameForDevice(deviceName);

@visibleForTesting
List<Offset> coolCastRandomBubbleStartsForTest(int seed) =>
    randomBubblePaths(math.Random(seed))
        .map((bubble) => bubble.start)
        .toList(growable: false);

@visibleForTesting
String? coolCastNirvanaControlUrlForTest(String payload) =>
    extractNirvanaControlUrl(payload);

@visibleForTesting
Map<String, Object?>? coolCastBiliNvaPlayForTest(String body) {
  final play = BiliNvaPlayRequest.fromBody(body);
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
  final play = BiliNvaPlayRequest.fromBody(playBody);
  final qn = biliSwitchQnFromBody(switchBody);
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
    'shouldStopPlayback': command == 'Stop',
    'seekSeconds': biliSeekPositionFromBody(body)?.inSeconds,
  };
}

@visibleForTesting
Uri? coolCastBiliTvPlayUrlUriForTest(String body) {
  final play = BiliNvaPlayRequest.fromBody(body);
  return play == null ? null : biliTvPlayUrlUri(play);
}

@visibleForTesting
Uri? coolCastBiliSwitchedTvPlayUrlUriForTest(String body, int qn) {
  final play = BiliNvaPlayRequest.fromBody(body);
  return play == null
      ? null
      : biliTvPlayUrlUri(play.copyWith(qn: qn, userDesireQn: qn));
}

@visibleForTesting
Uri? coolCastBiliPublicPlayerPlayUrlUriForTest(String body) {
  final play = BiliNvaPlayRequest.fromBody(body);
  return play == null ? null : biliPublicPlayerPlayUrlUri(play);
}

@visibleForTesting
Uri? coolCastBiliSwitchedPublicPlayerPlayUrlUriForTest(String body, int qn) {
  final play = BiliNvaPlayRequest.fromBody(body);
  return play == null
      ? null
      : biliPublicPlayerPlayUrlUri(
          play.copyWith(qn: qn, userDesireQn: qn),
        );
}

@visibleForTesting
Map<String, String> coolCastBiliPlaybackHeadersForTest({
  String? bvid,
  int? aid,
}) =>
    biliPlaybackHeaders(bvid: bvid, aid: aid);

@visibleForTesting
String coolCastSafeUrlForLogForTest(String value) => safeUrlForLog(value);

@visibleForTesting
String coolCastSafeTextForLogForTest(String value) => safeTextForLog(value);

@visibleForTesting
Future<String> coolCastReadUtf8WithLimitForTest(
  Stream<List<int>> stream, {
  required int maxBytes,
}) =>
    readUtf8WithLimit(stream, maxBytes: maxBytes);

@visibleForTesting
String? coolCastBiliPlayUrlFromJsonForTest(String body) =>
    extractBiliPlayUrl(tryJsonDecode(body));

@visibleForTesting
Map<String, Object?>? coolCastBiliCastStatusFromJsonForTest(
  String body, {
  int? aid,
  int? cid,
}) =>
    extractBiliCastStatus(tryJsonDecode(body), aid: aid, cid: cid)?.toJson();

@visibleForTesting
String coolCastNirvanaControlSummaryForTest(Uint8List data) =>
    nirvanaControlSummary(data);

@visibleForTesting
String coolCastNirvanaControlScpdForTest() => nirvanaControlScpd();

@visibleForTesting
bool coolCastLooksLikeTextNirvanaPayloadForTest(Uint8List data) =>
    looksLikeTextNirvanaPayload(data);

@visibleForTesting
bool coolCastLooksLikeCompleteNirvanaPayloadForTest(Uint8List data) =>
    looksLikeCompleteNirvanaPayload(data);

@visibleForTesting
bool coolCastShouldSendNirvanaTextAckForTest(Uint8List data) =>
    shouldSendNirvanaTextAck(data);

@visibleForTesting
String coolCastNirvanaProbeAckForTest() => nirvanaProbeAck();

@visibleForTesting
String coolCastNirvanaTextAckForTest(
  Uint8List data, {
  String localAddress = '',
}) =>
    nirvanaTextAck(data, localAddress: localAddress);

@visibleForTesting
Uint8List coolCastNirvanaPingFrameForTest(int sequence) =>
    nirvanaPingFrame(sequence);

Uint8List? coolCastNirvanaFrameResponseForTest(Uint8List data) {
  final responses = nirvanaFrameResponses(data);
  return responses.isEmpty ? null : responses.first;
}

@visibleForTesting
Uint8List? coolCastNirvanaFrameResponsesForTest(Uint8List data) {
  final responses = nirvanaFrameResponses(data);
  if (responses.isEmpty) {
    return null;
  }
  return Uint8List.fromList(responses.expand((response) => response).toList());
}

@visibleForTesting
int? coolCastNirvanaFrameLengthForTest(List<int> data) =>
    nvaFrameLength(data) ?? nirvanaShortControlFrameLength(data);

@visibleForTesting
String coolCastBiliPlayInfoResponseForTest({
  int? aid,
  int? cid,
  int? quality,
  int? timelength,
  List<int> acceptQuality = const [],
  int? playState,
}) =>
    biliPlayInfoResponseBody(
      BiliCastStatus(
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
    nvaServerEventFrame(command: command, body: body);

@visibleForTesting
Map<String, Object?>? coolCastNvaFrameForTest(Uint8List data) {
  final frame = parseNvaFrame(data);
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
    nvaFrame(
      op: biliNirvanaRequestOp,
      sequence: sequence,
      attributes: attributes,
      body: Uint8List.fromList(utf8.encode(body)),
    );

@visibleForTesting
Uint8List coolCastNvaEmptyRequestFrameForTest(
  int sequence,
  Map<String, String> attributes,
) =>
    nvaEmptyRequestFrame(sequence: sequence, attributes: attributes);

@visibleForTesting
Map<String, Object?>? coolCastBiliNvaExtForTest(String value) =>
    extractBiliNvaExt(value)?.toJson();

@visibleForTesting
String coolCastEncryptBiliNvaExtForTest(Map<String, Object?> value) =>
    encryptBiliNvaJson(jsonEncode(value));

@visibleForTesting
String? coolCastDecryptBiliNvaJsonForTest(String hex) =>
    decryptBiliNvaJson(hex);

@visibleForTesting
String coolCastBiliNvaLinkReplyForTest({
  required String localAddress,
  required String code,
}) =>
    biliNvaLinkReply(
      localAddress: localAddress,
      code: code,
    );

@visibleForTesting
List<String> coolCastMediaChipsForTest({
  required String currentUrl,
  required String mimeType,
  required PlaybackState state,
  Size? videoSize,
  String metadataResolution = '',
  int? metadataBitrate,
  int? biliQuality,
}) =>
    mediaChipsFor(
      currentUrl,
      mimeType,
      state,
      videoSize,
      metadataResolution: metadataResolution,
      metadataBitrate: metadataBitrate,
      biliStatus: biliQuality == null
          ? null
          : BiliCastStatus(
              aid: null,
              cid: null,
              quality: biliQuality,
              timelength: null,
              acceptQuality: const [],
            ),
    );

@visibleForTesting
bool coolCastShouldShowPlayingPageForTest({
  required bool isShowingVideo,
  required bool isPlayingPreviewVisible,
  String imageUrl = '',
  Uint8List? imageBytes,
}) =>
    shouldShowPlayingPage(
      isShowingVideo: isShowingVideo,
      isPlayingPreviewVisible: isPlayingPreviewVisible,
      imageUrl: imageUrl,
      imageBytes: imageBytes,
    );

@visibleForTesting
bool coolCastShouldClearPlayingPageOnDlnaStopForTest({
  String imageUrl = '',
  Uint8List? imageBytes,
}) =>
    shouldClearPlayingPageOnDlnaStop(
      imageUrl: imageUrl,
      imageBytes: imageBytes,
    );

@visibleForTesting
bool coolCastShouldDeferDlnaStopAfterSetUriForTest({
  required DateTime? lastSetUriAt,
  required DateTime now,
  required String currentUrl,
  required String pendingUrl,
}) =>
    shouldDeferDlnaStopAfterSetUri(
      lastSetUriAt: lastSetUriAt,
      now: now,
      currentUrl: currentUrl,
      pendingUrl: pendingUrl,
    );

@visibleForTesting
bool coolCastShouldReloadDlnaSetUriForTest({
  required String incomingUrl,
  required String currentUrl,
  required String pendingUrl,
  required bool isLoadingUrl,
  required bool hasActivePlayer,
}) =>
    shouldReloadDlnaSetUri(
      incomingUrl: incomingUrl,
      currentUrl: currentUrl,
      pendingUrl: pendingUrl,
      isLoadingUrl: isLoadingUrl,
      hasActivePlayer: hasActivePlayer,
    );

@visibleForTesting
bool coolCastShouldReportImageLoadFailureForTest({
  required int requestId,
  required int activeRequestId,
  required String requestUrl,
  required String currentImageUrl,
}) =>
    shouldReportImageLoadFailure(
      requestId: requestId,
      activeRequestId: activeRequestId,
      requestUrl: requestUrl,
      currentImageUrl: currentImageUrl,
    );
