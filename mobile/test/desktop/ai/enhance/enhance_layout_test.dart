// "Enhance (AI)" on 360° photos and 3D photos (release 53): the pieces the model is given, the seam of the sphere, its
// poles, the two eyes, the GPano tags kept, and the engine writing them.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/codec/dart_sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_chain.dart' show SbsCodecChoice;
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_engine.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_layout.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_levels.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_plan.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/desktop/ai/scene/scene_textures.dart' show encodeScenePicture;
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:path/path.dart' as p;

/// A picture of [width] x [height] whose colour of each pixel comes from [colour]
Uint8List _picture(int width, int height, List<int> Function(int x, int y) colour) {
  final rgba = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final c = colour(x, y);
      final at = 4 * (y * width + x);
      rgba
        ..[at] = c[0]
        ..[at + 1] = c[1]
        ..[at + 2] = c[2]
        ..[at + 3] = 255;
    }
  }
  return rgba;
}

/// A picture of the sphere whose colour is a smooth function of the direction of each pixel
Uint8List _sphere(int width, int height) => _picture(width, height, (x, y) {
  final longitude = (x + 0.5) / width * 2 * math.pi - math.pi;
  final latitude = math.pi / 2 - (y + 0.5) / height * math.pi;
  final dx = math.cos(latitude) * math.sin(longitude);
  final dy = math.sin(latitude);
  final dz = math.cos(latitude) * math.cos(longitude);
  return [(128 + 100 * dx).round(), (128 + 100 * dy).round(), (128 + 100 * dz).round()];
});

/// A blur of [rgba] along its rows, [1 2 1] / 4, the edges repeated: a model whose result depends on the neighbours
Uint8List _rowBlur(Uint8List rgba, int width, int height) {
  final out = Uint8List.fromList(rgba);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      for (var c = 0; c < 3; c++) {
        int at(int column) => rgba[4 * (y * width + column.clamp(0, width - 1)) + c];
        out[4 * (y * width + x) + c] = ((at(x - 1) + 2 * at(x) + at(x + 1)) / 4).round();
      }
    }
  }
  return out;
}

/// The same blur, the rows going round (what a model that saw across the seam gives)
Uint8List _rowBlurRound(Uint8List rgba, int width, int height) {
  final out = Uint8List.fromList(rgba);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      for (var c = 0; c < 3; c++) {
        int at(int column) => rgba[4 * (y * width + column % width) + c];
        out[4 * (y * width + x) + c] = ((at(x - 1) + 2 * at(x) + at(x + 1)) / 4).round();
      }
    }
  }
  return out;
}

int _maxDifference(Uint8List a, Uint8List b, {int fromRow = 0, int? toRow, required int width}) {
  final last = toRow ?? a.length ~/ (4 * width);
  var most = 0;
  for (var i = 4 * fromRow * width; i < 4 * last * width; i++) {
    if (i % 4 == 3) {
      continue;
    }
    most = math.max(most, (a[i] - b[i]).abs());
  }
  return most;
}

/// A model of the test: what it is given, each piece with its seed
class _Model {
  _Model(this.change);

  final Uint8List Function(SbsDecoded piece) change;
  final pieces = <({int width, int height})>[];

  Future<Uint8List> run(SbsDecoded piece, void Function(int done, int all) onStep) async {
    pieces.add((width: piece.width, height: piece.height));
    onStep(1, 2);
    onStep(2, 2);
    return change(piece);
  }
}

class _Memory implements MemoryProbe {
  const _Memory();

  @override
  MemoryFacts read() => const MemoryFacts(physical: 16 << 30, available: 8 << 30);
}

/// The backend of the engine: a model of the test, the seeds it was given
class _Backend implements EnhanceBackend {
  _Backend(this.change);

  final Uint8List Function(SbsDecoded piece) change;
  final given = <SbsDecoded>[];
  final seeds = <int>[];
  final folders = <String>[];

  @override
  String get model => 'Fake model';

