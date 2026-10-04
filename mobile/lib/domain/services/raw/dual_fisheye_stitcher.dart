// Turns the frame of a raw dual fisheye camera (an Insta360 .insp photo, both fisheye circles side by side) into an
// equirect picture, which the sphere of the panorama viewer and the immersive viewer of the Meta Quest show like any
// 360° photo. The GPU does it with a fragment shader (shaders/dual_fisheye.frag) drawn into a picture, in a few tens of
// milliseconds even at 8192 x 4096; the pure Dart math of dual_fisheye_math.dart does the same at a small size where
// the shader cannot run, and in the tests.
//
// The immersive viewer opens files and URLs only: a raw photo goes to it as a PNG in the cache of the app (see
// StitchedPhotoFiles), encoded in a background isolate.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:immich_mobile/domain/models/raw/dual_fisheye_calibration.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_math.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _log = Logger('DualFisheyeStitcher');

/// Asset key of the fragment shader, as pubspec.yaml lists it
const dualFisheyeShaderAsset = 'shaders/dual_fisheye.frag';

/// Widest equirect picture stitched: 8192 pixels is the most common largest texture of phone GPUs, and 8192 x 4096
/// pixels already take 128 MB
const dualFisheyeMaxOutputWidth = 8192;

/// Width of the equirect picture the pure Dart path stitches: about a second of work, sharp enough to look around
const dualFisheyeCpuOutputWidth = 1024;

/// The size of the equirect picture stitched from a frame [frameWidth] pixels wide: as wide as the frame, which holds
/// two half spheres side by side and so about as many pixels around the sphere, at most [maxWidth], and half as high.
/// Even, so that both halves of the sphere get the same number of columns.
({int width, int height}) dualFisheyeOutputSize(int frameWidth, {int maxWidth = dualFisheyeMaxOutputWidth}) {
  final width = math.max(2, math.min(frameWidth, maxWidth)) & ~1;
  return (width: width, height: width ~/ 2);
}

/// The uniforms of the shader, by name, four values each (see shaders/dual_fisheye.frag): the sizes, the scale from
/// canvas to frame pixels and the model, the rows of G and of the rotation of each lens, and the intrinsics of each lens
/// in canvas pixels. For a frame of [frameWidth] x [frameHeight] pixels drawn with [calibration], stitched into an
/// equirect picture of [outputWidth] x [outputHeight]. Throws an [ArgumentError] for a calibration without two lenses.
Map<String, List<double>> dualFisheyeShaderUniforms(
  DualFisheyeCalibration calibration, {
  required int frameWidth,
  required int frameHeight,
  required int outputWidth,
  required int outputHeight,
}) {
  final lenses = calibration.lenses;
  if (lenses.length < 2) {
    throw ArgumentError.value(lenses.length, 'calibration.lenses', 'two lenses expected');
  }
  final g = bodyFrame(calibration.downBody);
  List<double> row(Mat3 matrix, int index) => [matrix.at(index, 0), matrix.at(index, 1), matrix.at(index, 2), 0];
  Map<String, List<double>> lens(int index) {
    final lens = lenses[index];
    final pose = lensPose(lens, index);
    final name = 'uLens$index';
    return {
      'uR${index}0': row(pose, 0),
      'uR${index}1': row(pose, 1),
      'uR${index}2': row(pose, 2),
      '${name}Mei': [lens.xi ?? 0, lens.fx ?? 0, lens.fy ?? 0, lens.radius ?? 0],
      '${name}Centre': [lens.cx, lens.cy, lens.p1, lens.p2],
      '${name}K': [lens.k1, lens.k2, lens.k3, index.toDouble()],
    };
  }

  return {
    'uSizes': [outputWidth.toDouble(), outputHeight.toDouble(), frameWidth.toDouble(), frameHeight.toDouble()],
    'uParams': [canvasToFrameScale(calibration, frameHeight), calibration.model == DualFisheyeModel.mei ? 0 : 1, 0, 0],
    'uG0': row(g, 0),
    'uG1': row(g, 1),
    'uG2': row(g, 2),
    ...lens(0),
    ...lens(1),
  };
}

/// Stitches with the fragment shader, on the GPU of the UI isolate
class DualFisheyeStitcher {
  DualFisheyeStitcher(this._shader);

