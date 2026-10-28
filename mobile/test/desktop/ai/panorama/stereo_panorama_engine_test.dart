// The engine of the 3D versions of the 360° panoramas (lot P1, design-final 2026-10-27, sections 4.4 and 10.1) with a
// depth model of the tests: the chain in this isolate (the file read back by every reader of the app, the version of
// a generated panorama, the shift read back in the file against the budget of 1°, the date and the profile of the
// source, the refusals, the cancel at each step and between two views, what it leaves), then the engine with its
// worker. The same on the real model and a real 360° photo, by hand: real_stereo_panorama_test.dart.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// Pure Dart, already in the lock through maplibre_gl, as in lib/desktop/library/local_image_codec.dart
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/codec/dart_sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/codec/exif_minimal.dart';
import 'package:immich_mobile/desktop/ai/codec/jpeg_segments.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/ai_worker.dart';
import 'package:immich_mobile/desktop/ai/engine/depth_backend.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_chain.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/desktop/ai/panorama/pano_depth.dart';
import 'package:immich_mobile/desktop/ai/panorama/stereo_panorama_engine.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_input.dart';
import 'package:immich_mobile/desktop/ai/scene/scene_textures.dart' show encodeScenePicture;
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/desktop/library/library_metadata.dart';
import 'package:immich_mobile/desktop/library/native_sha1.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart'
    show parseGPanoCrop, parseGPanoProjectionType;
import 'package:path/path.dart' as p;

import '../codec/codec_fixtures.dart';
import '../fakes/fake_depth_backend.dart';
import '../fakes/fake_engine_tools.dart';
import '../fakes/fake_thread_priority.dart';

/// The depth model of the tests, small views, made in the worker isolate from this plain description
class _SmallDepthSpec implements DepthBackendSpec {
  const _SmallDepthSpec({this.failure});

  final String? failure;

  @override
  DepthBackend create() => FakeDepthBackend(inputWidth: 64, inputHeight: 48, failure: failure);
}

/// A 360° panorama of [width] x [height] that changes slowly and wraps across the seam, written in [folder]
String _panorama(Directory folder, String name, {int width = 192, int height = 96, int orientation = 1}) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final angle = 2 * math.pi * x / width;
      image.setPixelRgb(
        x,
        y,
        (128 + 90 * math.sin(angle)).round(),
        (128 + 90 * math.cos(angle)).round(),
        (40 + 170 * y / height).round(),
      );
    }
  }
  if (orientation != 1) {
    image.exif.imageIfd.orientation = orientation;
  }
  final path = p.join(folder.path, name);
  File(path).writeAsBytesSync(img.encodeJpg(image, quality: 95));
  return path;
}

/// The head of a JPEG of [width] x [height]: its frame header, then the start of its scan, no picture
List<int> _jpegHeadOfSize(int width, int height) => [
  ...[0xFF, 0xD8],
  ...[
    0xFF,
    0xC0,
    0,
    17,
    8,
    height >> 8,
    height & 0xFF,
    width >> 8,
    width & 0xFF,
    3,
    1,
    0x11,
    0,
    2,
    0x11,
    1,
    3,
    0x11,
    1,
  ],
  ...[0xFF, 0xDA, 0, 12, 3, 1, 0, 2, 0x11, 3, 0x11, 0, 63, 0],
  ...[0xFF, 0xD9],
];

/// The .part of the 3D version of [name] in [folder]
String _partIn(Directory folder, String name) => p.join(folder.path, '.${p.basenameWithoutExtension(name)}_3D.part');

/// The job of the 3D version of the 360° photo at [path], or of a panorama generated from [photo] ([parent] its
/// packet)
StereoPanoramaJob _jobFor(
  String path, {
  required String partPath,
  String? sha1,
  ImmersiveSource? photo,
  PanoramaXmp? parent,
  int quarterTurns = 0,
  bool asBytes = false,
}) {
  final bytes = File(path).readAsBytesSync();
  return StereoPanoramaJob(
    id: 'job-${p.basename(path)}',
    source: ImmersiveSource(
      name: p.basename(path),
      size: bytes.length,
      sha1: sha1 ?? (photo == null ? sha1OfFile(path) : ''),
      path: asBytes ? null : path,
      bytes: asBytes ? bytes : null,
    ),
    photo: photo,
    parent: parent,
    partPath: partPath,
    derivativeId: 'urn:uuid:6f1c2e0a-0000-4000-8000-000000000003',
    creatorTool: 'Immuch360 Desktop 3.4.0 (linux)',
    created: '2026-10-28T10:12:00+01:00',
    quarterTurns: quarterTurns,
  );
}

/// A depth model of the tests that reads the depth off the picture it is given: the blue of a pixel, 0 to 255, is its
/// disparity 1 / r up to a factor, and it answers 1 / z, z = r cos(theta) the depth along the axis of the view, as
/// Depth Anything gives a disparity; the views of [inverted] (by the order they run, 0 the first) it reads the wrong
/// way round. Views of 64 x 48, counted.
class _BlueDepthBackend implements DepthBackend {
  _BlueDepthBackend({this.inverted = const {}});

