// The TIFF decoder of the devices that have none (Android, see tiff_photos.dart), in pure Dart. It reads the strips or
// the tiles of the first image one band at a time and scales each band down as it comes: the whole picture is never in
// memory at its full size, only the file, one band and the picture shown.
//
// It reads the TIFFs photo editors, scanners and cameras write: 8 and 16 bit samples; gray, RGB, a palette or CMYK,
// with or without alpha; uncompressed, LZW, Deflate (ZIP), PackBits or JPEG; with the horizontal predictor; in strips
// or tiles; one sample after the other or in planes; in either byte order. The image package (MIT) reads the tags of
// the file, and decodes the other kinds (1, 2 and 4 bit samples, fax compressions, floating point samples) when
// nothing in them is known to come out wrong from it. Anything else is refused with a [TiffDecodeException]: a wrong
// picture is never shown as if it were right (its LZW and Deflate branches undo the predictor for 8 bit LZW only, read
// the compressed 16 bit samples of a big endian file in the wrong order, misplace the right column of tiles, ignore
// planes, and draw a damaged strip as a band).

import 'dart:io' show ZLibDecoder;
import 'dart:math' as math;
import 'dart:typed_data';

// Pure Dart, MIT, in the lock through maplibre_gl (as in lib/desktop/library/local_image_codec.dart)
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;

/// A TIFF the Dart decoder did not decode, with why (for the log; the user is told "This device cannot decode this
/// TIFF")
class TiffDecodeException implements Exception {
  const TiffDecodeException(this.reason);

  final String reason;

  @override
  String toString() => 'TiffDecodeException: $reason';
}

/// The pixels of a decoded TIFF, RGBA with 8 bits per channel, [width] by [height]
class TiffPixels {
  const TiffPixels(this.rgba, this.width, this.height);

  final Uint8List rgba;
  final int width;
  final int height;
}

/// [bytes], a TIFF: its first image as RGBA pixels, at most [maxSide] pixels on its long side, upright as its
/// orientation tag says. An image of more than [maxDecodedBytes] bytes of samples (its width, height, samples per pixel
/// and bytes per sample) is refused before it is decoded. Throws [TiffDecodeException] for any file that does not
/// decode, whatever went wrong in the decoder, a lack of memory included.
TiffPixels decodeTiffPixels(Uint8List bytes, {required int maxSide, required int maxDecodedBytes}) {
  try {
    return _decode(bytes, math.max(1, maxSide), maxDecodedBytes);
  } on TiffDecodeException {
    rethrow;
  } catch (error) {
    throw TiffDecodeException('$error');
  }
}

TiffPixels _decode(Uint8List bytes, int maxSide, int maxDecodedBytes) {
  final decoder = img.TiffDecoder();
  final img.TiffInfo? info;
  try {
    info = decoder.startDecode(bytes);
  } catch (error) {
    throw TiffDecodeException('unreadable header: $error');
  }
  final first = info?.images.firstOrNull;
  if (info == null || first == null || first.width <= 0 || first.height <= 0) {
    throw const TiffDecodeException('no image in the file');
  }
  final tiff = _Tiff(first, bytes, bigEndian: info.bigEndian ?? false);
  if (tiff.width * tiff.height * tiff.samplesPerPixel * tiff.bytesPerSample > maxDecodedBytes) {
    throw TiffDecodeException('${tiff.width} x ${tiff.height} pixels is more than this device decodes');
  }
  final ifd = decoder.exif?.imageIfd;
  final orientation = ifd != null && ifd.hasOrientation ? ifd.orientation ?? 1 : 1;
  final pixels = tiff.isBaseline ? _BandDecoder(tiff, maxSide).decode() : _decodeWithPackage(decoder, tiff, maxSide);
  return uprightTiffPixels(pixels, orientation);
}

