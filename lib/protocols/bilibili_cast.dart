import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' as pc;

import '../models/cast_models.dart';
import '../platform/player_bridge.dart';
import '../protocols/dlna_upnp.dart';
import '../services/http_cast_install.dart';

const String biliMobileAppKey = '1d8b6e7d45233436';
const String biliMobileAppSecret = '560c52ccd288fed045859ed18bffd973';
const String biliMobileMobiApp = 'android';
const String biliMobileChannel = 'bili';
const int biliProjectionMaxQn = 120;
const String biliNvaAesKey = '1pzhA828t4i.6Oq@';
const int biliNirvanaRequestOp = 0xe003;
const int biliNirvanaEmptyRequestOp = 0xe002;
const int biliNirvanaResponseOp = 0xe004;
const int biliNirvanaBodyResponseOp = 0xc003;
const int biliNirvanaHeartbeatRequestOp = 0xe400;
const int biliNirvanaHeartbeatResponseOp = 0xe401;
const int biliNirvanaShortControlOp = 0xc000;
const int ottBlinkPort = 8100;
const int nirvanaControlPort = 9958;

class BiliNvaLink {
  const BiliNvaLink({required this.callbackUrl, required this.code});

  final String callbackUrl;
  final String code;

  Map<String, Object?> toJson() => {
        'cb': callbackUrl,
        'cd': code,
      };
}