  final Set<int> inverted;
  var calls = 0;

  @override
  int get inputWidth => 64;

  @override
  int get inputHeight => 48;

  @override
  String get modelSha256 => depthModelOnnxSha256;

  @override
  DepthMap estimate(Float32List nchw) {
    final view = calls++;
    final plane = inputWidth * inputHeight;
    final tanX = panoDepthViewTanY * inputWidth / inputHeight;
    final values = Float32List(plane);
    for (var j = 0; j < inputHeight; j++) {
      for (var i = 0; i < inputWidth; i++) {
        final at = j * inputWidth + i;
        final blue = nchw[2 * plane + at] * reliefInputStd[2] + reliefInputMean[2];
        final a = ((i + 0.5) / inputWidth * 2 - 1) * tanX;
        final b = (1 - (j + 0.5) / inputHeight * 2) * panoDepthViewTanY;
        final disparity = blue * math.sqrt(1 + a * a + b * b);
        values[at] = inverted.contains(view) ? -disparity : disparity;
      }
    }
    return DepthMap(inputWidth, inputHeight, values);
  }

  @override
  void close() {}
}

/// A 360° panorama of 720 x 360 pixels, 2 a degree, for [_BlueDepthBackend]: what [near] says (longitude and
/// latitude in degrees, 0 ahead) is 1 m away (blue 255), the rest of the world 12 m (blue 21); red and green in
/// vertical stripes of 23 and 37 pixels, for the block matching
SbsDecoded _blueWorld(bool Function(double longitude, double latitude) near) {
  const width = 720;
  const height = 360;
  final rgba = Uint8List(4 * width * height);
  for (var y = 0; y < height; y++) {
    final latitude = 90 - (y + 0.5) * 180 / height;
    for (var x = 0; x < width; x++) {
      final longitude = (x + 0.5) * 360 / width - 180;
      final at = 4 * (y * width + x);
      rgba[at] = (128 + 100 * math.sin(2 * math.pi * x / 23)).round();
      rgba[at + 1] = (128 + 100 * math.sin(2 * math.pi * x / 37 + 1)).round();
      rgba[at + 2] = near(longitude, latitude) ? 255 : 21;
      rgba[at + 3] = 255;
    }
  }
  return SbsDecoded(width: width, height: height, rgba: rgba);
}

/// A pillar straight ahead, 60° wide and 50° high, the columns 300 to 419 and the rows 130 to 229
SbsDecoded _pillar() => _blueWorld((longitude, latitude) => longitude.abs() < 30 && latitude.abs() < 25);

/// A fence of 9 posts around the eye, 20° wide every 40°, up to 40° above and below the horizon
SbsDecoded _fence() => _blueWorld((longitude, latitude) {
  final along = (longitude + 180) % 40;
  return along >= 10 && along < 30 && latitude.abs() < 40;
});

/// How many pixels to the left the right eye of [frame] (top and bottom, the left eye on top) moved the columns [x0]
/// to [x0] + 31 of the [rows]: the shift, from -12 to 12, with the least difference of brightness
int _shiftAt(SbsDecoded frame, int x0, Iterable<int> rows) {
  final width = frame.width;
  final eye = frame.height ~/ 2;
  final rgba = frame.rgba;
  int brightness(int x, int y) {
    final at = 4 * (y * width + x % width);
    return 299 * rgba[at] + 587 * rgba[at + 1] + 114 * rgba[at + 2];
  }

  var best = 0;
  var least = -1;
  for (var shift = -12; shift <= 12; shift++) {
    var difference = 0;
    for (final y in rows) {
      for (var x = x0; x < x0 + 32; x++) {
        difference += (brightness(x, y) - brightness(x - shift, eye + y)).abs();
      }
    }
    if (least < 0 || difference < least) {
      least = difference;
      best = shift;
    }
  }
  return best;
}

/// The job of the 3D version of a panorama already decoded, named [name] in [folder]: no sum to check
StereoPanoramaJob _pictureJob(Directory folder, String name) => StereoPanoramaJob(
  id: 'job-$name',
  source: ImmersiveSource(name: name, size: 1, sha1: '', bytes: Uint8List(1)),
  partPath: _partIn(folder, name),
  derivativeId: 'urn:uuid:6f1c2e0a-0000-4000-8000-000000000004',
  creatorTool: 'Immuch360 Desktop 3.4.0 (linux)',
  created: '2026-10-28T10:12:00+01:00',
);

/// A GPano packet of an equirectangular panorama of [width] x [height] at ([left], [top]) of a full panorama of
/// [fullWidth] x [fullHeight]
String _gpanoPacket({
  required int width,
  required int height,
  required int fullWidth,
  required int fullHeight,
  int left = 0,
  int top = 0,
}) =>
    '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
    '<rdf:Description rdf:about="" xmlns:GPano="http://ns.google.com/photos/1.0/panorama/" '
    'GPano:ProjectionType="equirectangular" GPano:FullPanoWidthPixels="$fullWidth" '
    'GPano:FullPanoHeightPixels="$fullHeight" GPano:CroppedAreaImageWidthPixels="$width" '
    'GPano:CroppedAreaImageHeightPixels="$height" GPano:CroppedAreaLeftPixels="$left" '
    'GPano:CroppedAreaTopPixels="$top"/></rdf:RDF></x:xmpmeta>';

