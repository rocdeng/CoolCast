import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Standard ISO/IEC 18004 QR Code generator (Byte mode, ECC Level L, Versions 1-5).
class CoolCastQrCode {
  CoolCastQrCode._({
    required this.version,
    required this.size,
    required List<List<bool>> modules,
  }) : _modules = modules;

  final int version;
  final int size;
  final List<List<bool>> _modules;

  bool isDark(int row, int col) => _modules[row][col];

  static CoolCastQrCode fromText(String text) {
    final payload = Uint8List.fromList(utf8.encode(text));
    final spec = _QrVersionSpec.forByteLength(payload.length);
    final dataCodewords = _encodeDataCodewords(payload, spec);
    final ecCodewords = _reedSolomonRemainder(
      dataCodewords,
      spec.ecCodewords,
    );
    final allCodewords = Uint8List(dataCodewords.length + ecCodewords.length)
      ..setRange(0, dataCodewords.length, dataCodewords)
      ..setRange(dataCodewords.length, dataCodewords.length + ecCodewords.length,
          ecCodewords);

    final size = 17 + spec.version * 4;
    final modules = List<List<bool>>.generate(
      size,
      (_) => List<bool>.filled(size, false),
      growable: false,
    );
    final isFunction = List<List<bool>>.generate(
      size,
      (_) => List<bool>.filled(size, false),
      growable: false,
    );

    _drawFunctionPatterns(modules, isFunction, spec.version, size);
    _drawCodewords(modules, isFunction, allCodewords, size);

    var bestMask = 0;
    var bestPenalty = 0x7fffffff;
    for (var mask = 0; mask < 8; mask++) {
      final candidate = _cloneModules(modules);
      _applyMask(candidate, isFunction, mask, size);
      _drawFormatBits(candidate, isFunction, mask, size);
      final penalty = _calculatePenalty(candidate, size);
      if (penalty < bestPenalty) {
        bestPenalty = penalty;
        bestMask = mask;
      }
    }

    _applyMask(modules, isFunction, bestMask, size);
    _drawFormatBits(modules, isFunction, bestMask, size);

    return CoolCastQrCode._(
      version: spec.version,
      size: size,
      modules: modules,
    );
  }
}

class CoolCastQrCodeView extends StatelessWidget {
  const CoolCastQrCodeView({
    super.key,
    required this.data,
    this.size = 220,
    this.foregroundColor = const Color(0xFF102033),
    this.backgroundColor = Colors.white,
    this.quietZoneModules = 3,
  });

  final String data;
  final double size;
  final Color foregroundColor;
  final Color backgroundColor;
  final int quietZoneModules;

  @override
  Widget build(BuildContext context) {
    final qr = CoolCastQrCode.fromText(data.isEmpty ? 'http://TV-IP:7788/install' : data);
    return Semantics(
      label: '远程安装二维码 $data',
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _CoolCastQrPainter(
            qr: qr,
            foregroundColor: foregroundColor,
            backgroundColor: backgroundColor,
            quietZoneModules: quietZoneModules,
          ),
        ),
      ),
    );
  }
}

class _CoolCastQrPainter extends CustomPainter {
  const _CoolCastQrPainter({
    required this.qr,
    required this.foregroundColor,
    required this.backgroundColor,
    required this.quietZoneModules,
  });

  final CoolCastQrCode qr;
  final Color foregroundColor;
  final Color backgroundColor;
  final int quietZoneModules;

