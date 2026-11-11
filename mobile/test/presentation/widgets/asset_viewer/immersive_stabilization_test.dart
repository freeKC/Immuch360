// The stabilisation of the raw 360° videos in the immersive viewer of the Meta Quest (issue 14, lot d3): what the
// viewer is told before and after it shows a raw video, for an opening and for previous and next, the settings of a
// headset, the builds that stop, the share read without ranges, and the event of the viewer's button.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/raw/stabilization.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_math.dart';
import 'package:immich_mobile/domain/services/raw/raw_360_detection.dart';
import 'package:immich_mobile/domain/services/raw/raw_video_plan.dart';
import 'package:immich_mobile/domain/services/raw/raw_video_stabilization.dart';
import 'package:immich_mobile/domain/services/raw/stabilization.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart' show ByteRangeReader;
import 'package:immich_mobile/platform/immersive_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_stabilization.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';

typedef _Told = ({String url, bool enabled, bool hasTrack, int frames});

/// The viewer: what it is told about the stabilisation, what it opens and shows, all in one list in order
class _Viewer extends ImmersiveApi {
  // Whether showAdjacent shows the media; a test sets false for a viewer that keeps its own
  bool showsAdjacent = true;
  final events = <Object>[];

  List<_Told> get told => events.whereType<_Told>().toList();

  @override
  Future<void> setStabilization(
    String url,
    bool enabled,
    bool hasTrack,
    Int64List? presentationTimesUs,
    Float64List? corrections,
    String? summary,
  ) async {
    expect(corrections?.length ?? 0, 4 * (presentationTimesUs?.length ?? 0));
    events.add((url: url, enabled: enabled, hasTrack: hasTrack, frames: presentationTimesUs?.length ?? 0));
  }

  @override
  Future<void> open(
    String url,
    Map<String, String> headers,
    bool isVideo,
    String title,
    ImmersiveStereoLayout stereoLayout,
    Map<String, String> stereoLabels,
    ImmersiveSphereCoverage coverage,
    int startPositionMs,
    int openingId,
    String? fallbackUrl,
    String? rawProjection,
    String? stereoPair,
    bool reverseThumbstickTurn,
    bool sharpFlatScreens, {
    String? kiosk,
    String? sourceNotice,
    String? sourceRefusal,
    bool gaussianSplats = true,
    int watchMinDurationMs = -1,
    String? startNotice,
  }) async => events.add('open $url');

  @override
  Future<bool> showAdjacent(
    int requestId,
    String url,
    bool isVideo,
    String title,
    ImmersiveStereoLayout stereoLayout,
    ImmersiveSphereCoverage coverage,
    String? fallbackUrl,
    String? rawProjection,
    String? stereoPair, {
    String? sourceNotice,
    String? sourceRefusal,
    int startPositionMs = 0,
    String? startNotice,
  }) async {
    events.add('show $url');
    return showsAdjacent;
  }
}

/// A file of [size] bytes that reads zeros, and whether it reads at any position ([anywhere])
RawVideoInput _input(String name, {bool anywhere = true}) => RawVideoInput(
  name: name,
  key: 'test:$name',
  url: 'http://bridge/$name',
  open: () async => (size: 1000, read: (int offset, int length) async => Uint8List(length), close: () async {}),
  readsAnywhere: () => anywhere,
);

RawVideoPlan _plan(String name, {RawMediaKind kind = RawMediaKind.insta360Video, bool anywhere = true}) {
  final input = _input(name, anywhere: anywhere);
  return RawVideoPlan(
    kind: kind,
    layout: RawVideoLayout.sideBySide,
    tracks: const [RawVideoTrack(file: 0, videoTrack: 0, width: 5760, height: 2880, frameRate: 29.97)],
    calibration: kind == RawMediaKind.insta360Video ? nominalX3(2880) : null,
    url: input.url,
    trackOrderSource: 'single',
    motionTrackInput: input,
  );
}

ImmersiveRequest _video(String name, {RawVideoPlan? plan}) => ImmersiveRequest(
  url: plan?.url ?? 'http://bridge/$name',
  isVideo: true,
  title: name,
  view: raw360SphereView,
  rawProjection: plan?.toNativeJson(),
  rawPlan: plan,
);

