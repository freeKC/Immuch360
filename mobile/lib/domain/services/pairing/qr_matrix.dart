// The modules of a QR code (ISO/IEC 18004), for the code the big screens show to be signed in by a phone. Byte mode,
// error correction level M (15 % of the code can be lost: a screen photographed at an angle, a reflection), versions 1
// to 10 (up to 213 bytes; the pairing text is about 65). Written here rather than taken from a package so that the
// phone builds keep their packages (.github/desktop/check_phone_packages.py); test/domain/services/pairing holds the
// matrices of an independent encoder to compare with.

import 'dart:typed_data';

/// The dark and light modules of a QR code, without its quiet zone
class QrMatrix {
  QrMatrix._(this.version, this.mask, this.size, this._dark);

  /// 1 to 10
  final int version;

  /// The mask pattern used, 0 to 7
  final int mask;

  /// Modules per side: 17 + 4 x version
  final int size;
  final Uint8List _dark;

  bool isDark(int row, int column) => _dark[row * size + column] == 1;

  /// [data] at level M in the smallest version that holds it; [mask] forces a mask pattern (the tests), else the one
  /// with the lowest penalty is chosen. Throws an ArgumentError when [data] needs more than version 10.
  factory QrMatrix.encode(List<int> data, {int? mask}) {
    final version = _versionFor(data.length);
    final codewords = _codewords(data, version);
    final builder = _Builder(version);
    builder.placeFunctionPatterns();
    builder.placeData(codewords);
    if (mask != null) {
      if (mask < 0 || mask > 7) {
        throw ArgumentError.value(mask, 'mask');
      }
      return builder.finish(mask);
    }
    QrMatrix? best;
    var bestPenalty = 0;
    for (var candidate = 0; candidate < 8; candidate++) {
      final matrix = builder.finish(candidate);
      final penalty = _penalty(matrix);
      if (best == null || penalty < bestPenalty) {
        best = matrix;
        bestPenalty = penalty;
      }
    }
    return best!;
  }
}

/// Per version at level M: the error correction codewords of each block, and the blocks with their data codewords
const _levelM = <(int, List<int>)>[
  (10, [16]),
  (16, [28]),
  (26, [44]),
  (18, [32, 32]),
  (24, [43, 43]),
  (16, [27, 27, 27, 27]),
  (18, [31, 31, 31, 31]),
  (22, [38, 38, 39, 39]),
  (22, [36, 36, 36, 37, 37]),
  (26, [43, 43, 43, 43, 44]),
];

/// The centres of the alignment patterns, per version
const _alignment = <List<int>>[
  [],
  [6, 18],
  [6, 22],
  [6, 26],
  [6, 30],
  [6, 34],
  [6, 22, 38],
  [6, 24, 42],
  [6, 26, 46],
  [6, 28, 50],
];

int _dataCapacity(int version) => _levelM[version - 1].$2.fold(0, (sum, block) => sum + block);

/// Bits of the length of byte mode data: 8 up to version 9, 16 from version 10
int _countBits(int version) => version < 10 ? 8 : 16;

int _versionFor(int length) {
  for (var version = 1; version <= _levelM.length; version++) {
    final bits = 4 + _countBits(version) + 8 * length;
    if (bits <= 8 * _dataCapacity(version)) {
      return version;
    }
  }
  throw ArgumentError('$length bytes do not fit in a QR code of version 10');
}

/// The data and error correction codewords, interleaved in the order they are placed
List<int> _codewords(List<int> data, int version) {
  final capacity = _dataCapacity(version);
  final bits = <int>[];
  void put(int value, int count) {
    for (var i = count - 1; i >= 0; i--) {
      bits.add((value >> i) & 1);
    }
  }

  put(0x4, 4);
  put(data.length, _countBits(version));
  for (final byte in data) {
    put(byte, 8);
  }
  // The terminator, up to four zeros, then zeros to the end of the byte
  final room = capacity * 8 - bits.length;
  put(0, room < 4 ? room : 4);
  while (bits.length % 8 != 0) {
    bits.add(0);
  }
  final bytes = <int>[
    for (var i = 0; i < bits.length; i += 8) bits.sublist(i, i + 8).fold(0, (value, bit) => (value << 1) | bit),
  ];
  for (var pad = 0; bytes.length < capacity; pad++) {
    bytes.add(pad.isEven ? 0xec : 0x11);
  }

  final (ecLength, blockLengths) = _levelM[version - 1];
  final generator = _generator(ecLength);
  final blocks = <List<int>>[];
  final corrections = <List<int>>[];
  var offset = 0;
  for (final length in blockLengths) {
    final block = bytes.sublist(offset, offset + length);
    offset += length;
    blocks.add(block);
    corrections.add(_remainder(block, generator));
  }
  final longest = blockLengths.reduce((a, b) => a > b ? a : b);
  return [
    for (var i = 0; i < longest; i++)
      for (final block in blocks)
        if (i < block.length) block[i],
    for (var i = 0; i < ecLength; i++)
      for (final correction in corrections) correction[i],
  ];
}