// The TIFF tags read here (TIFF 6.0 and its technical notes)
const _bitsPerSample = 258;
const _compression = 259;
const _photometric = 262;
const _stripOffsets = 273;
const _samplesPerPixel = 277;
const _rowsPerStrip = 278;
const _stripByteCounts = 279;
const _planarConfiguration = 284;
const _predictor = 317;
const _colorMap = 320;
const _tileWidth = 322;
const _tileLength = 323;
const _tileOffsets = 324;
const _tileByteCounts = 325;
const _inkSet = 332;
const _extraSamples = 338;
const _sampleFormat = 339;
const _jpegTables = 347;

// The compressions
const _none = 1;
const _oldJpeg = 6;
const _jpeg = 7;
const _lzw = 5;
const _deflate = 8;
const _adobeDeflate = 32946;
const _packBits = 32773;

// The photometric interpretations
const _whiteIsZero = 0;
const _blackIsZero = 1;
const _rgb = 2;
const _palette = 3;
const _transparencyMask = 4;
const _cmyk = 5;
const _yCbCr = 6;

/// How the samples of a pixel make its color
enum _Colors { gray, whiteIsZeroGray, rgb, palette, cmyk }

/// The first image of a TIFF as its tags describe it, read from the file itself
class _Tiff {
  _Tiff(this.image, this.bytes, {required this.bigEndian}) : _data = ByteData.sublistView(bytes);

  final img.TiffImage image;
  final Uint8List bytes;
  final bool bigEndian;
  final ByteData _data;

  Endian get endian => bigEndian ? Endian.big : Endian.little;

  int get width => image.width;
  int get height => image.height;

  /// The integer values of [tag] (BYTE, SHORT, LONG or UNDEFINED), null when the image has none
  List<int>? ints(int tag) {
    final entry = image.tags[tag];
    if (entry == null) {
      return null;
    }
    // The types of IfdValueType are in the order of their TIFF numbers
    final size = switch (entry.type.index) {
      1 || 7 => 1,
      3 => 2,
      4 => 4,
      _ => 0,
    };
    if (size == 0) {
      return null;
    }
    final count = entry.count;
    // A value of four bytes or less is in its entry, whose place valueOffset gives then
    final start = entry.valueOffset;
    if (count <= 0 || start < 0 || start + count * size > bytes.length) {
      throw TiffDecodeException('the tag $tag points out of the file');
    }
    return List<int>.generate(count, (index) {
      final at = start + index * size;
      return switch (size) {
        1 => bytes[at],
        2 => _data.getUint16(at, endian),
        _ => _data.getUint32(at, endian),
      };
    }, growable: false);
  }

  int _one(int tag, int fallback) => ints(tag)?.first ?? fallback;

  late final int compression = _one(_compression, _none);
  late final int photometric = _one(_photometric, -1);
  late final int samplesPerPixel = math.max(1, _one(_samplesPerPixel, 1));
  late final List<int> _bits = ints(_bitsPerSample) ?? const [1];
  late final int bitsPerSample = _bits.first;
  late final bool sameBits = _bits.every((bits) => bits == bitsPerSample);
  late final int bytesPerSample = math.max(1, (bitsPerSample + 7) ~/ 8);
  late final bool unsignedSamples = (ints(_sampleFormat) ?? const [1]).every((format) => format == 1);
  late final int planar = _one(_planarConfiguration, 1);
  late final int predictor = _one(_predictor, 1);
  late final bool tiled = image.tags.containsKey(_tileOffsets);
  late final int blockWidth = tiled ? _one(_tileWidth, 0) : width;
  late final int blockHeight = tiled ? _one(_tileLength, 0) : _stripRows();
  late final List<int>? offsets = ints(tiled ? _tileOffsets : _stripOffsets);
  late final List<int>? byteCounts = ints(tiled ? _tileByteCounts : _stripByteCounts);

  int _stripRows() {
    final rows = _one(_rowsPerStrip, height);
    return rows <= 0 || rows > height ? height : rows;
  }

  int get blocksAcross => (width + blockWidth - 1) ~/ blockWidth;
  int get blocksDown => (height + blockHeight - 1) ~/ blockHeight;
  int get planes => planar == 2 ? samplesPerPixel : 1;