  // The program rather than the future of its load: a future completed in another zone (another test) would call its
  // listeners back there
  static ui.FragmentProgram? _program;

  final ui.FragmentProgram _shader;

  /// The stitcher of the app, its shader loaded once. A failed load is tried again next time.
  static Future<DualFisheyeStitcher> load() async =>
      DualFisheyeStitcher(_program ??= await ui.FragmentProgram.fromAsset(dualFisheyeShaderAsset));

  /// [source], a frame drawn with [calibration], stitched into an equirect picture of [dualFisheyeOutputSize]
  Future<ui.Image> stitch(
    ui.Image source,
    DualFisheyeCalibration calibration, {
    int maxWidth = dualFisheyeMaxOutputWidth,
  }) async {
    final (:width, :height) = dualFisheyeOutputSize(source.width, maxWidth: maxWidth);
    final uniforms = dualFisheyeShaderUniforms(
      calibration,
      frameWidth: source.width,
      frameHeight: source.height,
      outputWidth: width,
      outputHeight: height,
    );
    final shader = _shader.fragmentShader();
    try {
      for (final MapEntry(:key, :value) in uniforms.entries) {
        shader.getUniformVec4(key).set(value[0], value[1], value[2], value[3]);
      }
      // Bilinear: the output is never wider than the frame, mipmaps would only blur it
      shader.setImageSampler(0, source, filterQuality: ui.FilterQuality.low);
      final recorder = ui.PictureRecorder();
      ui.Canvas(
        recorder,
      ).drawRect(ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), ui.Paint()..shader = shader);
      final picture = recorder.endRecording();
      try {
        return await picture.toImage(width, height);
      } finally {
        picture.dispose();
      }
    } finally {
      shader.dispose();
    }
  }
}

/// The RGBA pixels of an equirect picture of [width] x [height] stitched from the RGBA pixels [rgba] of a frame of
/// [frameWidth] x [frameHeight] drawn with [calibration], with the pure Dart math (see [DualFisheyeSampler]): what the
/// shader does, pixel for pixel, sampled bilinearly as the GPU does. Opaque; black where no lens sees.
Uint8List stitchDualFisheyeRgba(
  Uint8List rgba, {
  required int frameWidth,
  required int frameHeight,
  required DualFisheyeCalibration calibration,
  required int width,
  required int height,
}) {
  final sampler = DualFisheyeSampler(calibration, frameWidth: frameWidth, frameHeight: frameHeight);
  final output = Uint8List(width * height * 4);
  final colour = Float64List(3);
  for (var j = 0; j < height; j++) {
    for (var i = 0; i < width; i++) {
      final (:lon, :lat) = equirectAngles(i, j, width, height);
      colour.fillRange(0, 3, 0);
      for (final sample in sampler.sample(lon, lat)) {
        _addBilinear(rgba, frameWidth, frameHeight, sample.x, sample.y, sample.weight, colour);
      }
      final at = (j * width + i) * 4;
      output[at] = colour[0].round().clamp(0, 255);
      output[at + 1] = colour[1].round().clamp(0, 255);
      output[at + 2] = colour[2].round().clamp(0, 255);
      output[at + 3] = 255;
    }
  }
  return output;
}

// Adds [weight] times the colour at frame position ([x], [y]) to [colour], interpolated between the four nearest
// pixels whose centres are at half pixels, the edges clamped: GPU texture sampling with a linear filter
void _addBilinear(Uint8List rgba, int width, int height, double x, double y, double weight, Float64List colour) {
  final tx = x - 0.5;
  final ty = y - 0.5;
  final x0 = tx.floor();
  final y0 = ty.floor();
  final fx = tx - x0;
  final fy = ty - y0;
  final left = x0.clamp(0, width - 1);
  final right = (x0 + 1).clamp(0, width - 1);
  final top = y0.clamp(0, height - 1);
  final bottom = (y0 + 1).clamp(0, height - 1);
  for (var c = 0; c < 3; c++) {
    final upper = rgba[(top * width + left) * 4 + c] * (1 - fx) + rgba[(top * width + right) * 4 + c] * fx;
    final lower = rgba[(bottom * width + left) * 4 + c] * (1 - fx) + rgba[(bottom * width + right) * 4 + c] * fx;
    colour[c] += weight * (upper * (1 - fy) + lower * fy);
  }
}

