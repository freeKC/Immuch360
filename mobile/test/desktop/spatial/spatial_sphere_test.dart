// Spatial 2.5D of a 360° or VR180 3D photo on the computers (lot P3, spatial_sphere_render.dart): the layouts, the
// direction each output pixel looks at (the 360° photo viewer's projection the other way round), the uniforms, the
// shader run in the tests on a random dot sphere of known disparity (p 0 the left eye, p 1 the right eye, p 0.5 half
// way, across the seam too, the left eye alone without a depth, nothing outside a VR180 eye), the page with a recorded
// track of the fake source, the drag, the wheel, the arrows and its closing, and which photos of the library viewer
// get the button: a 360° photo of two eyes opens as it is, a 360° photo of one eye through its 3D version made by AI
// first, while this computer makes that type.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_queue.dart';
import 'package:immich_mobile/desktop/ai/library/stereo_badge.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/library/library_index.dart';
import 'package:immich_mobile/desktop/spatial/spatial_conversion.dart';
import 'package:immich_mobile/desktop/spatial/spatial_photo_button.dart';
import 'package:immich_mobile/desktop/spatial/spatial_photo_page.dart';
import 'package:immich_mobile/desktop/spatial/spatial_photo_render.dart';
import 'package:immich_mobile/desktop/spatial/spatial_sphere_render.dart';
import 'package:immich_mobile/desktop/spatial/spatial_viewpoint.dart';
import 'package:immich_mobile/desktop/spatial/viewer_position.dart';
import 'package:immich_mobile/desktop/spatial/viewer_position_sources.dart';
import 'package:immich_mobile/desktop/video/projection_params.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/viewer_config.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/services/raw/raw_360_detection.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/presentation/widgets/images/local_image_provider.dart';
import 'package:immich_mobile/providers/ai_immersive/flat_stereo.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/sphere_coverage.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/splat/splat_photo.provider.dart';

import '../../unit/factories/remote_asset_factory.dart';
import '../../unit/presentation/presentation_context.dart';
import '../../widget_tester_extensions.dart';
import '../ai/fakes/fake_conversion_engines.dart';
import '../ai/fakes/fake_stereo_panorama_engine.dart';
import '../ai/ui/settle_still.dart';
import 'fake_viewer_position_source.dart';
import 'spatial_ai_fakes.dart';

const _tbSphere = SpatialPhotoLayout(packing: SpatialPhotoPacking.topBottom, sphere: fullSphereCrop);
const _sbsSphere = SpatialPhotoLayout(packing: SpatialPhotoPacking.sideBySide, sphere: fullSphereCrop);
const _vr180 = SpatialPhotoLayout(packing: SpatialPhotoPacking.sideBySide, sphere: halfSphereCrop);
const _convertFirst360 = 'Spatial 2.5D: makes the 360° 3D photo with AI first, then opens it';

Future<ui.Image> _imageOf(Uint8List rgba, int width, int height) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
  final descriptor = ui.ImageDescriptor.raw(buffer, width: width, height: height, pixelFormat: ui.PixelFormat.rgba8888);
  final codec = await descriptor.instantiateCodec();
  return (await codec.getNextFrame()).image;
}

Future<ui.Image> _picture(int width, int height, Color color) {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = color);
  return recorder.endRecording().toImage(width, height);
}

/// A sphere of big random blocks that go round (the column x and x + [width] are the same), its two eyes of
/// [width] x [width] / 2 one above the other, the right eye seeing everything [shift] pixels to the left of where the
/// left eye does: a sphere of one depth, as a stitcher would give it. The red of the left eye at (x, y), x taken round.
class _Sphere {
  _Sphere(this.width, this.shift) : height = width ~/ 2 {
    final random = math.Random(5);
    _cells = List.generate(width ~/ _block, (_) => List.generate(height ~/ _block + 1, (_) => random.nextInt(256)));
  }

  static const _block = 4;
  final int width;
  final int height;
  final int shift;
  late final List<List<int>> _cells;

  int red(int x, int y) => _cells[(x % width) ~/ _block][y.clamp(0, height - 1) ~/ _block];

  /// The red of the left eye at ([x], [y]) in pixels of the eye, between the texels (their centres at half a pixel)
  double between(double x, double y) {
    final fx = x - 0.5;
    final fy = y - 0.5;
    final x0 = fx.floor();
    final y0 = fy.floor();
    final tx = fx - x0;
    final ty = fy - y0;
    final top = red(x0, y0) * (1 - tx) + red(x0 + 1, y0) * tx;
    final bottom = red(x0, y0 + 1) * (1 - tx) + red(x0 + 1, y0 + 1) * tx;
    return top * (1 - ty) + bottom * ty;
  }

  Future<ui.Image> frame() {
    final rgba = Uint8List(width * height * 2 * 4);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        for (final (row, source) in [(y, x), (y + height, x + shift)]) {
          final i = (row * width + x) * 4;
          final v = red(source, y);
          rgba
            ..[i] = v
            ..[i + 1] = 255 - v
            ..[i + 2] = (v * 7) % 256
            ..[i + 3] = 255;
        }
      }
    }
    return _imageOf(rgba, width, height * 2);
  }
}