  /// The samples of a pixel in one block: all of them, or one per plane
  int get samplesInBlock => planar == 2 ? 1 : samplesPerPixel;

  /// The samples that make the color, before the extra ones
  int get colorSamples => switch (photometric) {
    _rgb => 3,
    _cmyk => 4,
    _yCbCr when compression == _jpeg => 3,
    _ => 1,
  };

  late final _Colors? colors = _colorsOf();

  _Colors? _colorsOf() {
    if (compression == _jpeg) {
      // The JPEG decoder gives RGB: from YCbCr (or RGB, or gray) as the stream says
      return (photometric == _yCbCr || photometric == _rgb) && samplesPerPixel == 3 ||
              photometric == _blackIsZero && samplesPerPixel == 1
          ? _Colors.rgb
          : null;
    }
    return switch (photometric) {
      _blackIsZero => _Colors.gray,
      _whiteIsZero => _Colors.whiteIsZeroGray,
      _rgb when samplesPerPixel >= 3 => _Colors.rgb,
      _palette when samplesPerPixel == 1 && bitsPerSample == 8 && colorMap != null => _Colors.palette,
      _cmyk when samplesPerPixel >= 4 && _one(_inkSet, 1) == 1 => _Colors.cmyk,
      _ => null,
    };
  }

  /// The 3 x 256 values of a palette, 16 bit
  late final List<int>? colorMap = (() {
    final values = photometric == _palette ? ints(_colorMap) : null;
    return values != null && values.length == 3 * 256 ? values : null;
  })();

  /// The index of the alpha sample among those of a pixel, null when the image has none
  late final int? alphaSample = (() {
    final extra = ints(_extraSamples) ?? const <int>[];
    // 1: associated alpha, 2: unassociated alpha; 0 is any other sample
    final index = extra.indexWhere((kind) => kind == 1 || kind == 2);
    final sample = colorSamples + index;
    return index >= 0 && sample < samplesPerPixel && photometric != _palette ? sample : null;
  })();

  /// The JPEG tables shared by the strips or tiles of a JPEG in TIFF, null when each holds its own
  late final Uint8List? jpegTables = (() {
    final entry = image.tags[_jpegTables];
    if (entry == null || entry.count < 4) {
      return null;
    }
    final start = entry.valueOffset;
    if (start < 0 || start + entry.count > bytes.length) {
      throw const TiffDecodeException('the JPEG tables point out of the file');
    }
    return Uint8List.sublistView(bytes, start, start + entry.count);
  })();

  /// Whether the band decoder reads this image (see the top of this file)
  late final bool isBaseline = (() {
    if (!sameBits || !unsignedSamples || colors == null) {
      return false;
    }
    if (compression == _jpeg) {
      return bitsPerSample == 8 && planar == 1 && predictor == 1 && blockWidth > 0 && blockHeight > 0 && _hasBlocks;
    }
    return (bitsPerSample == 8 || bitsPerSample == 16) &&
        const {_none, _lzw, _deflate, _adobeDeflate, _packBits}.contains(compression) &&
        (predictor == 1 || predictor == 2) &&
        (planar == 1 || planar == 2) &&
        blockWidth > 0 &&
        blockHeight > 0 &&
        _hasBlocks;
  })();

  bool get _hasBlocks {
    final count = blocksAcross * blocksDown * planes;
    return (offsets?.length ?? 0) >= count && (byteCounts?.length ?? 0) >= count;
  }

