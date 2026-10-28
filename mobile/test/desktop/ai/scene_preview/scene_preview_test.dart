// "Preview in 3D" of a computer on tiny_scene3D.jpg (design-final 2026-10-27, section 2.7): the photo read with its
// packet, its tail and its glb, or refused with the reason the headset gives (the scene data missing, not a scene of
// ours, made by a newer version); its textures decoded; the scene painted, the photo in place at the start and
// darkened to 5 % beyond the zone; then the page itself: "Preparing the 3D scene", the honesty label under the scene,
// a drag and the wheel that move the eye, Reset, Escape, and a photo whose scene is gone shown flat with its reason.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/scene/glb_reader.dart';
import 'package:immich_mobile/desktop/ai/scene_preview/scene_preview.dart';
import 'package:immich_mobile/desktop/ai/scene_preview/scene_projection.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:path/path.dart' as p;

import '../../../unit/presentation/presentation_context.dart';
import '../scene/glb_reader_test_files.dart';
import '../ui/settle_still.dart';

/// The fixture with its packet's [name] attribute set to [value]; the segment lengths of the JPEG are left as they
/// were, the readers finding the packet in the text of the head
Uint8List _fileWith(Uint8List file, String name, String value) {
  final text = latin1.decode(file);
  final pattern = RegExp('Immuch360:$name="[^"]*"');
  expect(pattern.hasMatch(text), isTrue, reason: 'no $name in the packet');
  return Uint8List.fromList(latin1.encode(text.replaceFirst(pattern, 'Immuch360:$name="$value"')));
}

/// The preview of the fixture followed by [glb], its packet naming it
Uint8List _carrying(Uint8List glb) {
  final withLength = _fileWith(tinyPreview(), 'SceneLength', '${glb.length}');
  return Uint8List.fromList([..._fileWith(withLength, 'SceneSha256', sha256Of(glb)), ...glb]);
}

ScenePreviewProblem? _problemOf(Uint8List file) {
  try {
    scenePreviewOf(file);
    return null;
  } on ScenePreviewException catch (error) {
    return error.problem;
  }
}

/// What [painter] draws in a box of [size], read back as RGBA
Future<(ByteData, int)> _paint(CustomPainter painter, Size size) async {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), size);
  final image = await recorder.endRecording().toImage(size.width.toInt(), size.height.toInt());
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final width = image.width;
  image.dispose();
  return (bytes, width);
}