Future<Uint8List> _render(CustomPainter painter, Size size) async {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), size);
  final picture = recorder.endRecording();
  final image = await picture.toImage(size.width.round(), size.height.round());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List();
}

/// The forward projection of the 360° photo viewer (panorama_viewer.widget.dart, _SpherePainter): where the point of
/// the sphere at [longitude] and [latitude] (degrees) lands on an output of [size] in [view]; null behind the viewer
Offset? _viewerProjection(double longitude, double latitude, Size size, ViewAngles view) {
  final yaw = view.yaw * math.pi / 180;
  final pitch = view.pitch * math.pi / 180;
  final elevation = latitude * math.pi / 180;
  final azimuth = longitude * math.pi / 180 - yaw;
  final x = math.cos(elevation) * math.sin(azimuth);
  final y = math.sin(elevation) * math.cos(pitch) - math.cos(elevation) * math.cos(azimuth) * math.sin(pitch);
  final depth = math.sin(elevation) * math.sin(pitch) + math.cos(elevation) * math.cos(azimuth) * math.cos(pitch);
  if (depth < 0.15) {
    return null;
  }
  final focal = size.height / 2 / math.tan(view.fov * math.pi / 360);
  return Offset(size.width / 2 + focal * x / depth, size.height / 2 - focal * y / depth);
}

LocalAsset _photo(String name, {int width = 8000, int height = 4000}) => LocalAsset(
  id: 'id-$name',
  name: name,
  type: AssetType.image,
  createdAt: DateTime(2026, 11, 26, 9),
  updatedAt: DateTime(2026, 11, 26, 9),
  width: width,
  height: height,
  playbackStyle: AssetPlaybackStyle.image,
  isEdited: false,
);

