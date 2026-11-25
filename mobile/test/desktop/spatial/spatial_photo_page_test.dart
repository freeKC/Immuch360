// The 2.5D photo page of the computers and its entry in the viewer: the viewpoint the shader gets for a recorded track
// of the fake source, the mouse, the keys, the settings, the depth states, and which photos get the button.

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/spatial/spatial_photo_button.dart';
import 'package:immich_mobile/desktop/spatial/spatial_photo_page.dart';
import 'package:immich_mobile/desktop/spatial/spatial_photo_render.dart';
import 'package:immich_mobile/desktop/spatial/spatial_settings.dart';
import 'package:immich_mobile/desktop/spatial/spatial_viewpoint.dart';
import 'package:immich_mobile/desktop/spatial/viewer_position.dart';
import 'package:immich_mobile/desktop/spatial/viewer_position_sources.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/flat_stereo.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/providers/ai_immersive/flat_stereo.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';

import '../../unit/presentation/presentation_context.dart';
import 'fake_viewer_position_source.dart';

const _sbs = SpatialPhotoLayout(packing: SpatialPhotoPacking.sideBySide);

/// An image provider that hands over a picture at once
class _ImageOf extends ImageProvider<_ImageOf> {
  const _ImageOf(this.image);

  final ui.Image image;

  @override
  Future<_ImageOf> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_ImageOf key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(SynchronousFuture(ImageInfo(image: image.clone())));
}

Future<ui.Image> _picture(int width, int height, Color color) {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = color);
  return recorder.endRecording().toImage(width, height);
}

