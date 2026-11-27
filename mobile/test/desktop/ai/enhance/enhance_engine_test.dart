import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/codec/dart_sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/codec/exif_minimal.dart';
import 'package:immich_mobile/desktop/ai/codec/jpeg_segments.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_chain.dart' show SbsCodecChoice;
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_engine.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_levels.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:path/path.dart' as p;

import '../fakes/app_progress.dart';

const _fixtures = 'test/fixtures/ai_immersive/codec';

/// A model that adds [add] to every channel, tile after tile, and remembers what it was given
class _FakeBackend implements EnhanceBackend {
  _FakeBackend({this.add = 40, this.failure, this.cancelAt, this.tiling});

  final int add;
  final BackendException? failure;
  final NativeCancelFlag? cancelAt;

  /// The tiles told at each step, as Rebuild details tells them; null: none, as Sharpen
  final List<EnhanceTileProgress>? tiling;
  SbsDecoded? given;
  String? folder;

  @override
  String get model => 'Fake model';

  @override
  String get modelSha256 => 'ab' * 32;

  @override
  bool fellBack = false;

  @override
  EnhanceTileProgress? tileProgress;

  @override
  Future<Uint8List> enhance(
    SbsDecoded picture, {
    required String workFolder,
    required int seed,
    required NativeCancelFlag cancel,
    required void Function(int done, int all) onStep,
  }) async {
    given = picture;
    folder = workFolder;
    expect(Directory(workFolder).existsSync(), isTrue);
    final told = tiling;
    if (told != null) {
      for (final (index, tiles) in told.indexed) {
        tileProgress = tiles;
        onStep(index, told.length);
      }
      tileProgress = null;
    } else {
      for (var tile = 1; tile <= 3; tile++) {
        onStep(tile, 3);
      }
    }
    cancelAt?.cancel();
    if (failure case final error?) {
      throw error;
    }
    final out = Uint8List.fromList(picture.rgba);
    for (var i = 0; i < out.length; i++) {
      if (i % 4 != 3) {
        out[i] = (out[i] + add).clamp(0, 255);
      }
    }
    return out;
  }
}

class _Memory implements MemoryProbe {
  const _Memory(this.available, {this.commit});

  final int? commit;

  final int? available;