  /// Why the image package would decode this image wrong, null when nothing is known to come out wrong from it
  String? get packageRefusal {
    if (predictor != 1) {
      return 'the predictor $predictor with $bitsPerSample bit samples';
    }
    if (planar == 2) {
      return 'samples in planes';
    }
    if (compression == _oldJpeg || compression == _jpeg) {
      return 'this kind of JPEG in TIFF';
    }
    if (!sameBits) {
      return 'samples of different sizes';
    }
    if (!const {_whiteIsZero, _blackIsZero, _rgb, _palette, _transparencyMask, _cmyk, _yCbCr}.contains(photometric)) {
      return 'the photometric interpretation $photometric';
    }
    if (tiled && image.tileWidth > 0 && width % image.tileWidth != 0) {
      return 'tiles that do not fill the width';
    }
    if (bigEndian && compression != _none && bitsPerSample > 8) {
      return 'compressed samples of $bitsPerSample bits in big endian order';
    }
    return null;
  }
}

/// The first image of [tiff], read one band of strips or tiles at a time and scaled down as each band comes
class _BandDecoder {
  _BandDecoder(this.tiff, int maxSide)
    : _scaler = _BoxScaler.fit(tiff.width, tiff.height, maxSide),
      // The byte of a 16 bit sample kept for 8 bits: its high byte
      _high = tiff.bytesPerSample == 2 && !tiff.bigEndian ? 1 : 0;

  final _Tiff tiff;
  final _BoxScaler _scaler;
  final int _high;

  TiffPixels decode() {
    final row = Uint8List(tiff.width * 4);
    for (var band = 0; band < tiff.blocksDown; band++) {
      final top = band * tiff.blockHeight;
      final rows = math.min(tiff.blockHeight, tiff.height - top);
      // A tile holds its whole height, past the bottom of the image too; a strip its rows only
      final blockRows = tiff.tiled ? tiff.blockHeight : rows;
      final blocks = [for (var across = 0; across < tiff.blocksAcross; across++) _chunky(band, across, blockRows)];
      for (var y = 0; y < rows; y++) {
        _row(blocks, y, row);
        _scaler.add(top + y, row);
      }
    }
    return _scaler.finish();
  }

  /// The strip or tile of [band] and [across], [rows] rows of [_Tiff.blockWidth] pixels, its samples one pixel after
  /// the other: those of an image in planes put together from the block of each plane
  Uint8List _chunky(int band, int across, int rows) {
    final index = band * tiff.blocksAcross + across;
    if (tiff.planar != 2) {
      return _block(index, rows);
    }
    final blocksPerPlane = tiff.blocksAcross * tiff.blocksDown;
    final spp = tiff.samplesPerPixel;
    final bps = tiff.bytesPerSample;
    final pixels = tiff.blockWidth * rows;
    final chunky = Uint8List(pixels * spp * bps);
    for (var plane = 0; plane < spp; plane++) {
      final samples = _block(plane * blocksPerPlane + index, rows);
      for (var pixel = 0; pixel < pixels; pixel++) {
        final to = (pixel * spp + plane) * bps;
        final from = pixel * bps;
        for (var byte = 0; byte < bps; byte++) {
          chunky[to + byte] = samples[from + byte];
        }
      }
    }
    return chunky;
  }

  /// The samples of the strip or tile [index], [rows] rows of [_Tiff.blockWidth] pixels, uncompressed, the predictor
  /// undone
  Uint8List _block(int index, int rows) {
    final offset = tiff.offsets![index];
    final count = tiff.byteCounts![index];
    if (offset < 0 || offset >= tiff.bytes.length || count <= 0) {
      throw TiffDecodeException('the strip $index is out of the file: the file is cut short');
    }
    final data = Uint8List.sublistView(tiff.bytes, offset, math.min(tiff.bytes.length, offset + count));
    if (tiff.compression == _jpeg) {
      return _jpegBlock(data, rows);
    }
    final expected = tiff.blockWidth * rows * tiff.samplesInBlock * tiff.bytesPerSample;
    var samples = switch (tiff.compression) {
      _lzw => lzwDecode(data, expected),
      _deflate || _adobeDeflate => _inflate(data),
      _packBits => _unpackBits(data, expected),
      _ => data,
    };
    if (samples.length < expected) {
      throw TiffDecodeException('the strip $index is shorter than its image: the file is damaged or cut short');
    }
    if (tiff.predictor == 2) {
      // Undone in place: never in the file itself
      if (identical(samples, data)) {
        samples = Uint8List.fromList(Uint8List.sublistView(data, 0, expected));
      }
      undoHorizontalPredictor(
        samples,
        width: tiff.blockWidth,
        rows: rows,
        samplesPerPixel: tiff.samplesInBlock,
        bytesPerSample: tiff.bytesPerSample,
        endian: tiff.endian,
      );
    }
    return samples;
  }

