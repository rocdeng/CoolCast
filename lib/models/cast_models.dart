import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/foundation.dart';

const int biliProjectionBuild = 104800;
const String biliNirvanaControlService =
    'urn:app-bilibili-com:service:NirvanaControl:3';
const String biliNirvanaSsdpService =
    'urn:schemas-upnp-org:service:NirvanaControl:3';

enum PlaybackState { idle, ready, playing, paused, failed }


enum CoolCastUpnpService {
  avTransport('urn:schemas-upnp-org:service:AVTransport:1'),
  renderingControl('urn:schemas-upnp-org:service:RenderingControl:1'),
  connectionManager('urn:schemas-upnp-org:service:ConnectionManager:1'),
  nirvanaControl(biliNirvanaControlService);

  const CoolCastUpnpService(this.urn);

  final String urn;
}

class CoolCastDebugAlert {
  const CoolCastDebugAlert(this.level, this.message, {this.timestamp});

  final String level;
  final String message;
  final DateTime? timestamp;

  bool get isHighSeverity => level == 'ERR' || level == 'FATAL';
}


class BiliCastStatus {
  const BiliCastStatus({
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


class CoolCastMediaInfo {
  const CoolCastMediaInfo({
    this.title = '',
    this.mimeType = '',
    this.resolution = '',
    this.bitrate,
  });

  final String title;
  final String mimeType;
  final String resolution;
  final int? bitrate;

  bool get isImage => isImageMimeType(mimeType);
}


List<String> printableAsciiFragments(Uint8List data) {
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

String compactSummary(String value) {
  final singleLine = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (singleLine.length <= 180) {
    return singleLine;
  }
  return '${singleLine.substring(0, 177)}...';
}

String shortHex(Uint8List data) {
  return data
      .take(64)
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join(' ');
}

void debugLog(String message) {
  if (kDebugMode) {
    debugPrint('CoolCast: $message');
  }
}


String biliQualityDescription(int quality) {
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


String formatDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:$minutes:$seconds';
  }
  return '$minutes:$seconds';
}

String formatDebugTime(DateTime? timestamp) {
  if (timestamp == null) {
    return '--:--:--';
  }
  final hour = timestamp.hour.toString().padLeft(2, '0');
  final minute = timestamp.minute.toString().padLeft(2, '0');
  final second = timestamp.second.toString().padLeft(2, '0');
  return '$hour:$minute:$second';
}


String resolutionLabel(Size size) {
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

List<String> mediaChipsFor(
  String currentUrl,
  String mimeType,
  PlaybackState state,
  Size? videoSize, {
  String metadataResolution = '',
  int? metadataBitrate,
  BiliCastStatus? biliStatus,
}) {
  final chips = <String>[];
  final biliQuality = biliStatus?.quality;
  if (biliQuality != null) {
    chips.add('B站 ${biliQualityDescription(biliQuality)}');
  }
  if (videoSize != null && videoSize.width > 0 && videoSize.height > 0) {
    chips.add(resolutionLabel(videoSize));
  } else {
    final resolution = metadataResolutionLabel(metadataResolution);
    if (resolution.isNotEmpty) {
      chips.add(resolution);
    }
  }
  final quality = qualityLabelFromUrl(currentUrl);
  if (quality.isNotEmpty && !chips.contains(quality)) {
    chips.add(quality);
  }
  final mediaType = mediaTypeLabel(mimeType, currentUrl);
  if (mediaType.isNotEmpty) {
    chips.add(mediaType);
  }
  final bitrate = bitrateLabel(metadataBitrate);
  if (bitrate.isNotEmpty) {
    chips.add(bitrate);
  }
  if (state == PlaybackState.paused) {
    chips.add('已暂停');
  } else if (state == PlaybackState.playing) {
    chips.add('播放中');
  }
  return chips.isEmpty ? const ['媒体已连接'] : chips.take(4).toList();
}

String metadataResolutionLabel(String resolution) {
  final match = RegExp(r'^(\d+)\s*[xX]\s*(\d+)$').firstMatch(resolution.trim());
  if (match == null) {
    return resolution.trim();
  }
  return resolutionLabel(Size(
    double.parse(match.group(1)!),
    double.parse(match.group(2)!),
  ));
}

String bitrateLabel(int? bitrate) {
  if (bitrate == null || bitrate <= 0) {
    return '';
  }
  final megabits = bitrate * 8 / 1000000;
  if (megabits >= 1) {
    final value = megabits >= 10
        ? megabits.toStringAsFixed(0)
        : megabits.toStringAsFixed(1);
    return '$value Mbps';
  }
  return '${(bitrate * 8 / 1000).round()} Kbps';
}


String videoSizeSummary(Size? size) {
  if (size == null || size.width <= 0 || size.height <= 0) {
    return '-';
  }
  return '${size.width.round()}x${size.height.round()}';
}

String qualityLabelFromUrl(String url) {
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

String mediaTypeLabel(String mimeType, String url) {
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

bool isImageMimeType(String mimeType) =>
    mimeType.toLowerCase().startsWith('image/');

bool isImageUrl(String url) {
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
  final extension = path.split('.').lastOrNull;
  return const {'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'}.contains(extension);
}

String shortError(Object error) {
  final text = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.length <= 96) {
    return text;
  }
  return '${text.substring(0, 96)}...';
}

String shortUrl(String value) {
  final text = value.trim();
  if (text.length <= 72) {
    return text;
  }
  return '${text.substring(0, 42)}...${text.substring(text.length - 18)}';
}

String safeUrlForLog(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return safeTextForLog(value);
  }
  final queryKeys = uri.queryParametersAll.keys.toList()..sort();
  final sanitized = uri.replace(
    userInfo: '',
    query: queryKeys.isEmpty
        ? null
        : queryKeys.map((key) => '$key=<redacted>').join('&'),
    fragment: null,
  );
  return shortUrl(sanitized.toString());
}

String safeTextForLog(String value) {
  final redacted = value
      .replaceAll(
        RegExp(
          r'("?(?:accessKey|access_key|mobile_access_key|token|sign)"?\s*[:=]\s*")([^"]+)(")',
          caseSensitive: false,
        ),
        r'$1<redacted>$3',
      )
      .replaceAll(
        RegExp(
          r'((?:accessKey|access_key|mobile_access_key|token|sign)=)[^&\s"<>]+',
          caseSensitive: false,
        ),
        r'$1<redacted>',
      );
  return compactSummary(redacted);
}

Future<Uint8List> readBytesWithLimit(
  Stream<List<int>> stream, {
  required int maxBytes,
}) async {
  final bytes = BytesBuilder(copy: false);
  var length = 0;
  await for (final chunk in stream) {
    length += chunk.length;
    if (length > maxBytes) {
      throw const FormatException('response body too large');
    }
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

Future<String> readUtf8WithLimit(
  Stream<List<int>> stream, {
  required int maxBytes,
}) async {
  final bytes = await readBytesWithLimit(stream, maxBytes: maxBytes);
  return utf8.decode(bytes, allowMalformed: true);
}

String shortText(String value, {int maxLength = 80}) {
  final text = value.trim();
  if (text.length <= maxLength) {
    return text;
  }
  return '${text.substring(0, maxLength - 24)}...${text.substring(text.length - 18)}';
}


String displayFileName(String url) {
  final uri = Uri.tryParse(url);
  final segment = uri?.pathSegments.where((item) => item.isNotEmpty).lastOrNull;
  if (segment == null || segment.isEmpty) {
    return '远端媒体';
  }
  return Uri.decodeComponent(segment);
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

