// Previous and next on the flat screen of the immersive viewer of the Meta Quest (GitHub issue 19, point 1): what a
// photo of the timeline becomes (flatScreenRequestOf), how a chunk is read four photos at a time, and the navigator of
// a photo opened on the big screen, in 3D or with an AI relief, through the session as the headset asks for them.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/relief_strength.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_pair_requests.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/flat_stereo.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/services/ai_immersive/quest_relief.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/domain/services/apple_spatial/heic_stereo_probe.dart';
import 'package:immich_mobile/domain/services/flat_screen_browse.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/platform/immersive_api.g.dart';
import 'package:immich_mobile/platform/video_decoder_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_viewer.page.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/flat_screen_navigator.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';
import 'package:immich_mobile/providers/asset_viewer/sphere_coverage.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../../../infrastructure/repository.mock.dart';
import '../../../unit/factories/remote_asset_factory.dart';
import '../../../unit/presentation/presentation_context.dart';

/// What the viewer was asked to show in place: the url and the stereoPair JSON
typedef _Shown = ({String url, String? stereoPair});

class _RecordingImmersiveApi extends ImmersiveApi {
  final shown = <_Shown>[];

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
    shown.add((url: url, stereoPair: stereoPair));
    return true;
  }
}

class _MockTimelineService extends Mock implements TimelineService {}

class _RecordingJump extends AssetViewerJump {
  final calls = <String>[];

  @override
  Future<void> jumpTo(int index) async => calls.add('jump $index');

  @override
  Future<void> recenter() async => calls.add('recenter');
}

class _NoProbes extends SphericalProbeService {
  _NoProbes()
    : super(
        storage: MockStorageRepository(),
        client: () => throw UnimplementedError('no network in these tests'),
        serverEndpoint: () => null,
        headers: () => const {},
      );
}

class _NoDecoders extends VideoDecoderApi {}

const _pair = HeicStereoPair(
  primaryItemId: 1,
  leftItemId: 1,
  rightItemId: 2,
  pitmIdOffset: 100,
  pitmIdBytes: 2,
  width: 2000,
  height: 1500,
);

/// The facts of these tests: what each read gives, by asset name, and how many reads ran at once
class _Facts implements FlatScreenBrowseFacts {
  final pairs = <String, HeicStereoPair>{};
  final sideBySides = <String, FlatStereoPhoto>{};
  final scenes = <String>{};
  final splats = <String>{};
  final slow = <String>{};
  final failing = <String>{};
  @override
  bool flat3dByName = true;

  /// The relief of a photo, null while the headset may not make one; the strength the settings say now
  bool reliefAllowed = true;
  ReliefStrength strength = ReliefStrength.normal;
  ReliefViewMode mode = ReliefViewMode.stereo;
  final reliefsAsked = <String>[];

  var running = 0;
  var mostAtOnce = 0;

  Future<T> _read<T>(BaseAsset asset, T value) async {
    running++;
    mostAtOnce = math.max(mostAtOnce, running);
    try {
      if (slow.contains(asset.name)) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      if (failing.contains(asset.name)) {
        throw StateError('read failed');
      }
      await Future<void>.delayed(Duration.zero);
      return value;
    } finally {
      running--;
    }
  }

  @override
  Future<HeicStereoPair?> spatialPair(BaseAsset asset) => _read(asset, pairs[asset.name]);

  @override
  Future<FlatStereoPhoto?> sideBySide(BaseAsset asset) => _read(asset, sideBySides[asset.name]);

  @override
  Future<bool> carriesScene(BaseAsset asset) => _read(asset, scenes.contains(asset.name));

  @override
  Future<bool> isSplat(BaseAsset asset) => _read(asset, splats.contains(asset.name));

  @override
  Future<DepthReliefRequest?> relief(BaseAsset asset) {
    reliefsAsked.add(asset.name);
    return _read(
      asset,
      reliefAllowed
          ? questReliefRequest(
              modelPath: '/models/depth.tflite',
              identity: 'sha1:${asset.name}',
              quarterTurns: 0,
              mode: mode,
              strength: strength,
            )
          : null,
    );
  }
}