  /// A JPEG strip or tile as RGB samples, [rows] rows of [_Tiff.blockWidth] pixels
  Uint8List _jpegBlock(Uint8List data, int rows) {
    if (data.length < 4 || data[0] != 0xFF || data[1] != 0xD8) {
      throw const TiffDecodeException('a JPEG strip without its start');
    }
    final tables = tiff.jpegTables;
    final stream = BytesBuilder(copy: false)..add(const [0xFF, 0xD8]);
    if (tiff.photometric == _rgb) {
      // An Adobe marker that says the samples are RGB already: without it, the decoder takes them for YCbCr
      stream.add(const [0xFF, 0xEE, 0x00, 0x0E, 0x41, 0x64, 0x6F, 0x62, 0x65, 0x00, 0x64, 0, 0, 0, 0, 0]);
    }
    if (tables != null) {
      // The tables shared by every strip, without their own start and end
      stream.add(Uint8List.sublistView(tables, 2, tables.length - 2));
    }
    stream.add(Uint8List.sublistView(data, 2));
    final decoded = img.JpegDecoder().decode(stream.takeBytes());
    if (decoded == null || decoded.width < tiff.blockWidth || decoded.height < rows) {
      throw const TiffDecodeException('a JPEG strip that does not decode to its place');
    }
    final rgb = decoded.format == img.Format.uint8 && decoded.numChannels == 3 && !decoded.hasPalette
        ? decoded
        : decoded.convert(format: img.Format.uint8, numChannels: 3);
    final source = rgb.getBytes(order: img.ChannelOrder.rgb);
    final block = Uint8List(tiff.blockWidth * rows * 3);
    for (var y = 0; y < rows; y++) {
      block.setRange(y * tiff.blockWidth * 3, (y + 1) * tiff.blockWidth * 3, source, y * decoded.width * 3);
    }
    return block;
  }

  /// The row [y] of the band whose strips or tiles are [blocks], from left to right, as RGBA in [out]
  void _row(List<Uint8List> blocks, int y, Uint8List out) {
    final jpeg = tiff.compression == _jpeg;
    // A pixel of the block: its samples one after the other, each of [bps] bytes, of which the one at [high] is kept
    final spp = jpeg ? 3 : tiff.samplesPerPixel;
    final bps = jpeg ? 1 : tiff.bytesPerSample;
    final high = jpeg ? 0 : _high;
    final pixelBytes = spp * bps;
    final alpha = jpeg ? null : tiff.alphaSample;
    final alphaAt = alpha == null ? 0 : alpha * bps;
    final colorMap = tiff.colorMap ?? const <int>[];
    for (var across = 0; across < tiff.blocksAcross; across++) {
      final block = blocks[across];
      final left = across * tiff.blockWidth;
      final pixels = math.min(tiff.blockWidth, tiff.width - left);
      var from = y * tiff.blockWidth * pixelBytes + high;
      var at = left * 4;
      final end = at + pixels * 4;
      switch (tiff.colors!) {
        case _Colors.gray:
          for (; at < end; at += 4, from += pixelBytes) {
            final gray = block[from];
            out[at] = gray;
            out[at + 1] = gray;
            out[at + 2] = gray;
            out[at + 3] = alpha == null ? 255 : block[from + alphaAt];
          }
        case _Colors.whiteIsZeroGray:
          for (; at < end; at += 4, from += pixelBytes) {
            final gray = 255 - block[from];
            out[at] = gray;
            out[at + 1] = gray;
            out[at + 2] = gray;
            out[at + 3] = alpha == null ? 255 : block[from + alphaAt];
          }
        case _Colors.rgb:
          for (; at < end; at += 4, from += pixelBytes) {
            out[at] = block[from];
            out[at + 1] = block[from + bps];
            out[at + 2] = block[from + 2 * bps];
            out[at + 3] = alpha == null ? 255 : block[from + alphaAt];
          }
        case _Colors.palette:
          for (; at < end; at += 4, from += pixelBytes) {
            final index = block[from];
            out[at] = colorMap[index] >> 8;
            out[at + 1] = colorMap[256 + index] >> 8;
            out[at + 2] = colorMap[512 + index] >> 8;
            out[at + 3] = 255;
          }
        case _Colors.cmyk:
          for (; at < end; at += 4, from += pixelBytes) {
            final white = 255 - block[from + 3 * bps];
            out[at] = ((255 - block[from]) * white + 127) ~/ 255;
            out[at + 1] = ((255 - block[from + bps]) * white + 127) ~/ 255;
            out[at + 2] = ((255 - block[from + 2 * bps]) * white + 127) ~/ 255;
            out[at + 3] = alpha == null ? 255 : block[from + alphaAt];
          }
      }
    }
  }
}