void main() {
  group('the maths', () {
    test('the layouts of the 360° viewers, and the shape of an eye of a sphere', () {
      expect(spatialSphereLayout(StereoLayout.topBottom), _tbSphere);
      expect(spatialSphereLayout(StereoLayout.leftRight), _sbsSphere);
      expect(spatialSphereLayout(StereoLayout.leftRight, crop: halfSphereCrop), _vr180);
      expect(spatialSphereLayout(StereoLayout.mono), isNull);
      expect(_tbSphere, isNot(const SpatialPhotoLayout(packing: SpatialPhotoPacking.topBottom)));
      // Two eyes of the whole sphere at 2:1 whatever the packing squeezed, a VR180 eye square
      expect(_tbSphere.eyeShownSize(const Size(4096, 4096)), const Size(4096, 2048));
      expect(_tbSphere.eyeShownSize(const Size(4096, 2048)), const Size(4096, 2048));
      expect(_sbsSphere.eyeShownSize(const Size(8192, 2048)), const Size(4096, 2048));
      expect(_sbsSphere.eyeShownSize(const Size(4096, 2048)), const Size(2048, 1024));
      expect(_vr180.eyeShownSize(const Size(4096, 2048)), const Size(2048, 2048));
      expect(spatialMadeSphereLayout, _tbSphere);
      expect(spatialMadeLayoutOf(ConversionKind.stereoPanoramaFromPanorama), _tbSphere);
      expect(spatialMadeLayoutOf(ConversionKind.sbsFromPhoto), spatialMadePhotoLayout);
    });

    test('where each pixel looks: the centre, the turns, the edges, up, and the front half of VR180', () {
      const size = Size(200, 200);
      Offset? at(Offset pixel, ViewAngles view, [Rect sphere = fullSphereCrop]) =>
          sphereEyePoint(pixel, size, view, sphere);
      void near(Offset? point, double x, double y) {
        expect(point, isNotNull);
        expect(point!.dx, closeTo(x, 1e-9));
        expect(point.dy, closeTo(y, 1e-9));
      }

      const centre = Offset(100, 100);
      near(at(centre, const ViewAngles()), 0.5, 0.5);
      near(at(centre, const ViewAngles(yaw: 90)), 0.75, 0.5);
      near(at(centre, const ViewAngles(yaw: -90)), 0.25, 0.5);
      near(at(centre, const ViewAngles(yaw: 179)), 0.5 + 179 / 360, 0.5);
      // Past the seam the rows go round
      near(at(centre, const ViewAngles(yaw: 200)), (0.5 + 200 / 360) - 1, 0.5);
      // At 90° of view on a square, the right edge is 45° to the right, the top edge 45° up
      near(at(const Offset(200, 100), const ViewAngles()), 0.625, 0.5);
      near(at(const Offset(100, 0), const ViewAngles()), 0.5, 0.25);
      near(at(centre, const ViewAngles(pitch: 45)), 0.5, 0.25);
      expect(at(centre, const ViewAngles(pitch: 90))!.dy, closeTo(0, 1e-9));
      // VR180: the front half only, its eye from -90° to 90°
      near(at(centre, const ViewAngles(), halfSphereCrop), 0.5, 0.5);
      near(at(centre, const ViewAngles(yaw: 45), halfSphereCrop), 0.75, 0.5);
      expect(at(centre, const ViewAngles(yaw: 120), halfSphereCrop), isNull);
    });

    test('the projection of the 360° photo viewer the other way round, in any view', () {
      const size = Size(320, 180);
      final random = math.Random(11);
      var checked = 0;
      for (var i = 0; i < 400; i++) {
        final view = ViewAngles(
          yaw: random.nextDouble() * 360 - 180,
          pitch: random.nextDouble() * 120 - 60,
          fov: 30 + random.nextDouble() * 80,
        );
        final longitude = random.nextDouble() * 360 - 180;
        final latitude = random.nextDouble() * 160 - 80;
        final pixel = _viewerProjection(longitude, latitude, size, view);
        if (pixel == null) {
          continue;
        }
        final point = sphereEyePoint(pixel, size, view, fullSphereCrop)!;
        final u = 0.5 + longitude / 360;
        expect((point.dx - u + 0.5) % 1 - 0.5, closeTo(0, 1e-9), reason: '$view $longitude $latitude');
        expect(point.dy, closeTo(0.5 - latitude / 180, 1e-9));
        checked++;
      }
      expect(checked, greaterThan(100));
    });

    test('the uniforms, in the order of the shader', () {
      final map = SpatialPhotoDepth(map: _FakeImage(320), minimum: -4, range: 16);
      const size = Size(800, 450);
      const view = ViewAngles(yaw: 30, pitch: -10, fov: 60);
      List<double> uniforms(SpatialPhotoLayout layout, {SpatialPhotoDepth? depth, bool showDepth = false}) =>
          spatialSphereUniforms(
            size: size,
            frame: const Size(4096, 4096),
            layout: layout,
            depth: depth,
            viewpoint: 0.7,
            view: view,
            showDepth: showDepth,
          );
      final scene = uniforms(_tbSphere, depth: map);
      expect(scene, hasLength(27));
      final flat = spatialPhotoUniforms(
        size: size,
        frame: const Size(4096, 4096),
        layout: _tbSphere,
        mapWidth: 320,
        minimum: -4,
        range: 16,
        viewpoint: 0.7,
      );
      expect(scene.sublist(0, 18), flat.sublist(0, 18), reason: 'the floats of the flat photos first');
      expect(scene[18], closeTo(30 * math.pi / 180, 1e-12));
      expect(scene[19], closeTo(-10 * math.pi / 180, 1e-12));
      expect(scene[20], closeTo(225 / math.tan(math.pi / 6), 1e-9));
      expect(scene[21], 1, reason: 'the rows of the whole sphere go round');
      expect(scene.sublist(22, 26), [0, 0, 1, 1]);
      expect(scene[26], 0);
      expect(uniforms(_tbSphere, depth: map, showDepth: true)[26], 1);
      expect(uniforms(_tbSphere)[26], 2, reason: 'the left eye alone without a depth');
      final half = uniforms(_vr180, depth: map);
      expect(half[21], 0);
      expect(half.sublist(22, 26), [0.25, 0, 0.5, 1]);
    });
  });

  group('the shader in the tests', () {
    testWidgets('p 0 the left eye, p 1 the right eye, half way between, across the seam, without a depth, VR180', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final program = await ui.FragmentProgram.fromAsset(spatialSphereShaderAsset);
        const width = 320;
        const shift = 6;
        final sphere = _Sphere(width, shift);
        final frame = await sphere.frame();
        final depth = await computeSpatialPhotoDepth(frame, _tbSphere);
        expect(depth.width, width, reason: 'the map at the size of an eye of 320 x 160');
        expect(depth.minimum, lessThanOrEqualTo(shift + 0.5));
        expect(depth.minimum + depth.range, greaterThanOrEqualTo(shift - 0.5));

        const size = Size(160, 120);
        final viewpoint = ValueNotifier(0.0);
        final view = ValueNotifier(const ViewAngles(fov: 60));
        SpatialSpherePainter painter({SpatialPhotoDepth? with_, SpatialPhotoLayout layout = _tbSphere}) =>
            SpatialSpherePainter(
              program: program,
              frame: frame,
              layout: layout,
              depth: with_,
              viewpoint: viewpoint,
              view: view,
            );

        /// The mean difference of the red of the view with what the left eye shows [move] pixels further along the
        /// row, at the point each pixel looks at, read between the texels as the sampler of the shader reads them
        Future<double> error(SpatialSpherePainter painter, double move) async {
          final out = await _render(painter, size);
          var total = 0.0;
          var n = 0;
          for (var y = 0; y < size.height; y++) {
            for (var x = 0; x < size.width; x++) {
              final point = sphereEyePoint(Offset(x + 0.5, y + 0.5), size, view.value, fullSphereCrop)!;
              final expected = sphere.between(point.dx * width + move, point.dy * sphere.height);
              total += (out[(y * size.width.round() + x) * 4] - expected).abs();
              n++;
            }
          }
          return total / n;
        }

        final scene = painter(with_: depth);
        viewpoint.value = 0;
        final leftAtZero = await error(scene, 0);
        final rightAtZero = await error(scene, shift.toDouble());
        viewpoint.value = 1;
        final rightAtOne = await error(scene, shift.toDouble());
        viewpoint.value = 0.5;
        final halfWay = await error(scene, shift / 2);
        // Across the seam: behind the viewer, where the rows meet
        view.value = const ViewAngles(yaw: 180, fov: 60);
        viewpoint.value = 0;
        final seamLeft = await error(scene, 0);
        viewpoint.value = 0.5;
        final seamHalf = await error(scene, shift / 2);
        debugPrint(
          'p 0: left $leftAtZero right $rightAtZero; p 1: right $rightAtOne; p 0.5: $halfWay; '
          'seam p 0: $seamLeft, p 0.5: $seamHalf',
        );
        expect(leftAtZero, lessThan(2));
        expect(rightAtOne, lessThan(2));
        expect(rightAtZero, greaterThan(30), reason: 'the eyes differ');
        expect(halfWay, lessThan(4), reason: 'the scene moved half way');
        expect(seamLeft, lessThan(2));
        expect(seamHalf, lessThan(4));

        // No depth yet: the left eye in the view, whatever the viewpoint
        view.value = const ViewAngles(yaw: 40, pitch: 10, fov: 60);
        viewpoint.value = 0.8;
        expect(await error(painter(), 0), lessThan(2));

        // The depth view: gray where the map is reliable
        final depthView = SpatialSpherePainter(
          program: program,
          frame: frame,
          layout: _tbSphere,
          depth: depth,
          viewpoint: viewpoint,
          view: view,
          showDepth: true,
        );
        final gray = await _render(depthView, size);
        final centre = ((size.height ~/ 2) * size.width.round() + size.width ~/ 2) * 4;
        expect(gray[centre], gray[centre + 1]);

        // VR180: nothing behind the viewer
        view.value = const ViewAngles(yaw: 180, fov: 60);
        final behind = await _render(painter(with_: depth, layout: _vr180), size);
        expect(behind[centre], 0);
        expect(behind[centre + 3], 255);
        frame.dispose();
        depth.dispose();
      });
    });

    test('without the shader, the left eye flat', () async {
      final sphere = _Sphere(32, 2);
      final frame = await sphere.frame();
      final painter = SpatialSpherePainter(
        program: null,
        frame: frame,
        layout: _tbSphere,
        depth: null,
        viewpoint: ValueNotifier(0.5),
        view: ValueNotifier(const ViewAngles()),
      );
      // A 32 x 16 eye contained in 32 x 32: rows 8 to 24
      final out = await _render(painter, const Size(32, 32));
      expect(out[(16 * 32 + 10) * 4], sphere.red(10, 8));
    });
  });

  group('the page', () {
    late PresentationContext context;
    late ui.Image frame;
    late ui.Image map;
    late ui.FragmentProgram program;
    var now = Duration.zero;

    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      frame = await _picture(64, 64, const Color(0xFF336699));
      map = await _picture(64, 32, const Color(0xFF808080));
      program = await ui.FragmentProgram.fromAsset(spatialSphereShaderAsset);
    });

    setUp(() async {
      context = await PresentationContext.create();
      now = Duration.zero;
    });

    tearDown(() async => context.dispose());

    List<Override> overrides({
      Map<ViewerPositionKind, ViewerPositionSource Function()>? sources,
      Future<SpatialPhotoDepth> Function()? depth,
    }) => [
      spatialSphereProgramProvider.overrideWithValue(() async => program),
      spatialPhotoProgramProvider.overrideWithValue(() async => fail('the flat shader is not for a sphere')),
      spatialHeadSourceProvider.overrideWithValue(null),
      spatialPhotoDepthProvider.overrideWithValue(
        (image, layout) => depth?.call() ?? Future.value(SpatialPhotoDepth(map: map.clone(), minimum: -2, range: 4)),
      ),
      if (sources != null) viewerPositionSourcesProvider.overrideWithValue(sources),
    ];

    Future<void> pumpPage(WidgetTester tester, List<Override> overrides) async {
      await tester.pumpTestWidget(
        context,
        SpatialPhotoPage(
          image: _ImageOf(frame),
          layout: _tbSphere,
          title: 'salon_360_3D.jpg',
          estimatedRelief: true,
          clock: () => now,
        ),
        overrides: overrides,
        expectSettle: false,
      );
      await tester.pump();
      await tester.pump();
    }

    SpatialSpherePainter painter(WidgetTester tester) =>
        tester.widget<CustomPaint>(find.byKey(const Key('spatial_photo_canvas'))).painter! as SpatialSpherePainter;

    Future<void> advance(WidgetTester tester, int ms) async {
      now += Duration(milliseconds: ms);
      await tester.pump(Duration(milliseconds: ms));
    }

    testWidgets('opens as the 360° viewer shows it: the left eye until the depth, then the shader with it', (
      tester,
    ) async {
      final measured = Completer<SpatialPhotoDepth>();
      await pumpPage(tester, overrides(depth: () => measured.future));
      expect(painter(tester).program, same(program), reason: 'the shader draws the left eye meanwhile');
      expect(painter(tester).depth, isNull);
      expect(painter(tester).view.value, const ViewAngles());
      expect(find.text('Measuring the depth of the photo'), findsOneWidget);
      expect(find.text('Drag to look around, the wheel zooms'), findsOneWidget);
      expect(find.text('Relief estimated by AI'), findsOneWidget);

      measured.complete(SpatialPhotoDepth(map: map.clone(), minimum: -2, range: 4));
      await tester.pump();
      await tester.pump();
      expect(painter(tester).depth, isNotNull);
      expect(find.text('Move the pointer across the picture to look around the scene; R recenters'), findsOneWidget);
    });

    testWidgets('a recorded track of the fake source moves the viewpoint as on a flat 3D photo, R reaches it', (
      tester,
    ) async {
      final fake = FakeViewerPositionSource();
      await SettingsRepository.instance.write(SettingsKey.viewerSpatialMoveWith, ViewerPositionKind.head);
      await pumpPage(
        tester,
        overrides(sources: {ViewerPositionKind.head: () => fake, ViewerPositionKind.mouse: MousePositionSource.new}),
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
      expect(seen[2], closeTo(0.85, 1e-9));
      expect(seen[3], closeTo(0.675, 1e-9));
      await advance(tester, 600);
      expect(painter(tester).viewpoint.value, spatialViewpointCentre);
      expect(painter(tester).view.value, const ViewAngles(), reason: 'the viewpoint never turns the view');
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      expect(fake.recenters, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(fake.closed, isTrue, reason: 'the page closes its source');
    });

    testWidgets('a drag turns the view, the wheel zooms, the arrows turn it; in Keys only left and right step', (
      tester,
    ) async {
      await pumpPage(tester, overrides());
      final canvas = find.byKey(const Key('spatial_photo_canvas'));
      final height = tester.getSize(canvas).height;
      ViewAngles view() => painter(tester).view.value;

      // The picture follows the pointer: dragging to the left and down turns the view right and up
      tester.widget<GestureDetector>(find.byKey(const Key('spatial_photo_sphere_drag'))).onPanUpdate!(
        DragUpdateDetails(globalPosition: Offset.zero, delta: const Offset(-120, 30)),
      );
      await tester.pump();
      expect(view().yaw, closeTo(120 * 90 / height, 1e-9));
      expect(view().pitch, closeTo(30 * 90 / height, 1e-9));
      final before = view();
      await tester.drag(canvas, const Offset(-200, 0));
      await tester.pump();
      expect(view().yaw, greaterThan(before.yaw), reason: 'a real drag of the mouse');
      expect(view().pitch, closeTo(before.pitch, 1e-9));

      final centre = tester.getCenter(canvas);
      tester.binding.handlePointerEvent(PointerScrollEvent(position: centre, scrollDelta: const Offset(0, 20)));
      await tester.pump();
      expect(view().fov, closeTo(99, 1e-9));
      tester.binding.handlePointerEvent(PointerScrollEvent(position: centre, scrollDelta: const Offset(0, -20)));
      tester.binding.handlePointerEvent(PointerScrollEvent(position: centre, scrollDelta: const Offset(0, -20)));
      await tester.pump();
      expect(view().fov, closeTo(90 / 1.1, 1e-9));

      final turned = view();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(view().yaw, closeTo(turned.yaw - 10, 1e-9));
      expect(view().pitch, closeTo(turned.pitch + 10, 1e-9));
      expect(painter(tester).viewpoint.value, spatialViewpointCentre);

      await tester.tap(find.byKey(const Key('spatial_photo_move_with')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('spatial_photo_move_keys')));
      await tester.pumpAndSettle();
      final kept = view();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await advance(tester, 2000);
      expect(painter(tester).viewpoint.value, closeTo(0.5 + 0.35 * 0.2, 1e-3));
      expect(view(), kept, reason: 'left and right move the viewpoint in Keys only');
    });

    testWidgets('a depth that cannot be measured: the left eye in the view, and said so', (tester) async {
      await pumpPage(tester, overrides(depth: () => Future.error(StateError('no depth'))));
      expect(find.text('The depth of this photo could not be measured: one eye is shown'), findsOneWidget);
      expect(painter(tester).depth, isNull);
      expect(painter(tester).program, same(program));
      // D does nothing without a depth
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await tester.pump();
      expect(painter(tester).showDepth, isFalse);
    });

    testWidgets('closed while the depth is measured: the late depth is let go, the source closed', (tester) async {
      final fake = FakeViewerPositionSource();
      await SettingsRepository.instance.write(SettingsKey.viewerSpatialMoveWith, ViewerPositionKind.head);
      final measured = Completer<SpatialPhotoDepth>();
      await pumpPage(
        tester,
        overrides(
          sources: {ViewerPositionKind.head: () => fake, ViewerPositionKind.mouse: MousePositionSource.new},
          depth: () => measured.future,
        ),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(fake.closed, isTrue);
      final late = map.clone();
      measured.complete(SpatialPhotoDepth(map: late, minimum: 0, range: 1));
      await tester.pump();
      await tester.pump();
      expect(late.debugDisposed, isTrue);
    });
  });

  group('the decode of a 3D sphere of the library', () {
    /// The size the decoder of a photo of the device gives a photo of [width] x [height] for [box] at [dpr]: the box at
    /// the pixel ratio (LocalFullImageProvider.previewTargetSize), covered (image_request.dart, _targetSize), rounded up
    (int, int) decoded(int width, int height, Size box, double dpr) {
      final target = LocalFullImageProvider.previewTargetSize(
        box.width * dpr,
        box.height * dpr,
        width,
        height,
        previewIsFinal: true,
      );
      final scale = math.max(target.width / width, target.height / height);
      return scale >= 1 ? (width, height) : ((width * scale).ceil(), (height * scale).ceil());
    }

    test('at most 4096 pixels on the long side, whatever the shape and the pixel ratio of the window', () {
      for (final (width, height, dpr) in [
        (8192, 4096, 1.0), // VR180 side by side
        (7680, 7680, 1.5), // one above the other, a window at 150 %
        (11520, 2880, 1.25), // a 360° photo side by side
        (5760, 11520, 2.0), // VR180 one above the other
      ]) {
        final (w, h) = decoded(
          width,
          height,
          sphereDecodeBox(width: width, height: height, devicePixelRatio: dpr),
          dpr,
        );
        expect(math.max(w, h), sphereMaxDecodeSide, reason: '$width x $height at $dpr');
        expect(w / h, closeTo(width / height, 0.01), reason: 'the shape kept');
      }
      // A smaller sphere at its own size
      expect(decoded(4000, 4000, sphereDecodeBox(width: 4000, height: 4000, devicePixelRatio: 1.5), 1.5), (4000, 4000));
      // Unknown size: a square box at the pixel ratio
      expect(sphereDecodeBox(width: null, height: 2000, devicePixelRatio: 2), const Size.square(2048));
    });
  });

  group('the viewer of the library', () {
    late SpatialAiWorld world;
    late List<(String, SpatialPhoto)> opened;
    late List<BaseAsset> looked;
    SpatialMadePhoto? known;
    late bool spatial;
    late SphereCoverage? coverage;
    late Map<String, IndexedVersion> versions;
    late bool raw;
    late bool splat;
    late Future<SphereFileFacts> Function() facts;

    setUp(() {
      world = SpatialAiWorld();
      opened = [];
      looked = [];
      known = null;
      spatial = true;
      coverage = null;
      versions = {};
      raw = false;
      splat = false;
      facts = () async => (gpanoCrop: null, estimatedRelief: false);
    });

    tearDown(() => world.dispose());

    final button = find.byKey(const Key('desktop_spatial_photo'));

    Future<ProviderContainer> pumpViewer(
      WidgetTester tester,
      BaseAsset asset, {
      bool equirect = true,
      bool ai = false,
      List<Override> extra = const [],
    }) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      world.enabled = ai;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpConsumerWidget(
        Scaffold(
          appBar: AppBar(actions: [DesktopSpatialPhotoButton(asset: asset)]),
        ),
        overrides: [
          ...world.overrides(),
          appConfigProvider.overrideWithValue(AppConfig(viewer: ViewerConfig(spatial25d: spatial))),
          flatStereoProvider(asset).overrideWith((ref) async => null),
          isEquirectangularProvider(asset).overrideWithValue(equirect),
          rawMediaKindProvider(asset).overrideWithValue(raw ? RawMediaKind.insta360Photo : null),
          splatPhotoHoldsProvider(asset).overrideWithValue(splat),
          sphereCoverageOverrideProvider(asset).overrideWithValue(coverage),
          spatialSphereFileFactsProvider(asset).overrideWith((ref) => facts()),
          generatedVersionsProvider.overrideWith((ref) async => versions),
          // The rule of the dialog for a 360° photo of one eye is aiMonoPanoramaProvider's (conversion_dialog_test)
          aiSourceProvider.overrideWith(
            (ref, source) => source.kind == ConversionKind.stereoPanoramaFromPanorama && source.asset.width == 8000,
          ),
          spatialMadeSphereOfAssetProvider.overrideWithValue((asset) async {
            looked.add(asset);
            return known;
          }),
          spatialMadeVersionOfAssetProvider.overrideWithValue((asset) async => fail('not a flat photo')),
          spatialSharePhotoOpenerProvider.overrideWithValue((context, image, name, photo) => opened.add((name, photo))),
          spatialPhotoOpenerProvider.overrideWithValue(
            (context, asset, layout, estimated) =>
                opened.add((asset.name, (layout: layout, estimatedRelief: estimated))),
          ),
          ...extra,
        ],
      );
      await settleStill(tester);
      return ProviderScope.containerOf(tester.element(find.byType(Scaffold)));
    }

    group('a 360° photo of two eyes', () {
      testWidgets('one above the other, side by side, VR180: offered with the layout of the 360° viewers', (
        tester,
      ) async {
        await pumpViewer(tester, _photo('salon_360.jpg', width: 5760, height: 5760));
        expect(find.byTooltip('Spatial 2.5D'), findsOneWidget);
        await tester.tap(button);
        await pumpViewer(tester, _photo('salon_360_LR.jpg', width: 11520, height: 2880));
        await tester.tap(button);
        await pumpViewer(tester, _photo('lac_VR180.jpg', width: 8000, height: 4000));
        await tester.tap(button);
        coverage = SphereCoverage.half;
        await pumpViewer(tester, _photo('IMG_0001.jpg', width: 6000, height: 3000));
        await tester.tap(button);
        expect(opened, [
          ('salon_360.jpg', (layout: _tbSphere, estimatedRelief: false)),
          ('salon_360_LR.jpg', (layout: _sbsSphere, estimatedRelief: false)),
          ('lac_VR180.jpg', (layout: _vr180, estimatedRelief: false)),
          ('IMG_0001.jpg', (layout: _vr180, estimatedRelief: false)),
        ]);
      });

      testWidgets('the 3D version of a 360° photo the app made: one above the other, its relief estimated by AI', (
        tester,
      ) async {
        final ours = _photo('salon_360_3D.jpg', width: 4096, height: 4096);
        versions = {ours.id: (origin: IndexedOrigin.estimated, kind: ImmersiveKind.stereoPanorama360)};
        await pumpViewer(tester, ours);
        await tester.tap(button);
        expect(opened, [('salon_360_3D.jpg', (layout: _tbSphere, estimatedRelief: true))]);
      });

      testWidgets('a partial panorama is one picture, as the 360° viewer shows it, whatever its shape', (tester) async {
        // A band of the sphere of 8000 x 2000, a 4:1 frame, and a square Photo Sphere of part of it
        facts = () async => (gpanoCrop: const Rect.fromLTWH(0, 0.375, 1, 0.25), estimatedRelief: false);
        await pumpViewer(tester, _photo('PANO_band.jpg', width: 8000, height: 2000));
        expect(button, findsNothing, reason: 'a band of the sphere is no two eyes side by side');
        facts = () async => (gpanoCrop: const Rect.fromLTWH(0.3, 0.2, 0.4, 0.6), estimatedRelief: false);
        await pumpViewer(tester, _photo('PANO_part.jpg', width: 4000, height: 4000));
        expect(button, findsNothing, reason: 'part of the sphere is no two eyes one above the other');
        // The crop tags many cameras write on a full sphere change nothing
        facts = () async => (gpanoCrop: fullSphereCrop, estimatedRelief: false);
        await pumpViewer(tester, _photo('salon_360.jpg', width: 5760, height: 5760));
        await tester.tap(button);
        expect(opened, [('salon_360.jpg', (layout: _tbSphere, estimatedRelief: false))]);
      });

      testWidgets('nothing until the file was read for its crop', (tester) async {
        final reading = Completer<SphereFileFacts>();
        facts = () => reading.future;
        await pumpViewer(tester, _photo('salon_360.jpg', width: 5760, height: 5760));
        expect(button, findsNothing);
        reading.complete((gpanoCrop: null, estimatedRelief: false));
        await settleStill(tester);
        expect(button, findsOneWidget);
      });

      testWidgets('an asset the server edited: the frame of its file decides, as in the 360° viewer', (tester) async {
        // A 3D sphere of 5760 x 5760 the server cropped to 5760 x 2880, and a mono sphere cropped to a square
        const stereoFile = ExifInfo(width: 5760, height: 5760);
        const monoFile = ExifInfo(width: 8000, height: 4000);
        final stereo = RemoteAssetFactory.create(
          width: 5760,
          height: 2880,
          name: 'salon_360.jpg',
        ).copyWith(isEdited: true);
        await pumpViewer(
          tester,
          stereo,
          extra: [assetExifProvider(stereo).overrideWith((ref) => Stream.value(stereoFile))],
        );
        await tester.tap(button);
        expect(opened, [('salon_360.jpg', (layout: _tbSphere, estimatedRelief: false))]);
        final mono = RemoteAssetFactory.create(width: 4000, height: 4000, name: 'lac_360.jpg').copyWith(isEdited: true);
        await pumpViewer(tester, mono, extra: [assetExifProvider(mono).overrideWith((ref) => Stream.value(monoFile))]);
        expect(button, findsNothing, reason: 'a mono sphere the server cropped square is no two eyes');
        // Until its exif is known, nothing
        await pumpViewer(
          tester,
          stereo,
          extra: [assetExifProvider(stereo).overrideWith((ref) => const Stream.empty())],
        );
        expect(button, findsNothing);
      });

      testWidgets('the 3D version made on another computer, on the server only: its packet says the relief is AI', (
        tester,
      ) async {
        final uploaded = RemoteAssetFactory.create(width: 4096, height: 4096, name: 'salon_360_3D.jpg');
        facts = () async => (gpanoCrop: null, estimatedRelief: true);
        await pumpViewer(tester, uploaded);
        await tester.tap(button);
        expect(opened, [('salon_360_3D.jpg', (layout: _tbSphere, estimatedRelief: true))]);
      });

      testWidgets('nothing for a raw photo, a splat photo, with the switch off, nor for a square photo not 360°', (
        tester,
      ) async {
        final square = _photo('salon_360.jpg', width: 5760, height: 5760);
        raw = true;
        await pumpViewer(tester, square);
        expect(button, findsNothing, reason: 'a raw photo of a 360° camera');
        raw = false;
        splat = true;
        await pumpViewer(tester, square);
        expect(button, findsNothing, reason: 'a splat photo');
        splat = false;
        spatial = false;
        await pumpViewer(tester, square);
        expect(button, findsNothing, reason: 'the switch off');
        spatial = true;
        await pumpViewer(tester, square, equirect: false);
        expect(button, findsNothing, reason: 'not 360°');
      });
    });

    group('a 360° photo of one eye', () {
      setUp(() => world.kinds = fakeConversionEngines(stereoPanorama: FakeStereoPanoramaEngine()));

      testWidgets('offered while this computer makes its 3D version, with its own tooltip', (tester) async {
        await pumpViewer(tester, _photo('PANO_0001.jpg'), ai: true);
        expect(find.byTooltip(_convertFirst360), findsOneWidget);
      });

      testWidgets('not with the AI off, without the engine, held back, the gate refusing, nor the switch off', (
        tester,
      ) async {
        final pano = _photo('PANO_0001.jpg');
        await pumpViewer(tester, pano);
        expect(button, findsNothing, reason: 'the AI features off');
        world.kinds = const {};
        await pumpViewer(tester, pano, ai: true);
        expect(button, findsNothing, reason: 'this build does not make the type');
        world.kinds = fakeConversionEngines(stereoPanorama: FakeStereoPanoramaEngine());
        world.held = {AiFeatureGroup.photos};
        await pumpViewer(tester, pano, ai: true);
        expect(button, findsNothing, reason: 'held back');
        world.held = const {};
        world.memory = 2 << 30;
        await pumpViewer(tester, pano, ai: true);
        expect(button, findsNothing, reason: 'not enough memory');
        world.memory = 16 << 30;
        spatial = false;
        await pumpViewer(tester, pano, ai: true);
        expect(button, findsNothing, reason: 'the switch off');
        spatial = true;
        await pumpViewer(tester, _photo('PANO_0002.jpg', width: 6000, height: 3000), ai: true);
        expect(button, findsNothing, reason: 'a photo the type does not take');
      });

      testWidgets('pressed with its 3D version made already: opened at once as a sphere, no dialog, no job', (
        tester,
      ) async {
        known = (image: MemoryImage(Uint8List(0)), name: 'PANO_0001_3D.jpg', layout: spatialMadeSphereLayout);
        final container = await pumpViewer(tester, _photo('PANO_0001.jpg'), ai: true);
        await tester.tap(button);
        await settleStill(tester, until: () => opened.isNotEmpty);
        expect(opened, [('PANO_0001_3D.jpg', (layout: _tbSphere, estimatedRelief: true))]);
        expect(looked.map((asset) => asset.name), ['PANO_0001.jpg']);
        expect(find.byKey(const Key('ai_conversion_dialog')), findsNothing);
        expect(container.read(conversionQueueProvider).jobs, isEmpty);
      });

      testWidgets('pressed without: the dialog of that type alone, Convert, the job, then the sphere on its file', (
        tester,
      ) async {
        world.original('PANO_0001.jpg');
        final container = await pumpViewer(tester, _photo('PANO_0001.jpg'), ai: true);
        await tester.tap(button);
        await settleStill(tester);
        expect(find.byKey(const Key('ai_conversion_dialog')), findsOneWidget);
        expect(find.byKey(const Key('ai_conversion_types')), findsNothing, reason: 'no choice of the type');
        final convert = find.byKey(const Key('ai_conversion_convert'));
        expect(tester.widget<FilledButton>(convert).onPressed, isNotNull);

        await tester.tap(convert);
        await settleStill(tester, until: () => opened.isNotEmpty);
        final job = container.read(conversionQueueProvider).jobs.single;
        expect(job.kind, ConversionKind.stereoPanoramaFromPanorama);
        expect(job.state, ConversionState.done);
        expect(opened.single.$2, (layout: _tbSphere, estimatedRelief: true));
        expect(opened.single.$1, isNot('PANO_0001.jpg'));
        expect(find.byKey(const Key('spatial_conversion_dialog')), findsNothing);
      });
    });
  });
}

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

/// A map of [width] pixels for the uniforms, never drawn
class _FakeImage implements ui.Image {
  _FakeImage(this.width);

  @override
  final int width;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