/// [source], a frame drawn with [calibration], stitched with the pure Dart math in a background isolate (see
/// [stitchDualFisheyeRgba]), [width] pixels wide at most: slower than the shader, for devices where it cannot run
Future<ui.Image> stitchDualFisheyeOnCpu(
  ui.Image source,
  DualFisheyeCalibration calibration, {
  int width = dualFisheyeCpuOutputWidth,
}) async {
  final size = dualFisheyeOutputSize(source.width, maxWidth: width);
  final bytes = await source.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (bytes == null) {
    throw StateError('The frame has no pixels to read');
  }
  final output = await _stitchRgbaInBackground(
    TransferableTypedData.fromList([bytes]),
    source.width,
    source.height,
    calibration,
    size.width,
    size.height,
  );
  return imageFromRgba(output, size.width, size.height);
}

// In a function of its own, so that the closure sent to the isolate holds nothing but what it needs: no image, whose
// native handle cannot cross isolates
Future<Uint8List> _stitchRgbaInBackground(
  TransferableTypedData pixels,
  int frameWidth,
  int frameHeight,
  DualFisheyeCalibration calibration,
  int width,
  int height,
) async {
  final output = await Isolate.run(
    () => TransferableTypedData.fromList([
      stitchDualFisheyeRgba(
        pixels.materialize().asUint8List(),
        frameWidth: frameWidth,
        frameHeight: frameHeight,
        calibration: calibration,
        width: width,
        height: height,
      ),
    ]),
  );
  return output.materialize().asUint8List();
}

/// An image of the RGBA pixels [rgba], [width] x [height]
Future<ui.Image> imageFromRgba(Uint8List rgba, int width, int height) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(rgba, width, height, ui.PixelFormat.rgba8888, completer.complete);
  return completer.future;
}

/// [source], a frame drawn with [calibration], stitched into an equirect picture: with the shader at up to [maxWidth]
/// pixels wide (see [DualFisheyeStitcher]), else with the pure Dart math at up to [cpuWidth] (see
/// [stitchDualFisheyeOnCpu]). [source] stays the caller's to dispose.
Future<ui.Image> stitchDualFisheye(
  ui.Image source,
  DualFisheyeCalibration calibration, {
  int maxWidth = dualFisheyeMaxOutputWidth,
  int cpuWidth = dualFisheyeCpuOutputWidth,
}) async {
  try {
    final stitcher = await DualFisheyeStitcher.load();
    return await stitcher.stitch(source, calibration, maxWidth: maxWidth);
  } catch (error, stackTrace) {
    _log.warning('The shader could not stitch the frame, stitching it on the CPU', error, stackTrace);
    return stitchDualFisheyeOnCpu(source, calibration, width: math.min(cpuWidth, maxWidth));
  }
}

// PNG

const _pngSignature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

// Colour type 2: RGB, 8 bits per channel. The stitched pictures are opaque: no alpha to keep.
const _pngTruecolour = 2;

// Filter type 1 of each row (Sub): each byte minus the same channel of the pixel on its left, which deflate packs much
// better than the raw bytes of a photo, at the cost of one subtraction per byte
const _pngSubFilter = 1;

/// A PNG of the RGBA pixels [rgba], [width] x [height], without the alpha: the format the immersive viewer reads from a
/// file that dart:ui writes no JPEG of. Pure Dart, to run in a background isolate. [level] is the deflate level, low
/// by default: the file only lives in the cache, and a 8192 x 4096 picture must not keep the user waiting.
Uint8List encodeOpaquePng(Uint8List rgba, int width, int height, {int level = 3}) {
  final compressed = BytesBuilder(copy: false);
  final deflate = ZLibEncoder(level: level).startChunkedConversion(_BytesSink(compressed));
  final row = Uint8List(1 + width * 3);
  row[0] = _pngSubFilter;
  for (var y = 0; y < height; y++) {
    var from = y * width * 4;
    var to = 1;
    var left0 = 0;
    var left1 = 0;
    var left2 = 0;
    for (var x = 0; x < width; x++, from += 4, to += 3) {
      final c0 = rgba[from];
      final c1 = rgba[from + 1];
      final c2 = rgba[from + 2];
      row[to] = (c0 - left0) & 0xff;
      row[to + 1] = (c1 - left1) & 0xff;
      row[to + 2] = (c2 - left2) & 0xff;
      left0 = c0;
      left1 = c1;
      left2 = c2;
    }
    deflate.add(row);
  }
  deflate.close();

  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, _pngTruecolour);
  final png = BytesBuilder(copy: false)..add(_pngSignature);
  _addPngChunk(png, 'IHDR', header.buffer.asUint8List());
  _addPngChunk(png, 'IDAT', compressed.takeBytes());
  _addPngChunk(png, 'IEND', Uint8List(0));
  return png.takeBytes();
}