/// The rows of a picture [_sourceWidth] by [_sourceHeight], given top to bottom, averaged into one of at most a given
/// number of pixels on its long side, each pixel of the result the mean of those of the source it covers
class _BoxScaler {
  _BoxScaler(this._sourceWidth, this._sourceHeight, this.width, this.height)
    : _pixels = Uint8List(width * height * 4),
      _same = _sourceWidth == width && _sourceHeight == height {
    if (!_same) {
      _sums = Uint32List(width * 4);
      _columnOf = Int32List(_sourceWidth);
      _columnCount = Int32List(width);
      for (var x = 0; x < _sourceWidth; x++) {
        final column = x * width ~/ _sourceWidth;
        _columnOf[x] = column;
        _columnCount[column]++;
      }
    }
  }

  /// For a picture [width] by [height], at most [maxSide] pixels on its long side
  factory _BoxScaler.fit(int width, int height, int maxSide) {
    final longSide = math.max(width, height);
    if (longSide <= maxSide) {
      return _BoxScaler(width, height, width, height);
    }
    final scale = maxSide / longSide;
    return _BoxScaler(
      width,
      height,
      math.min(width, math.max(1, (width * scale).round())),
      math.min(height, math.max(1, (height * scale).round())),
    );
  }

  final int _sourceWidth;
  final int _sourceHeight;
  final int width;
  final int height;
  final Uint8List _pixels;
  final bool _same;
  late final Uint32List _sums;
  late final Int32List _columnOf;
  late final Int32List _columnCount;
  var _row = 0;
  var _rowsSummed = 0;

  /// The row [y] of the source, RGBA
  void add(int y, Uint8List rgba) {
    if (_same) {
      _pixels.setRange(y * width * 4, (y + 1) * width * 4, rgba);
      return;
    }
    final row = y * height ~/ _sourceHeight;
    if (row != _row && _rowsSummed > 0) {
      _flush();
    }
    _row = row;
    for (var x = 0; x < _sourceWidth; x++) {
      final to = _columnOf[x] * 4;
      final from = x * 4;
      _sums[to] += rgba[from];
      _sums[to + 1] += rgba[from + 1];
      _sums[to + 2] += rgba[from + 2];
      _sums[to + 3] += rgba[from + 3];
    }
    _rowsSummed++;
  }

  void _flush() {
    final start = _row * width * 4;
    for (var column = 0; column < width; column++) {
      final count = _columnCount[column] * _rowsSummed;
      final half = count >> 1;
      for (var channel = column * 4; channel < column * 4 + 4; channel++) {
        _pixels[start + channel] = (_sums[channel] + half) ~/ count;
        _sums[channel] = 0;
      }
    }
    _rowsSummed = 0;
  }

