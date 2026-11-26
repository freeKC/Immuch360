// The 2.5D photo page of the computers following the recorded head track of the clip
// (test/fixtures/spatial/painted-head-12s.track) through the head tracker's own library: its fake camera "track:"
// goes through the same thread, callback and session as a webcam, then HeadPositionSource, the page's viewpoint and
// the uniform of its shader. No webcam: the build machines have none.
//
// Which library: as head_tracker_native_test.dart (IMMUCH360_HEAD_TRACKER_LIBRARY, else the app's build on Windows,
// else on macOS the code asset of the package's build hook). Without one the test is skipped, unless
// IMMUCH360_REQUIRE_HEAD_TRACKER is 1.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/spatial/head_position_source.dart';
import 'package:immich_mobile/desktop/spatial/head_tracking.dart';
import 'package:immich_mobile/desktop/spatial/spatial_photo_page.dart';
import 'package:immich_mobile/desktop/spatial/spatial_photo_render.dart';
import 'package:immich_mobile/desktop/spatial/spatial_settings.dart';
import 'package:immich_mobile/desktop/spatial/spatial_viewpoint.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immuch_head_tracker/immuch_head_tracker.dart';
import 'package:path/path.dart' as p;

import '../../unit/presentation/presentation_context.dart';

const _track = 'test/fixtures/spatial/painted-head-12s.track';
const _sbs = SpatialPhotoLayout(packing: SpatialPhotoPacking.sideBySide);

String? _library() {
  final given = Platform.environment['IMMUCH360_HEAD_TRACKER_LIBRARY'];
  if (given != null && given.isNotEmpty) {
    return File(given).existsSync() ? p.absolute(given) : null;
  }
  if (Platform.isWindows) {
    final build = Platform.environment['IMMUCH360_BUILD_DIR'];
    for (final dir in [
      if (build != null && build.isNotEmpty) build,
      for (final mode in ['Debug', 'Profile', 'Release']) p.join('build', 'windows', 'x64', 'runner', mode),
    ]) {
      final dll = File(p.join(dir, 'immuch_head_tracker.dll'));
      if (dll.existsSync()) {
        return p.absolute(dll.path);
      }
    }
    return null;
  }
  if (Platform.isMacOS) {
    return NativeHeadTracker.macosAssetPath();
  }
  return null;
}

/// The tracker's library with one camera listed: the recorded track, opened as a webcam is
class _RecordedTrack implements SpatialHeadSource {
  _RecordedTrack(HeadTracker tracker) : _native = NativeSpatialHeadSource(tracker);

  final NativeSpatialHeadSource _native;
  static final camera = HeadCamera(id: 'track:${File(_track).absolute.path}', name: 'recorded track');

  @override
  Future<List<HeadCamera>> cameras() async => [camera];

  @override
  HeadTrackingSession start(HeadCamera camera, {bool colourOnly = false}) =>
      _native.start(camera, colourOnly: colourOnly);
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

Future<ui.Image> _picture(int width, int height, Color color) {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = color);
  return recorder.endRecording().toImage(width, height);
}