void _addPngChunk(BytesBuilder png, String type, Uint8List data) {
  final typeBytes = ascii.encode(type);
  final crc = _crc32(data, _crc32(typeBytes, 0xffffffff)) ^ 0xffffffff;
  png
    ..add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List())
    ..add(typeBytes)
    ..add(data)
    ..add((ByteData(4)..setUint32(0, crc)).buffer.asUint8List());
}

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  }
  return c;
});

// The running CRC-32 of [bytes] from [crc], as PNG chunks carry it (the caller starts from and ends with all ones)
int _crc32(List<int> bytes, int crc) {
  var c = crc;
  for (final byte in bytes) {
    c = _crcTable[(c ^ byte) & 0xff] ^ (c >>> 8);
  }
  return c;
}

class _BytesSink implements Sink<List<int>> {
  _BytesSink(this._builder);

  final BytesBuilder _builder;

  @override
  void add(List<int> data) => _builder.add(data);

  @override
  void close() {}
}

/// The equirect pictures stitched from raw photos for the immersive viewer of the Meta Quest, which opens files: PNG
/// files in the directory [directory] gives, under a hash of a key that names the photo and its calibration. Only the
/// [keep] newest stay, so that the viewer still finds the ones it may go back to with previous and next.
///
/// A picture is stitched once however many ask for it meanwhile (see [obtain]): a local 72 MP stitch takes seconds,
/// and the user may press next again in the viewer, which finds the same photo while its stitch is still running.
class StitchedPhotoFiles {
  StitchedPhotoFiles(this._directory, {this.keep = 4, this.partialMaxAge = const Duration(minutes: 5)});

  /// The pictures in the cache directory of the app, which the system may empty
  factory StitchedPhotoFiles.temporary() =>
      StitchedPhotoFiles(() async => Directory(p.join((await getTemporaryDirectory()).path, folderName)));

  /// Name of the directory of the pictures in the cache directory
  static const folderName = 'raw360';

  static const _extension = '.png';
  static const _partial = '.tmp';

  // The pictures being obtained, by the path of their file, and the partial files being written. Shared by all the
  // instances: each opening of the viewer makes its own, on the same directory.
  static final _obtaining = <String, Future<File>>{};
  static final _writing = <String>{};
  static var _partials = 0;

  final Future<Directory> Function() _directory;

  /// Most pictures kept
  final int keep;

  /// Age past which a partial file that no write of the app is writing counts as left by a write cut short. Another
  /// process may be writing a younger one.
  final Duration partialMaxAge;

  /// The file name of the picture of [key]: a hash, as the key may hold any character
  static String fileNameFor(String key) =>
      'stitched_${sha1.convert(utf8.encode(key)).toString().substring(0, 24)}$_extension';

  /// The file of the picture of [key], written or not
  Future<File> fileFor(String key) async => File(p.join((await _directory()).path, fileNameFor(key)));

  /// The picture of [key] when it was stitched already, null otherwise. Marked as used now, so that the cleaning
  /// keeps it.
  Future<File?> existing(String key) async {
    final file = await fileFor(key);
    if (!file.existsSync()) {
      return null;
    }
    try {
      file.setLastModifiedSync(DateTime.now());
    } on FileSystemException catch (error) {
      _log.fine('Could not mark ${file.path} as used: $error');
    }
    return file;
  }