  TiffPixels finish() {
    if (!_same && _rowsSummed > 0) {
      _flush();
    }
    return TiffPixels(_pixels, width, height);
  }
}

/// The first image of [tiff] decoded by the image package, which holds it whole, then scaled down to [maxSide]
TiffPixels _decodeWithPackage(img.TiffDecoder decoder, _Tiff tiff, int maxSide) {
  final refusal = tiff.packageRefusal;
  if (refusal != null) {
    throw TiffDecodeException('$refusal: not decoded on this device');
  }
  var image = decoder.decodeFrame(0);
  if (image == null || image.width <= 0 || image.height <= 0) {
    throw const TiffDecodeException('the image did not decode');
  }
  final longSide = math.max(image.width, image.height);
  if (longSide > maxSide) {
    final scale = maxSide / longSide;
    image = img.copyResize(
      image,
      width: math.max(1, (image.width * scale).round()),
      height: math.max(1, (image.height * scale).round()),
      interpolation: img.Interpolation.average,
    );
  }
  final rgba = image.format == img.Format.uint8 && image.numChannels == 4 && !image.hasPalette
      ? image
      : image.convert(format: img.Format.uint8, numChannels: 4, alpha: 255);
  return TiffPixels(Uint8List.fromList(rgba.getBytes(order: img.ChannelOrder.rgba)), rgba.width, rgba.height);
}

/// [pixels] turned upright as the TIFF orientation tag [orientation] says (1 to 8, as in EXIF): a copy for 2 to 8,
/// [pixels] themselves for any other value
TiffPixels uprightTiffPixels(TiffPixels pixels, int orientation) {
  if (orientation < 2 || orientation > 8) {
    return pixels;
  }
  final width = pixels.width;
  final height = pixels.height;
  final rgba = pixels.rgba.offsetInBytes % 4 == 0 ? pixels.rgba : Uint8List.fromList(pixels.rgba);
  final source = rgba.buffer.asUint32List(rgba.offsetInBytes, width * height);
  final swap = orientation >= 5;
  final outWidth = swap ? height : width;
  final outHeight = swap ? width : height;
  final out = Uint32List(outWidth * outHeight);
  for (var y = 0; y < outHeight; y++) {
    for (var x = 0; x < outWidth; x++) {
      final (sx, sy) = switch (orientation) {
        2 => (width - 1 - x, y),
        3 => (width - 1 - x, height - 1 - y),
        4 => (x, height - 1 - y),
        5 => (y, x),
        6 => (y, height - 1 - x),
        7 => (width - 1 - y, height - 1 - x),
        _ => (width - 1 - y, x),
      };
      out[y * outWidth + x] = source[sy * width + sx];
    }
  }
  return TiffPixels(out.buffer.asUint8List(), outWidth, outHeight);
}

/// [samples], rows of [width] pixels of [samplesPerPixel] samples of [bytesPerSample] bytes in the order [endian],
/// stored as the difference to the same sample of the pixel on their left (the horizontal predictor, TIFF tag 317 = 2):
/// turned back into the samples, in place, modulo their size
@pragma('vm:prefer-inline')
void undoHorizontalPredictor(
  Uint8List samples, {
  required int width,
  required int rows,
  required int samplesPerPixel,
  required int bytesPerSample,
  required Endian endian,
}) {
  final rowSamples = width * samplesPerPixel;
  if (bytesPerSample == 1) {
    for (var row = 0; row < rows; row++) {
      final end = (row + 1) * rowSamples;
      for (var at = row * rowSamples + samplesPerPixel; at < end; at++) {
        // A Uint8List keeps the low 8 bits
        samples[at] += samples[at - samplesPerPixel];
      }
    }
    return;
  }
  final view = ByteData.sublistView(samples);
  final stride = samplesPerPixel * bytesPerSample;
  for (var row = 0; row < rows; row++) {
    final end = (row + 1) * rowSamples * bytesPerSample;
    for (var at = row * rowSamples * bytesPerSample + stride; at < end; at += bytesPerSample) {
      if (bytesPerSample == 2) {
        view.setUint16(at, view.getUint16(at, endian) + view.getUint16(at - stride, endian), endian);
      } else {
        view.setUint32(at, view.getUint32(at, endian) + view.getUint32(at - stride, endian), endian);
      }
    }
  }
}

