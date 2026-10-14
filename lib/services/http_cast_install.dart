import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/cast_models.dart';

const int maxControlRequestBodyBytes = 256 * 1024;
const int maxApiResponseBodyBytes = 2 * 1024 * 1024;
const int maxImageBytes = 24 * 1024 * 1024;
const int maxApkUploadBytes = 512 * 1024 * 1024;

String htmlForm({
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

String htmlResponse(String url, {required bool isAccepted}) {
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


String installPageUrl(String ipAddress) {
  final normalized = ipAddress.trim();
  if (normalized.isEmpty ||
      normalized == 'TV-IP' ||
      normalized == 'Browser Preview') {
    return 'http://TV-IP:7788/install';
  }
  return 'http://$normalized:7788/install';
}

String installHtmlForm({
  required String receiverName,
  required String ipAddress,
  required String statusMessage,
}) {
  final safeReceiverName = htmlEscape(receiverName);
  final safeIpAddress = htmlEscape(ipAddress);
  final safeStatus = htmlEscape(statusMessage);
  return '''
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>远程安装应用 - $safeReceiverName</title>
  <style>
    body{font-family:system-ui,-apple-system,sans-serif;margin:0;background:#eaf6ff;color:#102033}
    main{max-width:640px;margin:0 auto;padding:32px 20px}
    section{background:rgba(255,255,255,.86);border:1px solid #d6e6f5;border-radius:24px;padding:24px;box-shadow:0 20px 60px rgba(10,58,107,.12)}
    h1{margin:0 0 8px;font-size:28px}
    p{color:#5e7186;line-height:1.6;margin:8px 0}
    .status{background:#f2f8ff;border:1px solid #d6e6f5;border-radius:14px;padding:12px 14px;color:#102033;font-weight:600;margin:14px 0}
    input[type=file]{box-sizing:border-box;width:100%;margin:16px 0;padding:14px;border-radius:14px;border:1px dashed #0a84ff;background:#f7fbff;color:#102033;font-size:16px}
    button{box-sizing:border-box;width:100%;font-size:18px;padding:14px;border-radius:14px;background:#0a84ff;color:white;border:0;font-weight:800;cursor:pointer}
    button:disabled{opacity:.6;cursor:not-allowed}
    progress{width:100%;height:12px;margin-top:14px;display:none}
  </style>
</head>
<body>
  <main>
    <section>
      <h1>远程安装到 $safeReceiverName</h1>
      <p>选择一个手机本地的 <strong>.apk</strong> 安装包上传，上传完成后电视将自动开始安装。</p>
      <div class="status" id="status-box">当前状态：$safeStatus</div>
      <form id="apk-upload-form" action="/install/upload" method="post" enctype="multipart/form-data">
        <input id="apk-file" type="file" name="apk" accept=".apk,application/vnd.android.package-archive" required>
        <button id="submit-btn" type="submit">上传并安装 APK</button>
        <progress id="upload-progress" value="0" max="100"></progress>
      </form>
      <p>目标设备 IP：$safeIpAddress</p>
    </section>
  </main>
  <script>
    (function() {
      var form = document.getElementById('apk-upload-form');
      var fileInput = document.getElementById('apk-file');
      var submitBtn = document.getElementById('submit-btn');
      var statusBox = document.getElementById('status-box');
      var progressBar = document.getElementById('upload-progress');
      if (!form || !fileInput || !window.XMLHttpRequest) return;
      form.addEventListener('submit', function(e) {
        var file = fileInput.files && fileInput.files[0];
        if (!file) return;
        e.preventDefault();
        submitBtn.disabled = true;
        progressBar.style.display = 'block';
        progressBar.value = 0;
        statusBox.textContent = '正在上传 ' + file.name + ' (0%)...';
        var xhr = new XMLHttpRequest();
        xhr.open('POST', '/install/upload?filename=' + encodeURIComponent(file.name), true);
        xhr.setRequestHeader('Content-Type', 'application/vnd.android.package-archive');
        xhr.upload.onprogress = function(event) {
          if (event.lengthComputable) {
            var percent = Math.round((event.loaded / event.total) * 100);
            progressBar.value = percent;
            statusBox.textContent = '正在上传 ' + file.name + ' (' + percent + '%)...';
          }
        };
        xhr.onload = function() {
          document.open();
          document.write(xhr.responseText);
          document.close();
        };
        xhr.onerror = function() {
          submitBtn.disabled = false;
          statusBox.textContent = '上传中断，请检查局域网连接后重试。';
        };
        xhr.send(file);
      });
    })();
  </script>
</body>
</html>
''';
}

String installUploadHtmlResponse({
  required String fileName,
  required bool isAccepted,
  required String detail,
}) {
  final title = isAccepted ? 'APK 上传成功，正在安装' : 'APK 上传失败';
  final safeFileName = htmlEscape(fileName);
  final safeDetail = htmlEscape(detail);
  return '''
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>$title - CoolCast</title>
</head>
<body style="font-family:system-ui,-apple-system,sans-serif;margin:32px;background:#eaf6ff;color:#102033">
  <h1>$title</h1>
  <p>$safeDetail</p>
  <p>${safeFileName.isEmpty ? '未识别到有效的 APK 文件' : '文件：$safeFileName'}</p>
  <p><a href="/install">返回继续上传</a></p>
</body>
</html>
''';
}

class UploadedApkPayload {
  const UploadedApkPayload({
    required this.fileName,
    required this.bytes,
  });

  final String fileName;
  final Uint8List bytes;
}

UploadedApkPayload? extractUploadedApk(
  Uint8List rawBytes, {
  String? contentTypeHeader,
  String? queryFileName,
}) {
  if (rawBytes.isEmpty) {
    return null;
  }
  final contentType = contentTypeHeader ?? '';
  if (contentType.toLowerCase().contains('multipart/form-data')) {
    final boundaryMatch =
        RegExp(r'boundary=([^;\s]+)', caseSensitive: false)
            .firstMatch(contentType);
    var boundary = boundaryMatch?.group(1)?.trim() ?? '';
    if (boundary.startsWith('"') && boundary.endsWith('"') && boundary.length >= 2) {
      boundary = boundary.substring(1, boundary.length - 1);
    }
    if (boundary.isEmpty) {
      return null;
    }
    return extractMultipartApk(rawBytes, boundary);
  }

  final candidateName = (queryFileName ?? '').trim();
  final fileName =
      candidateName.isEmpty ? 'uploaded_app.apk' : sanitizeApkFileName(candidateName);
  if (!isValidApkFileNameAndMagic(fileName, rawBytes)) {
    return null;
  }
  return UploadedApkPayload(fileName: fileName, bytes: rawBytes);
}

UploadedApkPayload? extractMultipartApk(Uint8List rawBytes, String boundary) {
  const headerDelimiter = [13, 10, 13, 10]; // \r\n\r\n
  var searchOffset = 0;
  while (searchOffset < rawBytes.length) {
    final headerEnd = indexOfBytes(rawBytes, headerDelimiter, searchOffset);
    if (headerEnd < 0) {
      break;
    }
    final headerText =
        utf8.decode(rawBytes.sublist(searchOffset, headerEnd), allowMalformed: true);
    final bodyStart = headerEnd + 4;
    final closingBoundary = utf8.encode('\r\n--$boundary');
    final partEnd = indexOfBytes(rawBytes, closingBoundary, bodyStart);
    if (partEnd < 0) {
      break;
    }
    final fileNameMatch = RegExp(
      r'filename\s*=\s*"([^"]+)"',
      caseSensitive: false,
    ).firstMatch(headerText);
    final rawFileName = fileNameMatch?.group(1)?.trim() ?? '';
    if (rawFileName.isNotEmpty) {
      final partBytes = Uint8List.sublistView(rawBytes, bodyStart, partEnd);
      final sanitized = sanitizeApkFileName(rawFileName);
      if (isValidApkFileNameAndMagic(sanitized, partBytes)) {
        return UploadedApkPayload(
          fileName: sanitized,
          bytes: Uint8List.fromList(partBytes),
        );
      }
    }
    searchOffset = partEnd + closingBoundary.length;
  }
  return null;
}

int indexOfBytes(Uint8List source, List<int> pattern, int start) {
  if (pattern.isEmpty || source.length - start < pattern.length) {
    return -1;
  }
  final first = pattern.first;
  final maxIndex = source.length - pattern.length;
  for (var i = start; i <= maxIndex; i++) {
    if (source[i] != first) {
      continue;
    }
    var matched = true;
    for (var j = 1; j < pattern.length; j++) {
      if (source[i + j] != pattern[j]) {
        matched = false;
        break;
      }
    }
    if (matched) {
      return i;
    }
  }
  return -1;
}

bool isValidApkFileNameAndMagic(String fileName, Uint8List bytes) {
  if (!fileName.toLowerCase().endsWith('.apk')) {
    return false;
  }
  // APK is a ZIP archive starting with 'PK\x03\x04' (0x50, 0x4B, 0x03, 0x04).
  return bytes.length >= 4 &&
      bytes[0] == 0x50 &&
      bytes[1] == 0x4B &&
      bytes[2] == 0x03 &&
      bytes[3] == 0x04;
}

String sanitizeApkFileName(String fileName) {
  final baseName = fileName
      .trim()
      .split(RegExp(r'[/\\\\]'))
      .where((part) => part.isNotEmpty)
      .lastOrNull ??
      'uploaded_app.apk';
  final cleaned = baseName.replaceAll(RegExp(r'[^A-Za-z0-9._\-\u4e00-\u9fa5]'), '_');
  return cleaned.isEmpty ? 'uploaded_app.apk' : cleaned;
}


String httpRequestHeaderSummary(HttpRequest request) {
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

String normalizeHttpPath(String path) {
  final normalized = path.replaceAll(RegExp(r'/+'), '/');
  return normalized.isEmpty ? '/' : normalized;
}

String normalizeHttpUriPath(Uri uri) {
  final authority = uri.authority;
  if (authority.isEmpty) {
    return normalizeHttpPath(uri.path);
  }
  return normalizeHttpPath('/$authority/${uri.path}');
}


String sourceWithRemoteAddress(String label, HttpRequest request) {
  final address = request.connectionInfo?.remoteAddress.address;
  if (address == null || address.isEmpty) {
    return label;
  }
  return '$label · $address';
}

bool isValidCastUrl(String value) {
  final parsed = Uri.tryParse(value);
  return parsed != null &&
      parsed.hasScheme &&
      parsed.host.isNotEmpty &&
      (parsed.scheme == 'http' || parsed.scheme == 'https');
}