void main() {
  late PresentationContext context;
  late ui.Image frame;
  late ui.Image map;
  late ui.FragmentProgram program;
  var now = Duration.zero;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    frame = await _picture(64, 16, const Color(0xFF336699));
    map = await _picture(32, 16, const Color(0xFF808080));
    program = await ui.FragmentProgram.fromAsset(spatialPhotoShaderAsset);
  });

  setUp(() async {
    context = await PresentationContext.create();
    now = Duration.zero;
  });

  tearDown(() async {
    await context.dispose();
  });

  List<Override> pageOverrides({
    Map<ViewerPositionKind, ViewerPositionSource Function()>? sources,
    bool depthFails = false,
  }) => [
    spatialPhotoProgramProvider.overrideWithValue(() async => program),
    spatialPhotoDepthProvider.overrideWithValue(
      (image, layout) async => depthFails
          ? throw StateError('no depth')
          : SpatialPhotoDepth(map: map.clone(), minimum: -2, range: 4),
    ),
    if (sources != null) viewerPositionSourcesProvider.overrideWithValue(sources),
  ];

  Future<void> pumpPage(WidgetTester tester, {List<Override> overrides = const [], bool estimated = false}) async {
    await tester.pumpTestWidget(
      context,
      SpatialPhotoPage(
        image: _ImageOf(frame),
        layout: _sbs,
        title: 'salon_3D_LRF_Full_SBS.jpg',
        estimatedRelief: estimated,
        clock: () => now,
      ),
      overrides: overrides,
      expectSettle: false,
    );
    // The shader and the depth come in futures
    await tester.pump();
    await tester.pump();
  }

  SpatialPhotoPainter painter(WidgetTester tester) =>
      tester.widget<CustomPaint>(find.byKey(const Key('spatial_photo_canvas'))).painter! as SpatialPhotoPainter;

  /// Lets the clock of the page and the frames move on by [ms]
  Future<void> advance(WidgetTester tester, int ms) async {
    now += Duration(milliseconds: ms);
    await tester.pump(Duration(milliseconds: ms));
  }

  group('page', () {
    testWidgets('opens with the mouse, measures the depth, then draws with the shader', (tester) async {
      await pumpPage(tester, overrides: pageOverrides(), estimated: true);
      expect(find.text('Relief estimated by AI'), findsOneWidget);
      expect(find.text('Move the pointer across the picture to look around the scene; R recenters'), findsOneWidget);
      expect(painter(tester).depth, isNotNull);
      expect(painter(tester).program, same(program));
      expect(painter(tester).viewpoint.value, spatialViewpointCentre);
      expect(find.text('Mouse'), findsOneWidget);

      await tester.tap(find.byKey(const Key('spatial_photo_move_with')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('spatial_photo_move_mouse')), findsOneWidget);
      expect(find.byKey(const Key('spatial_photo_move_sway')), findsOneWidget);
      expect(find.byKey(const Key('spatial_photo_move_keys')), findsOneWidget);
      // No head without the tracker of its own lot
      expect(find.byKey(const Key('spatial_photo_move_head')), findsNothing);
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();
    });

    testWidgets('a recorded track of the fake source moves the uniform as the phones would', (tester) async {
      final fake = FakeViewerPositionSource();
      await SettingsRepository.instance.write(SettingsKey.viewerSpatialMoveWith, ViewerPositionKind.head);
      await pumpPage(
        tester,
        overrides: pageOverrides(
          sources: {ViewerPositionKind.head: () => fake, ViewerPositionKind.mouse: MousePositionSource.new},
        ),
      );
      final seen = <double>[];
      for (final (ms, x, confidence) in [(33, 0.5, 0.9), (33, 1.0, 0.9), (33, 0.0, 0.0), (500, 0.0, 0.0)]) {
        await advance(tester, ms);
        fake.add(ViewerPosition(x: x, y: 0, timestamp: now, confidence: confidence));
        await advance(tester, 0);
        seen.add(painter(tester).viewpoint.value);
      }
      expect(seen[0], closeTo(0.675, 1e-9));
      expect(seen[1], closeTo(0.85, 1e-9));
      // No one seen: held, then half way back after half a second
      expect(seen[2], closeTo(0.85, 1e-9));
      expect(seen[3], closeTo(0.675, 1e-9));
      await advance(tester, 600);
      expect(painter(tester).viewpoint.value, spatialViewpointCentre);
      // R reaches the source
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      expect(fake.recenters, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(fake.closed, isTrue, reason: 'the page closes its source');
    });

    testWidgets('the mouse across the picture moves the view towards its side, and back when it leaves', (
      tester,
    ) async {
      await pumpPage(tester, overrides: pageOverrides());
      final canvas = tester.getRect(find.byKey(const Key('spatial_photo_canvas')));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: canvas.center);
      await advance(tester, 16);
      await mouse.moveTo(Offset(canvas.right - 1, canvas.center.dy));
      for (var i = 0; i < 60; i++) {
        await advance(tester, 16);
      }
      expect(painter(tester).viewpoint.value, closeTo(0.85, 0.01));
      await mouse.moveTo(Offset(canvas.left + 1, canvas.center.dy));
      for (var i = 0; i < 60; i++) {
        await advance(tester, 16);
      }
      expect(painter(tester).viewpoint.value, closeTo(0.15, 0.01));
      await mouse.removePointer();
    });

    testWidgets('keys only: the arrows step the view, R recenters, and the choice is kept in the settings', (
      tester,
    ) async {
      await pumpPage(tester, overrides: pageOverrides());
      await tester.tap(find.byKey(const Key('spatial_photo_move_with')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('spatial_photo_move_keys')));
      await tester.pumpAndSettle();
      expect(SettingsRepository.instance.appConfig.viewer.spatialMoveWith, ViewerPositionKind.keys);
      expect(find.text('The left and right arrows move the view; R recenters'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await advance(tester, 2000);
      expect(painter(tester).viewpoint.value, closeTo(0.5 + 0.35 * 0.4, 1e-3));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await advance(tester, 2000);
      expect(painter(tester).viewpoint.value, closeTo(0.5, 1e-3));
    });

    testWidgets('sensitivity and reverse of the settings apply; D shows the depth', (tester) async {
      await SettingsRepository.instance.write(SettingsKey.viewerSpatialMoveWith, ViewerPositionKind.keys);
      await SettingsRepository.instance.write(SettingsKey.viewerSpatialSensitivity, 50);
      await SettingsRepository.instance.write(SettingsKey.viewerSpatialReverse, true);
      await pumpPage(tester, overrides: pageOverrides());
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await advance(tester, 2000);
      expect(painter(tester).viewpoint.value, closeTo(0.5 - 0.35 * 0.5 * 0.2, 1e-3));
      expect(painter(tester).showDepth, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await tester.pump();
      expect(painter(tester).showDepth, isTrue);
    });

    testWidgets('a depth that cannot be measured leaves the left eye, and says so', (tester) async {
      await pumpPage(tester, overrides: pageOverrides(depthFails: true));
      expect(find.text('The depth of this photo could not be measured: one eye is shown'), findsOneWidget);
      expect(painter(tester).depth, isNull);
      expect(painter(tester).program, isNull);
    });
  });

  group('entry', () {
    LocalAsset asset(String name, {int width = 3840, int height = 1080}) => LocalAsset(
      id: name,
      name: name,
      type: AssetType.image,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      width: width,
      height: height,
      playbackStyle: AssetPlaybackStyle.image,
      isEdited: false,
    );

    test('the layouts of the probe and of the names', () {
      expect(
        spatialLayoutOfSideBySide(const FlatStereoPhoto(eyes: StereoEyes.half, eyeOrder: EyeOrder.rightLeft)),
        const SpatialPhotoLayout(packing: SpatialPhotoPacking.sideBySide, swapped: true, squeezed: true),
      );
      expect(spatialLayoutOfSideBySide(const FlatStereoPhoto(eyes: StereoEyes.full)), _sbs);
      expect(spatialLayoutOfStacked(FlatStereoFormat.tb), const SpatialPhotoLayout(packing: SpatialPhotoPacking.topBottom));
      expect(
        spatialLayoutOfStacked(FlatStereoFormat.halfTb),
        const SpatialPhotoLayout(packing: SpatialPhotoPacking.topBottom, squeezed: true),
      );
      expect(spatialLayoutOfStacked(FlatStereoFormat.sbs), isNull);
    });

    Future<List<(SpatialPhotoLayout, bool)>> pumpButton(
      WidgetTester tester,
      BaseAsset asset, {
      FlatStereoPhoto? photo,
      bool equirect = false,
    }) async {
      final opened = <(SpatialPhotoLayout, bool)>[];
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpTestWidget(
        context,
        ColoredBox(color: Colors.black, child: DesktopSpatialPhotoButton(asset: asset)),
        overrides: [
          flatStereoProvider(asset).overrideWith((ref) async => photo),
          isEquirectangularProvider(asset).overrideWithValue(equirect),
          spatialPhotoOpenerProvider.overrideWithValue(
            (context, asset, layout, estimated) => opened.add((layout, estimated)),
          ),
        ],
      );
      return opened;
    }

    testWidgets('a side by side photo of ours opens with its layout and the AI label', (tester) async {
      final ours = asset('salon_3D_LRF_Full_SBS.jpg');
      final opened = await pumpButton(tester, ours, photo: const FlatStereoPhoto(eyes: StereoEyes.full));
      expect(find.byTooltip('Spatial 2.5D'), findsOneWidget);
      await tester.tap(find.byKey(const Key('desktop_spatial_photo')));
      expect(opened, [(_sbs, false)]);
    });

    testWidgets('two eyes one above the other by the name, never a 360° one, nothing for a flat photo', (tester) async {
      final stacked = asset('chateau_3D_TB.jpg', width: 1920, height: 2160);
      var opened = await pumpButton(tester, stacked);
      await tester.tap(find.byKey(const Key('desktop_spatial_photo')));
      expect(opened, [(const SpatialPhotoLayout(packing: SpatialPhotoPacking.topBottom), false)]);

      opened = await pumpButton(tester, stacked, equirect: true);
      expect(find.byKey(const Key('desktop_spatial_photo')), findsNothing);

      await pumpButton(tester, asset('IMG_1234.jpg', width: 4000, height: 3000));
      expect(find.byKey(const Key('desktop_spatial_photo')), findsNothing);
    });

    testWidgets('nothing while the Spatial 2.5D switch is off', (tester) async {
      await SettingsRepository.instance.write(SettingsKey.viewerSpatial25d, false);
      await pumpButton(tester, asset('salon_3D_LRF_Full_SBS.jpg'), photo: const FlatStereoPhoto(eyes: StereoEyes.full));
      expect(find.byKey(const Key('desktop_spatial_photo')), findsNothing);
    });
  });

  group('settings', () {
    testWidgets('what moves the view, the strength and the direction are written to the settings', (tester) async {
      await tester.pumpTestWidget(context, const SingleChildScrollView(child: DesktopSpatialSettings()));
      expect(find.text('Move the view with'), findsOneWidget);
      expect(find.text('Strength of the movement: 100 %'), findsOneWidget);
      await tester.tap(find.byType(DropdownButton<ViewerPositionKind>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Automatic sway').last);
      await tester.pumpAndSettle();
      expect(SettingsRepository.instance.appConfig.viewer.spatialMoveWith, ViewerPositionKind.sway);
      expect(find.text('The view sways gently from side to side'), findsOneWidget);

      await tester.tap(find.text('Reverse direction'));
      await tester.pumpAndSettle();
      expect(SettingsRepository.instance.appConfig.viewer.spatialReverse, isTrue);

      final slider = find.byType(Slider);
      await tester.drag(slider, const Offset(-2000, 0));
      await tester.pumpAndSettle();
      expect(SettingsRepository.instance.appConfig.viewer.spatialSensitivity, spatialSensitivityMin);
    });
  });
}