/// The packet of a panorama generated from salon.jpg, which the queue gives a chained job
PanoramaXmp _generatedPanorama() => PanoramaXmp.generated(
  width: 192,
  height: 96,
  region: const PhotoRegion(yaw: 0, pitch: 0, hfov: 65.4, vfov: 50.6),
  sourceCoverage: 0.08,
  generator: 'flux2-klein-base-4b-q4_0',
  generatorSha256: 'a' * 64,
  generatorLora: 'flux2-klein-4b-360-erp-lora-v1',
  generatorLoraSha256: 'b' * 64,
  seed: 42,
  steps: 20,
  upscaler: 'realesrgan-x4plus',
  sourceName: 'salon.jpg',
  sourceSize: 4182311,
  sourceSha1: 'X8tYgvibyzHDDN2yXGU/ft1XxeM=',
  sourceQuarterTurns: 1,
  created: '2026-10-28T10:00:00+01:00',
  creatorTool: 'Immuch360 Desktop 3.4.0 (linux)',
  derivativeId: 'urn:uuid:6f1c2e0a-0000-4000-8000-000000000002',
  qualityFlags: const [ReliefQualityFlag.seam, ReliefQualityFlag.mostlyInvented, ReliefQualityFlag.fovGuessed],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory folder;
  setUp(() => folder = Directory.systemTemp.createTempSync('stereo_panorama_test_'));
  tearDown(() => folder.deleteSync(recursive: true));

  StereoPanoramaOutcome runChain(
    StereoPanoramaJob job, {
    FakeDepthShape shape = FakeDepthShape.gradient,
    DepthBackend? backend,
    SbsDecoded? decoded,
    double maxShiftDegrees = Relief360V1.maxShiftDegrees,
    bool Function()? isCancelled,
    void Function(ImmersiveProgress progress)? onProgress,
    PartWriter writePart = writePartFile,
    MemoryProbe? memory,
  }) =>
      StereoPanoramaChain(
        backend: backend ?? FakeDepthBackend(shape: shape, inputWidth: 64, inputHeight: 48),
        codecs: const [DartSbsCodec()],
        writePart: writePart,
        memory: memory,
        maxShiftDegrees: maxShiftDegrees,
      ).run(
        job,
        ChainOriginal(bytes: job.source.bytes ?? File(job.source.path!).readAsBytesSync(), decoded: decoded),
        isCancelled: isCancelled ?? () => false,
        onProgress: onProgress,
      );

  group('the chain', () {
    test('a 360° photo: a square of both eyes, the left one the panorama, read as a stereo sphere', () {
      final path = _panorama(folder, 'PANO_0001.jpg');
      final before = File(path).readAsBytesSync();
      final job = _jobFor(path, partPath: _partIn(folder, 'PANO_0001.jpg'), quarterTurns: 0);
      final outcome = runChain(job);

      expect(outcome.result.isDone, isTrue, reason: '${outcome.result.error}: ${outcome.result.message}');
      expect(File(path).readAsBytesSync(), before, reason: 'the original is never written');
      final bytes = File(job.partPath).readAsBytesSync();
      final xmp = ImmersiveXmp.findIn(bytes)! as StereoPanoramaXmp;
      final details = outcome.result.details! as StereoPanoramaResultDetails;
      expect((details.width, details.height), (192, 192));
      expect(outcome.result.bytesWritten, bytes.length);

      // The packet: a version of the 360° photo itself, its relief estimated
      expect(xmp.kind, ImmersiveKind.stereoPanorama360);
      expect(xmp.origin, ImmersiveOrigin.estimatedDepth);
      expect(xmp.relief, isNull);
      expect(xmp.pipeline, Relief360V1.pipeline);
      expect(xmp.depthModel, depthModelName);
      expect(xmp.depthModelSha256, depthModelOnnxSha256);
      expect(xmp.maxShiftDegrees, Relief360V1.maxShiftDegrees);
      expect(xmp.sourceName, 'PANO_0001.jpg');
      expect(xmp.sourceSize, before.length);
      expect(xmp.sourceSha1, job.source.sha1);
      expect(xmp.parentDerivativeId, isNull);
      expect(xmp.derivativeId, job.derivativeId);
      expect(xmp.digitalSourceType, iptcCompositeWithTrainedAlgorithmicMedia);
      expect(xmp.description, stereo360Description);
      expect(xmp.settingsKey, stereoPanoramaSettingsKeyOf(0, depthModelSha256: depthModelOnnxSha256));

      // GPano under its literal prefix, a whole sphere; the frame square: top and bottom, the left eye on top
      final text = latin1.decode(bytes.sublist(0, math.min(bytes.length, 128 * 1024)));
      expect(text, contains('GPano:ProjectionType="equirectangular"'));
      expect(parseGPanoProjectionType(text), 'equirectangular');
      final crop = parseGPanoCrop(text)!;
      expect(isPartialSphere(crop), isFalse);
      expect(guessStereoLayout(width: details.width, height: details.height), StereoLayout.topBottom);
      expect(
        guessSphereCoverage(fileName: 'PANO_0001_3D.jpg', width: details.width, height: details.height),
        SphereCoverage.full,
      );
      expect(probeStereoPhotoHead(bytes, name: 'PANO_0001_3D.jpg'), isNull, reason: 'no side by side photo');

      // The left eye is the panorama, the right eye close to it (1° at most)
      final frame = const DartSbsCodec().decodeJpeg(bytes);
      final source = const DartSbsCodec().decodeJpeg(before);
      expect((frame.width, frame.height), (192, 192));
      var top = 0;
      var bottom = 0;
      for (var i = 0; i < source.rgba.length; i += 4) {
        for (var channel = 0; channel < 3; channel++) {
          top = math.max(top, (frame.rgba[i + channel] - source.rgba[i + channel]).abs());
          bottom = math.max(bottom, (frame.rgba[source.rgba.length + i + channel] - source.rgba[i + channel]).abs());
        }
      }
      expect(top, lessThanOrEqualTo(8), reason: 'the panorama, through a JPEG of quality 90');
      expect(bottom, lessThanOrEqualTo(16), reason: 'the panorama moved by 1° at most');

      // The scanner of the library: a 360° photo, ours, of its kind
      final target = p.join(folder.path, 'PANO_0001_3D.jpg');
      File(job.partPath).copySync(target);
      final metadata = readMediaMetadataSync(target, LibraryMediaKind.image);
      expect(metadata.immersive, isA<StereoPanoramaXmp>());
      expect(metadata.projection, 'equirectangular');
    });

    test('the version of a generated panorama: of its photo, its parent named, never turned again', () {
      final path = _panorama(folder, 'salon_360.jpg');
      final parent = _generatedPanorama();
      final photo = ImmersiveSource(
        name: 'salon.jpg',
        size: 4182311,
        sha1: 'X8tYgvibyzHDDN2yXGU/ft1XxeM=',
        path: p.join(folder.path, 'salon.jpg'),
      );
      final job = _jobFor(
        path,
        partPath: _partIn(folder, 'salon_360.jpg'),
        photo: photo,
        parent: parent,
        quarterTurns: 1,
      );
      final outcome = runChain(job);

      expect(outcome.result.isDone, isTrue, reason: '${outcome.result.error}: ${outcome.result.message}');
      final bytes = File(job.partPath).readAsBytesSync();
      final xmp = ImmersiveXmp.findIn(bytes)! as StereoPanoramaXmp;
      expect(xmp.origin, ImmersiveOrigin.generatedContent);
      expect(xmp.relief, ImmersiveOrigin.estimatedDepth);
      expect(xmp.isGenerated, isTrue);
      expect(xmp.parentDerivativeId, parent.derivativeId);
      expect(xmp.region, parent.region);
      expect(xmp.sourceCoverage, parent.sourceCoverage);
      expect((xmp.sourceName, xmp.sourceSize, xmp.sourceSha1), ('salon.jpg', 4182311, 'X8tYgvibyzHDDN2yXGU/ft1XxeM='));
      expect(xmp.sourceQuarterTurns, 1, reason: 'the turns of the photo, for its identity and its settings');
      expect(xmp.description, stereoPanoramaDescription);
      // The seam and the invented share of the panorama go with its 3D version; the flags of another kind do not
      expect(xmp.qualityFlags, [ReliefQualityFlag.seam, ReliefQualityFlag.mostlyInvented]);
      expect(outcome.result.qualityFlags, xmp.qualityFlags);
      // The panorama is upright already: a square frame, not turned by the quarter turn of the photo
      final frame = const DartSbsCodec().decodeJpeg(bytes);
      expect((frame.width, frame.height), (192, 192));
    });

    test('the steps of a 3D panorama in their order, the views told one by one', () {
      final path = _panorama(folder, 'pano.jpg');
      final seen = <ImmersiveProgress>[];
      runChain(_jobFor(path, partPath: _partIn(folder, 'pano.jpg')), onProgress: seen.add);

      expect(seen.map((progress) => progress.stage).toSet().toList(), ImmersiveStage.stereoPanorama);
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i].perMille, greaterThanOrEqualTo(seen[i - 1].perMille), reason: 'never back');
        expect(seen[i].stage.index, greaterThanOrEqualTo(seen[i - 1].stage.index));
      }
      final views = seen.where((progress) => progress.stage == ImmersiveStage.panoramaDepth && progress.step! > 0);
      expect(views.map((progress) => progress.step), [for (var k = 1; k <= Relief360V1.tangentViews; k++) k]);
      expect(views.map((progress) => progress.steps).toSet(), {Relief360V1.tangentViews});
      expect(seen.last, const ImmersiveProgress(ImmersiveStage.writing, 1000));
    });

    test('a world without relief: notEnoughRelief, no file, the mono panorama stays', () {
      final path = _panorama(folder, 'flat.jpg');
      final part = _partIn(folder, 'flat.jpg');
      final outcome = runChain(_jobFor(path, partPath: part), shape: FakeDepthShape.constant);

      expect(outcome.result.error, ImmersiveErrorCode.notEnoughRelief);
      expect(File(part).existsSync(), isFalse);
    });

    test('a frame that is not 2:1 is no whole sphere: refused before the depth', () {
      final path = _panorama(folder, 'wide.jpg', width: 300, height: 100);
      final seen = <ImmersiveStage>{};
      final outcome = runChain(
        _jobFor(path, partPath: _partIn(folder, 'wide.jpg')),
        onProgress: (progress) => seen.add(progress.stage),
      );

      expect(outcome.result.error, ImmersiveErrorCode.unsupportedFormat);
      expect(seen, isNot(contains(ImmersiveStage.panoramaDepth)));
    });

    test('upright by its EXIF orientation: a 360° photo stored turned comes out a 2:1 sphere', () {
      // Stored 96 x 192, its orientation 6 (turned a quarter): seen as 192 x 96
      final path = _panorama(folder, 'turned.jpg', width: 96, height: 192, orientation: 6);
      final outcome = runChain(_jobFor(path, partPath: _partIn(folder, 'turned.jpg')));

      expect(outcome.result.isDone, isTrue, reason: '${outcome.result.error}: ${outcome.result.message}');
      expect((outcome.result.details! as StereoPanoramaResultDetails).width, 192);
    });

    test('a 360° photo changed after it was chosen: sourceLost, nothing written', () {
      final path = _panorama(folder, 'changed.jpg');
      final part = _partIn(folder, 'changed.jpg');
      final outcome = runChain(_jobFor(path, partPath: part, sha1: 'AAAAAAAAAAAAAAAAAAAAAAAAAAA='));

      expect(outcome.result.error, ImmersiveErrorCode.sourceLost);
      expect(File(part).existsSync(), isFalse);
    });

    test('cancelled at each step: cancelled, the .part as it was found', () {
      final path = _panorama(folder, 'pano.jpg');
      for (final stage in ImmersiveStage.stereoPanorama) {
        final part = _partIn(folder, 'pano.jpg');
        // The write probe left an empty .part
        File(part).writeAsBytesSync(const []);
        var at = ImmersiveStage.reading;
        final outcome = runChain(
          _jobFor(path, partPath: part),
          onProgress: (progress) => at = progress.stage,
          isCancelled: () => at == stage,
        );
        expect(outcome.result.error, ImmersiveErrorCode.cancelled, reason: stage.name);
        expect(File(part).lengthSync(), 0, reason: 'after a cancel at ${stage.name}');
      }
    });

    test('a write refused: its code, the .part as it was', () {
      final path = _panorama(folder, 'pano.jpg');
      final part = _partIn(folder, 'pano.jpg');
      final outcome = runChain(
        _jobFor(path, partPath: part),
        // The code of a disk full on this system, as writeFailureOf reads it
        writePart: (path, bytes) => throw FileSystemException(
          'No space left on device',
          path,
          OSError('No space left on device', Platform.isWindows ? 112 : 28),
        ),
      );

      expect(outcome.result.error, ImmersiveErrorCode.diskFull);
      expect(File(part).existsSync(), isFalse);
    });

    test('the memory checked before the decoding: outOfMemory with both figures', () {
      final path = _panorama(folder, 'pano.jpg');
      final outcome = runChain(
        _jobFor(path, partPath: _partIn(folder, 'pano.jpg')),
        memory: const FixedMemoryProbe(available: 100 * 1000 * 1000),
      );

      expect(outcome.result.error, ImmersiveErrorCode.outOfMemory);
      expect(outcome.result.message, matches(RegExp(r'^This panorama needs about \d+ MB of memory, 100 MB are free$')));
    });
  });

  group('the chain, what it writes and what it refuses', () {
    test('the nearest moves 1° at the equator and no more, the far stays, the poles do not move: read in the file', () {
      final job = _pictureJob(folder, 'pillar.png');
      final outcome = runChain(job, backend: _BlueDepthBackend(), decoded: _pillar());

      expect(outcome.result.isDone, isTrue, reason: '${outcome.result.error}: ${outcome.result.message}');
      final frame = const DartSbsCodec().decodeJpeg(File(job.partPath).readAsBytesSync());
      expect((frame.width, frame.height), (720, 720));
      // 2 pixels a degree: the pillar, the nearest, 2 pixels at the equator, and no column more than that
      final equator = [for (var y = 172; y < 188; y++) y];
      final shifts = {for (var x0 = 0; x0 + 32 <= 720; x0 += 32) x0: _shiftAt(frame, x0, equator)};
      expect(shifts[352], 2, reason: 'the pillar ahead, d = 1: 1° at the equator');
      expect(shifts.values.reduce(math.max), lessThanOrEqualTo(2), reason: 'the budget of 1°: $shifts');
      expect(shifts.values.reduce(math.min), greaterThanOrEqualTo(0), reason: 'never the wrong way: $shifts');
      for (final MapEntry(key: x0, value: shift) in shifts.entries) {
        if (x0 + 32 <= 292 || x0 >= 428) {
          expect(shift, 0, reason: 'the far world at the column $x0 stays put');
        }
      }
      final poles = [for (var y = 0; y < 8; y++) y, for (var y = 352; y < 360; y++) y];
      for (var x0 = 0; x0 + 32 <= 720; x0 += 32) {
        expect(_shiftAt(frame, x0, poles), 0, reason: 'nothing moves at the poles, column $x0');
      }
    });

    test('cancelled between two views: the views after it never run', () {
      final path = _panorama(folder, 'pano.jpg');
      final backend = FakeDepthBackend(inputWidth: 64, inputHeight: 48);
      final outcome = runChain(
        _jobFor(path, partPath: _partIn(folder, 'pano.jpg')),
        backend: backend,
        isCancelled: () => backend.calls >= 3,
      );

      expect(outcome.result.error, ImmersiveErrorCode.cancelled);
      expect(backend.calls, lessThanOrEqualTo(4), reason: 'not the twenty views');
    });

    test('the date of the 360° photo and its Display P3 profile go into its 3D version', () {
      final profile = codecFixture('display_p3.icc');
      final pixels = const DartSbsCodec().decodeJpeg(File(_panorama(folder, 'plain.jpg')).readAsBytesSync());
      final (jpeg, _) = encodeScenePicture(
        const [DartSbsCodec()],
        SbsDecoded(width: pixels.width, height: pixels.height, rgba: pixels.rgba, iccProfile: profile),
        quality: 95,
        exif: minimalExif(const ImmersiveExif(dateTimeOriginal: '2026:07:14 18:30:00', offsetTimeOriginal: '+02:00')),
      );
      final path = p.join(folder.path, 'PANO_0002.jpg');
      File(path).writeAsBytesSync(jpeg);
      final job = _jobFor(path, partPath: _partIn(folder, 'PANO_0002.jpg'));
      final outcome = runChain(job);

      expect(outcome.result.isDone, isTrue, reason: '${outcome.result.error}: ${outcome.result.message}');
      final header = JpegHeader.read(File(job.partPath).readAsBytesSync());
      final kept = keptExif(header.exif);
      expect((kept.dateTimeOriginal, kept.offsetTimeOriginal), ('2026:07:14 18:30:00', '+02:00'));
      expect(header.iccProfile, profile);
    });

    test('more than 8 % of the right eye filled in: notEnoughRelief, no file, the mono panorama stays', () {
      final job = _pictureJob(folder, 'fence.png');
      final outcome = runChain(job, backend: _BlueDepthBackend(), decoded: _fence(), maxShiftDegrees: 14);

      expect(outcome.result.error, ImmersiveErrorCode.notEnoughRelief);
      expect(outcome.result.message, matches(RegExp(r'^\d+\.\d % of the right eye would be filled in$')));
      expect(double.parse(outcome.result.message!.split(' ').first), greaterThan(8));
      expect(File(job.partPath).existsSync(), isFalse);
    });

    test('between 5 and 8 % of the right eye filled in: made, hiddenAreas in the result and in the packet', () {
      final job = _pictureJob(folder, 'fence.png');
      final outcome = runChain(job, backend: _BlueDepthBackend(), decoded: _fence(), maxShiftDegrees: 7);

      expect(outcome.result.isDone, isTrue, reason: '${outcome.result.error}: ${outcome.result.message}');
      final filled = (outcome.result.details! as StereoPanoramaResultDetails).filledFraction;
      expect(filled, inExclusiveRange(ReliefV1.hiddenAreasRatio, Relief360V1.maxFilled));
      expect(outcome.result.qualityFlags, [ReliefQualityFlag.hiddenAreas]);
      final xmp = ImmersiveXmp.findIn(File(job.partPath).readAsBytesSync())! as StereoPanoramaXmp;
      expect(xmp.qualityFlags, [ReliefQualityFlag.hiddenAreas]);
    });

    test('views left out until part of the sphere has no depth: notEnoughRelief, no file, nothing made up', () {
      // The five views around the north pole read the wrong way round: each left out, and the pole seen by no view
      final job = _pictureJob(folder, 'fence.png');
      final outcome = runChain(
        job,
        backend: _BlueDepthBackend(inverted: {0, 1, 2, 3, 4}),
        decoded: _fence(),
      );

      expect(outcome.result.error, ImmersiveErrorCode.notEnoughRelief);
      expect(outcome.result.message, matches(RegExp(r'^\d+ pixels of the sphere have no depth the views agree on$')));
      expect(
        [for (final alignment in outcome.alignments) alignment.isUsed],
        [for (var k = 0; k < Relief360V1.tangentViews; k++) k >= 5],
      );
      expect(File(job.partPath).existsSync(), isFalse);
    });

    test('the depth model fails: modelFailed, its session closed at once, nothing written', () {
      final path = _panorama(folder, 'pano.jpg');
      final backend = FakeDepthBackend(inputWidth: 64, inputHeight: 48, failure: 'broken model');
      final outcome = runChain(_jobFor(path, partPath: _partIn(folder, 'pano.jpg')), backend: backend);

      expect(outcome.result.error, ImmersiveErrorCode.modelFailed);
      expect(outcome.result.message, 'broken model');
      expect(backend.calls, 1);
      expect(backend.closed, isTrue, reason: 'its memory given back now, not at the next job');
      expect(File(_partIn(folder, 'pano.jpg')).existsSync(), isFalse);
    });

    test('cancelled once the file is written: cancelled, the .part as it was found', () {
      final path = _panorama(folder, 'pano.jpg');
      final part = _partIn(folder, 'pano.jpg');
      for (final probed in [true, false]) {
        if (probed) {
          // The write probe left an empty .part
          File(part).writeAsBytesSync(const []);
        }
        var cancelled = false;
        final outcome = runChain(
          _jobFor(path, partPath: part),
          isCancelled: () => cancelled,
          writePart: (path, bytes) {
            writePartFile(path, bytes);
            cancelled = true;
          },
        );

        expect(outcome.result.error, ImmersiveErrorCode.cancelled, reason: 'probed $probed');
        if (probed) {
          expect(File(part).lengthSync(), 0, reason: 'empty again');
          File(part).deleteSync();
        } else {
          expect(File(part).existsSync(), isFalse, reason: 'gone again');
        }
      }
    });
  });

  group('sizes and settings', () {
    test('the left eye 4096 x 2048 at most, an exact 2:1; the map half as wide', () {
      expect(stereoPanoramaEyeSize(8192), (4096, 2048));
      expect(stereoPanoramaEyeSize(5376), (4096, 2048));
      expect(stereoPanoramaEyeSize(3841), (3840, 1920));
      expect(stereoPanoramaMapSize(4096), (2048, 1024));
      expect(stereoPanoramaMapSize(1000), (1000, 500));
      expect(isWholeSphereFrame(6000, 3008), isTrue);
      expect(isWholeSphereFrame(4000, 4000), isFalse);
      expect(isWholeSphereFrame(4800, 2000), isFalse);
    });

    test('the memory of a panorama of 8192 x 4096: the design figure of the queue, the session apart', () {
      final need = stereoPanoramaJobMemoryNeed(sourceWidth: 8192, sourceHeight: 4096);
      expect(need, lessThanOrEqualTo(stereoPanoramaJobMemory + 128 * 1024 * 1024));
      expect(
        need - stereoPanoramaJobMemoryNeed(sourceWidth: 8192, sourceHeight: 4096, sessionOpen: true),
        depthSessionMemory,
      );
    });

    test('the key of the settings: the depth model, relief-360-v1, 1°, the turns', () {
      expect(stereoPanoramaSettingsKeyOf(5, depthModelSha256: 'abc'), 'abc|relief-360-v1|1.0|1');
    });
  });

  group('the engine', () {
    late NativeCancelFlag cancel;
    setUp(() => cancel = NativeCancelFlag());
    tearDown(() => cancel.free());

    StereoPanoramaEngine engineWith({
      DepthBackendSpec model = const _SmallDepthSpec(),
      Map<String, int?> files = const {},
      MemoryProbe memory = const FixedMemoryProbe(),
    }) {
      final engine = StereoPanoramaEngine(
        model: model,
        requiredFiles: files,
        codec: SbsCodecChoice.dart,
        priority: FakeThreadPriority(threads: {1: 'main'}),
        memory: memory,
      );
      addTearDown(engine.dispose);
      return engine;
    }

    test(
      'reads the panorama by its path and makes its 3D version in the worker, the model kept for the next',
      () async {
        final path = _panorama(folder, 'pano.jpg');
        final engine = engineWith();
        final seen = <ImmersiveProgress>[];
        final result = await engine.run(
          _jobFor(path, partPath: _partIn(folder, 'pano.jpg')),
          cancel: cancel,
          onProgress: seen.add,
        );

        expect(result.isDone, isTrue, reason: '${result.error}: ${result.message}');
        expect(seen.map((progress) => progress.stage).toSet().toList(), ImmersiveStage.stereoPanorama);
        expect(engine.lastOutcome!.alignments, hasLength(Relief360V1.tangentViews));
        final second = await engine.run(
          _jobFor(path, partPath: _partIn(folder, 'again.jpg'), asBytes: true),
          cancel: cancel,
        );
        expect(second.isDone, isTrue, reason: '${second.error}: ${second.message}');
        final status = await engine.worker!.status();
        expect(status.jobs, 2);
        expect(status.openSessions, [stereoPanoramaDepthSession]);
      },
    );

    test('a PNG decoded by the engine of Flutter on the root isolate, then made 3D in the worker', () async {
      final jpeg = _panorama(folder, 'source.jpg');
      final decoded = const DartSbsCodec().decodeJpeg(File(jpeg).readAsBytesSync());
      final png = p.join(folder.path, 'pano.png');
      File(png).writeAsBytesSync(
        img.encodePng(
          img.Image.fromBytes(width: decoded.width, height: decoded.height, bytes: decoded.rgba.buffer, numChannels: 4),
        ),
      );
      final result = await engineWith().run(_jobFor(png, partPath: _partIn(folder, 'pano.png')), cancel: cancel);

      expect(result.isDone, isTrue, reason: '${result.error}: ${result.message}');
    });

    test('the depth model fails: modelFailed with its message, nothing written', () async {
      final path = _panorama(folder, 'pano.jpg');
      final result = await engineWith(
        model: const _SmallDepthSpec(failure: 'broken model'),
      ).run(_jobFor(path, partPath: _partIn(folder, 'pano.jpg')), cancel: cancel);

      expect(result.error, ImmersiveErrorCode.modelFailed);
      expect(result.message, 'broken model');
      expect(File(_partIn(folder, 'pano.jpg')).existsSync(), isFalse);
    });

    test('a component missing or damaged: componentsMissing before anything is read', () async {
      final model = p.join(folder.path, 'model.onnx');
      File(model).writeAsBytesSync(List.filled(10, 1));
      final path = _panorama(folder, 'pano.jpg');
      final job = _jobFor(path, partPath: _partIn(folder, 'pano.jpg'));

      final damaged = await engineWith(files: {model: 11}).run(job, cancel: cancel);
      final gone = await engineWith(files: {p.join(folder.path, 'onnxruntime.so'): null}).run(job, cancel: cancel);

      expect(damaged.error, ImmersiveErrorCode.componentsMissing);
      expect(gone.error, ImmersiveErrorCode.componentsMissing);
    });

    test('cancelled before it starts: nothing read, no worker', () async {
      final path = _panorama(folder, 'pano.jpg');
      final engine = engineWith();
      cancel.cancel();
      final result = await engine.run(_jobFor(path, partPath: _partIn(folder, 'pano.jpg')), cancel: cancel);

      expect(result.error, ImmersiveErrorCode.cancelled);
      expect(engine.worker, isNull);
    });

    test(
      'a 2:1 panorama whose GPano crop is 180° x 90°: unsupportedFormat before the worker; a whole one is made',
      () async {
        final pixels = const DartSbsCodec().decodeJpeg(File(_panorama(folder, 'plain.jpg')).readAsBytesSync());
        String written(String name, String xmp) {
          final (jpeg, _) = encodeScenePicture(const [DartSbsCodec()], pixels, quality: 95, xmp: xmp);
          final path = p.join(folder.path, name);
          File(path).writeAsBytesSync(jpeg);
          return path;
        }

        // A phone panorama of 180° x 90°: a 2:1 frame of a quarter of the sphere, centred
        final partial = written(
          'PANO_half.jpg',
          _gpanoPacket(width: 192, height: 96, fullWidth: 384, fullHeight: 192, left: 96, top: 48),
        );
        // A camera that writes the crop of a whole sphere
        final whole = written('PANO_whole.jpg', _gpanoPacket(width: 192, height: 96, fullWidth: 192, fullHeight: 96));
        final engine = engineWith();

        final refused = await engine.run(_jobFor(partial, partPath: _partIn(folder, 'PANO_half.jpg')), cancel: cancel);
        expect(refused.error, ImmersiveErrorCode.unsupportedFormat);
        expect(refused.message, 'A partial panorama of 180° x 90° has no sphere to go around');
        expect(engine.worker, isNull, reason: 'refused before the worker starts');
        expect(File(_partIn(folder, 'PANO_half.jpg')).existsSync(), isFalse);

        final made = await engine.run(_jobFor(whole, partPath: _partIn(folder, 'PANO_whole.jpg')), cancel: cancel);
        expect(made.isDone, isTrue, reason: '${made.error}: ${made.message}');
      },
    );

    test('the worker checks the memory before it decodes the panorama, from its header', () async {
      // The head of a JPEG of 16 384 x 8 192: about 1.8 GB to make, more than the 100 MB free and the 1 GiB Windows
      // gives beyond them; refused before anything is decoded
      final path = p.join(folder.path, 'huge.jpg');
      File(path).writeAsBytesSync(_jpegHeadOfSize(16384, 8192));
      final result = await engineWith(
        memory: const FixedMemoryProbe(available: 100 * 1000 * 1000),
      ).run(_jobFor(path, partPath: _partIn(folder, 'huge.jpg')), cancel: cancel);

      expect(result.error, ImmersiveErrorCode.outOfMemory);
      expect(result.message, matches(RegExp(r'^This panorama needs about \d+ MB of memory, 100 MB are free$')));
    });
  });
}
