import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/cast_models.dart';
import '../platform/player_bridge.dart';
import '../services/http_cast_install.dart';

const String defaultReceiverName = 'CoolCast';
const String receiverNameKey = 'coolcast.receiverName';
const String biliProjectionManufacturer = 'bilibili';
const String biliProjectionBrandName = 'bilibili';
const String biliProjectionFriendlyName = 'CoolCast';
const String biliProjectionModelName = '云视听小电视';
const String biliProjectionModelDescription =
    'bilibili official projection receiver';
const String biliProjectionModelUrl = 'https://www.bilibili.com/';
const String biliProjectionMobiApp = 'android_bilithings';
const Duration dlnaSetUriStopGracePeriod = Duration(milliseconds: 3500);
const int biliProjectionFourk = 1;
const int biliProjectionCapability = 1;
const String biliProjectionCastService =
    'urn:schemas-upnp-org:service:AVTransport:1';
const bool biliProjectionSupport4k = true;
const bool biliProjectionNeedNvaExtra = true;
const bool biliProjectionIgnoreDirect = true;
const String biliProjectionChannelName = 'bilibili';
const String biliProjectionAutoPullId = 'coolcast-tv-main';
const int ssdpNotifyIntervalSeconds = 5;
const List<int> ssdpStartupNotifyBurstSeconds = [
  0,
  1,
  2,
  3,
  5,
  8,
  12,
  18,
  25,
  35,
  50,
  70,
];
const String biliDescriptionPath = '/bilibili/description.xml';
const String ssdpDeviceUuid = 'uuid:$biliProjectionAutoPullId';
const String upnpCacheControlHeader = 'max-age=900';

@visibleForTesting
CoolCastMediaInfo coolCastMediaInfoFromMetadataForTest(String metadata) =>
    mediaInfoFromMetadata(metadata);

const Set<String> upnpEventPaths = {
  '/AVTransport/event',
  '/RenderingControl/event',
  '/ConnectionManager/event',
  '/NirvanaControl/event',
};

const List<String> ssdpTargets = [
  'upnp:rootdevice',
  ssdpDeviceUuid,
  'urn:schemas-upnp-org:device:MediaRenderer:1',
  'urn:schemas-upnp-org:service:AVTransport:1',
  'urn:schemas-upnp-org:service:RenderingControl:1',
  'urn:schemas-upnp-org:service:ConnectionManager:1',
  biliNirvanaSsdpService,
  biliNirvanaControlService,
];

String biliFriendlyName(String receiverName) {
  final name = receiverName.trim();
  return name.isEmpty ? biliProjectionFriendlyName : name;
}

String receiverNameForDevice(String? deviceName) {
  final normalized = deviceName?.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (normalized == null ||
      normalized.isEmpty ||
      normalized.toLowerCase() == 'unknown') {
    return defaultReceiverName;
  }
  if (normalized.toLowerCase().startsWith('coolcast')) {
    return normalized;
  }
  return '$defaultReceiverName - $normalized';
}

bool isDlnaRendererExtraPath(String path) =>
    path.toLowerCase() == '/dlna/render/dmr_extra.xml';

Map<String, String> upnpResponseHeaders() => const {
      'CACHE-CONTROL': upnpCacheControlHeader,
      'EXT': '',
      'SERVER': upnpServerHeader,
    };

void applyUpnpResponseHeaders(HttpHeaders headers) {
  upnpResponseHeaders().forEach(headers.set);
}

bool isUpnpEventSubscription(HttpRequest request) {
  final method = request.method.toUpperCase();
  if (method != 'SUBSCRIBE' && method != 'UNSUBSCRIBE') {
    return false;
  }
  return upnpEventPaths.contains(normalizeHttpUriPath(request.uri));
}