  @override
  MemoryFacts read() => MemoryFacts(physical: 16 << 30, available: available, commitAvailable: commit);
}

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('enhance-engine-'));
  tearDown(() => temp.deleteSync(recursive: true));

  EnhanceJob jobOf(String fixture, {EnhanceLevel level = EnhanceLevel.sharpen, int strength = 100}) {
    final path = '$_fixtures/$fixture';
    return EnhanceJob(
      id: 'conversion-1',
      source: ImmersiveSource(name: fixture, size: File(path).lengthSync(), sha1: 'c2hhMQ==', path: path),
      partPath: p.join(temp.path, '.out.part'),
      derivativeId: 'urn:uuid:7c0ffee0-0000-4000-8000-000000000001',
      creatorTool: 'Immuch360 Desktop 3.4.6 (windows)',
      created: '2026-11-23T15:00:00+01:00',
      level: level,
      strength: strength,
    );
  }

  EnhanceEngine engineWith(EnhanceBackend backend, {int? available = 8 << 30, int? commit}) => EnhanceEngine(
    backend: backend,
    workFolder: (id) => Directory(p.join(temp.path, 'work-$id'))..createSync(),
    codecs: SbsCodecChoice.dart,
    memory: _Memory(available, commit: commit),
  );

  test(
    'keeps the date, the place and the orientation, writes upright with our mark, never touches the original',
    () async {
      final original = File('$_fixtures/exif_camera.jpg').readAsBytesSync();
      final backend = _FakeBackend();
      final stages = <ImmersiveStage>[];
      final job = jobOf('exif_camera.jpg');
      final heard = <ImmersiveProgress>[];
      // As the queue of the app gives it: a callback no isolate takes (issue 23)
      final result = await engineWith(backend).run(job, cancel: NativeCancelFlag(), onProgress: appLikeCallback(heard));
      stages.addAll(heard.map((progress) => progress.stage));

      expect(result.isDone, isTrue, reason: result.message);
      expect(File('$_fixtures/exif_camera.jpg').readAsBytesSync(), original);
      final written = File(job.partPath).readAsBytesSync();
      final header = JpegHeader.read(written);
      // The pixels upright, the orientation 1: the photo shows the way it did
      expect(exifOrientation(header.exif), 1);
      final source = JpegHeader.read(original);
      expect(exifOrientation(source.exif), 6);
      final decoded = const DartSbsCodec().decodeJpeg(written);
      expect((decoded.width, decoded.height), (source.height, source.width));
      expect((backend.given!.width, backend.given!.height), (source.height, source.width));
      final kept = keptExif(header.exif);
      expect(kept.dateTimeOriginal, '2025:05:03 09:20:00');
      expect(kept.offsetTimeOriginal, '+02:00');
      expect(kept.latitude, closeTo(-33.8568, 1e-4));
      expect(kept.longitude, closeTo(-70.6483, 1e-4));
      expect(kept.altitude, closeTo(512.5, 1e-3));
      // No make nor model is carried over (a sphere is never guessed from a camera)
      expect(cameraExifOf(header.exif).make, isNull);

      final xmp = ImmersiveXmp.findIn(written);
      expect(xmp, isA<EnhancedPhotoXmp>());
      final packet = xmp! as EnhancedPhotoXmp;
      expect(packet.kind, ImmersiveKind.enhancedPhoto);
      expect(packet.level, 'Sharpen');
      expect(packet.strength, 100);
      expect(packet.model, 'Fake model');
      expect(packet.modelSha256, 'ab' * 32);
      expect((packet.width, packet.height), (decoded.width, decoded.height));
      expect(packet.origin, ImmersiveOrigin.generatedContent);
      expect(packet.digitalSourceType, iptcCompositeWithTrainedAlgorithmicMedia);
      expect(packet.creatorTool, 'Immuch360 Desktop 3.4.6 (windows)');
      expect(packet.description, startsWith('AI enhanced (Sharpen, 100 %)'));
      expect(packet.description, contains(enhancedHonesty));
      expect(packet.sourceName, 'exif_camera.jpg');
      expect(packet.sourceSha1, 'c2hhMQ==');
      expect(packet.derivativeId, job.derivativeId);

      expect(stages.toSet().toList(), ImmersiveStage.enhance);
      expect(result.details, isA<EnhanceResultDetails>());
      expect(Directory(backend.folder!).existsSync(), isFalse);
    },
  );

  test('keeps the colour profile its pixels are in', () async {
    final result = await engineWith(_FakeBackend()).run(jobOf('display_p3.jpg'), cancel: NativeCancelFlag());
    expect(result.isDone, isTrue, reason: result.message);
    final written = File(jobOf('display_p3.jpg').partPath).readAsBytesSync();
    expect(
      JpegHeader.read(written).iccProfile,
      JpegHeader.read(File('$_fixtures/display_p3.jpg').readAsBytesSync()).iccProfile,
    );
  });

  test('the strength blends with the photo: 0 gives the photo back, 50 half the change', () async {
    Future<int> meanRed(int strength) async {
      final job = jobOf('orientation_1.jpg', strength: strength);
      final result = await engineWith(_FakeBackend(add: 80)).run(job, cancel: NativeCancelFlag());
      expect(result.isDone, isTrue, reason: result.message);
      final decoded = const DartSbsCodec().decodeJpeg(File(job.partPath).readAsBytesSync());
      var sum = 0;
      for (var i = 0; i < decoded.rgba.length; i += 4) {
        sum += decoded.rgba[i];
      }
      return sum ~/ (decoded.width * decoded.height);
    }

    final photo = const DartSbsCodec().decodeJpeg(File('$_fixtures/orientation_1.jpg').readAsBytesSync());
    var sum = 0;
    for (var i = 0; i < photo.rgba.length; i += 4) {
      sum += photo.rgba[i];
    }
    final original = sum ~/ (photo.width * photo.height);
    expect(await meanRed(0), closeTo(original, 3));
    final full = await meanRed(100);
    final half = await meanRed(50);
    expect(half, closeTo((original + full) / 2, 4));
  });

  test('refuses to start with less memory free than the level needs, in words that say to close programs', () async {
    final result = await engineWith(
      _FakeBackend(),
      available: 1 << 30,
    ).run(jobOf('orientation_1.jpg', level: EnhanceLevel.rebuild), cancel: NativeCancelFlag());
    expect(result.error, ImmersiveErrorCode.outOfMemory);
    expect(result.message, startsWith(enhanceMemoryMessage));
  });

  test(
    'the refusal carries the memory available and the need of the photo, read as stable-diffusion.cpp does',
    () async {
      // The physical memory is there, the commit is not: sd-cli counts the least of the two (backend_fit.cpp)
      final result = await engineWith(
        _FakeBackend(),
        available: 8 << 30,
        commit: 2 << 30,
      ).run(jobOf('orientation_1.jpg', level: EnhanceLevel.rebuild), cancel: NativeCancelFlag());
      expect(result.error, ImmersiveErrorCode.outOfMemory);
      final figures = enhanceMemoryFiguresOf(result.message)!;
      expect(figures.available, 2 << 30);
      expect(figures.need, greaterThan(3 << 30));
      expect(enhanceMemoryFiguresOf('${enhanceMemoryRanShortMessage(26070320)}: [E] RAM graph'), (
        available: null,
        need: null,
        short: 26070320,
      ));
      expect(enhanceMemoryFiguresOf('enhance: the graphics card lacks the integer dot product'), isNull);
      expect(enhanceMemoryFiguresOf(enhanceMemoryMessage), isNull);
    },
  );

  test('tiles told with their phase: no time left while the models load, the backend\'s own once it has one', () async {
    final heard = <ImmersiveProgress>[];
    final tiling = <EnhanceTileProgress>[
      (phase: ImmersiveTilePhase.encode, tile: 1, tiles: 30, left: null),
      (phase: ImmersiveTilePhase.sample, tile: 2, tiles: 30, left: null),
      (phase: ImmersiveTilePhase.decode, tile: 2, tiles: 30, left: const Duration(seconds: 40)),
    ];
    final result = await engineWith(_FakeBackend(tiling: tiling)).run(
      jobOf('orientation_1.jpg', level: EnhanceLevel.rebuild),
      cancel: NativeCancelFlag(),
      onProgress: heard.add,
    );
    expect(result.isDone, isTrue, reason: result.message);
    final loading = heard.where((progress) => progress.stage == ImmersiveStage.loadingModels);
    expect(loading, isNotEmpty);
    expect(loading.every((progress) => progress.remaining == null), isTrue);
    final tiles = heard.where((progress) => progress.tilePhase != null).toList();
    expect(tiles.map((progress) => progress.tilePhase), [
      ImmersiveTilePhase.encode,
      ImmersiveTilePhase.sample,
      ImmersiveTilePhase.decode,
    ]);
    expect(tiles.map((progress) => progress.remaining), [null, null, const Duration(seconds: 40)]);
    expect(tiles.map((progress) => (progress.step, progress.steps)), [(1, 30), (2, 30), (2, 30)]);
    expect(tiles.map((progress) => progress.perMille), [80, 80 + 780 ~/ 3, 80 + 780 * 2 ~/ 3]);
  });

  test('a failure of the model, a cancel and an unreadable photo end the job without a file', () async {
    final failed = await engineWith(
      _FakeBackend(failure: const BackendException(ImmersiveErrorCode.gpuUnavailable, enhanceNoIntDotMessage)),
    ).run(jobOf('orientation_1.jpg', level: EnhanceLevel.rebuild), cancel: NativeCancelFlag());
    expect(failed.error, ImmersiveErrorCode.gpuUnavailable);
    expect(failed.message, enhanceNoIntDotMessage);

    final cancel = NativeCancelFlag();
    final cancelled = await engineWith(_FakeBackend(cancelAt: cancel)).run(jobOf('orientation_1.jpg'), cancel: cancel);
    expect(cancelled.error, ImmersiveErrorCode.cancelled);
    expect(File(jobOf('orientation_1.jpg').partPath).existsSync(), isFalse);

    final broken = File(p.join(temp.path, 'broken.jpg'))..writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xDB, 0, 1, 2]);
    final job = EnhanceJob(
      id: 'conversion-2',
      source: ImmersiveSource(name: 'broken.jpg', size: 7, sha1: '', path: broken.path),
      partPath: p.join(temp.path, '.broken.part'),
      derivativeId: 'urn:uuid:2',
      creatorTool: 'tool',
      created: 'now',
      level: EnhanceLevel.sharpen,
      strength: 60,
    );
    final unreadable = await EnhanceEngine(
      backend: _FakeBackend(),
      workFolder: (id) => Directory(p.join(temp.path, 'work-$id'))..createSync(),
      codecs: SbsCodecChoice.dart,
      memory: const _Memory(8 << 30),
      decodeOther: (bytes) async => throw const SbsCodecException('not a picture'),
    ).run(job, cancel: NativeCancelFlag());
    expect(unreadable.error, anyOf(ImmersiveErrorCode.decodeFailed, ImmersiveErrorCode.unsupportedFormat));
  });

  test('the packet reads back as it was written', () {
    final packet = EnhancedPhotoXmp.enhanced(
      level: EnhanceLevel.natural.xmp,
      levelName: enhanceLevelWords(EnhanceLevel.natural),
      strength: 100,
      model: 'VOSR 2.0 1.4B int8',
      modelSha256: 'cd' * 32,
      width: 4000,
      height: 3000,
      sourceName: 'Lyon & "Fourvière".jpg',
      sourceSize: 1234,
      sourceSha1: 'c2hhMQ==',
      created: '2026-11-23T15:00:00+01:00',
      creatorTool: 'Immuch360 Desktop',
    );
    final read = EnhancedPhotoXmp.parse(packet.toXml());
    expect(read, packet);
    expect(read!.settingsKey, '${'cd' * 32}|enhance-v1|Natural|100');
    expect(EnhanceLevel.fromXmp(read.level), EnhanceLevel.natural);
    expect(ImmersiveXmp.parse(packet.toXml()), isA<EnhancedPhotoXmp>());
  });

  test('the name of the version: name_enhanced.jpg, a JPEG whatever the original', () {
    expect(derivedFileNameFor(ImmersiveKind.enhancedPhoto, 'salon.jpg'), 'salon_enhanced.jpg');
    expect(derivedFileNameFor(ImmersiveKind.enhancedPhoto, 'IMG_0001.HEIC'), 'IMG_0001_enhanced.jpg');
    expect(derivedFileNameFor(ImmersiveKind.enhancedPhoto, 'scan.png'), 'scan_enhanced.jpg');
  });
}