// Reed-Solomon over GF(256), primitive polynomial x^8 + x^4 + x^3 + x^2 + 1

final _exp = Uint8List(512);
final _log = Uint8List(256);
var _tablesReady = false;

void _tables() {
  if (_tablesReady) {
    return;
  }
  var value = 1;
  for (var i = 0; i < 255; i++) {
    _exp[i] = value;
    _log[value] = i;
    value <<= 1;
    if (value & 0x100 != 0) {
      value ^= 0x11d;
    }
  }
  for (var i = 255; i < 512; i++) {
    _exp[i] = _exp[i - 255];
  }
  _tablesReady = true;
}

int _multiply(int a, int b) => a == 0 || b == 0 ? 0 : _exp[_log[a] + _log[b]];

/// The generator polynomial of [degree], highest power first, without its leading 1
List<int> _generator(int degree) {
  _tables();
  var polynomial = <int>[1];
  for (var i = 0; i < degree; i++) {
    final next = List<int>.filled(polynomial.length + 1, 0);
    for (var j = 0; j < polynomial.length; j++) {
      next[j] ^= polynomial[j];
      next[j + 1] ^= _multiply(polynomial[j], _exp[i]);
    }
    polynomial = next;
  }
  return polynomial.sublist(1);
}

List<int> _remainder(List<int> data, List<int> generator) {
  final remainder = List<int>.filled(generator.length, 0);
  for (final byte in data) {
    final factor = byte ^ remainder.first;
    remainder
      ..setRange(0, remainder.length - 1, remainder, 1)
      ..last = 0;
    for (var i = 0; i < generator.length; i++) {
      remainder[i] ^= _multiply(generator[i], factor);
    }
  }
  return remainder;
}

/// BCH code of [value] with [generator]: [value] followed by the remainder of its division
int _bch(int value, int generator, int generatorBits) {
  var remainder = value << (generatorBits - 1);
  while (remainder.bitLength >= generatorBits) {
    remainder ^= generator << (remainder.bitLength - generatorBits);
  }
  return (value << (generatorBits - 1)) | remainder;
}

class _Builder {
  _Builder(this.version)
    : size = 17 + 4 * version,
      _dark = Uint8List((17 + 4 * version) * (17 + 4 * version)),
      _function = Uint8List((17 + 4 * version) * (17 + 4 * version));

  final int version;
  final int size;
  final Uint8List _dark;

  /// The modules of the patterns, which the data and the mask leave alone
  final Uint8List _function;

  void _set(int row, int column, bool dark) {
    _dark[row * size + column] = dark ? 1 : 0;
    _function[row * size + column] = 1;
  }

  void placeFunctionPatterns() {
    for (var i = 0; i < size; i++) {
      _set(6, i, i.isEven);
      _set(i, 6, i.isEven);
    }
    _finder(3, 3);
    _finder(3, size - 4);
    _finder(size - 4, 3);
    final centres = _alignment[version - 1];
    for (final row in centres) {
      for (final column in centres) {
        final onFinder =
            (row == 6 && column == 6) || (row == 6 && column == centres.last) || (row == centres.last && column == 6);
        if (!onFinder) {
          _alignmentAt(row, column);
        }
      }
    }
    // Reserved for the format and version information, written by finish()
    _formatBits(0);
    if (version >= 7) {
      _versionBits();
    }
  }

  void _finder(int row, int column) {
    for (var dr = -4; dr <= 4; dr++) {
      for (var dc = -4; dc <= 4; dc++) {
        final r = row + dr;
        final c = column + dc;
        if (r < 0 || r >= size || c < 0 || c >= size) {
          continue;
        }
        final distance = dr.abs() > dc.abs() ? dr.abs() : dc.abs();
        _set(r, c, distance != 2 && distance != 4);
      }
    }
  }

  void _alignmentAt(int row, int column) {
    for (var dr = -2; dr <= 2; dr++) {
      for (var dc = -2; dc <= 2; dc++) {
        final distance = dr.abs() > dc.abs() ? dr.abs() : dc.abs();
        _set(row + dr, column + dc, distance != 1);
      }
    }
  }

  /// The 15 bits of the format information (level M, [mask]) in their two copies, and the dark module
  void _formatBits(int mask) {
    // Level M is 00
    final bits = _bch(mask, 0x537, 11) ^ 0x5412;
    bool bit(int i) => (bits >> i) & 1 == 1;
    for (var i = 0; i <= 5; i++) {
      _set(i, 8, bit(i));
    }
    _set(7, 8, bit(6));
    _set(8, 8, bit(7));
    _set(8, 7, bit(8));
    for (var i = 9; i < 15; i++) {
      _set(8, 14 - i, bit(i));
    }
    for (var i = 0; i < 8; i++) {
      _set(8, size - 1 - i, bit(i));
    }
    for (var i = 8; i < 15; i++) {
      _set(size - 15 + i, 8, bit(i));
    }
    _set(size - 8, 8, true);
  }