List<int> _pixel((ByteData, int) painted, int x, int y) {
  final (bytes, width) = painted;
  final at = (y * width + x) * 4;
  return [bytes.getUint8(at), bytes.getUint8(at + 1), bytes.getUint8(at + 2)];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the scene of a photo', () {
    test('the fixture: its packet, and its glb read by the reader of the format', () {
      final data = scenePreviewOf(tinySceneFile());
      expect(data.xmp.kind, ImmersiveKind.volumetricScene);
      expect(data.xmp.safe, const SceneSafeZone(lateral: 0.15, vertical: 0.09, forward: 0.3, backward: 0.075));
      expect(data.scene.meshes, hasLength(2));
      expect(data.scene.triangles, data.xmp.sceneTriangles);
      expect(data.scene.vertices, data.xmp.sceneVertices);
    });

    test('a photo whose scene cannot be read gets the reason the headset gives', () {
      final file = tinySceneFile();
      // Saved again by another program: the tail is gone
      expect(_problemOf(tinyPreview()), ScenePreviewProblem.missing);
      // A byte changed in the scene: its sum is wrong
      expect(_problemOf(Uint8List.fromList(file)..[file.length - 1] ^= 0xFF), ScenePreviewProblem.missing);
      // A photo without our packet, and a 3D photo of ours
      expect(_problemOf(tinyImages()[0]), ScenePreviewProblem.notOurs);
      final sbs = File('test/fixtures/ai_immersive/xmp_v1_sample.xmp').readAsBytesSync();
      expect(_problemOf(Uint8List.fromList([...tinyImages()[0], ...sbs])), ScenePreviewProblem.notOurs);
      // A later format of the packet, or of the scene it names
      expect(_problemOf(_fileWith(file, 'FormatVersion', '2')), ScenePreviewProblem.newerVersion);
      expect(_problemOf(_fileWith(file, 'SceneFormat', 'glb-layers-v2')), ScenePreviewProblem.newerVersion);
      expect(_problemOf(_fileWith(file, 'SceneFormat', 'gltf')), ScenePreviewProblem.notOurs);
      // A tail whose sum is right but whose glb is not ours, or of a later format
      expect(_problemOf(_carrying(tinyGlbWith(['materials', 0, 'alphaMode'], 'BLEND'))), ScenePreviewProblem.notOurs);
      expect(
        _problemOf(_carrying(tinyGlbWith(['extras', 'immuch360', 'format'], 'glb-layers-v2'))),
        ScenePreviewProblem.newerVersion,
      );
      // The same glb carried again reads
      expect(_problemOf(_carrying(tinyGlb())), isNull);
    });

    test(
      'heavier than a Quest 3 opens, by its packet or by its glb, or a file over 64 MiB: too heavy, not drawn',
      () async {
        final file = tinySceneFile();
        expect(_problemOf(_fileWith(file, 'SceneTriangles', '400001')), ScenePreviewProblem.tooHeavy);
        expect(_problemOf(_fileWith(file, 'SceneVertices', '200001')), ScenePreviewProblem.tooHeavy);
        expect(_problemOf(_fileWith(file, 'SceneTriangles', '400000')), isNull, reason: 'the cap itself opens');
        // A file of 64 MiB and a byte: refused before it is read
        final folder = Directory.systemTemp.createTempSync('scene_preview_heavy');
        addTearDown(() => folder.deleteSync(recursive: true));
        final big = File(p.join(folder.path, 'big_scene3D.jpg'));
        final handle = big.openSync(mode: FileMode.write)
          ..writeFromSync(file)
          ..truncateSync(64 * 1024 * 1024 + 1);
        handle.closeSync();
        await expectLater(
          readScenePreview(big.path),
          throwsA(isA<ScenePreviewException>().having((e) => e.problem, 'problem', ScenePreviewProblem.tooHeavy)),
        );
      },
    );

    test('read away from the screen; a file that cannot be read says so', () async {
      final data = await readScenePreview(File(tinyScenePath).absolute.path);
      expect(data.scene.meshes, hasLength(2));
      await expectLater(
        readScenePreview(p.join(Directory.systemTemp.path, 'no_such_scene3D.jpg')),
        throwsA(isA<ScenePreviewException>().having((e) => e.problem, 'problem', ScenePreviewProblem.unreadable)),
      );
    });

    test('its textures decoded, the photo at its size, as the preview draws them', () async {
      final loaded = await loadScenePreview(File(tinyScenePath).absolute.path);
      addTearDown(loaded.dispose);
      expect([for (final image in loaded.textures) (image.width, image.height)], [(32, 24), (16, 16)]);
      expect(loaded.model.fovDegrees, 60);
      expect(loaded.model.photoPlane, 2.25);
    });
  });

  group('the painter', () {
    test('the photo in place at the start, the scene darkened to 5 % beyond the zone', () async {
      final loaded = await loadScenePreview(File(tinyScenePath).absolute.path);
      addTearDown(loaded.dispose);
      const size = Size(320, 240);
      final start = await _paint(
        ScenePreviewPainter(model: loaded.model, textures: loaded.textures, eye: SceneEye.start),
        size,
      );
      // The block (1, 1) of the photo, 8 x 8 pixels of one colour in make_scene_fixture.py (pattern 1: 148, 122, 60),
      // at the place of its centre in the photo: a third of the way across, half way down
      final colour = _pixel(start, 120, 120);
      for (final (channel, expected) in [(colour[0], 148), (colour[1], 122), (colour[2], 60)]) {
        expect(channel, closeTo(expected, 4), reason: '$colour');
      }
      // Every corner of the view shows the photo: the scene fills its rectangle
      for (final (x, y) in [(2, 2), (317, 2), (2, 237), (317, 237)]) {
        expect(_pixel(start, x, y).reduce((a, b) => a + b), greaterThan(60), reason: 'corner $x, $y');
      }

      // Twice the lateral zone to the right: flat, and 95 % dark
      final beyond = await _paint(
        ScenePreviewPainter(model: loaded.model, textures: loaded.textures, eye: const SceneEye(0.3, 0, 0)),
        size,
      );
      for (var x = 0; x < 320; x += 20) {
        for (var y = 0; y < 240; y += 20) {
          expect(_pixel(beyond, x, y).every((channel) => channel <= 255 * 0.05 + 2), isTrue, reason: '$x, $y');
        }
      }
      // Within the zone, as bright as the photo
      final inside = await _paint(
        ScenePreviewPainter(model: loaded.model, textures: loaded.textures, eye: const SceneEye(0.05, 0, 0)),
        size,
      );
      expect(_pixel(inside, 160, 60).reduce((a, b) => a + b), greaterThan(150));
    });

    test('repaints when the eye moves, not otherwise', () {
      final model = ScenePreviewModel(GlbReader.read(tinyGlb()));
      final painter = ScenePreviewPainter(model: model, textures: const [], eye: SceneEye.start);
      expect(painter.shouldRepaint(ScenePreviewPainter(model: model, textures: const [], eye: SceneEye.start)), false);
      expect(
        painter.shouldRepaint(ScenePreviewPainter(model: model, textures: const [], eye: const SceneEye(0.1, 0, 0))),
        true,
      );
    });
  });

  group('the page', () {
    late PresentationContext context;
    late Directory folder;

    setUp(() async {
      context = await PresentationContext.create();
      folder = Directory.systemTemp.createTempSync('scene_preview');
    });
    tearDown(() async {
      await context.dispose();
      folder.deleteSync(recursive: true);
    });

    /// A copy of [bytes] named [name] in the folder of the test
    String fileOf(String name, Uint8List bytes) {
      final path = p.join(folder.path, name);
      File(path).writeAsBytesSync(bytes);
      return path;
    }

    ScenePreviewPainter painter(WidgetTester tester) =>
        tester.widget<CustomPaint>(find.byKey(const Key('scene_preview_canvas'))).painter! as ScenePreviewPainter;

    bool resetEnabled(WidgetTester tester) =>
        tester.widget<ButtonStyleButton>(find.byKey(const Key('scene_preview_reset'))).enabled;

    /// A button that opens the preview of [path] the way the app does
    Future<void> pumpOpener(WidgetTester tester, String path) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpTestWidget(
        context,
        Consumer(
          builder: (context, ref, _) => TextButton(
            key: const Key('open'),
            onPressed: () => ref.read(scenePreviewOpenerProvider)(context, path),
            child: const Text('open'),
          ),
        ),
        expectSettle: false,
      );
      await settleStill(tester);
      await tester.tap(find.byKey(const Key('open')));
      await tester.pump();
    }

    testWidgets('the fixture: prepared, then shown with its honesty label, moved by the mouse and the wheel', (
      tester,
    ) async {
      final path = fileOf('salon_scene3D.jpg', tinySceneFile());
      await pumpOpener(tester, path);

      expect(find.text('Preparing the 3D scene'), findsOneWidget);
      await settleStill(tester, until: () => find.byKey(const Key('scene_preview_canvas')).evaluate().isNotEmpty);

      expect(find.text('Preview in 3D'), findsOneWidget);
      expect(find.text('Reconstructed from one photo, explore within its limits'), findsOneWidget);
      expect(find.text('Preview: the headset shows the full detail'), findsOneWidget);
      expect(painter(tester).eye, SceneEye.start);
      expect(painter(tester).textures, hasLength(2));
      expect(resetEnabled(tester), isFalse);

      // A drag to the right moves the eye to the right, within its limit
      await tester.drag(find.byKey(const Key('scene_preview_canvas')), const Offset(120, 0));
      await tester.pump();
      final moved = painter(tester).eye;
      expect(moved.x, greaterThan(0));
      expect(moved.y, closeTo(0, 1e-9));
      expect(resetEnabled(tester), isTrue);

      // The wheel pushed away goes forward, a notch as this computer sends one: 100 pixels for the phone of the tests,
      // one physical pixel to a logical one, as under Windows at 100 % (a test pointer scrolls in physical pixels)
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      final centre = tester.getCenter(find.byKey(const Key('scene_preview_canvas')));
      await tester.sendEventToBinding(pointer.hover(centre));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -100)));
      await tester.pump();
      expect(painter(tester).eye.z, closeTo(-0.25 * 0.3, 1e-9));
      expect(painter(tester).eye.x, moved.x);

      // Reset: back where the photo was taken
      await tester.tap(find.byKey(const Key('scene_preview_reset')));
      await tester.pump();
      expect(painter(tester).eye, SceneEye.start);
      expect(resetEnabled(tester), isFalse);

      // Escape closes the preview
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settleStill(tester, until: () => find.byKey(const Key('scene_preview')).evaluate().isEmpty);
      expect(find.byKey(const Key('scene_preview')), findsNothing);
      expect(find.byKey(const Key('open')), findsOneWidget);
    });

    testWidgets('a notch of a Windows wheel at 200 %, 50 logical pixels, is a quarter of the reach', (tester) async {
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetDevicePixelRatio);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final path = fileOf('salon_scene3D.jpg', tinySceneFile());
        await pumpOpener(tester, path);
        await settleStill(tester, until: () => find.byKey(const Key('scene_preview_canvas')).evaluate().isNotEmpty);
        final pointer = TestPointer(1, PointerDeviceKind.mouse);
        await tester.sendEventToBinding(pointer.hover(tester.getCenter(find.byKey(const Key('scene_preview_canvas')))));
        // 100 physical pixels for a notch, 50 logical at 200 %, which the fixed 100 of S4 counted as half a notch
        await tester.sendEventToBinding(pointer.scroll(const Offset(0, -100)));
        await tester.pump();

        expect(painter(tester).eye.z, closeTo(-0.25 * 0.3, 1e-9));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('on a touchpad two fingers parted go forward, closed go back, moved go like a drag', (tester) async {
      final path = fileOf('salon_scene3D.jpg', tinySceneFile());
      await pumpOpener(tester, path);
      await settleStill(tester, until: () => find.byKey(const Key('scene_preview_canvas')).evaluate().isNotEmpty);
      final centre = tester.getCenter(find.byKey(const Key('scene_preview_canvas')));
      final pad = TestPointer(2, PointerDeviceKind.trackpad);

      await tester.sendEventToBinding(pad.panZoomStart(centre));
      for (final scale in [1.2, 1.5, 2.0, 2.5]) {
        await tester.sendEventToBinding(pad.panZoomUpdate(centre, scale: scale));
      }
      await tester.sendEventToBinding(pad.panZoomEnd());
      await tester.pump();
      final forward = painter(tester).eye;
      expect(forward.z, lessThan(-0.05), reason: 'parted: forward');
      expect(forward.x, closeTo(0, 1e-9));

      await tester.sendEventToBinding(pad.panZoomStart(centre));
      for (final scale in [0.8, 0.5, 0.3]) {
        await tester.sendEventToBinding(pad.panZoomUpdate(centre, scale: scale));
      }
      await tester.sendEventToBinding(pad.panZoomEnd());
      await tester.pump();
      expect(painter(tester).eye.z, greaterThan(forward.z), reason: 'closed: back');

      await tester.sendEventToBinding(pad.panZoomStart(centre));
      for (final dx in [20.0, 40.0, 60.0]) {
        await tester.sendEventToBinding(pad.panZoomUpdate(centre, pan: Offset(dx, 0)));
      }
      await tester.sendEventToBinding(pad.panZoomEnd());
      await tester.pump();
      expect(painter(tester).eye.x, greaterThan(0), reason: 'moved right: the eye goes right');
    });

    testWidgets('a photo whose scene is gone is shown flat with its reason, and closes', (tester) async {
      final path = fileOf('salon_scene3D.jpg', tinyPreview());
      await pumpOpener(tester, path);
      await settleStill(tester, until: () => find.byKey(const Key('scene_preview_problem')).evaluate().isNotEmpty);

      expect(find.text('The 3D scene data is missing from this file'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(find.byKey(const Key('scene_preview_canvas')), findsNothing);
      expect(find.byKey(const Key('scene_preview_reset')), findsNothing);
      expect(find.text('Reconstructed from one photo, explore within its limits'), findsOneWidget);

      await tester.tap(find.byTooltip('Close'));
      await settleStill(tester, until: () => find.byKey(const Key('scene_preview')).evaluate().isEmpty);
      expect(find.byKey(const Key('open')), findsOneWidget);
    });

    testWidgets('a photo of a later format, and a file gone, say so', (tester) async {
      await pumpOpener(tester, fileOf('later_scene3D.jpg', _fileWith(tinySceneFile(), 'FormatVersion', '2')));
      await settleStill(tester, until: () => find.byKey(const Key('scene_preview_problem')).evaluate().isNotEmpty);
      expect(find.text('Made by a newer version of Immuch360: shown flat'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settleStill(tester, until: () => find.byKey(const Key('scene_preview')).evaluate().isEmpty);

      // The same button, its file deleted meanwhile
      File(p.join(folder.path, 'later_scene3D.jpg')).deleteSync();
      await tester.tap(find.byKey(const Key('open')));
      await tester.pump();
      await settleStill(tester, until: () => find.byKey(const Key('scene_preview_problem')).evaluate().isNotEmpty);
      expect(find.text('Error occurred'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });
  });
}