  /// The picture of [key]: the one stitched already, else the one being stitched, else the PNG [stitch] gives,
  /// written as the picture of [key]. A call while the picture is being stitched gets that stitch, failure included;
  /// once it failed, the next call stitches anew.
  Future<File> obtain(String key, Future<Uint8List> Function() stitch) async {
    final file = await fileFor(key);
    final running = _obtaining[file.path];
    if (running != null) {
      return running;
    }
    final obtained = _existingOrWritten(key, stitch);
    _obtaining[file.path] = obtained;
    try {
      return await obtained;
    } finally {
      unawaited(_obtaining.remove(file.path));
    }
  }

  Future<File> _existingOrWritten(String key, Future<Uint8List> Function() stitch) async =>
      await existing(key) ?? await write(key, await stitch());

  /// Writes [png] as the picture of [key], then removes the oldest ones past [keep]
  Future<File> write(String key, Uint8List png) async {
    final file = await fileFor(key);
    await file.parent.create(recursive: true);
    // Renamed once whole: the viewer never opens half a file. A partial file of its own, named after the process and
    // a count: another write of the same picture (from another opening of the viewer) must not pull it from under it.
    final partial = File('${file.path}.$pid-${_partials++}$_partial');
    _writing.add(partial.path);
    try {
      await partial.writeAsBytes(png, flush: true);
      await partial.rename(file.path);
    } finally {
      _writing.remove(partial.path);
    }
    await clean(except: file);
    return file;
  }

  /// Removes the pictures past the [keep] newest, never [except], and the partial files that writes cut short left:
  /// older than [partialMaxAge], and that no write of the app is writing
  Future<void> clean({File? except}) async {
    try {
      final directory = await _directory();
      if (!directory.existsSync()) {
        return;
      }
      final pictures = <(File, DateTime)>[];
      final now = DateTime.now();
      for (final entry in directory.listSync()) {
        if (entry is! File) {
          continue;
        }
        if (entry.path.endsWith(_partial)) {
          if (!_writing.contains(entry.path) && now.difference(entry.lastModifiedSync()) > partialMaxAge) {
            entry.deleteSync();
          }
        } else if (entry.path.endsWith(_extension) && entry.path != except?.path) {
          pictures.add((entry, entry.lastModifiedSync()));
        }
      }
      pictures.sort((a, b) => b.$2.compareTo(a.$2));
      final kept = except == null ? keep : keep - 1;
      for (final (file, _) in pictures.skip(math.max(0, kept))) {
        file.deleteSync();
      }
    } on FileSystemException catch (error) {
      // What is left is in the cache, which the system empties when it needs room
      _log.info('Could not clean the stitched pictures: $error');
    }
  }
}

/// The picture of [key] in [files], stitched from the raw photo [load] gives, drawn with [calibration], when it is not
/// there yet: on the GPU at up to [maxWidth] pixels wide (see [stitchDualFisheye]), encoded as a PNG in a background
/// isolate (see [encodeOpaquePng]). A call while the same picture is being stitched waits for that stitch (see
/// [StitchedPhotoFiles.obtain]).
Future<File> stitchedPhotoFile(
  StitchedPhotoFiles files,
  String key,
  DualFisheyeCalibration calibration,
  Future<ui.Image> Function() load, {
  int maxWidth = dualFisheyeMaxOutputWidth,
}) => files.obtain(key, () => _stitchedPng(calibration, load, maxWidth));

Future<Uint8List> _stitchedPng(
  DualFisheyeCalibration calibration,
  Future<ui.Image> Function() load,
  int maxWidth,
) async {
  final source = await load();
  final ui.Image stitched;
  try {
    stitched = await stitchDualFisheye(source, calibration, maxWidth: maxWidth);
  } finally {
    source.dispose();
  }
  final ByteData? bytes;
  final width = stitched.width;
  final height = stitched.height;
  try {
    bytes = await stitched.toByteData(format: ui.ImageByteFormat.rawRgba);
  } finally {
    stitched.dispose();
  }
  if (bytes == null) {
    throw StateError('The stitched picture has no pixels to read');
  }
  return _encodePngInBackground(TransferableTypedData.fromList([bytes]), width, height);
}

// See _stitchRgbaInBackground
Future<Uint8List> _encodePngInBackground(TransferableTypedData pixels, int width, int height) async {
  final png = await Isolate.run(
    () => TransferableTypedData.fromList([encodeOpaquePng(pixels.materialize().asUint8List(), width, height)]),
  );
  return png.materialize().asUint8List();
}
