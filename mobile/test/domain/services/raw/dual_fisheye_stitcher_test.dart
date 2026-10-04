import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/raw/dual_fisheye_calibration.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_math.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_stitcher.dart';
import 'package:immich_mobile/domain/services/raw/insta360_trailer.dart';

import '../../../fixtures/raw/dual_fisheye_frames.dart';
import '../../../fixtures/raw/insta360.stub.dart';

// The accelerometer of the MakerNote of the real X3 photo whose calibration the fixtures hold: the camera leans by
// about 9 degrees
const _x3Accelerometer = [-1.003906, -0.124023, 0.082031];

/// The calibration of the real X3 photo, levelled by its accelerometer
DualFisheyeCalibration _x3() =>
    parseInsta360OffsetV3(x3OffsetV3)!.copyWith(downBody: downBodyFromAccelerometer(_x3Accelerometer));

// Squares of the synthetic frames: 1024 x 512 frames, the size of the proxy of an X3 video
const _square = 512;

Future<Uint8List> _pixels(ui.Image image) async =>
    (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();

void main() {
  group('dualFisheyeOutputSize', () {
    test('is as wide as the frame, at most 8192, and half as high', () {
      expect(dualFisheyeOutputSize(2880), (width: 2880, height: 1440));
      expect(dualFisheyeOutputSize(11968), (width: 8192, height: 4096));
      expect(dualFisheyeOutputSize(8191), (width: 8190, height: 4095));
      expect(dualFisheyeOutputSize(11968, maxWidth: 1024), (width: 1024, height: 512));
      expect(dualFisheyeOutputSize(1), (width: 2, height: 1));
    });
  });

  group('dualFisheyeShaderUniforms', () {
    test('give the sizes, the scale, the rotations and the intrinsics of both lenses', () {
      final calibration = _x3();
      final uniforms = dualFisheyeShaderUniforms(
        calibration,
        frameWidth: 11968,
        frameHeight: 5984,
        outputWidth: 8192,
        outputHeight: 4096,
      );

      expect(uniforms.values, everyElement(hasLength(4)));
      expect(uniforms['uSizes'], [8192, 4096, 11968, 5984]);
      expect(uniforms['uParams']![0], closeTo(5984 / 5952, 1e-12));
      expect(uniforms['uParams']![1], 0);
      final g = bodyFrame(calibration.downBody);
      final r1 = lensPose(calibration.lenses[1], 1);
      for (var row = 0; row < 3; row++) {
        expect(uniforms['uG$row'], [g.at(row, 0), g.at(row, 1), g.at(row, 2), 0]);
        expect(uniforms['uR1$row'], [r1.at(row, 0), r1.at(row, 1), r1.at(row, 2), 0]);
      }
      final lens0 = calibration.lenses[0];
      expect(uniforms['uLens0Mei'], [lens0.xi, lens0.fx, lens0.fy, 0]);
      expect(uniforms['uLens0Centre'], [lens0.cx, lens0.cy, lens0.p1, lens0.p2]);
      expect(uniforms['uLens0K'], [lens0.k1, lens0.k2, lens0.k3, 0]);
      expect(uniforms['uLens1K']![3], 1);
    });

    test('flag the equidistant model and give its radius', () {
      final calibration = parseInsta360OffsetV1(x3OffsetV1)!;
      final uniforms = dualFisheyeShaderUniforms(
        calibration,
        frameWidth: 1024,
        frameHeight: 512,
        outputWidth: 1024,
        outputHeight: 512,
      );

      expect(uniforms['uParams']![1], 1);
      expect(uniforms['uLens1Mei'], [0, 0, 0, calibration.lenses[1].radius]);
    });

    test('refuse a calibration without two lenses', () {
      final calibration = _x3().copyWith(lenses: [_x3().lenses.first]);

      expect(
        () => dualFisheyeShaderUniforms(calibration, frameWidth: 2, frameHeight: 1, outputWidth: 2, outputHeight: 1),
        throwsArgumentError,
      );
    });
  });

  group('stitchDualFisheyeRgba', () {
    // A synthetic X3 frame of the pattern, made by inverse mapping: stitched back, it must give the pattern
    final calibration = _x3();
    final frame = patternDualFisheye(calibration, _square);

    test('gives back the pattern a dual fisheye frame was drawn from', () {
      const width = 512;
      const height = 256;
      final stitched = stitchDualFisheyeRgba(
        frame,
        frameWidth: 2 * _square,
        frameHeight: _square,
        calibration: calibration,
        width: width,
        height: height,
      );

      expect(stitched, hasLength(width * height * 4));
      // About 0.3 levels of 255: what bilinear sampling of the frame costs
      expect(meanPatternError(stitched, width, height), lessThan(1));
      expect(meanDifference(stitched, patternEquirect(width, height)), lessThan(1));
    });

    test('shows the error of a wrong calibration: unlevelled, or nominal', () {
      const width = 256;
      const height = 128;
      double errorWith(DualFisheyeCalibration wrong) => meanPatternError(
        stitchDualFisheyeRgba(
          frame,
          frameWidth: 2 * _square,
          frameHeight: _square,
          calibration: wrong,
          width: width,
          height: height,
        ),
        width,
        height,
      );

      // About 0.3 levels right, 15 with either mistake: the pattern tells a stitch off by a degree or a few pixels
      final right = errorWith(calibration);
      expect(right, lessThan(1));
      expect(errorWith(calibration.copyWith(downBody: const [1, 0, 0])), greaterThan(10 * right));
      expect(errorWith(nominalX3(_square)), greaterThan(10 * right));
    });

    test('gives back the pattern drawn with an equidistant (V1) calibration', () {
      final v1 = parseInsta360OffsetV1(x3OffsetV1)!.copyWith(downBody: downBodyFromAccelerometer(_x3Accelerometer));
      const width = 256;
      const height = 128;
      final stitched = stitchDualFisheyeRgba(
        patternDualFisheye(v1, _square),
        frameWidth: 2 * _square,
        frameHeight: _square,
        calibration: v1,
        width: width,
        height: height,
      );

      expect(meanPatternError(stitched, width, height), lessThan(2.5));
    });

    test('is black where no lens sees and opaque everywhere', () {
      // Lenses whose image circle is a point: nothing lands inside their squares but the centres
      final blind = nominalX3(_square).copyWith(
        lenses: [
          for (var i = 0; i < 2; i++)
            const DualFisheyeLens(cx: -1000, cy: -1000, yaw: 0, pitch: 0, roll: 90, xi: 1.9, fx: 1, fy: 1),
        ],
      );
      final stitched = stitchDualFisheyeRgba(
        frame,
        frameWidth: 2 * _square,
        frameHeight: _square,
        calibration: blind,
        width: 8,
        height: 4,
      );

      expect(stitched, [
        for (var i = 0; i < 32; i++) ...[0, 0, 0, 255],
      ]);
    });
  });

  group('encodeOpaquePng', () {
    test('writes a PNG that decodes to the same pixels, without the alpha', () async {
      const width = 37;
      const height = 11;
      final rgba = Uint8List(width * height * 4);
      for (var i = 0; i < width * height; i++) {
        rgba
          ..[i * 4] = i % 256
          ..[i * 4 + 1] = (i * 7) % 256
          ..[i * 4 + 2] = 255 - i % 256
          ..[i * 4 + 3] = 17;
      }

      final png = encodeOpaquePng(rgba, width, height);
      expect(png.sublist(0, 8), [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
      final codec = await ui.instantiateImageCodec(png);
      final image = (await codec.getNextFrame()).image;
      final decoded = await _pixels(image);
      image.dispose();
      codec.dispose();

      expect(decoded, [
        for (var i = 0; i < width * height; i++) ...[rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2], 255],
      ]);
    });
  });

  group('StitchedPhotoFiles', () {
    late Directory directory;
    late StitchedPhotoFiles files;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('raw360_test');
      files = StitchedPhotoFiles(() async => directory, keep: 2);
    });

    tearDown(() => directory.deleteSync(recursive: true));

    test('names a picture after a hash of its key, in the cache directory', () async {
      final name = StitchedPhotoFiles.fileNameFor('remote-id:1700000000000:file');

      expect(name, matches(RegExp(r'^stitched_[0-9a-f]{24}\.png$')));
      expect(StitchedPhotoFiles.fileNameFor('remote-id:1700000000000:file'), name);
      expect(StitchedPhotoFiles.fileNameFor('remote-id:1700000000000:nominal'), isNot(name));
      expect((await files.fileFor('remote-id:1700000000000:file')).path, '${directory.path}/$name');
      expect(StitchedPhotoFiles.folderName, 'raw360');
    });

    test('writes a picture whole, finds it again, and keeps the newest ones only', () async {
      expect(await files.existing('a'), isNull);

      final a = await files.write('a', Uint8List.fromList([1, 2, 3]));
      expect(a.readAsBytesSync(), [1, 2, 3]);
      expect((await files.existing('a'))?.path, a.path);
      a.setLastModifiedSync(DateTime(2020));
      final b = await files.write('b', Uint8List.fromList([4]));
      b.setLastModifiedSync(DateTime(2021));
      // Left by a write cut short, long ago
      File('${directory.path}/stitched_cut.png.1-0.tmp')
        ..writeAsBytesSync([0])
        ..setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 1)));
      final c = await files.write('c', Uint8List.fromList([5]));

      final left = directory.listSync().map((entry) => entry.path).toSet();
      expect(left, {b.path, c.path});
      expect(await files.existing('a'), isNull);
    });

    test('keeps a picture used again over newer ones', () async {
      final a = await files.write('a', Uint8List.fromList([1]));
      a.setLastModifiedSync(DateTime(2020));
      final b = await files.write('b', Uint8List.fromList([2]));
      b.setLastModifiedSync(DateTime(2021));
      // Used again: newest of all
      await files.existing('a');
      final c = await files.write('c', Uint8List.fromList([3]));

      expect(directory.listSync().map((entry) => entry.path).toSet(), {a.path, c.path});
    });

    test('keeps the young partial files, which another write may still be writing', () async {
      final young = File('${directory.path}/stitched_young.png.1-0.tmp')..writeAsBytesSync([0]);
      final old = File('${directory.path}/stitched_old.png.1-1.tmp')
        ..writeAsBytesSync([0])
        ..setLastModifiedSync(DateTime.now().subtract(const Duration(minutes: 6)));

      final a = await files.write('a', Uint8List.fromList([1]));

      expect(directory.listSync().map((entry) => entry.path).toSet(), {a.path, young.path});
      expect(old.existsSync(), isFalse, reason: 'left by a write cut short');
    });

    test('stitches a picture once for all the calls that come while it is being stitched', () async {
      final png = Completer<Uint8List>();
      var stitches = 0;
      Future<Uint8List> stitch() {
        stitches++;
        return png.future;
      }

      final first = files.obtain('a', stitch);
      final second = files.obtain('a', stitch);
      // Another opening of the viewer, with files of its own on the same directory
      final third = StitchedPhotoFiles(() async => directory).obtain('a', stitch);
      await pumpEventQueue();
      expect(stitches, 1);
      png.complete(Uint8List.fromList([1, 2, 3]));
      final obtained = await Future.wait([first, second, third]);

      final file = await files.fileFor('a');
      expect(obtained.map((file) => file.path), everyElement(file.path));
      expect(file.readAsBytesSync(), [1, 2, 3]);
      expect(directory.listSync().map((entry) => entry.path), [file.path], reason: 'no partial file left');
      expect(stitches, 1);
    });

    test('stitches anew at the next call once a stitch failed', () async {
      final failure = Completer<Uint8List>();
      final failed = files.obtain('a', () => failure.future);
      final waiting = files.obtain('a', () async => Uint8List.fromList([9]));
      await pumpEventQueue();
      failure.completeError(StateError('the GPU is gone'));
      await Future.wait([expectLater(failed, throwsStateError), expectLater(waiting, throwsStateError)]);

      final file = await files.obtain('a', () async => Uint8List.fromList([1]));

      expect(file.readAsBytesSync(), [1]);
      expect(directory.listSync().map((entry) => entry.path), [file.path]);
    });

    test('writes the same picture twice at once, each write from a partial file of its own', () async {
      final big = Uint8List(8 << 20);
      final written = await Future.wait([files.write('a', big), files.write('a', Uint8List.fromList(big))]);

      expect(written[1].path, written[0].path);
      expect(written[0].lengthSync(), big.length);
      expect(directory.listSync().map((entry) => entry.path), [written[0].path], reason: 'no partial file left');
    });
  });

  group('DualFisheyeStitcher', () {
    testWidgets('stitches on the GPU what the pure Dart math stitches', (tester) async {
      await tester.runAsync(() async {
        final calibration = _x3();
        final frame = patternDualFisheye(calibration, _square);
        final source = await imageFromRgba(frame, 2 * _square, _square);
        final stitcher = await DualFisheyeStitcher.load();

        final stitched = await stitcher.stitch(source, calibration, maxWidth: 512);
        expect((stitched.width, stitched.height), (512, 256));
        final gpu = await _pixels(stitched);
        final cpu = stitchDualFisheyeRgba(
          frame,
          frameWidth: 2 * _square,
          frameHeight: _square,
          calibration: calibration,
          width: 512,
          height: 256,
        );
        stitched.dispose();
        source.dispose();

        // About 0.02 levels apart: single against double precision
        expect(meanDifference(gpu, cpu), lessThan(0.5));
        expect(meanPatternError(gpu, 512, 256), lessThan(1));
      });
    });

    testWidgets('falls back on the pure Dart math when asked a CPU stitch', (tester) async {
      await tester.runAsync(() async {
        final calibration = _x3();
        final source = await imageFromRgba(patternDualFisheye(calibration, _square), 2 * _square, _square);

        final stitched = await stitchDualFisheyeOnCpu(source, calibration, width: 256);
        expect((stitched.width, stitched.height), (256, 128));
        expect(meanPatternError(await _pixels(stitched), 256, 128), lessThan(2.5));
        stitched.dispose();
        source.dispose();
      });
    });

    testWidgets('writes the stitched picture of a photo as a PNG, once, however many ask for it', (tester) async {
      await tester.runAsync(() async {
        final directory = Directory.systemTemp.createTempSync('raw360_stitch');
        addTearDown(() => directory.deleteSync(recursive: true));
        final files = StitchedPhotoFiles(() async => directory);
        final calibration = _x3();
        final frame = patternDualFisheye(calibration, _square);
        var loads = 0;
        Future<ui.Image> load() {
          loads++;
          return imageFromRgba(frame, 2 * _square, _square);
        }

        // Twice at once, as the viewer may ask again while the stitch runs, then once more when done
        final [file, meanwhile] = await Future.wait([
          stitchedPhotoFile(files, 'photo', calibration, load, maxWidth: 512),
          stitchedPhotoFile(files, 'photo', calibration, load, maxWidth: 512),
        ]);
        final again = await stitchedPhotoFile(files, 'photo', calibration, load, maxWidth: 512);

        expect(meanwhile.path, file.path);
        expect(again.path, file.path);
        expect(loads, 1);
        expect(directory.listSync().map((entry) => entry.path), [file.path]);
        final codec = await ui.instantiateImageCodec(file.readAsBytesSync());
        final image = (await codec.getNextFrame()).image;
        expect((image.width, image.height), (512, 256));
        expect(meanPatternError(await _pixels(image), 512, 256), lessThan(2.5));
        image.dispose();
        codec.dispose();
      });
    });
  });

  test('the pattern is smooth enough for bilinear sampling and sharp enough to show a pixel off', () {
    // One pixel of a 512 pixel square is about 0.4 degrees: the pattern moves by a few levels for that
    final a = patternColour(viewDirection(0, 0));
    final b = patternColour(viewDirection(0.4 * math.pi / 180, 0));
    final change = [for (var c = 0; c < 3; c++) (a[c] - b[c]).abs()].reduce(math.max);
    expect(change, inInclusiveRange(0.5, 5));
  });
}