void main() {
  final library = _library();
  final required = Platform.environment['IMMUCH360_REQUIRE_HEAD_TRACKER'] == '1';
  if (library == null && required) {
    test('the head tracker library is there', () {
      fail('IMMUCH360_REQUIRE_HEAD_TRACKER is 1 and no head tracker library was found');
    });
    return;
  }
  final skip = library == null ? 'no head tracker library here (see the top of this file)' : null;

  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  testWidgets('the page follows the recorded head track played by the fake camera of the library', (tester) async {
    final frame = await tester.runAsync(() => _picture(64, 16, const Color(0xFF336699)));
    final map = await tester.runAsync(() => _picture(32, 16, const Color(0xFF808080)));
    final program = await tester.runAsync(() => ui.FragmentProgram.fromAsset(spatialPhotoShaderAsset));
    // A small surface at one pixel per point: the shader draws in software here, at each frame
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final source = _RecordedTrack(HeadTracker.load(library));
    final heads = <HeadPositionSource>[];
    await SettingsRepository.instance.write(SettingsKey.viewerSpatialWebcamConsent, true);
    final watch = Stopwatch()..start();

    await tester.pumpTestWidget(
      context,
      SpatialPhotoPage(
        image: _ImageOf(frame!),
        layout: _sbs,
        title: 'salon_3D_LRF_Full_SBS.jpg',
        clock: () => watch.elapsed,
      ),
      overrides: [
        spatialPhotoProgramProvider.overrideWithValue(() async => program!),
        spatialPhotoDepthProvider.overrideWithValue(
          (image, layout) async => SpatialPhotoDepth(map: map!.clone(), minimum: -2, range: 4),
        ),
        spatialHeadSourceProvider.overrideWithValue(source),
        headPositionSourceFactoryProvider.overrideWithValue(() {
          final head = HeadPositionSource(
            store: const AppSpatialSettingsStore(),
            source: source,
            away: ValueNotifier(false),
            observeLifecycle: false,
          );
          heads.add(head);
          return head;
        }),
      ],
      expectSettle: false,
    );

    SpatialPhotoPainter painter() =>
        tester.widget<CustomPaint>(find.byKey(const Key('spatial_photo_canvas'))).painter! as SpatialPhotoPainter;

    // The track's frames come on the tracker's thread in real time; each pump hands them to the page and draws
    final views = <(Duration, double)>[];
    Duration? first;
    var mismatches = 0;
    var checked = 0;
    var turns = 0;
    while (watch.elapsed < const Duration(seconds: 20)) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 1));
      turns++;
      final head = heads.isEmpty ? null : heads.single;
      final latest = head?.latest;
      if (latest == null) {
        continue;
      }
      first ??= watch.elapsed;
      final view = painter().viewpoint.value;
      views.add((watch.elapsed - first, view));
      expect(view, inInclusiveRange(spatialViewpointMin, spatialViewpointMax));
      if (latest.seen && watch.elapsed - first > const Duration(milliseconds: 400)) {
        // The tracker smooths: the view is where the head's position asks, at once
        checked++;
        if ((view - spatialViewpointOf(latest.x)).abs() > 1e-9) {
          mismatches++;
        }
      }
      if (watch.elapsed - first > const Duration(milliseconds: 4200)) {
        break;
      }
    }
    // ignore: avoid_print
    print(
      '2.5D page on the track: $turns turns in ${watch.elapsed.inMilliseconds} ms, ${views.length} views, $checked checked',
    );
    expect(heads, hasLength(1));
    expect(find.byKey(const Key('spatial_camera_indicator')), findsOneWidget, reason: 'the "webcam" is open');
    expect(views, isNotEmpty, reason: 'the track reached the page');
    double low(Duration from, Duration to) =>
        views.where((v) => v.$1 >= from && v.$1 < to).map((v) => v.$2).fold(1.0, (a, b) => a < b ? a : b);
    double high(Duration from, Duration to) =>
        views.where((v) => v.$1 >= from && v.$1 < to).map((v) => v.$2).fold(0.0, (a, b) => a > b ? a : b);
    // The painted head goes to the right of the frame in its first second (the user's left): the view moves towards
    // the left eye; in its third second to the left of the frame, the view towards the right eye
    expect(low(Duration.zero, const Duration(seconds: 2)), lessThan(spatialViewpointCentre - 0.1));
    expect(
      high(const Duration(seconds: 2), const Duration(milliseconds: 4200)),
      greaterThan(spatialViewpointCentre + 0.1),
    );
    expect(checked, greaterThan(10));
    expect(mismatches, 0);
    // ignore: avoid_print
    print(
      'lowest view in the first 2 s ${low(Duration.zero, const Duration(seconds: 2)).toStringAsFixed(3)}, highest '
      'after ${high(const Duration(seconds: 2), const Duration(milliseconds: 4200)).toStringAsFixed(3)}',
    );

    // Closing the page closes the "webcam"
    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 25; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 1));
    }
    await tester.runAsync(() => heads.single.tracking.released.timeout(const Duration(seconds: 10)));
    frame.dispose();
    map!.dispose();
  }, skip: skip != null);
}