  void _versionBits() {
    final bits = _bch(version, 0x1f25, 13);
    for (var i = 0; i < 18; i++) {
      final dark = (bits >> i) & 1 == 1;
      final a = size - 11 + i % 3;
      final b = i ~/ 3;
      _set(a, b, dark);
      _set(b, a, dark);
    }
  }

  /// The codewords in the zigzag of two columns, from the bottom right, skipping the vertical timing pattern
  void placeData(List<int> codewords) {
    var bitIndex = 0;
    final totalBits = codewords.length * 8;
    var upward = true;
    for (var right = size - 1; right >= 1; right -= 2) {
      if (right == 6) {
        right = 5;
      }
      for (var step = 0; step < size; step++) {
        final row = upward ? size - 1 - step : step;
        for (var dc = 0; dc < 2; dc++) {
          final column = right - dc;
          if (_function[row * size + column] == 1) {
            continue;
          }
          // The remainder bits past the codewords stay light
          final dark = bitIndex < totalBits && (codewords[bitIndex >> 3] >> (7 - (bitIndex & 7))) & 1 == 1;
          _dark[row * size + column] = dark ? 1 : 0;
          bitIndex++;
        }
      }
      upward = !upward;
    }
  }

  QrMatrix finish(int mask) {
    // The format modules are function modules: the mask leaves them alone, and the next call writes over them
    _formatBits(mask);
    final dark = Uint8List.fromList(_dark);
    for (var row = 0; row < size; row++) {
      for (var column = 0; column < size; column++) {
        final index = row * size + column;
        if (_function[index] == 0 && _masked(mask, row, column)) {
          dark[index] ^= 1;
        }
      }
    }
    return QrMatrix._(version, mask, size, dark);
  }

  static bool _masked(int mask, int row, int column) => switch (mask) {
    0 => (row + column) % 2 == 0,
    1 => row % 2 == 0,
    2 => column % 3 == 0,
    3 => (row + column) % 3 == 0,
    4 => (row ~/ 2 + column ~/ 3) % 2 == 0,
    5 => (row * column) % 2 + (row * column) % 3 == 0,
    6 => ((row * column) % 2 + (row * column) % 3) % 2 == 0,
    _ => ((row + column) % 2 + (row * column) % 3) % 2 == 0,
  };
}

/// The penalty of ISO/IEC 18004 7.8.3: runs, blocks, finder-like patterns and the balance of dark and light
int _penalty(QrMatrix matrix) {
  final size = matrix.size;
  var penalty = 0;

  bool dark(int row, int column) => matrix.isDark(row, column);

  // N1, runs of five or more of one colour in a row or a column, and N3, 1:1:3:1:1 patterns with four light modules
  // on one side
  for (var pass = 0; pass < 2; pass++) {
    for (var line = 0; line < size; line++) {
      bool at(int i) => pass == 0 ? dark(line, i) : dark(i, line);
      var run = 1;
      for (var i = 1; i <= size; i++) {
        if (i < size && at(i) == at(i - 1)) {
          run++;
          continue;
        }
        if (run >= 5) {
          penalty += 3 + run - 5;
        }
        run = 1;
      }
      for (var i = 0; i + 7 <= size; i++) {
        final finderLike = at(i) && !at(i + 1) && at(i + 2) && at(i + 3) && at(i + 4) && !at(i + 5) && at(i + 6);
        if (!finderLike) {
          continue;
        }
        bool lightFrom(int start, int end) {
          for (var j = start; j < end; j++) {
            if (j >= 0 && j < size && at(j)) {
              return false;
            }
          }
          return true;
        }

        if (lightFrom(i - 4, i) || lightFrom(i + 7, i + 11)) {
          penalty += 40;
        }
      }
    }
  }

  // N2, blocks of 2 x 2 of one colour
  for (var row = 0; row + 1 < size; row++) {
    for (var column = 0; column + 1 < size; column++) {
      final colour = dark(row, column);
      if (dark(row, column + 1) == colour && dark(row + 1, column) == colour && dark(row + 1, column + 1) == colour) {
        penalty += 3;
      }
    }
  }

  // N4, ten points per 5 % away from half dark
  var darkCount = 0;
  for (var row = 0; row < size; row++) {
    for (var column = 0; column < size; column++) {
      if (dark(row, column)) {
        darkCount++;
      }
    }
  }
  final total = size * size;
  final k = ((darkCount * 20 - total * 10).abs() + total - 1) ~/ total - 1;
  penalty += (k < 0 ? 0 : k) * 10;
  return penalty;
}