const _server = PresentationContext.serverEndpoint;

BaseAsset _photo(String id, {String? name, AssetType type = AssetType.image, int? width, int? height}) =>
    RemoteAssetFactory.create(id: id, name: name ?? '$id.jpg', type: type, width: width, height: height);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('flatScreenRequestOf', () {
    late _Facts facts;

    setUp(() => facts = _Facts());

    Future<FlatScreenChoice> of(BaseAsset asset, {bool relief = false, Duration? timeout}) =>
        flatScreenRequestOf(asset, facts, relief: relief, readTimeout: timeout ?? flatScreenReadTimeout);

    test('skips a video, a splat photo and a photo that carries a scene', () async {
      expect(await of(_photo('v', name: 'clip.mp4', type: AssetType.video)), isA<FlatScreenSkip>());
      final splat = _photo('s', name: 'salon_splat.jpg');
      final scene = _photo('c', name: 'salon_scene3d.jpg');
      facts.splats.add(splat.name);
      facts.scenes.add(scene.name);
      expect(await of(splat), isA<FlatScreenSkip>());
      expect(await of(scene), isA<FlatScreenSkip>(), reason: 'a name like a scene, its packet read: a scene');
    });

    test('a spatial photo becomes heic, a side by side photo sbs, two eyes by name flat3d', () async {
      final spatial = _photo('h', name: 'IMG_0001.HEIC');
      facts.pairs[spatial.name] = _pair;
      expect(await of(spatial), isA<FlatScreenHeic>());

      final sbs = _photo('b', name: 'beach_3D_LRF_Full_SBS.jpg', width: 4000, height: 1500);
      facts.sideBySides[sbs.name] = const FlatStereoPhoto(eyes: StereoEyes.full);
      expect(FlatStereoService.isCandidate(sbs), isTrue);
      expect(await of(sbs), isA<FlatScreenSbs>());

      final stacked = _photo('t', name: 'mountain_TB.jpg');
      expect(await of(stacked), isA<FlatScreenFlat3d>());
      facts.flat3dByName = false;
      expect(await of(stacked), isA<FlatScreenBigScreen>(), reason: '3D told by the file name off');
    });

    test('a HEIF photo without a pair is one picture on the big screen', () async {
      expect(await of(_photo('h', name: 'IMG_0002.heic')), isA<FlatScreenBigScreen>());
    });

    test('any other photo is a relief from a relief opening the headset may make, else the big screen', () async {
      final photo = _photo('p');
      expect(await of(photo), isA<FlatScreenBigScreen>(), reason: 'not a relief opening');
      expect(facts.reliefsAsked, isEmpty, reason: 'nothing of the AI asked for a big screen opening');

      final relief = await of(photo, relief: true);
      expect(relief, isA<FlatScreenRelief>());

      facts.reliefAllowed = false;
      expect(await of(photo, relief: true), isA<FlatScreenBigScreen>(), reason: 'the gate or the model refuses');
    });

    test('the strength and the first view of a relief are read at each photo', () async {
      final first = await of(_photo('p1'), relief: true) as FlatScreenRelief;
      expect(first.request.parallax, ReliefStrength.normal.parallax);
      // Changed in the viewer between two photos (ImmersiveEvents.reliefSettingsChanged)
      facts.strength = ReliefStrength.strong;
      facts.mode = ReliefViewMode.mesh25d;
      final second = await of(_photo('p2'), relief: true) as FlatScreenRelief;
      expect(second.request.parallax, ReliefStrength.strong.parallax);
      expect(second.request.mode, ReliefViewMode.mesh25d);
    });

    test('a slow or failing read gives the big screen, never holds the search', () async {
      final slow = _photo('h1', name: 'IMG_0003.heic');
      final failing = _photo('h2', name: 'IMG_0004.heic');
      facts.pairs[slow.name] = _pair;
      facts.slow.add(slow.name);
      facts.failing.add(failing.name);
      expect(await of(slow, timeout: const Duration(milliseconds: 50)), isA<FlatScreenBigScreen>());
      expect(await of(failing), isA<FlatScreenBigScreen>());
    });
  });

  group('classifyNearestFirst', () {
    test('reads four photos at once, and none past the batch that holds one to show', () async {
      final assets = [for (var i = 0; i < 12; i++) _photo('n$i', name: 'n$i.mp4', type: AssetType.video)];
      assets[5] = _photo('shown');
      final facts = _Facts();
      final classified = <String>[];
      final choices = await classifyNearestFirst(assets, (asset) {
        classified.add(asset.name);
        return flatScreenRequestOf(asset, facts, relief: false);
      });
      expect(classified, [for (var i = 0; i < 8; i++) assets[i].name], reason: 'two batches of four');
      expect(choices[5], isA<FlatScreenBigScreen>());
      expect(choices.sublist(8), everyElement(isNull));
    });

    test('runs the reads of a batch together', () async {
      final facts = _Facts();
      final assets = [for (var i = 0; i < 6; i++) _photo('s$i', name: 'IMG_$i.heic')];
      await classifyNearestFirst(assets, (asset) => flatScreenRequestOf(asset, facts, relief: false));
      expect(facts.mostAtOnce, 4);
    });
  });

  group('FlatScreenImmersiveNavigator', () {
    late ProviderContainer container;
    late _RecordingImmersiveApi api;
    late ImmersiveSession session;
    late List<BaseAsset> assets;
    late _MockTimelineService timeline;
    late _RecordingJump jump;
    late _Facts facts;
    late Set<String> flagged;
    var requestId = 0;
    var openingId = 0;

    setUp(() async {
      await PresentationContext.create();
      container = ProviderContainer(overrides: [storeServiceProvider.overrideWithValue(StoreService.I)]);
      api = _RecordingImmersiveApi();
      session = ImmersiveSession();
      facts = _Facts();
      // A photo, a video, a 360 photo the server flags, a spatial photo, a photo
      assets = [
        _photo('a0'),
        _photo('a1', name: 'clip.mp4', type: AssetType.video),
        _photo('a2', name: 'pano.jpg'),
        _photo('a3', name: 'IMG_0005.HEIC'),
        _photo('a4'),
      ];
      facts.pairs['IMG_0005.HEIC'] = _pair;
      flagged = {assets[2].remoteId!};
      timeline = _MockTimelineService();
      when(() => timeline.origin).thenReturn(TimelineOrigin.main);
      when(() => timeline.totalAssets).thenAnswer((_) => assets.length);
      when(() => timeline.loadAssets(any(), any())).thenAnswer((invocation) async {
        final start = invocation.positionalArguments[0] as int;
        final count = invocation.positionalArguments[1] as int;
        return assets.sublist(start, math.min(assets.length, start + count));
      });
      when(() => timeline.getIndex(any())).thenAnswer((invocation) {
        final index = assets.indexWhere((asset) => asset.heroTag == invocation.positionalArguments[0]);
        return index < 0 ? null : index;
      });
      when(() => timeline.getAssetSafe(any())).thenAnswer((invocation) {
        final index = invocation.positionalArguments[0] as int;
        return index >= 0 && index < assets.length ? assets[index] : null;
      });
      jump = _RecordingJump();
    });

    tearDown(() => container.dispose());

    ImmersiveAssetResolver resolver() => ImmersiveAssetResolver(
      api: api,
      stereoLabels: const {},
      coverageOverrides: container.read(sphereCoverageOverridesProvider.notifier),
      storage: MockStorageRepository(),
      probeService: _NoProbes(),
      gpanoClient: MockClient((_) async => http.Response('', 404)),
      videoSources: VideoSourceService(_NoDecoders()),
    );

    FlatScreenImmersiveNavigator open(int index, {bool relief = false}) {
      final asset = assets[index];
      final navigator = FlatScreenImmersiveNavigator(
        resolver: resolver(),
        timeline: timeline,
        asset: asset,
        request: ImmersiveRequest(
          url: 'start',
          isVideo: false,
          title: asset.name,
          view: (layout: StereoLayout.mono, coverage: SphereCoverage.full, coverageGuess: SphereCoverage.full),
          stereoPair: const StereoPhotoRequest.bigScreen().toImmersiveJson(),
        ),
        index: index,
        classify: (photo) => flatScreenRequestOf(photo, facts, relief: relief),
        forced: const {},
        localIds: const {},
        equirectangularRemoteIds: (ids) async => flagged.intersection(ids.toSet()),
        jump: jump,
      );
      openingId = session.start(navigator);
      return navigator;
    }

    Future<bool> request(int step) =>
        session.requestAdjacent(openingId, ++requestId, step, ImmersiveStereoLayout.mono, ImmersiveSphereCoverage.full);

    String? kindOf(String? stereoPair) =>
        stereoPair == null ? null : (jsonDecode(stereoPair) as Map)['kind'] as String?;

    String urlOf(BaseAsset asset, {required bool edited}) =>
        '$_server/assets/${asset.remoteId}/original?edited=$edited';

    test('next skips the video and the 360 photo: the spatial photo in 3D, then a photo on the big screen', () async {
      final navigator = open(0);

      expect(await request(1), isTrue);
      expect(api.shown.last.url, urlOf(assets[3], edited: false));
      expect(kindOf(api.shown.last.stereoPair), 'heicStereoPair');
      expect(navigator.currentAsset, assets[3]);

      expect(await request(1), isTrue);
      expect(api.shown.last.url, urlOf(assets[4], edited: true), reason: 'a big screen photo shows as the app does');
      expect(kindOf(api.shown.last.stereoPair), 'bigScreen');

      expect(await request(1), isFalse, reason: 'nothing after the last photo');

      expect(await request(-1), isTrue);
      expect(navigator.currentAsset, assets[3], reason: 'previous goes back to the spatial photo');
      expect(await request(-1), isTrue);
      expect(navigator.currentAsset, assets[0]);
      expect(await request(-1), isFalse);
    });

    test('the asset viewer shows the photo shown last once the viewer closes', () async {
      open(0);
      expect(await request(1), isTrue);
      expect(await request(1), isTrue);
      session.closed(openingId, api.shown.last.url, ImmersiveStereoLayout.mono, ImmersiveSphereCoverage.full, 0);
      await pumpEventQueue();
      expect(jump.calls.last, 'jump 4');
    });

    test('from a relief opening the photos come as reliefs at the strength of the settings at that moment', () async {
      open(0, relief: true);
      facts.strength = ReliefStrength.strong;
      expect(await request(1), isTrue);
      expect(kindOf(api.shown.last.stereoPair), 'heicStereoPair', reason: 'a spatial photo keeps its two eyes');
      expect(await request(1), isTrue);
      final json = jsonDecode(api.shown.last.stereoPair!) as Map;
      expect(json['kind'], 'depthRelief');
      expect(json['parallax'], ReliefStrength.strong.parallax);
    });

    test('from a relief opening without the model, the photos go on the big screen', () async {
      facts.reliefAllowed = false;
      open(3, relief: true);
      expect(await request(1), isTrue);
      expect(kindOf(api.shown.last.stereoPair), 'bigScreen');
    });

    test('a viewer opened without a navigator has no previous or next', () async {
      openingId = session.start(null);
      expect(await request(1), isFalse);
      expect(api.shown, isEmpty);
    });
  });

  test('every choice but a skip has its request of the stereo quad', () {
    expect(stereoPhotoRequestOf(const FlatScreenSkip('a video')), isNull);
    expect(stereoPhotoRequestOf(const FlatScreenBigScreen()), isA<BigScreenStereoPhotoRequest>());
    expect(stereoPhotoRequestOf(const FlatScreenHeic(_pair)), isA<HeicStereoPhotoRequest>());
    expect(
      stereoPhotoRequestOf(const FlatScreenFlat3d(Flat3dRequest(FlatStereoFormat.tb))),
      isA<Flat3dStereoPhotoRequest>(),
    );
  });
}