String deviceDescription(String ip, String receiverName) {
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
    <friendlyName>${xmlEscape(biliFriendlyName(receiverName))}</friendlyName>
    <manufacturer>$biliProjectionManufacturer</manufacturer>
    <manufacturerURL>$biliProjectionModelUrl</manufacturerURL>
    <modelName>$biliProjectionModelName</modelName>
    <X_brandName>$biliProjectionBrandName</X_brandName>
    <modelDescription>$biliProjectionModelDescription</modelDescription>
    <ottVersion>$biliProjectionBuild</ottVersion>
    <channelName>$biliProjectionChannelName</channelName>
    <autoPullId>$biliProjectionAutoPullId</autoPullId>
    <capability>$biliProjectionCapability</capability>
    <modelURL>$biliProjectionModelUrl</modelURL>
    <serialNumber>$biliProjectionAutoPullId</serialNumber>
    <UDN>uuid:$biliProjectionAutoPullId</UDN>
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
        <serviceType>$biliNirvanaControlService</serviceType>
        <serviceId>urn:app-bilibili-com:serviceId:NirvanaControl</serviceId>
        <controlURL>/NirvanaControl/control</controlURL>
        <eventSubURL>/NirvanaControl/event</eventSubURL>
        <SCPDURL>/NirvanaControl/scpd.xml</SCPDURL>
      </service>
      <service>
        <serviceType>$biliNirvanaSsdpService</serviceType>
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

String dlnaRendererExtraXml(String receiverName) {
  final friendlyName = xmlEscape(biliFriendlyName(receiverName));
  return '''
<?xml version="1.0" encoding="utf-8"?>
<root>
  <device>
    <friendlyName>$friendlyName</friendlyName>
    <manufacturer>$biliProjectionManufacturer</manufacturer>
    <modelName>$biliProjectionModelName</modelName>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <dlnaDoc>DMR-1.50</dlnaDoc>
  </device>
</root>
''';
}

String ssdpSearchResponse(String localIp, String target) {
  return '''
HTTP/1.1 200 OK\r
CACHE-CONTROL: $upnpCacheControlHeader\r
EXT:\r
LOCATION: http://$localIp:7788$biliDescriptionPath\r
SERVER: $upnpServerHeader\r
ST: $target\r
USN: ${ssdpUsn(target)}\r
\r
''';
}

String ssdpNotify(String localIp, String target) {
  return '''
NOTIFY * HTTP/1.1\r
HOST: 239.255.255.250:1900\r
CACHE-CONTROL: $upnpCacheControlHeader\r
LOCATION: http://$localIp:7788$biliDescriptionPath\r
NT: $target\r
NTS: ssdp:alive\r
SERVER: $upnpServerHeader\r
USN: ${ssdpUsn(target)}\r
\r
''';
}

String ssdpUsn(String target) {
  if (target.toLowerCase() == ssdpDeviceUuid.toLowerCase()) {
    return ssdpDeviceUuid;
  }
  return '$ssdpDeviceUuid::$target';
}

List<String> ssdpSearchResponses(String localIp, String message) {
  final target = ssdpSearchTarget(message);
  if (target == null) {
    return const [];
  }
  final lowerTarget = target.toLowerCase();
  final targets = lowerTarget == 'ssdp:all'
      ? ssdpTargets
      : ssdpTargets.where(
          (candidate) => candidate.toLowerCase() == lowerTarget,
        );
  return [
    for (final target in targets) ssdpSearchResponse(localIp, target),
  ];
}

String? ssdpSearchTarget(String message) {
  final match = RegExp(
    r'^ST\s*:\s*([^\r\n]+)',
    caseSensitive: false,
    multiLine: true,
  ).firstMatch(message);
  final value = match?.group(1)?.trim();
  return value == null || value.isEmpty ? null : value;
}

String soapResponse(
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

String transportInfoResponse(PlaybackState state) {
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

String positionInfoResponse({
  required Duration position,
  required Duration duration,
  required String currentUrl,
}) {
  return '''
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
  s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:GetPositionInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      <Track>1</Track>
      <TrackDuration>${dlnaDuration(duration)}</TrackDuration>
      <TrackMetaData></TrackMetaData>
      <TrackURI>${xmlEscape(currentUrl)}</TrackURI>
      <RelTime>${dlnaDuration(position)}</RelTime>
      <AbsTime>${dlnaDuration(position)}</AbsTime>
      <RelCount>2147483647</RelCount>
      <AbsCount>2147483647</AbsCount>
    </u:GetPositionInfoResponse>
  </s:Body>
</s:Envelope>
''';
}

String mediaInfoResponse(CoolCastPlayer? player, String currentUrl) {
  final duration = player?.duration ?? Duration.zero;
  return soapResponse(
    'GetMediaInfoResponse',
    body: '''
<NrTracks>${currentUrl.isEmpty ? 0 : 1}</NrTracks>
<MediaDuration>${dlnaDuration(duration)}</MediaDuration>
<CurrentURI>${xmlEscape(currentUrl)}</CurrentURI>
<CurrentURIMetaData></CurrentURIMetaData>
<NextURI></NextURI>
<NextURIMetaData></NextURIMetaData>
<PlayMedium>NETWORK</PlayMedium>
<RecordMedium>NOT_IMPLEMENTED</RecordMedium>
<WriteStatus>NOT_IMPLEMENTED</WriteStatus>''',
  );
}

String transportSettingsResponse() {
  return soapResponse(
    'GetTransportSettingsResponse',
    body: '''
<PlayMode>NORMAL</PlayMode>
<RecQualityMode>NOT_IMPLEMENTED</RecQualityMode>''',
  );
}

String deviceCapabilitiesResponse() {
  return soapResponse(
    'GetDeviceCapabilitiesResponse',
    body: '''
<PlayMedia>NETWORK</PlayMedia>
<RecMedia>NOT_IMPLEMENTED</RecMedia>
<RecQualityModes>NOT_IMPLEMENTED</RecQualityModes>''',
  );
}

String currentTransportActionsResponse(PlaybackState state) {
  final actions = switch (state) {
    PlaybackState.playing => 'Pause,Stop,Seek',
    PlaybackState.paused => 'Play,Stop,Seek',
    PlaybackState.ready => 'Play,Stop',
    PlaybackState.idle => 'Play',
    PlaybackState.failed => 'Play',
  };
  return soapResponse(
    'GetCurrentTransportActionsResponse',
    body: '<Actions>$actions</Actions>',
  );
}

String protocolInfoResponse() {
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
  return soapResponse(
    'GetProtocolInfoResponse',
    service: CoolCastUpnpService.connectionManager,
    body: '<Source></Source><Sink>${sink.join(',')}</Sink>',
  );
}

String dlnaDuration(Duration duration) {
  final hours = duration.inHours.toString().padLeft(2, '0');
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$hours:$minutes:$seconds';
}

Duration? parseDlnaDuration(String value) {
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

CoolCastMediaInfo mediaInfoFromMetadata(String metadata) {
  if (metadata.trim().isEmpty) {
    return const CoolCastMediaInfo();
  }
  final title = extractXmlValue(metadata, 'title');
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
  final resAttributes = RegExp(
        r'''<(?:[^:>]+:)?res\b([^>]*)>''',
        caseSensitive: false,
      ).firstMatch(metadata)?.group(1) ??
      '';
  final resolution = extractXmlAttribute(resAttributes, 'resolution');
  final bitrate = int.tryParse(extractXmlAttribute(resAttributes, 'bitrate'));
  return CoolCastMediaInfo(
    title: title,
    mimeType: mimeType,
    resolution: resolution,
    bitrate: bitrate,
  );
}

String extractXmlAttribute(String attributes, String name) => htmlUnescape(
      RegExp(
            '$name\\s*=\\s*["\']([^"\']*)["\']',
            caseSensitive: false,
          ).firstMatch(attributes)?.group(1)?.trim() ??
          '',
    );

String extractXmlValue(String body, String localName) {
  final match = RegExp(
    '<(?:[^:>]+:)?$localName>(.*?)</(?:[^:>]+:)?$localName>',
    dotAll: true,
    caseSensitive: false,
  ).firstMatch(body);
  if (match == null) {
    return '';
  }
  return htmlUnescape(match.group(1) ?? '').trim();
}

String extractSoapValue(String body, String tagName) {
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

String soapActionSummary(String body) {
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
  return body.trim().isEmpty ? '空请求' : shortUrl(body.replaceAll('\n', ' '));
}

bool shouldShowPlayingPage({
  required bool isShowingVideo,
  required bool isPlayingPreviewVisible,
  required String imageUrl,
  required Uint8List? imageBytes,
}) =>
    isShowingVideo ||
    isPlayingPreviewVisible ||
    imageUrl.isNotEmpty ||
    imageBytes != null;

bool shouldClearPlayingPageOnDlnaStop({
  required String imageUrl,
  required Uint8List? imageBytes,
}) =>
    imageUrl.isEmpty && imageBytes == null;

bool shouldDeferDlnaStopAfterSetUri({
  required DateTime? lastSetUriAt,
  required DateTime now,
  required String currentUrl,
  required String pendingUrl,
}) {
  if (lastSetUriAt == null || pendingUrl.isEmpty) {
    return false;
  }
  if (currentUrl.isNotEmpty && currentUrl != pendingUrl) {
    return false;
  }
  final elapsed = now.difference(lastSetUriAt);
  return !elapsed.isNegative && elapsed <= dlnaSetUriStopGracePeriod;
}

bool shouldReloadDlnaSetUri({
  required String incomingUrl,
  required String currentUrl,
  required String pendingUrl,
  required bool isLoadingUrl,
  required bool hasActivePlayer,
}) {
  if (incomingUrl.isEmpty) {
    return true;
  }
  final isSameCurrent = currentUrl == incomingUrl;
  final isSamePending = pendingUrl == incomingUrl;
  if ((hasActivePlayer && isSameCurrent) || (isLoadingUrl && isSamePending)) {
    return false;
  }
  return true;
}

bool shouldReportImageLoadFailure({
  required int requestId,
  required int activeRequestId,
  required String requestUrl,
  required String currentImageUrl,
}) =>
    requestId == activeRequestId && requestUrl == currentImageUrl;

String avTransportScpd() {
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
      <name>GetTransportInfo</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        <argument><name>CurrentTransportState</name><direction>out</direction><relatedStateVariable>TransportState</relatedStateVariable></argument>
        <argument><name>CurrentTransportStatus</name><direction>out</direction><relatedStateVariable>TransportStatus</relatedStateVariable></argument>
        <argument><name>CurrentSpeed</name><direction>out</direction><relatedStateVariable>TransportPlaySpeed</relatedStateVariable></argument>
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
      <name>GetCurrentTransportActions</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        <argument><name>Actions</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_TransportActions</relatedStateVariable></argument>
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
  </actionList>
  <serviceStateTable>
    <stateVariable sendEvents="no"><name>A_ARG_TYPE_InstanceID</name><dataType>ui4</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>AVTransportURI</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>AVTransportURIMetaData</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>AVTransportSourceId</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>AVTransportExtendData</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>NextAVTransportURI</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>NextAVTransportURIMetaData</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>TransportState</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>TransportStatus</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>TransportPlaySpeed</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>CurrentTrack</name><dataType>ui4</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>CurrentTrackDuration</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>CurrentTrackMetaData</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>CurrentTrackURI</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>RelativeTimePosition</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>AbsoluteTimePosition</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>RelativeCounterPosition</name><dataType>i4</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>AbsoluteCounterPosition</name><dataType>i4</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>NumberOfTracks</name><dataType>ui4</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>CurrentMediaDuration</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>PlaybackStorageMedium</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>RecordStorageMedium</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>RecordMediumWriteStatus</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>PossiblePlaybackStorageMedia</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>PossibleRecordStorageMedia</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>PossibleRecordQualityModes</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>CurrentPlayMode</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>CurrentRecordQualityMode</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>A_ARG_TYPE_TransportActions</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>A_ARG_TYPE_SeekMode</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>A_ARG_TYPE_SeekTarget</name><dataType>string</dataType></stateVariable>
  </serviceStateTable>
</scpd>
''';
}

String renderingControlScpd() {
  return '''
<?xml version="1.0" encoding="utf-8"?>
<scpd xmlns="urn:schemas-upnp-org:service-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <actionList>
    <action>
      <name>GetVolume</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        <argument><name>Channel</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Channel</relatedStateVariable></argument>
        <argument><name>CurrentVolume</name><direction>out</direction><relatedStateVariable>Volume</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action>
      <name>SetVolume</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        <argument><name>Channel</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Channel</relatedStateVariable></argument>
        <argument><name>DesiredVolume</name><direction>in</direction><relatedStateVariable>Volume</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action>
      <name>GetMute</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        <argument><name>Channel</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Channel</relatedStateVariable></argument>
        <argument><name>CurrentMute</name><direction>out</direction><relatedStateVariable>Mute</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action>
      <name>SetMute</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        <argument><name>Channel</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_Channel</relatedStateVariable></argument>
        <argument><name>DesiredMute</name><direction>in</direction><relatedStateVariable>Mute</relatedStateVariable></argument>
      </argumentList>
    </action>
  </actionList>
  <serviceStateTable>
    <stateVariable sendEvents="no"><name>A_ARG_TYPE_InstanceID</name><dataType>ui4</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>A_ARG_TYPE_Channel</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>Volume</name><dataType>ui2</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>Mute</name><dataType>boolean</dataType></stateVariable>
  </serviceStateTable>
</scpd>
''';
}

String connectionManagerScpd() {
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

String nirvanaControlScpd() {
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