  @override
  String get modelSha256 => 'ab' * 32;

  @override
  bool get fellBack => false;

  @override
  Future<Uint8List> enhance(
    SbsDecoded picture, {
    required String workFolder,
    required int seed,
    required NativeCancelFlag cancel,
    required void Function(int done, int all) onStep,
  }) async {
    expect(Directory(workFolder).existsSync(), isTrue);
    given.add(picture);
    seeds.add(seed);
    folders.add(workFolder);
    onStep(1, 1);
    return change(picture);
  }
}

Uint8List _plus(SbsDecoded piece, int add) {
  final out = Uint8List.fromList(piece.rgba);
  for (var i = 0; i < out.length; i++) {
    if (i % 4 != 3) {
      out[i] = (out[i] + add).clamp(0, 255);
    }
  }
  return out;
}

void main() {
  group('the pieces', () {
    test('a flat photo is one piece, a 3D photo one per eye, a 360° photo its seam and its two poles', () {
      expect(enhancePiecesOf(4000, 3000, EnhanceLayout.flat), [(width: 4000, height: 3000)]);
      expect(enhancePiecesOf(6000, 2000, const EnhanceLayout(eyes: EnhanceEyes.sideBySide)), [
        (width: 3000, height: 2000),
        (width: 3000, height: 2000),
      ]);
      expect(enhancePiecesOf(4000, 4000, const EnhanceLayout(eyes: EnhanceEyes.topBottom)), [
        (width: 4000, height: 2000),
        (width: 4000, height: 2000),
      ]);
      final pad = sphereSeamPad(8000);
      final face = poleFaceSize(4000);
      expect(pad, 125);
      expect(face, 2546);
      expect(enhancePiecesOf(8000, 4000, const EnhanceLayout(sphere: true)), [
        (width: 8000 + 2 * pad, height: 4000),
        (width: face, height: face),
        (width: face, height: face),
      ]);
      // A 360° 3D photo: two eyes stacked, each a sphere
      expect(enhancePiecesOf(4000, 4000, const EnhanceLayout(eyes: EnhanceEyes.topBottom, sphere: true)).length, 6);
      // A phone panorama that goes round but reaches neither pole
      expect(
        enhancePiecesOf(
          8000,
          2000,
          const EnhanceLayout(sphere: true),
          cover: const EnhanceSphereCover(north: false, south: false),
        ),
        [(width: 8000 + 2 * pad, height: 2000)],
      );
      // A 360° photo takes about a third more work than its pixels, a 3D photo none
      expect(enhanceWorkPixels(8000, 4000, const EnhanceLayout(sphere: true)) / (8000 * 4000), closeTo(1.43, 0.02));
      expect(enhanceWorkPixels(6000, 2000, const EnhanceLayout(eyes: EnhanceEyes.sideBySide)), 6000 * 2000);
    });

    test('the time of a 3D or 360° photo is that of its pieces', () {
      final flat = enhanceEstimate(EnhanceLevel.sharpen, 6000, 2000);
      final stereo = enhanceLayoutEstimate(
        EnhanceLevel.sharpen,
        6000,
        2000,
        const EnhanceLayout(eyes: EnhanceEyes.sideBySide),
      );
      // The same pixels, the start of the model twice
      expect(stereo - flat, const Duration(seconds: 2));
      final sphere = enhanceLayoutEstimate(EnhanceLevel.sharpen, 8000, 4000, const EnhanceLayout(sphere: true));
      expect(sphere, greaterThan(enhanceEstimate(EnhanceLevel.sharpen, 8000, 4000)));
    });
  });

  group('the seam of a 360° photo', () {
    test('the model sees across the seam: the result is that of a model that went round', () async {
      const width = 96;
      const height = 24;
      final random = math.Random(7);
      final rgba = _picture(width, height, (x, y) => [random.nextInt(256), random.nextInt(256), random.nextInt(256)]);
      final model = _Model((piece) => _rowBlur(piece.rgba, piece.width, piece.height));
      final result = await enhanceLaidOut(
        SbsDecoded(width: width, height: height, rgba: rgba),
        const EnhanceLayout(sphere: true),
        model.run,
        cover: const EnhanceSphereCover(north: false, south: false),
      );
      expect(_maxDifference(result, _rowBlurRound(rgba, width, height), width: width), 0);
      // Without the wrap, the first and the last columns would not meet
      expect(
        _maxDifference(_rowBlur(rgba, width, height), _rowBlurRound(rgba, width, height), width: width),
        greaterThan(20),
      );
    });

    test(
      'two results of the seam blend over the first columns: the left edge goes from the one past the right edge',
      () {
        const width = 64;
        const height = 2;
        const pad = 16;
        // The picture past the right edge is 200, the picture in place 0: the first columns go from one to the other
        final padded = _picture(width + 2 * pad, height, (x, y) => x >= pad + width ? [200, 200, 200] : [0, 0, 0]);
        final out = unwrapSeam(padded, width, height, pad);
        expect(out[0], greaterThan(150));
        expect(out[4 * 4], inExclusiveRange(50, 150));
        expect(out[4 * 8], 0);
        expect(out[4 * (width - 1)], 0);
      },
    );
  });

  group('the poles of a 360° photo', () {
    test('a face drawn and drawn back gives the photo again near the pole', () {
      const width = 512;
      const height = 256;
      final rgba = _sphere(width, height);
      final size = poleFaceSize(height);
      for (final north in [true, false]) {
        final face = poleFace(rgba, width, height, size, north: north);
        final back = Uint8List.fromList(rgba);
        pastePoleFace(back, width, height, face, size, north: north);
        expect(_maxDifference(back, rgba, width: width), lessThanOrEqualTo(3));
      }
    });

    test(
      'rows near a pole stand for one point: once its face is drawn back, they no longer change along the row',
      () async {
        const width = 512;
        const height = 256;
        final rgba = _picture(width, height, (x, y) => [120, 120, 120]);
        // A model that invents a pattern along the columns of whatever it is given
        Uint8List invent(SbsDecoded piece) {
          final out = Uint8List.fromList(piece.rgba);
          for (var y = 0; y < piece.height; y++) {
            for (var x = 0; x < piece.width; x++) {
              out[4 * (y * piece.width + x)] = (120 + 40 * math.sin(x * 0.05)).round();
            }
          }
          return out;
        }

        double spreadOfTopRow(Uint8List picture) {
          final reds = [for (var x = 0; x < width; x++) picture[4 * x]];
          return (reds.reduce(math.max) - reds.reduce(math.min)).toDouble();
        }

        final model = _Model(invent);
        final flat = await enhanceLaidOut(
          SbsDecoded(width: width, height: height, rgba: rgba),
          EnhanceLayout.flat,
          model.run,
        );
        final sphere = await enhanceLaidOut(
          SbsDecoded(width: width, height: height, rgba: rgba),
          const EnhanceLayout(sphere: true),
          model.run,
        );
        expect(spreadOfTopRow(flat), greaterThan(60));
        expect(spreadOfTopRow(sphere), lessThan(8));
        // The equator stays the picture enhanced with its seam: the faces of the poles do not reach it
        final seamOnly = await enhanceLaidOut(
          SbsDecoded(width: width, height: height, rgba: rgba),
          const EnhanceLayout(sphere: true),
          model.run,
          cover: const EnhanceSphereCover(north: false, south: false),
        );
        const equator = height ~/ 2;
        for (var x = 0; x < width; x++) {
          expect(sphere[4 * (equator * width + x)], seamOnly[4 * (equator * width + x)]);
        }
      },
    );
  });

  group('the eyes of a 3D photo', () {
    test('each eye is given alone and put back where it was; the same eyes give the same result', () async {
      const width = 64;
      const height = 16;
      // The same picture in both eyes
      final rgba = _picture(width, height, (x, y) => [(x % 32) * 7, y * 9, 50]);
      final model = _Model((piece) => _rowBlur(piece.rgba, piece.width, piece.height));
      final result = await enhanceLaidOut(
        SbsDecoded(width: width, height: height, rgba: rgba),
        const EnhanceLayout(eyes: EnhanceEyes.sideBySide),
        model.run,
      );
      expect(model.pieces, [(width: 32, height: 16), (width: 32, height: 16)]);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < 32; x++) {
          final left = 4 * (y * width + x);
          expect(result[left], result[left + 4 * 32], reason: 'row $y, column $x');
        }
      }
      // No blur across the middle: the first column of the right eye is blurred with its own neighbours only
      final alone = _rowBlur(cropRgbaAtTest(rgba, width, 32, 0, 32, height), 32, height);
      expect(result[4 * 32], alone[0]);
    });

    test('one above the other, then a 360° 3D photo: each eye a sphere', () async {
      final model = _Model((piece) => piece.rgba);
      final stacked = _picture(64, 64, (x, y) => [x * 3, y * 3, 0]);
      final result = await enhanceLaidOut(
        SbsDecoded(width: 64, height: 64, rgba: stacked),
        const EnhanceLayout(eyes: EnhanceEyes.topBottom),
        model.run,
      );
      expect(model.pieces, [(width: 64, height: 32), (width: 64, height: 32)]);
      expect(result, stacked);

      final sphereModel = _Model((piece) => piece.rgba);
      final steps = <(int, int)>[];
      await enhanceLaidOut(
        SbsDecoded(width: 128, height: 128, rgba: _picture(128, 128, (x, y) => [1, 2, 3])),
        const EnhanceLayout(eyes: EnhanceEyes.topBottom, sphere: true),
        sphereModel.run,
        onStep: (done, all) => steps.add((done, all)),
      );
      expect(sphereModel.pieces.length, 6);
      // The tiles of all the pieces, never going back
      for (var i = 1; i < steps.length; i++) {
        expect(steps[i].$1, greaterThanOrEqualTo(steps[i - 1].$1));
      }
      expect(steps.last.$1, steps.last.$2);
      expect(steps.last.$1, 12);
    });
  });

  group('GPano tags', () {
    test('read as attributes or elements, values with spaces left out, the crop told as a cover', () {
      final camera = Uint8List.fromList(
        '<x:xmpmeta><rdf:Description GPano:ProjectionType="equirectangular" GPano:UsePanoramaViewer="True" '
                'GPano:CaptureSoftware="Insta360 Studio" GPano:PoseHeadingDegrees="12.5" '
                'GPano:FullPanoWidthPixels="8000" GPano:FullPanoHeightPixels="4000" '
                'GPano:CroppedAreaImageWidthPixels="8000" GPano:CroppedAreaImageHeightPixels="2000" '
                'GPano:CroppedAreaLeftPixels="0" GPano:CroppedAreaTopPixels="1000"/></x:xmpmeta>'
            .codeUnits,
      );
      final tags = gpanoTagsOfFile(camera);
      expect(tags.first, ('ProjectionType', 'equirectangular'));
      expect(tags, contains(('PoseHeadingDegrees', '12.5')));
      expect(tags.map((tag) => tag.$1), isNot(contains('CaptureSoftware')));
      expect(sphereCoverOfTags(tags), const EnhanceSphereCover(north: false, south: false));

      final server = Uint8List.fromList(
        '<GPano:ProjectionType>equirectangular</GPano:ProjectionType><GPano:FullPanoWidthPixels>4000'
                '</GPano:FullPanoWidthPixels>'
            .codeUnits,
      );
      expect(gpanoTagsOfFile(server), [('ProjectionType', 'equirectangular'), ('FullPanoWidthPixels', '4000')]);
      expect(sphereCoverOfTags(gpanoTagsOfFile(server)), EnhanceSphereCover.whole);
      expect(gpanoTagsOfFile(Uint8List.fromList('no tags here'.codeUnits)), isEmpty);
    });
  });

  group('the engine', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('enhance-layout-'));
    tearDown(() => temp.deleteSync(recursive: true));

    /// A JPEG of [width] x [height] with [xmp]
    String photo(String name, int width, int height, {String? xmp, List<int> Function(int x, int y)? colour}) {
      final picture = SbsDecoded(
        width: width,
        height: height,
        rgba: _picture(width, height, colour ?? (x, y) => [(x * 5) % 256, (y * 7) % 256, 90]),
      );
      final path = p.join(temp.path, name);
      File(path).writeAsBytesSync(encodeScenePicture(SbsCodecChoice.dart.codecs(), picture, quality: 95, xmp: xmp).$1);
      return path;
    }

    Future<(ImmersiveResult, Uint8List)> run(String path, EnhanceLayout layout, _Backend backend) async {
      final job = EnhanceJob(
        id: 'conversion-1',
        source: ImmersiveSource(name: p.basename(path), size: File(path).lengthSync(), sha1: 'c2hhMQ==', path: path),
        partPath: p.join(temp.path, '.out.part'),
        derivativeId: 'urn:uuid:7c0ffee0-0000-4000-8000-000000000001',
        creatorTool: 'Immuch360 Desktop 3.4.7 (windows)',
        created: '2026-11-25T15:00:00+01:00',
        level: EnhanceLevel.sharpen,
        strength: 100,
        layout: layout,
      );
      final result = await EnhanceEngine(
        backend: backend,
        workFolder: (id) => Directory(p.join(temp.path, 'work-$id'))..createSync(),
        codecs: SbsCodecChoice.dart,
        memory: const _Memory(),
      ).run(job, cancel: NativeCancelFlag());
      return (result, result.isDone ? File(job.partPath).readAsBytesSync() : Uint8List(0));
    }

    test('a 360° photo keeps its GPano tags, its seam and poles given apart, each in a folder of its own', () async {
      const xmp =
          '<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?><x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF '
          'xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" '
          'xmlns:GPano="http://ns.google.com/photos/1.0/panorama/" GPano:ProjectionType="equirectangular" '
          'GPano:UsePanoramaViewer="True" GPano:PoseHeadingDegrees="90.0" GPano:FullPanoWidthPixels="256" '
          'GPano:FullPanoHeightPixels="128" GPano:CroppedAreaImageWidthPixels="256" '
          'GPano:CroppedAreaImageHeightPixels="128" GPano:CroppedAreaLeftPixels="0" GPano:CroppedAreaTopPixels="0"/>'
          '</rdf:RDF></x:xmpmeta><?xpacket end="w"?>';
      final path = photo('VID_360.jpg', 256, 128, xmp: xmp);
      final backend = _Backend((piece) => _plus(piece, 10));
      final (result, written) = await run(path, const EnhanceLayout(sphere: true), backend);
      expect(result.isDone, isTrue, reason: result.message);
      final pad = sphereSeamPad(256);
      final face = poleFaceSize(128);
      expect(
        [for (final piece in backend.given) (piece.width, piece.height)],
        [(256 + 2 * pad, 128), (face, face), (face, face)],
      );
      expect(backend.seeds.toSet(), {42});
      expect(backend.folders.toSet().length, 3);
      final packet = ImmersiveXmp.findIn(written)! as EnhancedPhotoXmp;
      expect(packet.input, 'Sphere');
      expect(packet.gpano, contains(('ProjectionType', 'equirectangular')));
      expect(packet.gpano, contains(('PoseHeadingDegrees', '90.0')));
      expect(String.fromCharCodes(written.sublist(0, 4096)), contains('GPano:ProjectionType="equirectangular"'));
      final decoded = const DartSbsCodec().decodeJpeg(written);
      expect((decoded.width, decoded.height), (256, 128));
      // Every folder of the pieces went with the work folder
      expect(Directory(p.join(temp.path, 'work-conversion-1')).existsSync(), isFalse);
    });

    test('a 360° photo only its camera told gets the GPano tags of a whole sphere', () async {
      final path = photo('IMG_20261125.jpg', 256, 128);
      final (result, written) = await run(path, const EnhanceLayout(sphere: true), _Backend((piece) => piece.rgba));
      expect(result.isDone, isTrue, reason: result.message);
      final packet = ImmersiveXmp.findIn(written)! as EnhancedPhotoXmp;
      expect(packet.gpano, wholeSphereGPanoTags(256, 128));
    });

    test('a 3D photo side by side stays one: its eyes in our XMP, read back as two eyes by the viewers', () async {
      final path = photo('beach_LR.jpg', 192, 64, colour: (x, y) => [(x % 96) * 2, y * 3, 40]);
      final backend = _Backend((piece) => _plus(piece, 20));
      final (result, written) = await run(
        path,
        const EnhanceLayout(eyes: EnhanceEyes.sideBySide, halfEyes: true),
        backend,
      );
      expect(result.isDone, isTrue, reason: result.message);
      expect([for (final piece in backend.given) (piece.width, piece.height)], [(96, 64), (96, 64)]);
      final packet = ImmersiveXmp.findIn(written)! as EnhancedPhotoXmp;
      expect(packet.input, 'SideBySide');
      expect(packet.stereoEyes, StereoEyes.half);
      expect(packet.eyeOrder, EyeOrder.leftRight);
      expect(packet.gpano, isEmpty);
      final seen = probeStereoPhotoHead(written, name: 'beach_LR_enhanced.jpg', width: 192, height: 64);
      expect(seen, isNotNull);
      expect(seen!.eyes, StereoEyes.half);
      // A flat enhanced photo stays flat, whatever its name
      final flat = EnhancedPhotoXmp.enhanced(
        level: EnhanceLevel.sharpen.xmp,
        levelName: enhanceLevelWords(EnhanceLevel.sharpen),
        strength: 60,
        model: 'Fake model',
        modelSha256: 'ab' * 32,
        width: 192,
        height: 64,
        sourceName: 'beach_LR.jpg',
        sourceSize: 1,
        sourceSha1: 'c2hhMQ==',
        created: '2026-11-25T15:00:00+01:00',
        creatorTool: 'Immuch360 Desktop',
      );
      expect(
        decideStereoPhoto(
          name: 'beach_LR_enhanced.jpg',
          width: 192,
          height: 64,
          xmp: StereoPhotoXmp.parse(flat.toXml()),
        ),
        isNull,
      );
    });

    test('the packet of a 360° 3D photo reads back as it was written', () {
      final packet = EnhancedPhotoXmp.enhanced(
        level: EnhanceLevel.sharpen.xmp,
        levelName: enhanceLevelWords(EnhanceLevel.sharpen),
        strength: 60,
        model: 'Real-ESRGAN x4plus',
        modelSha256: 'cd' * 32,
        width: 4000,
        height: 4000,
        sourceName: 'pano_TB.jpg',
        sourceSize: 1,
        sourceSha1: 'c2hhMQ==',
        created: '2026-11-25T15:00:00+01:00',
        creatorTool: 'Immuch360 Desktop',
        input: 'SphereTopBottom',
        gpano: wholeSphereGPanoTags(4000, 4000),
      );
      expect(EnhancedPhotoXmp.parse(packet.toXml()), packet);
    });
  });
}

/// [cropRgbaAt] of the engine, for the test
Uint8List cropRgbaAtTest(Uint8List rgba, int width, int x, int y, int toWidth, int toHeight) {
  final out = Uint8List(toWidth * toHeight * 4);
  for (var row = 0; row < toHeight; row++) {
    out.setRange(4 * row * toWidth, 4 * (row + 1) * toWidth, rgba, 4 * ((y + row) * width + x));
  }
  return out;
}