class BiliNvaExt {
  const BiliNvaExt({
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
  final BiliNvaLink? link;

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


BiliCastStatus? latestBiliCastStatus;
BiliNvaPlayRequest? latestBiliNvaPlayRequest;
final Set<Socket> biliNvaSessions = <Socket>{};
final Map<Socket, Future<void>> biliNvaSessionWrites =
    <Socket, Future<void>>{};
int biliNvaServerSequence = 1000;
int biliNvaPlayState = biliPlayStateIdle;

const int biliPlayStateIdle = 0;
const int biliPlayStatePlaying = 4;
const int biliPlayStatePaused = 5;


bool isOttBlinkSearch(Uint8List data) {
  return data.length >= 6 && data[0] == 0x24 && data[1] == 0x10;
}

Uint8List ottBlinkResponse(String receiverName) {
  final payload = utf8.encode(jsonEncode(ottBlinkDeviceMsg(receiverName)));
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

Map<String, Object> ottBlinkDeviceMsg(String receiverName) {
  return {
    'address': biliProjectionMobiApp,
    'uuid': biliProjectionAutoPullId,
    'friendlyName': biliFriendlyName(receiverName),
    'model_name': biliProjectionModelName,
    'brand_name': biliProjectionBrandName,
    'manufacture': biliProjectionManufacturer,
    'brandName': biliProjectionBrandName,
    'manufacturer': biliProjectionManufacturer,
    'channelName': biliProjectionChannelName,
    'mobiApp': biliProjectionMobiApp,
    'build': biliProjectionBuild,
    'version': biliProjectionBuild,
    'ottVersion': biliProjectionBuild,
    'support4k': biliProjectionSupport4k,
    'fourk': biliProjectionFourk,
    'capability': biliProjectionCapability,
    'castService': biliProjectionCastService,
    'needNvaExtra': biliProjectionNeedNvaExtra,
    'autoPullId': biliProjectionAutoPullId,
    'ignoreDirect': biliProjectionIgnoreDirect,
  };
}

BiliNvaExt? extractBiliNvaExt(String value) {
  final text = value.trim();
  if (text.isEmpty) {
    return null;
  }

  final encrypted = findQueryLikeValue(text, '_nva_ext_');
  if (encrypted != null && encrypted.isNotEmpty) {
    final json = decryptBiliNvaJson(encrypted);
    if (json != null) {
      return parseBiliNvaJson(json);
    }
  }

  final plain = findQueryLikeValue(text, 'nva_ext');
  if (plain != null && plain.isNotEmpty) {
    return parseBiliNvaJson(plain);
  }

  final parsed = tryJsonDecode(text);
  final nested = findBiliNvaExtInJson(parsed);
  if (nested != null) {
    return nested;
  }

  return null;
}

String? findQueryLikeValue(String value, String key) {
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

BiliNvaExt? findBiliNvaExtInJson(Object? value) {
  if (value is String) {
    return extractBiliNvaExt(value);
  }
  if (value is List) {
    for (final item in value) {
      final ext = findBiliNvaExtInJson(item);
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
          final json = decryptBiliNvaJson(raw);
          if (json != null) {
            return parseBiliNvaJson(json);
          }
        } else {
          return parseBiliNvaJson(raw);
        }
      }
    }
    for (final item in value.values) {
      final ext = findBiliNvaExtInJson(item);
      if (ext != null) {
        return ext;
      }
    }
  }
  return null;
}

BiliNvaExt? parseBiliNvaJson(String json) {
  final parsed = tryJsonDecode(json);
  if (parsed is! Map) {
    return null;
  }

  final content = parsed['content'];
  final raw = <String, Object?>{
    for (final entry in (content is Map ? content : parsed).entries)
      if (entry.key is String) entry.key as String: entry.value,
  };
  final link = raw['nl'];
  BiliNvaLink? nvaLink;
  if (link is Map) {
    nvaLink = BiliNvaLink(
      callbackUrl: (link['cb'] as String?)?.trim() ?? '',
      code: (link['cd'] as String?)?.trim() ?? '',
    );
  }

  return BiliNvaExt(
    raw: raw,
    qn: jsonInt(raw['qn']),
    userDesiredQn: jsonInt(raw['userDesireQn']),
    ignoreDirect: jsonBool(raw['ignore_direct'] ?? raw['ignoreDirect']),
    link: nvaLink,
  );
}

int? jsonInt(Object? value) {
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

bool? jsonBool(Object? value) {
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

String? decryptBiliNvaJson(String hex) {
  try {
    final encrypted = hexToBytes(hex);
    final decrypted = biliNvaAesProcess(encrypted, forEncryption: false);
    return utf8.decode(decrypted, allowMalformed: false);
  } on Object {
    return null;
  }
}

String encryptBiliNvaJson(String json) {
  final encrypted = biliNvaAesProcess(
    Uint8List.fromList(utf8.encode(json)),
    forEncryption: true,
  );
  return bytesToHex(encrypted);
}

Uint8List biliNvaAesProcess(
  Uint8List input, {
  required bool forEncryption,
}) {
  final key = Uint8List.fromList(utf8.encode(biliNvaAesKey));
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

Uint8List hexToBytes(String hex) {
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

String bytesToHex(Uint8List bytes) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

Future<String?> sendBiliNvaLinkReply(
  BiliNvaExt nvaExt,
  String localAddress,
) async {
  final callbackUrl = nvaExt.link?.callbackUrl.trim() ?? '';
  if (callbackUrl.isEmpty) {
    return null;
  }
  final callback = Uri.tryParse(callbackUrl);
  if (callback == null || !callback.hasScheme || callback.host.isEmpty) {
    return 'B站 NVA callback 不可用：${safeUrlForLog(callbackUrl)}';
  }
  if (callback.scheme != 'http' && callback.scheme != 'https') {
    return 'B站 NVA callback 协议不受支持：${callback.scheme}';
  }

  final reply = biliNvaLinkReply(
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
    return 'B站 link_reply 回调失败：${shortError(error)}';
  } finally {
    client.close(force: true);
  }
}

String biliNvaLinkReply({
  required String localAddress,
  required String code,
}) {
  return encryptBiliNvaJson(jsonEncode({
    'code': code,
    'from': 'coolcast',
    'buvid': biliProjectionAutoPullId,
    'nvaLinkAddress': biliNvaLinkAddress(localAddress),
    'friendlyName': biliProjectionFriendlyName,
    'modelName': biliProjectionModelName,
    'brandName': biliProjectionBrandName,
    'manufacturer': biliProjectionManufacturer,
    'ottVersion': biliProjectionBuild,
    'ignoreDirect': biliProjectionIgnoreDirect,
    'autoPullId': biliProjectionAutoPullId,
  }));
}

String biliNvaLinkAddress(String localAddress) {
  final address = localAddress.trim();
  if (address.isEmpty || address == '0.0.0.0') {
    return '$biliProjectionAutoPullId:$nirvanaControlPort';
  }
  return '$address:$nirvanaControlPort';
}

bool looksLikeCompleteNirvanaPayload(List<int> data) {
  if (data.isEmpty) {
    return false;
  }
  final text = utf8.decode(data, allowMalformed: true).trim();
  if (text.startsWith('SETUP ') || text.startsWith('RESTORE ')) {
    return hasNirvanaHeader(text, 'Session') &&
        hasNirvanaHeader(text, 'NvaVersion') &&
        hasNirvanaHeader(text, 'UUID');
  }
  if (text.startsWith('{') && text.endsWith('}')) {
    return true;
  }
  return text.contains('\r\n\r\n');
}

bool hasNirvanaHeader(String text, String name) {
  return RegExp(
    '^$name\\s*:',
    caseSensitive: false,
    multiLine: true,
  ).hasMatch(text);
}

bool looksLikeTextNirvanaPayload(List<int> data) {
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

bool shouldSendNirvanaTextAck(List<int> data) {
  if (data.isEmpty || !looksLikeTextNirvanaPayload(data)) {
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

String? extractNirvanaControlUrl(String payload) {
  final parsed = tryJsonDecode(payload);
  final fromJson = parsed == null ? null : findUrlInJson(parsed);
  if (isValidCastUrl(fromJson ?? '')) {
    return fromJson;
  }

  final urlMatch = RegExp(
    r'https?://[^\s"<>\\]+',
    caseSensitive: false,
  ).firstMatch(payload);
  final rawUrl = urlMatch?.group(0);
  if (isValidCastUrl(rawUrl ?? '')) {
    return rawUrl;
  }
  return null;
}

Object? tryJsonDecode(String payload) {
  try {
    return jsonDecode(payload.trim());
  } on Object {
    return null;
  }
}

String? findUrlInJson(Object? value) {
  if (value is String) {
    if (isValidCastUrl(value)) {
      return value;
    }
    final nested = tryJsonDecode(value);
    if (nested != null) {
      return findUrlInJson(nested);
    }
    return null;
  }
  if (value is List) {
    for (final item in value) {
      final url = findUrlInJson(item);
      if (url != null) {
        return url;
      }
    }
    return null;
  }
  if (value is Map) {
    for (final key in const ['url', 'playUrl', 'play_url']) {
      final url = findUrlInJson(value[key]);
      if (url != null) {
        return url;
      }
    }
    for (final item in value.values) {
      final url = findUrlInJson(item);
      if (url != null) {
        return url;
      }
    }
  }
  return null;
}

class BiliNvaPlayRequest {
  const BiliNvaPlayRequest({
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
    return accessKey.isEmpty ? preferredQn : biliProjectionMaxQn;
  }

  BiliNvaPlayRequest copyWith({
    int? qn,
    int? userDesireQn,
    int? seekTs,
  }) {
    return BiliNvaPlayRequest(
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

  static BiliNvaPlayRequest? fromBody(String body) {
    final decoded = tryJsonDecode(body);
    if (decoded is! Map) {
      return null;
    }
    final raw = decoded.cast<String, Object?>();
    final aid = jsonInt(raw['aid']) ?? jsonInt(raw['avid']);
    final cid = jsonInt(raw['cid']);
    final accessKey = jsonString(raw['accessKey']) ??
        jsonString(raw['access_key']) ??
        jsonString(raw['mobile_access_key']) ??
        '';
    if (cid == null || accessKey.isEmpty) {
      return null;
    }
    return BiliNvaPlayRequest(
      raw: raw,
      aid: aid,
      cid: cid,
      accessKey: accessKey,
      qn: jsonInt(raw['qn']),
      userDesireQn:
          jsonInt(raw['userDesireQn']) ?? jsonInt(raw['userDesiredQn']),
      contentType: jsonInt(raw['contentType']),
      seasonId: jsonInt(raw['seasonId']),
      epId: jsonInt(raw['epId']),
      seekTs: jsonInt(raw['seekTs']),
      mobileVersion: jsonInt(raw['mobileVersion']),
      bvid: findBvidInJson(raw),
    );
  }
}

int? biliSwitchQnFromBody(String body) {
  final decoded = tryJsonDecode(body);
  if (decoded is! Map) {
    return null;
  }
  return jsonInt(decoded['qn']) ??
      jsonInt(decoded['quality']) ??
      jsonInt(decoded['userDesireQn']);
}

Duration? biliSeekPositionFromBody(String body) {
  final decoded = tryJsonDecode(body);
  if (decoded is! Map) {
    return null;
  }
  final seconds = jsonInt(decoded['position']) ??
      jsonInt(decoded['progress']) ??
      jsonInt(decoded['seekTs']) ??
      jsonInt(decoded['pos']);
  return seconds == null ? null : Duration(seconds: seconds);
}

class BiliPlayUrlResult {
  const BiliPlayUrlResult.url(this.url, {this.status}) : error = null;
  const BiliPlayUrlResult.error(this.error)
      : url = null,
        status = null;

  final String? url;
  final String? error;
  final BiliCastStatus? status;
}

Future<BiliPlayUrlResult> fetchBiliPlayUrl(BiliNvaPlayRequest play) async {
  final publicUri = biliPublicPlayerPlayUrlUri(play);
  if (publicUri != null) {
    final publicResult = await fetchBiliPlayUrlFromUri(
      publicUri,
      label: 'B站 player playurl',
      refererBvid: play.bvid,
      aid: play.aid,
      cid: play.cid,
    );
    if (publicResult.url != null) {
      return publicResult;
    }
    debugLog('B站 player playurl failed, fallback to tv playurl');
    final tvResult = await fetchBiliPlayUrlFromUri(
      biliTvPlayUrlUri(play),
      label: 'B站 tv playurl',
      refererBvid: play.bvid,
      aid: play.aid,
      cid: play.cid,
    );
    if (tvResult.url != null) {
      return tvResult;
    }
    return BiliPlayUrlResult.error(
      '${publicResult.error ?? 'player playurl failed'}; '
      '${tvResult.error ?? 'tv playurl failed'}',
    );
  }
  return fetchBiliPlayUrlFromUri(
    biliTvPlayUrlUri(play),
    label: 'B站 tv playurl',
    refererBvid: play.bvid,
    aid: play.aid,
    cid: play.cid,
  );
}

Future<BiliPlayUrlResult> fetchBiliPlayUrlFromUri(
  Uri uri, {
  required String label,
  required String? refererBvid,
  required int? aid,
  required int? cid,
}) async {
  debugLog('$label request: ${safeUrlForLog(uri.toString())}');
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
    final body = await readUtf8WithLimit(
      response,
      maxBytes: maxApiResponseBodyBytes,
    );
    debugLog(
      '$label response status=${response.statusCode} '
      'bytes=${body.length} body=${safeTextForLog(body)}',
    );
    if (response.statusCode != HttpStatus.ok) {
      return BiliPlayUrlResult.error('$label HTTP ${response.statusCode}');
    }
    final decoded = tryJsonDecode(body);
    final apiCode = biliApiCode(decoded);
    if (apiCode != null && apiCode != 0) {
      return BiliPlayUrlResult.error(
        '$label code=$apiCode ${biliApiMessage(decoded)}'.trim(),
      );
    }
    final url = extractBiliPlayUrl(decoded);
    if (url == null) {
      return BiliPlayUrlResult.error('$label 无 durl/url');
    }
    return BiliPlayUrlResult.url(
      url,
      status: extractBiliCastStatus(
        decoded,
        aid: aid,
        cid: cid,
      ),
    );
  } on Object catch (error) {
    return BiliPlayUrlResult.error('$label 异常：${shortError(error)}');
  } finally {
    client.close(force: true);
  }
}

Uri biliTvPlayUrlUri(BiliNvaPlayRequest play) {
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
        ? '{need_hdr=0, ott_build=$biliProjectionBuild}'
        : '',
    'fnver': '0',
    'fnval': '0',
    'fourk': '$biliProjectionFourk',
    'sys_ver': '${play.mobileVersion ?? biliProjectionBuild}',
    'buvid': biliProjectionAutoPullId,
    'access_key': play.accessKey,
    'ogv_aid': '${play.aid ?? 0}',
    'language': 'zh-CN',
    'device_type': '1',
    'from_outside': '1',
  };
  addBiliSignedCommonParams(query, build: play.mobileVersion);
  return Uri.https('api.bilibili.com', '/x/tv/playurl', query);
}

Uri? biliPublicPlayerPlayUrlUri(BiliNvaPlayRequest play) {
  if (play.cid == null) {
    return null;
  }
  final query = <String, String>{
    'cid': '${play.cid}',
    'qn': '${play.preferredPublicQn}',
    'fnver': '0',
    'fnval': play.accessKey.isEmpty ? '0' : '4048',
    'fourk': '$biliProjectionFourk',
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

Map<String, String> biliPlaybackHeaders({String? bvid, int? aid}) {
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

String? extractBiliPlayUrl(Object? decoded) {
  final data = jsonMap(decoded)?['data'] ?? jsonMap(decoded)?['result'];
  return findUrlInBiliPlayUrl(data) ?? findUrlInBiliPlayUrl(decoded);
}

BiliCastStatus? extractBiliCastStatus(
  Object? decoded, {
  required int? aid,
  required int? cid,
}) {
  final data = jsonMap(decoded)?['data'] ?? jsonMap(decoded)?['result'];
  final map = jsonMap(data);
  if (map == null) {
    return null;
  }
  final quality = jsonInt(map['quality']);
  final timelength = jsonInt(map['timelength']);
  final acceptQuality = jsonIntList(map['accept_quality']);
  if (quality == null && timelength == null && acceptQuality.isEmpty) {
    return null;
  }
  return BiliCastStatus(
    aid: aid,
    cid: cid,
    quality: quality,
    timelength: timelength,
    acceptQuality: acceptQuality,
  );
}

String? findUrlInBiliPlayUrl(Object? value) {
  if (value is String) {
    return isValidCastUrl(value) ? value : null;
  }
  if (value is List) {
    for (final item in value) {
      final url = findUrlInBiliPlayUrl(item);
      if (url != null) {
        return url;
      }
    }
    return null;
  }
  final map = jsonMap(value);
  if (map == null) {
    return null;
  }
  final directUrl = findDirectBiliPlayUrl(map);
  if (directUrl != null) {
    return directUrl;
  }
  final dashUrl = findBiliDashUrl(map['dash'], jsonInt(map['quality']));
  if (dashUrl != null) {
    return dashUrl;
  }
  for (final item in map.values) {
    final url = findUrlInBiliPlayUrl(item);
    if (url != null) {
      return url;
    }
  }
  return null;
}

String? findDirectBiliPlayUrl(Map<String, Object?> map) {
  for (final key in const ['durl', 'url', 'baseUrl', 'base_url']) {
    final url = findUrlInBiliPlayUrl(map[key]);
    if (url != null) {
      return url;
    }
  }
  return null;
}

String? findBiliDashUrl(Object? value, int? quality) {
  final dash = jsonMap(value);
  if (dash == null) {
    return null;
  }
  final videos = dash['video'];
  if (videos is List) {
    if (quality != null) {
      for (final item in videos) {
        final map = jsonMap(item);
        if (map != null && jsonInt(map['id']) == quality) {
          final url = findDirectBiliPlayUrl(map);
          if (url != null) {
            return url;
          }
        }
      }
    }
    for (final item in videos) {
      final map = jsonMap(item);
      if (map != null) {
        final url = findDirectBiliPlayUrl(map);
        if (url != null) {
          return url;
        }
      }
    }
  }
  return findDirectBiliPlayUrl(dash);
}

int? biliApiCode(Object? decoded) => jsonInt(jsonMap(decoded)?['code']);

List<int> jsonIntList(Object? value) {
  if (value is! List) {
    return const [];
  }
  return value.map(jsonInt).whereType<int>().toList(growable: false);
}

String biliApiMessage(Object? decoded) {
  final map = jsonMap(decoded);
  return (jsonString(map?['message']) ?? jsonString(map?['msg']) ?? '')
      .trim();
}

Map<String, Object?>? jsonMap(Object? value) {
  if (value is! Map) {
    return null;
  }
  return value.cast<String, Object?>();
}

String? jsonString(Object? value) {
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  return null;
}

String? findBvidInJson(Object? value) {
  if (value is String) {
    final direct = RegExp(r'BV[0-9A-Za-z]+').firstMatch(value)?.group(0);
    if (direct != null) {
      return direct;
    }
    final nested = tryJsonDecode(value);
    return nested == null ? null : findBvidInJson(nested);
  }
  if (value is List) {
    for (final item in value) {
      final bvid = findBvidInJson(item);
      if (bvid != null) {
        return bvid;
      }
    }
    return null;
  }
  final map = jsonMap(value);
  if (map == null) {
    return null;
  }
  final direct = jsonString(map['bvid']);
  if (direct != null && direct.startsWith('BV')) {
    return direct;
  }
  for (final item in map.values) {
    final bvid = findBvidInJson(item);
    if (bvid != null) {
      return bvid;
    }
  }
  return null;
}

void addBiliSignedCommonParams(
  Map<String, String> query, {
  required int? build,
}) {
  query
    ..putIfAbsent('platform', () => 'android')
    ..putIfAbsent('mobi_app', () => biliMobileMobiApp)
    ..putIfAbsent('appkey', () => biliMobileAppKey)
    ..putIfAbsent('build', () => '${build ?? biliProjectionBuild}')
    ..putIfAbsent('channel', () => biliMobileChannel)
    ..putIfAbsent('c_locale', () => 'zh_CN')
    ..putIfAbsent('s_locale', () => 'zh_CN');
  query.remove('sign');
  query['sign'] = biliSignQuery(query);
}

String biliSignQuery(Map<String, String> query) {
  final canonical = query.entries.where((entry) => entry.key != 'sign').toList()
    ..sort((left, right) => left.key.compareTo(right.key));
  final source = canonical
      .map((entry) =>
          '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}')
      .join('&');
  return md5Hex('$source$biliMobileAppSecret');
}

String md5Hex(String value) {
  final digest =
      pc.Digest('MD5').process(Uint8List.fromList(utf8.encode(value)));
  return digest.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

String nirvanaControlSummary(Uint8List data) {
  if (data.isEmpty) {
    return '空包';
  }
  final text = utf8.decode(data, allowMalformed: true).trim();
  final printable = text.runes.every((rune) {
    return rune == 0x09 || rune == 0x0a || rune == 0x0d || rune >= 0x20;
  });
  if (printable && text.isNotEmpty) {
    return compactSummary(text);
  }
  final nvaFrame = parseNvaFrame(data);
  if (nvaFrame != null) {
    return nvaFrame.summary;
  }
  final nativeSummary = nativeFrameTextSummary(data);
  if (nativeSummary != null) {
    return nativeSummary;
  }
  final heartbeatSummary = nirvanaHeartbeatFrameSummary(data);
  if (heartbeatSummary != null) {
    return heartbeatSummary;
  }
  final shortControlSummary = nirvanaShortControlFrameSummary(data);
  if (shortControlSummary != null) {
    return shortControlSummary;
  }
  return 'hex ${data.take(32).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(' ')}';
}

String? nvaCommandForLog(Uint8List data) {
  final frame = parseNvaFrame(data);
  return frame?.attributes['Command'];
}

class NvaFrame {
  const NvaFrame({
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
      op == biliNirvanaRequestOp || op == biliNirvanaEmptyRequestOp;

  String get bodyText => utf8.decode(body, allowMalformed: true);

  String get summary {
    final command = attributes['Command'];
    final pieces = <String>[
      isRequest ? 'request' : 'response',
      'seq=$sequence',
      'op=0x${op.toRadixString(16)}',
      if (command != null) 'Command=$command',
      if (body.isNotEmpty) compactSummary(bodyText),
    ];
    return 'native ${pieces.join(' ')}';
  }
}

int? nvaFrameLength(List<int> data) {
  if (data.length < 7) {
    return null;
  }
  final op = readUint16(data, 0);
  if (op != biliNirvanaRequestOp &&
      op != biliNirvanaEmptyRequestOp &&
      op != biliNirvanaBodyResponseOp &&
      op != biliNirvanaResponseOp) {
    return null;
  }
  var offset = 6;
  final attrCount = data[offset];
  offset += 1;
  for (var i = 0; i < attrCount; i++) {
    final keyLength = nvaStringLength(data, offset);
    if (keyLength == null) {
      return null;
    }
    offset += 1 + keyLength;
    final valueLength = nvaStringLength(data, offset);
    if (valueLength == null) {
      return null;
    }
    offset += 1 + valueLength;
  }
  if (op == biliNirvanaEmptyRequestOp) {
    return offset;
  }
  if (data.length < offset + 4) {
    return null;
  }
  final bodyLength = readUint32(data, offset);
  if (bodyLength == null) {
    return null;
  }
  return offset + 4 + bodyLength;
}

int? nirvanaShortControlFrameLength(List<int> data) {
  if (data.length < 6) {
    return null;
  }
  final op = readUint16(data, 0);
  return op == biliNirvanaShortControlOp ? 6 : null;
}

int? nvaStringLength(List<int> data, int offset) {
  if (data.length < offset + 1) {
    return null;
  }
  final length = data[offset];
  if (data.length < offset + 1 + length) {
    return null;
  }
  return length;
}

NvaFrame? parseNvaFrame(Uint8List data) {
  final frameLength = nvaFrameLength(data);
  if (frameLength != data.length || data.length < 7) {
    return null;
  }
  final op = readUint16(data, 0);
  final sequence = readUint32(data, 2);
  if (op == null || sequence == null) {
    return null;
  }
  if (op != biliNirvanaRequestOp &&
      op != biliNirvanaEmptyRequestOp &&
      op != biliNirvanaBodyResponseOp &&
      op != biliNirvanaResponseOp) {
    return null;
  }
  var offset = 6;
  final attrCount = data[offset];
  offset += 1;
  final attributes = <String, String>{};
  for (var i = 0; i < attrCount; i++) {
    final key = readNvaString(data, offset);
    if (key == null) {
      return null;
    }
    offset += 1 + key.lengthInBytes;
    final value = readNvaString(data, offset);
    if (value == null) {
      return null;
    }
    offset += 1 + value.lengthInBytes;
    attributes[key.value] = value.value;
  }
  var body = Uint8List(0);
  if (op != biliNirvanaEmptyRequestOp && offset < data.length) {
    final bodyLength = readUint32(data, offset);
    if (bodyLength == null || data.length < offset + 4 + bodyLength) {
      return null;
    }
    offset += 4;
    body = Uint8List.sublistView(data, offset, offset + bodyLength);
  }
  return NvaFrame(
    op: op,
    sequence: sequence,
    attributes: attributes,
    body: body,
  );
}

class NvaString {
  const NvaString(this.value, this.lengthInBytes);

  final String value;
  final int lengthInBytes;
}

NvaString? readNvaString(List<int> data, int offset) {
  final length = nvaStringLength(data, offset);
  if (length == null) {
    return null;
  }
  final start = offset + 1;
  return NvaString(
    utf8.decode(data.sublist(start, start + length), allowMalformed: true),
    length,
  );
}

int? readUint16(List<int> data, int offset) {
  if (data.length < offset + 2) {
    return null;
  }
  return ByteData.sublistView(Uint8List.fromList(data), offset, offset + 2)
      .getUint16(0);
}

int? readUint32(List<int> data, int offset) {
  if (data.length < offset + 4) {
    return null;
  }
  return ByteData.sublistView(Uint8List.fromList(data), offset, offset + 4)
      .getUint32(0);
}

Uint8List nvaFrame({
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
    addNvaString(bytes, entry.key);
    addNvaString(bytes, entry.value);
  }
  final bodyHeader = ByteData(4)..setUint32(0, body.length);
  bytes.add(bodyHeader.buffer.asUint8List());
  bytes.add(body);
  return bytes.toBytes();
}

Uint8List nvaEmptyRequestFrame({
  required int sequence,
  required Map<String, String> attributes,
}) {
  final bytes = BytesBuilder();
  final header = ByteData(7);
  header.setUint16(0, biliNirvanaEmptyRequestOp);
  header.setUint32(2, sequence);
  header.setUint8(6, attributes.length);
  bytes.add(header.buffer.asUint8List());
  for (final entry in attributes.entries) {
    addNvaString(bytes, entry.key);
    addNvaString(bytes, entry.value);
  }
  return bytes.toBytes();
}

void addNvaString(BytesBuilder bytes, String value) {
  final encoded = utf8.encode(value);
  bytes.addByte(encoded.length);
  bytes.add(encoded);
}

String? nirvanaHeartbeatFrameSummary(Uint8List data) {
  if (data.length != 11) {
    return null;
  }
  final view = ByteData.view(data.buffer, data.offsetInBytes, data.length);
  final op = view.getUint16(0);
  if (op != biliNirvanaHeartbeatRequestOp &&
      op != biliNirvanaHeartbeatResponseOp) {
    return null;
  }
  final seq = view.getUint32(2);
  final length = view.getUint32(7);
  final name =
      op == biliNirvanaHeartbeatRequestOp ? 'heartbeat request' : 'heartbeat';
  return 'native $name seq=$seq op=0x${op.toRadixString(16)} len=$length';
}

String? nirvanaShortControlFrameSummary(Uint8List data) {
  if (nirvanaShortControlFrameLength(data) != data.length) {
    return null;
  }
  final sequence = readUint32(data, 2);
  if (sequence == null) {
    return null;
  }
  return 'native control seq=$sequence op=0xc000';
}

String? nativeFrameTextSummary(Uint8List data) {
  final fragments = printableAsciiFragments(data)
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
  return compactSummary('native ${selected.join(' | ')}');
}


String nirvanaProbeAck({String localAddress = ''}) {
  return jsonEncode({
    'code': 0,
    'status': 'ok',
    'message': 'success',
    'receiver': biliProjectionModelName,
    'from': 'coolcast',
    'buvid': biliProjectionAutoPullId,
    'nvaLinkAddress': biliNvaLinkAddress(localAddress),
    'friendlyName': biliProjectionFriendlyName,
    'modelName': biliProjectionModelName,
    'brandName': biliProjectionBrandName,
    'manufacturer': biliProjectionManufacturer,
    'ottVersion': biliProjectionBuild,
    'device': ottBlinkDeviceMsg(biliProjectionFriendlyName),
    'support4k': biliProjectionSupport4k,
    'capability': biliProjectionCapability,
    'castService': biliProjectionCastService,
    'needNvaExtra': biliProjectionNeedNvaExtra,
    'ignoreDirect': biliProjectionIgnoreDirect,
    'autoPullId': biliProjectionAutoPullId,
  });
}

String nirvanaTextAck(Uint8List data, {String localAddress = ''}) {
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
      'Server: $upnpServerHeader',
      'Connection: Keep-Alive',
      'Content-Length: 0',
      '',
      '',
    ];
    return headers.join('\r\n');
  }
  return nirvanaProbeAck(localAddress: localAddress);
}

Uint8List nirvanaPingFrame(int sequence) {
  final frame = Uint8List(11);
  ByteData.view(frame.buffer).setUint16(0, biliNirvanaHeartbeatResponseOp);
  ByteData.view(frame.buffer).setUint32(2, sequence);
  frame[6] = 0x00;
  ByteData.view(frame.buffer).setUint32(7, 0);
  return frame;
}

Uint8List nirvanaShortControlFrame(int sequence) {
  final frame = Uint8List(6);
  ByteData.view(frame.buffer).setUint16(0, biliNirvanaShortControlOp);
  ByteData.view(frame.buffer).setUint32(2, sequence);
  return frame;
}

List<Uint8List> nirvanaFrameResponses(Uint8List data) {
  final parsedFrame = parseNvaFrame(data);
  if (parsedFrame != null && parsedFrame.isRequest) {
    final command = parsedFrame.attributes['Command'];
    final responseBody = defaultNirvanaResponseBodyForCommand(
      command,
    );
    if (responseBody.isEmpty) {
      return [nirvanaShortControlFrame(parsedFrame.sequence)];
    }
    return [
      nvaFrame(
        op: biliNirvanaBodyResponseOp,
        sequence: parsedFrame.sequence,
        attributes: {
          if (command != null && command.isNotEmpty) 'Command': command,
        },
        body: Uint8List.fromList(utf8.encode(responseBody)),
      ),
    ];
  }
  if (data.length != 11) {
    return const [];
  }
  final view = ByteData.view(data.buffer, data.offsetInBytes, data.length);
  final op = view.getUint16(0);
  if (op != biliNirvanaHeartbeatRequestOp) {
    return const [];
  }
  final sequence = view.getUint32(2);
  return [nirvanaPingFrame(sequence)];
}

String defaultNirvanaResponseBodyForCommand(String? command) {
  switch (command) {
    case 'GetVolume':
      return jsonEncode({'volume': 50});
    case 'GetTvInfo':
      return biliTvInfoResponseBody(latestBiliCastStatus);
    case 'GetPlayInfo':
      return biliPlayInfoResponseBody(
        latestBiliCastStatus,
        playState: biliNvaPlayState,
      );
    default:
      return '';
  }
}

String biliTvInfoResponseBody(BiliCastStatus? status) {
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

String biliPlayInfoResponseBody(
  BiliCastStatus? status, {
  int? playState,
}) {
  final durationMs = status?.timelength ?? 0;
  final durationSeconds = biliSecondsFromMilliseconds(durationMs);
  final currentPlayState =
      status == null ? biliPlayStateIdle : playState ?? biliPlayStatePlaying;
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
    'qn': biliQnDescriptionBody(status),
    'title': '',
    'volume': 50,
    'speedInfo': {
      'supportSpeedList': [0.5, 0.75, 1.0, 1.25, 1.5, 2.0],
      'currSpeed': 1.0,
    },
  });
}

int biliSecondsFromMilliseconds(int milliseconds) =>
    (milliseconds / Duration.millisecondsPerSecond).round();

Map<String, Object?>? biliQnDescriptionBody(BiliCastStatus? status) {
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
          'description': biliQualityDescription(quality),
          'displayDesc': biliQualityDescription(quality),
          'superscript': '',
          'needLogin': false,
          'needVip': false,
        },
    ],
    'curQn': status.quality ?? qualities.first,
    'userDesireQn': status.quality ?? qualities.first,
  };
}


Uint8List nvaServerEventFrame({
  required String command,
  required String body,
}) =>
    nvaFrame(
      op: biliNirvanaRequestOp,
      sequence: ++biliNvaServerSequence,
      attributes: {'Command': command},
      body: Uint8List.fromList(utf8.encode(body)),
    );