  @override
  void paint(Canvas canvas, Size size) {
    final bgPaint = Paint()..color = backgroundColor;
    canvas.drawRect(Offset.zero & size, bgPaint);

    final totalModules = qr.size + quietZoneModules * 2;
    final moduleSize = size.shortestSide / totalModules;
    final darkPaint = Paint()
      ..color = foregroundColor
      ..style = PaintingStyle.fill;

    for (var r = 0; r < qr.size; r++) {
      for (var c = 0; c < qr.size; c++) {
        if (!qr.isDark(r, c)) {
          continue;
        }
        final left = (c + quietZoneModules) * moduleSize;
        final top = (r + quietZoneModules) * moduleSize;
        canvas.drawRect(
          Rect.fromLTWH(left, top, moduleSize + 0.35, moduleSize + 0.35),
          darkPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CoolCastQrPainter oldDelegate) {
    return oldDelegate.qr != qr ||
        oldDelegate.foregroundColor != foregroundColor ||
        oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.quietZoneModules != quietZoneModules;
  }
}

class _QrVersionSpec {
  const _QrVersionSpec({
    required this.version,
    required this.dataCodewords,
    required this.ecCodewords,
  });

  final int version;
  final int dataCodewords;
  final int ecCodewords;

  int get maxByteLength => dataCodewords - 2;

  static const List<_QrVersionSpec> _specs = [
    _QrVersionSpec(version: 1, dataCodewords: 19, ecCodewords: 7),
    _QrVersionSpec(version: 2, dataCodewords: 34, ecCodewords: 10),
    _QrVersionSpec(version: 3, dataCodewords: 55, ecCodewords: 15),
    _QrVersionSpec(version: 4, dataCodewords: 80, ecCodewords: 20),
    _QrVersionSpec(version: 5, dataCodewords: 108, ecCodewords: 26),
  ];

  static _QrVersionSpec forByteLength(int length) {
    for (final spec in _specs) {
      if (length <= spec.maxByteLength) {
        return spec;
      }
    }
    throw ArgumentError('QR text too long for versions 1-5: $length bytes');
  }
}

Uint8List _encodeDataCodewords(Uint8List payload, _QrVersionSpec spec) {
  final bitCap = spec.dataCodewords * 8;
  final bits = <int>[];

  void appendBits(int value, int length) {
    for (var i = length - 1; i >= 0; i--) {
      bits.add((value >> i) & 1);
    }
  }

  // Byte mode indicator (0100) + 8-bit character count.
  appendBits(0x4, 4);
  appendBits(payload.length, 8);
  for (final byte in payload) {
    appendBits(byte, 8);
  }

  // Terminator (up to 4 zero bits).
  for (var i = 0; i < 4 && bits.length < bitCap; i++) {
    bits.add(0);
  }
  while (bits.length % 8 != 0) {
    bits.add(0);
  }

  final codewords = Uint8List(spec.dataCodewords);
  final byteCount = bits.length ~/ 8;
  for (var i = 0; i < byteCount; i++) {
    var value = 0;
    for (var b = 0; b < 8; b++) {
      value = (value << 1) | bits[i * 8 + b];
    }
    codewords[i] = value;
  }

  const padBytes = [0xEC, 0x11];
  for (var i = byteCount; i < spec.dataCodewords; i++) {
    codewords[i] = padBytes[(i - byteCount) % 2];
  }
  return codewords;
}

int _gfMultiply(int x, int y) {
  var result = 0;
  var a = x;
  var b = y;
  for (var i = 7; i >= 0; i--) {
    result = (result << 1) ^ ((result >> 7) * 0x11D);
    result ^= ((b >> i) & 1) * a;
  }
  return result;
}

Uint8List _reedSolomonGenerator(int degree) {
  final result = Uint8List(degree);
  result[degree - 1] = 1;
  var root = 1;
  for (var i = 0; i < degree; i++) {
    for (var j = 0; j < degree; j++) {
      result[j] = _gfMultiply(result[j], root);
      if (j + 1 < degree) {
        result[j] ^= result[j + 1];
      }
    }
    root = _gfMultiply(root, 0x02);
  }
  return result;
}

Uint8List _reedSolomonRemainder(Uint8List data, int degree) {
  final generator = _reedSolomonGenerator(degree);
  final result = Uint8List(degree);
  for (final byte in data) {
    final factor = byte ^ result[0];
    for (var i = 0; i < degree - 1; i++) {
      result[i] = result[i + 1] ^ _gfMultiply(generator[i], factor);
    }
    result[degree - 1] = _gfMultiply(generator[degree - 1], factor);
  }
  return result;
}

void _setFunctionModule(
  List<List<bool>> modules,
  List<List<bool>> isFunction,
  int row,
  int col,
  bool isDark,
) {
  modules[row][col] = isDark;
  isFunction[row][col] = true;
}

void _drawFinderPattern(
  List<List<bool>> modules,
  List<List<bool>> isFunction,
  int centerRow,
  int centerCol,
  int size,
) {
  for (var dy = -4; dy <= 4; dy++) {
    for (var dx = -4; dx <= 4; dx++) {
      final r = centerRow + dy;
      final c = centerCol + dx;
      if (r < 0 || r >= size || c < 0 || c >= size) {
        continue;
      }
      final dist = dy.abs() > dx.abs() ? dy.abs() : dx.abs();
      final isDark = dist != 2 && dist != 4;
      _setFunctionModule(modules, isFunction, r, c, isDark);
    }
  }
}

void _drawAlignmentPattern(
  List<List<bool>> modules,
  List<List<bool>> isFunction,
  int centerRow,
  int centerCol,
) {
  for (var dy = -2; dy <= 2; dy++) {
    for (var dx = -2; dx <= 2; dx++) {
      final dist = dy.abs() > dx.abs() ? dy.abs() : dx.abs();
      _setFunctionModule(
        modules,
        isFunction,
        centerRow + dy,
        centerCol + dx,
        dist != 1,
      );
    }
  }
}

void _drawFunctionPatterns(
  List<List<bool>> modules,
  List<List<bool>> isFunction,
  int version,
  int size,
) {
  for (var i = 0; i < size; i++) {
    _setFunctionModule(modules, isFunction, 6, i, i.isEven);
    _setFunctionModule(modules, isFunction, i, 6, i.isEven);
  }

  _drawFinderPattern(modules, isFunction, 3, 3, size);
  _drawFinderPattern(modules, isFunction, 3, size - 4, size);
  _drawFinderPattern(modules, isFunction, size - 4, 3, size);

  if (version >= 2) {
    _drawAlignmentPattern(modules, isFunction, size - 7, size - 7);
  }

  _drawFormatBits(modules, isFunction, 0, size);
}

void _drawFormatBits(
  List<List<bool>> modules,
  List<List<bool>> isFunction,
  int mask,
  int size,
) {
  // ECC Level L indicator is 01 (binary 1).
  const eccFormatBits = 1;
  final data = (eccFormatBits << 3) | mask;
  var rem = data;
  for (var i = 0; i < 10; i++) {
    rem = (rem << 1) ^ ((rem >> 9) * 0x537);
  }
  final bits = ((data << 10) | rem) ^ 0x5412;

  bool bit(int index) => ((bits >> index) & 1) != 0;

  for (var i = 0; i <= 5; i++) {
    _setFunctionModule(modules, isFunction, i, 8, bit(i));
  }
  _setFunctionModule(modules, isFunction, 7, 8, bit(6));
  _setFunctionModule(modules, isFunction, 8, 8, bit(7));
  _setFunctionModule(modules, isFunction, 8, 7, bit(8));
  for (var i = 9; i < 15; i++) {
    _setFunctionModule(modules, isFunction, 8, 14 - i, bit(i));
  }

  for (var i = 0; i < 8; i++) {
    _setFunctionModule(modules, isFunction, 8, size - 1 - i, bit(i));
  }
  for (var i = 8; i < 15; i++) {
    _setFunctionModule(modules, isFunction, size - 15 + i, 8, bit(i));
  }
  _setFunctionModule(modules, isFunction, size - 8, 8, true);
}

void _drawCodewords(
  List<List<bool>> modules,
  List<List<bool>> isFunction,
  Uint8List codewords,
  int size,
) {
  var bitIndex = 0;
  final totalBits = codewords.length * 8;

  for (var right = size - 1; right >= 1; right -= 2) {
    if (right == 6) {
      right = 5;
    }
    for (var vert = 0; vert < size; vert++) {
      for (var j = 0; j < 2; j++) {
        final col = right - j;
        final upward = ((right + 1) & 2) == 0;
        final row = upward ? size - 1 - vert : vert;
        if (!isFunction[row][col] && bitIndex < totalBits) {
          final byte = codewords[bitIndex >> 3];
          final isDark = ((byte >> (7 - (bitIndex & 7))) & 1) != 0;
          modules[row][col] = isDark;
          bitIndex++;
        }
      }
    }
  }
}

void _applyMask(
  List<List<bool>> modules,
  List<List<bool>> isFunction,
  int mask,
  int size,
) {
  for (var r = 0; r < size; r++) {
    for (var c = 0; c < size; c++) {
      if (isFunction[r][c]) {
        continue;
      }
      final invert = switch (mask) {
        0 => (r + c) % 2 == 0,
        1 => r % 2 == 0,
        2 => c % 3 == 0,
        3 => (r + c) % 3 == 0,
        4 => (r ~/ 2 + c ~/ 3) % 2 == 0,
        5 => (r * c) % 2 + (r * c) % 3 == 0,
        6 => ((r * c) % 2 + (r * c) % 3) % 2 == 0,
        7 => ((r + c) % 2 + (r * c) % 3) % 2 == 0,
        _ => false,
      };
      if (invert) {
        modules[r][c] = !modules[r][c];
      }
    }
  }
}

List<List<bool>> _cloneModules(List<List<bool>> source) => [
      for (final row in source) List<bool>.from(row, growable: false),
    ];

int _calculatePenalty(List<List<bool>> modules, int size) {
  var penalty = 0;
  for (var r = 0; r < size; r++) {
    var runColor = modules[r][0];
    var runLength = 1;
    for (var c = 1; c < size; c++) {
      if (modules[r][c] == runColor) {
        runLength++;
        if (runLength == 5) {
          penalty += 3;
        } else if (runLength > 5) {
          penalty += 1;
        }
      } else {
        runColor = modules[r][c];
        runLength = 1;
      }
    }
  }
  for (var c = 0; c < size; c++) {
    var runColor = modules[0][c];
    var runLength = 1;
    for (var r = 1; r < size; r++) {
      if (modules[r][c] == runColor) {
        runLength++;
        if (runLength == 5) {
          penalty += 3;
        } else if (runLength > 5) {
          penalty += 1;
        }
      } else {
        runColor = modules[r][c];
        runLength = 1;
      }
    }
  }
  for (var r = 0; r < size - 1; r++) {
    for (var c = 0; c < size - 1; c++) {
      final color = modules[r][c];
      if (modules[r][c + 1] == color &&
          modules[r + 1][c] == color &&
          modules[r + 1][c + 1] == color) {
        penalty += 3;
      }
    }
  }
  return penalty;
}