/// The first [expected] bytes of the TIFF LZW stream [input] (TIFF 6.0, section 13: codes of 9 to 12 bits, most
/// significant bit first, one bit wider one code early). Shorter when the stream ends before; throws
/// [TiffDecodeException] on a code the stream cannot hold.
Uint8List lzwDecode(Uint8List input, int expected) {
  if (input.length >= 2 && input[0] == 0x00 && input[1] == 0x01) {
    throw const TiffDecodeException('the LZW of the TIFF 5 era');
  }
  final out = Uint8List(expected);
  // Each code past 257 is a run of the output already written: where it starts and how long it is
  final starts = Int32List(4096);
  final lengths = Int32List(4096);
  var written = 0;
  var width = 9;
  var next = 258;
  var previousStart = -1;
  var previousLength = 0;
  var bits = 0;
  var bitCount = 0;
  var read = 0;
  while (written < expected) {
    while (bitCount < width && read < input.length) {
      bits = (bits << 8) | input[read++];
      bitCount += 8;
    }
    if (bitCount < width) {
      // The data ended without its end code
      break;
    }
    bitCount -= width;
    final code = (bits >> bitCount) & ((1 << width) - 1);
    bits &= (1 << bitCount) - 1;
    if (code == 257) {
      break;
    }
    if (code == 256) {
      width = 9;
      next = 258;
      previousStart = -1;
      continue;
    }
    final start = written;
    int length;
    if (code < 256) {
      out[written++] = code;
      length = 1;
    } else if (previousStart < 0 || code > next || code > 4095) {
      throw TiffDecodeException('damaged LZW data (code $code of $next)');
    } else if (code < next) {
      length = lengths[code];
      final from = starts[code];
      final count = math.min(length, expected - written);
      out.setRange(written, written + count, out, from);
      written += count;
    } else {
      // The code being defined: the previous run and its own first byte
      length = previousLength + 1;
      for (var index = 0; index < previousLength && written < expected; index++) {
        out[written++] = out[previousStart + index];
      }
      if (written < expected) {
        out[written++] = out[previousStart];
      }
    }
    if (previousStart >= 0 && next < 4096) {
      starts[next] = previousStart;
      lengths[next] = previousLength + 1;
      next++;
      if (next >= (1 << width) - 1 && width < 12) {
        width++;
      }
    }
    previousStart = start;
    previousLength = length;
  }
  return written == expected ? out : Uint8List.sublistView(out, 0, written);
}

Uint8List _inflate(Uint8List input) {
  final List<int> out;
  try {
    out = ZLibDecoder().convert(input);
  } on FormatException catch (error) {
    throw TiffDecodeException('damaged Deflate data: ${error.message}');
  }
  return out is Uint8List ? out : Uint8List.fromList(out);
}

/// The first [expected] bytes of the PackBits stream [input]; shorter when the stream ends before
Uint8List _unpackBits(Uint8List input, int expected) {
  final out = Uint8List(expected);
  var written = 0;
  var read = 0;
  while (written < expected && read < input.length) {
    final header = input[read++];
    if (header < 128) {
      // header + 1 bytes as they are
      final count = math.min(header + 1, math.min(expected - written, input.length - read));
      out.setRange(written, written + count, input, read);
      written += count;
      read += header + 1;
    } else if (header > 128) {
      // 257 - header times the next byte
      if (read >= input.length) {
        break;
      }
      final value = input[read++];
      final end = math.min(expected, written + 257 - header);
      out.fillRange(written, end, value);
      written = end;
    }
  }
  return written == expected ? out : Uint8List.sublistView(out, 0, written);
}
