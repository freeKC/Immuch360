// The photos of a splat scene made ready for COLMAP (lot SP5, splat_inputs.dart): at most 200, spread evenly in time;
// each read then released before the next one is read; turned upright by its EXIF, reduced to 1 600 pixels, written
// as a JPEG with its camera and a focal length COLMAP reads right (the focal plane resolution scaled with the photo);
// one folder per camera and size; the unreadable, the 360° and the blurred ones left out with their reason; fewer than
// 20 usable ones make no scene; a cancel ends it.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// Pure Dart, already in the lock through maplibre_gl
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/codec/exif_minimal.dart';
import 'package:immich_mobile/desktop/ai/codec/jpeg_segments.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_inputs.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:path/path.dart' as p;

import 'splat_input_support.dart';

/// A member whose bytes are given, which tells when it is read and released
class _Member implements SplatMember {
  _Member(this.name, this.bytes, {this.taken, this.log, this.failure});

  @override
  final String name;
  final Uint8List? bytes;
  final List<String>? log;
  final ConversionException? failure;

  @override
  final DateTime? taken;

  @override
  String? get camera => null;

  @override
  Future<ImmersiveSource> load(NativeCancelFlag cancel) async {
    log?.add('load $name');
    if (failure != null) {
      throw failure!;
    }
    return ImmersiveSource(name: name, size: bytes!.length, sha1: 'sha1', bytes: bytes);
  }

  @override
  Future<void> release() async {
    log?.add('release $name');
  }
}

/// Twenty-four photos of a walk, 320 x 240, one camera
List<_Member> _walk(int count, {Set<int> blurred = const {}, List<String>? log, TestCamera? camera}) => [
  for (var step = 0; step < count; step++)
    _Member(
      'IMG_${1000 + step}.JPG',
      testJpeg(
        texturedRgba(320, 240, shift: step * 5, blur: blurred.contains(step) ? 2 : 0),
        320,
        240,
        camera: camera,
      ),
      taken: DateTime(2026, 11, 1, 12).add(Duration(seconds: step)),
      log: log,
    ),
];