StabilizationTable _table(int frames) => StabilizationTable(
  presentationTimesUs: Int64List.fromList([for (var i = 0; i < frames; i++) i * 33367]),
  corrections: Float32List.fromList([
    for (var i = 0; i < frames; i++) ...[1.0, 0.0, 0.0, 0.0],
  ]),
  summary: StabilizationSummary(source: 'test', frames: frames),
);

void main() {
  late _Viewer viewer;
  late ImmersiveSession session;
  // The requests of the builds, and the build of each file, completed by the test
  late List<RawStabilizationRequest> requests;
  late Map<String, Completer<StabilizationTable?>> builds;

  // The build of the file [name], which the test may complete before the build asks for it
  Completer<StabilizationTable?> buildOf(String name) => builds.putIfAbsent(name, Completer.new);

  Future<StabilizationTable?> build(RawStabilizationRequest request, ByteRangeReader read) async {
    requests.add(request);
    // A read, as the readers do: it fails once the media went away
    await read(0, 16);
    final table = await buildOf(request.name).future;
    await read(16, 16);
    return table;
  }

  ImmersiveStabilization stabilization({bool supported = true, bool enabled = true}) =>
      ImmersiveStabilization(api: viewer, session: session, supported: supported, enabled: enabled, build: build);

  setUp(() {
    viewer = _Viewer();
    session = ImmersiveSession();
    requests = [];
    builds = {};
  });

  test(
    'announces a raw video before the viewer opens, then delivers its table built with the headset settings',
    () async {
      final stabilizer = stabilization();
      final request = _video('VID_a.insv', plan: _plan('VID_a.insv'));
      final openingId = session.start(null);

      await openImmersiveRequest(
        viewer,
        request,
        stereoLabels: const {},
        openingId: openingId,
        stabilization: stabilizer,
      );
      buildOf('VID_a.insv').complete(_table(3));
      expect(await stabilizer.lastDelivery, isNotNull);

      expect(viewer.events, [
        (url: request.url, enabled: true, hasTrack: true, frames: 0),
        'open ${request.url}',
        (url: request.url, enabled: true, hasTrack: true, frames: 3),
      ]);
      expect(requests.single.options.headingTimeConstant, 2);
      expect(requests.single.options.headingMaxDegreesPerSecond, 30);
    },
  );

  test('tells the setting off as it is', () async {
    final stabilizer = stabilization(enabled: false);
    final request = _video('VID_a.insv', plan: _plan('VID_a.insv'));
    await stabilizer.around(request, () async => viewer.events.add('open'));
    buildOf('VID_a.insv').complete(_table(2));
    await stabilizer.lastDelivery;
    expect(viewer.told.map((t) => t.enabled), [false, false]);
  });

  test('shows the next media with its own table and stops the build of the one before', () async {
    final stabilizer = stabilization();
    final first = _video('VID_a.insv', plan: _plan('VID_a.insv'));
    final second = _video('VID_b.insv', plan: _plan('VID_b.insv'));
    await openImmersiveRequest(
      viewer,
      first,
      stereoLabels: const {},
      openingId: session.start(null),
      stabilization: stabilizer,
    );
    final firstDelivery = stabilizer.lastDelivery!;

    expect(await showImmersiveRequest(viewer, 7, second, stabilization: stabilizer), isTrue);
    buildOf('VID_b.insv').complete(_table(4));
    await stabilizer.lastDelivery;
    // The first table comes once the viewer moved on: its build stopped at its next read, nothing more is told
    buildOf('VID_a.insv').complete(_table(5));
    expect(await firstDelivery, isNull);

    expect(viewer.events, [
      (url: first.url, enabled: true, hasTrack: true, frames: 0),
      'open ${first.url}',
      (url: second.url, enabled: true, hasTrack: true, frames: 0),
      'show ${second.url}',
      (url: second.url, enabled: true, hasTrack: true, frames: 4),
    ]);
  });

  test('stops the build of a raw video once a photo is shown in its place', () async {
    final stabilizer = stabilization();
    await stabilizer.around(_video('VID_a.insv', plan: _plan('VID_a.insv')), () async => viewer.events.add('open'));
    final firstDelivery = stabilizer.lastDelivery!;

    await showImmersiveRequest(
      viewer,
      9,
      const ImmersiveRequest(url: 'file:///photo.jpg', isVideo: false, title: 'photo', view: raw360SphereView),
      stabilization: stabilizer,
    );
    buildOf('VID_a.insv').complete(_table(3));

    expect(await firstDelivery, isNull);
    expect(viewer.told, hasLength(1), reason: 'the announcement only');
  });

  test('builds no table for a media the viewer did not show, and keeps the build of the one it shows', () async {
    final stabilizer = stabilization();
    final first = _video('VID_a.insv', plan: _plan('VID_a.insv'));
    await stabilizer.around(first, () async => viewer.events.add('open'));
    final firstDelivery = stabilizer.lastDelivery!;
    viewer.showsAdjacent = false;

    final shown = await showImmersiveRequest(
      viewer,
      8,
      _video('VID_b.insv', plan: _plan('VID_b.insv')),
      stabilization: stabilizer,
    );

    expect(shown, isFalse);
    expect(requests.map((r) => r.name), ['VID_a.insv'], reason: 'no build for the media not shown');
    buildOf('VID_a.insv').complete(_table(2));
    expect(await firstDelivery, isNotNull);
    expect(viewer.told.last, (url: first.url, enabled: true, hasTrack: true, frames: 2));
  });

  test('stops the build when the viewer closes, and tells it nothing more', () async {
    final stabilizer = stabilization();
    final request = _video('VID_a.insv', plan: _plan('VID_a.insv'));
    final openingId = session.start(null);
    await openImmersiveRequest(
      viewer,
      request,
      stereoLabels: const {},
      openingId: openingId,
      stabilization: stabilizer,
    );

    session.closed(openingId, request.url, ImmersiveStereoLayout.mono, ImmersiveSphereCoverage.full, 0);
    buildOf('VID_a.insv').complete(_table(3));

    expect(await stabilizer.lastDelivery, isNull);
    expect(viewer.told, hasLength(1));
  });

  test('tells a raw video of a share read without ranges that it has no track, and reads nothing', () async {
    final stabilizer = stabilization();
    final request = _video('VID_a.insv', plan: _plan('VID_a.insv', anywhere: false));

    await stabilizer.around(request, () async => viewer.events.add('open'));

    expect(viewer.events, [(url: request.url, enabled: true, hasTrack: false, frames: 0), 'open']);
    expect(requests, isEmpty);
    expect(stabilizer.lastDelivery, isNull);
  });

  test('tells nothing where the viewer does not stabilise, nor for a plain video or a photo', () async {
    final raw = _video('VID_a.insv', plan: _plan('VID_a.insv'));
    await stabilization(supported: false).around(raw, () async => viewer.events.add('open'));
    final stabilizer = stabilization();
    await stabilizer.around(_video('plain.mp4'), () async => viewer.events.add('open plain'));
    await stabilizer.around(
      const ImmersiveRequest(url: 'file:///photo.jpg', isVideo: false, title: 'photo', view: raw360SphereView),
      () async => viewer.events.add('open photo'),
    );
    expect(viewer.events, ['open', 'open plain', 'open photo']);
    expect(requests, isEmpty);
  });

  test('a press of the button in the viewer stores the setting, whichever opening it came from', () async {
    final stored = <bool>[];
    final followed = ImmersiveSession(
      onStabilizationChanged: (enabled) async {
        stored.add(enabled);
      },
    );
    final openingId = followed.start(null);
    followed.stabilizationChanged(openingId, false);
    followed.stabilizationChanged(openingId - 5, true);
    await Future<void>.delayed(Duration.zero);
    expect(stored, [false, true]);
    // Without a store, nothing happens
    ImmersiveSession().stabilizationChanged(1, true);
  });

  test('the openings carry the labels of the stabilisation for the button and the notices', () {
    final labels = immersiveOpeningLabels(const {});
    for (final key in ['stabilization', 'stabilizationEnabled', 'stabilizationDisabled', 'stabilizationOn']) {
      expect(labels[key], isNotEmpty, reason: key);
    }
    expect(labels['stabilizationNoTrack'], isNotEmpty);
  });

  test('the immersive viewer reads the plan of a raw video: a share and the library give it', () {
    final plan = _plan('VID_a.insv');
    expect(_video('VID_a.insv', plan: plan).rawPlan, same(plan));
    expect(rawVideoHasReadableTrack(plan), isTrue);
    expect(rawVideoHasReadableTrack(_plan('VID_a.insv', anywhere: false)), isFalse);
    expect(StabilizationOptions.headset.toString(), contains('30'));
  });
}