void main() {
  late Directory work;
  late NativeCancelFlag cancel;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('immuch360_splat_inputs_');
    cancel = NativeCancelFlag();
  });

  tearDown(() async {
    cancel.free();
    await work.delete(recursive: true);
  });

  String images() => p.join(work.path, 'images');

  group('the plan', () {
    test('takes every photo up to 200, in the order of time, those without a date after by name', () {
      final members = [
        _Member('c.jpg', null, taken: DateTime(2026, 5, 3)),
        _Member('z.jpg', null),
        _Member('a.jpg', null, taken: DateTime(2026, 5, 1)),
        _Member('b.jpg', null),
        _Member('d.jpg', null, taken: DateTime(2026, 5, 2)),
      ];
      final plan = planSplatPhotos(members);
      expect(plan.taken.map((member) => member.name), ['a.jpg', 'd.jpg', 'c.jpg', 'b.jpg', 'z.jpg']);
      expect(plan.total, 5);
      expect(plan.isCapped, isFalse);
    });

    test('takes 200 of 512 spread evenly in time, the first and the last among them', () {
      final start = DateTime(2026, 11, 1);
      final members = [
        for (var i = 511; i >= 0; i--) _Member('P$i.jpg', null, taken: start.add(Duration(seconds: i * 3))),
      ];
      final plan = planSplatPhotos(members);
      expect(plan.taken, hasLength(SplatV1.maxPhotos));
      expect(plan.total, 512);
      expect(plan.isCapped, isTrue);
      final indexes = [for (final member in plan.taken) int.parse(member.name.substring(1, member.name.length - 4))];
      expect(indexes.first, 0);
      expect(indexes.last, 511);
      final gaps = {for (var i = 1; i < indexes.length; i++) indexes[i] - indexes[i - 1]};
      expect(gaps, {2, 3}, reason: '511 / 199 = 2.57: the photos taken stay evenly apart');
    });
  });

  group('the halving before the reduction', () {
    test('averages 2 x 2 pixels, rounded half up, while the result stays as large as asked', () {
      final rgba = Uint8List.fromList([
        // Row 0: four pixels
        0, 0, 0, 255, 10, 20, 30, 255, 100, 100, 100, 255, 101, 101, 101, 255,
        // Row 1
        1, 2, 3, 255, 11, 22, 33, 255, 103, 103, 103, 255, 103, 103, 103, 255,
      ]);
      final halved = halvedTo(SbsDecoded(width: 4, height: 2, rgba: rgba), 2);
      expect((halved.width, halved.height), (2, 1));
      // (0 + 10 + 1 + 11 + 2) / 4 = 6; (0 + 20 + 2 + 22 + 2) / 4 = 11; (0 + 30 + 3 + 33 + 2) / 4 = 17
      // (100 + 101 + 103 + 103 + 2) / 4 = 102
      expect(halved.rgba, [6, 11, 17, 255, 102, 102, 102, 255]);
    });

    test('a photo of 12 Mpx is halved once, one twice as large as asked to the size asked, a small one kept', () {
      SbsDecoded blank(int width, int height) =>
          SbsDecoded(width: width, height: height, rgba: Uint8List(width * height * 4));
      final skull = halvedTo(blank(4272, 2848), 1600);
      expect((skull.width, skull.height), (2136, 1424));
      final twice = halvedTo(blank(3200, 1800), 1600);
      expect((twice.width, twice.height), (1600, 900));
      final small = blank(3000, 2000);
      expect(identical(halvedTo(small, 1600), small), isTrue);
    });
  });

  group('the preparation', () {
    test('reads each photo then releases it before the next one is read, and counts them', () async {
      final log = <String>[];
      final progress = <(int, int)>[];
      final members = _walk(22, log: log);
      final inputs = await prepareSplatPhotos(
        members,
        imagesFolder: images(),
        cancel: cancel,
        onProgress: (done, total) => progress.add((done, total)),
      );
      expect(log, [
        for (final member in members) ...['load ${member.name}', 'release ${member.name}'],
      ]);
      expect(progress.map((step) => step.$2).toSet(), {22});
      expect(progress.map((step) => step.$1), [for (var i = 1; i <= 22; i++) i]);
      expect(inputs.images, hasLength(22));
      expect(inputs.total, 22);
      expect(inputs.isEnough, isTrue);
      expect(inputs.leftOut, isEmpty);
    });

    test('turns each photo upright, reduces it to 1 600 pixels and keeps its focal length for COLMAP', () async {
      const camera = TestCamera(
        make: 'Canon',
        model: 'Canon EOS REBEL T3',
        focalLength: (55, 1),
        focalPlaneXResolution: (4272000, 866),
        focalPlaneResolutionUnit: 2,
      );
      // Stored 2400 x 1800, to be turned a quarter clockwise (orientation 6): upright 1800 x 2400. Its bottom band is
      // red: once upright, the band is on the left
      final stored = texturedRgba(2400, 1800);
      for (var at = 1500 * 2400 * 4; at < stored.length; at += 4) {
        stored
          ..[at] = 230
          ..[at + 1] = 10
          ..[at + 2] = 10;
      }
      final members = [
        for (var step = 0; step < 20; step++)
          _Member(
            'IMG_$step.JPG',
            step == 0 ? testJpeg(stored, 2400, 1800, orientation: 6, camera: camera) : null,
            taken: DateTime(2026, 11, 1).add(Duration(seconds: step)),
          ),
      ];
      final small = _walk(19, camera: camera);
      final inputs = await prepareSplatPhotos([members.first, ...small], imagesFolder: images(), cancel: cancel);
      final first = inputs.images.first;
      expect((first.width, first.height), (1200, 1600));
      expect(first.source, 'IMG_0.JPG');
      final jpeg = File(p.join(images(), first.relativePath)).readAsBytesSync();
      final header = JpegHeader.read(jpeg);
      expect((header.width, header.height), (1200, 1600), reason: 'the pixels themselves upright');
      expect(exifOrientation(header.exif), 1);
      final written = cameraExifOf(header.exif);
      expect(written.make, 'Canon');
      expect(written.model, 'Canon EOS REBEL T3');
      expect(written.focalLength, (55, 1));
      expect(written.focalPlaneResolutionUnit, 2);
      // 4932.9 pixels an inch on the sensor of 2400 pixels; 1600 / 2400 of it once reduced
      final resolution = written.focalPlaneXResolution!;
      expect(resolution.$1 / resolution.$2, closeTo(4272000 / 866 * 1600 / 2400, 0.01));
      final decoded = img.decodeJpg(jpeg)!;
      final left = decoded.getPixel(60, 800);
      final right = decoded.getPixel(1100, 800);
      expect(left.r, greaterThan(190), reason: 'the red band on the left');
      expect(left.g, lessThan(60));
      expect(left.b, lessThan(60));
      expect(right.r < 190 || right.g >= 60, isTrue, reason: 'the texture on the right');
      // The large photo and the small ones are two cameras for COLMAP: same lens, other sizes
      expect(inputs.images.map((image) => image.folder).toSet(), {'cam1', 'cam2'});
      expect(inputs.cameras, {'cam1': 'Canon EOS REBEL T3 55 mm', 'cam2': 'Canon EOS REBEL T3 55 mm'});
      expect(inputs.images.where((image) => image.folder == 'cam2'), hasLength(19));
    });

    test('numbers the images in the order of time across the folders of two cameras', () async {
      const phone = TestCamera(make: 'samsung', model: 'SM-S926B', focalLength: (630, 100), focalLength35mm: 23);
      const wide = TestCamera(make: 'samsung', model: 'SM-S926B', focalLength: (220, 100), focalLength35mm: 13);
      final members = [
        for (var step = 0; step < 24; step++)
          _Member(
            'S$step.jpg',
            testJpeg(texturedRgba(320, 240, shift: step * 5), 320, 240, camera: step.isEven ? phone : wide),
            taken: DateTime(2026, 11, 1).add(Duration(seconds: step)),
          ),
      ];
      final inputs = await prepareSplatPhotos(members, imagesFolder: images(), cancel: cancel);
      expect(inputs.images.map((image) => image.name), [for (var i = 0; i < 24; i++) splatImageName(i)]);
      expect(inputs.images.map((image) => image.folder), [for (var i = 0; i < 24; i++) i.isEven ? 'cam1' : 'cam2']);
      expect(inputs.cameras, {'cam1': 'samsung SM-S926B 6.3 mm', 'cam2': 'samsung SM-S926B 2.2 mm'});
      final files = Directory(images()).listSync(recursive: true).whereType<File>().map((file) => file.path);
      expect(files, hasLength(24));
      expect(files.where((path) => path.contains('.staging')), isEmpty);
      final written = cameraExifOf(JpegHeader.read(File(p.join(images(), 'cam2', '00002.jpg')).readAsBytesSync()).exif);
      expect(written.focalLength35mm, 13);
    });

    test('leaves out the blurred, the unreadable and the 360° photos with their reason', () async {
      final members = <SplatMember>[
        ..._walk(24, blurred: {5, 17}),
        _Member('lost.jpg', null, failure: const ConversionException(ImmersiveErrorCode.sourceLost, 'gone')),
        _Member('broken.jpg', Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 4, 1, 2])),
        _Member('heic.heic', Uint8List.fromList([0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63])),
        _Member(
          'pano.jpg',
          testJpeg(
            texturedRgba(400, 200),
            400,
            200,
            camera: const TestCamera(make: 'Arashi Vision', model: 'X4'),
          ),
        ),
      ];
      final inputs = await prepareSplatPhotos(
        members,
        imagesFolder: images(),
        cancel: cancel,
        decodeOther: (bytes, {maxWidth}) async => throw const SbsCodecException('no HEIC decoder here'),
      );
      final reasons = {for (final out in inputs.leftOut) out.name: out.reason};
      expect(reasons, {
        'IMG_1005.JPG': SplatLeftOutReason.blurred,
        'IMG_1017.JPG': SplatLeftOutReason.blurred,
        'lost.jpg': SplatLeftOutReason.unreadable,
        'broken.jpg': SplatLeftOutReason.unreadable,
        'heic.heic': SplatLeftOutReason.unreadable,
        'pano.jpg': SplatLeftOutReason.sphere,
      });
      expect(inputs.blurred, 2);
      expect(inputs.total, 28);
      expect(inputs.images, hasLength(22));
      expect(inputs.images.map((image) => image.source), isNot(contains('IMG_1005.JPG')));
      final files = Directory(images()).listSync(recursive: true).whereType<File>();
      expect(files, hasLength(22));
    });

    test('a photo the JPEG codec does not read is decoded by the engine, already upright', () async {
      final members = [
        ..._walk(19),
        _Member('scan.png', Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 8)))),
      ];
      final inputs = await prepareSplatPhotos(
        members,
        imagesFolder: images(),
        cancel: cancel,
        decodeOther: (bytes, {maxWidth}) async => SbsDecoded(width: 2000, height: 3000, rgba: texturedRgba(2000, 3000)),
      );
      final scan = inputs.images.singleWhere((image) => image.source == 'scan.png');
      expect((scan.width, scan.height), (1067, 1600));
      expect(inputs.images, hasLength(20));
    });

    test('fewer than 20 usable photos make no scene: the counts say why', () async {
      final inputs = await prepareSplatPhotos(
        _walk(21, blurred: {4, 12}),
        imagesFolder: images(),
        cancel: cancel,
      );
      expect(inputs.images, hasLength(19));
      expect(inputs.isEnough, isFalse);
      expect(inputs.countsMessage, '19/21');
      expect(splatCountsOf(inputs.countsMessage), (19, 21));
    });

    test('a cancel ends it, a disk full is said as such, a member that fails otherwise ends it', () async {
      final members = _walk(30);
      var seen = 0;
      await expectLater(
        prepareSplatPhotos(
          members,
          imagesFolder: images(),
          cancel: cancel,
          onProgress: (done, total) {
            if (++seen == 3) {
              cancel.cancel();
            }
          },
        ),
        throwsA(isA<ConversionException>().having((error) => error.code, 'code', ImmersiveErrorCode.cancelled)),
      );

      final full = NativeCancelFlag();
      addTearDown(full.free);
      await expectLater(
        prepareSplatPhotos(
          [..._walk(3), _Member('server.jpg', null, failure: const ConversionException(ImmersiveErrorCode.diskFull))],
          imagesFolder: images(),
          cancel: full,
        ),
        throwsA(isA<ConversionException>().having((error) => error.code, 'code', ImmersiveErrorCode.diskFull)),
      );
    });
  });
}
