// Previous, next and closing of the immersive viewer of the Meta Quest, as the native viewer asks for them through
// the session: among the assets of a timeline, and among the files of a share folder.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/platform/immersive_api.g.dart';
import 'package:immich_mobile/platform/video_decoder_api.g.dart';
import 'package:immich_mobile/presentation/pages/network/network_browser.page.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_viewer.page.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';
import 'package:immich_mobile/providers/asset_viewer/sphere_coverage.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../../../infrastructure/repository.mock.dart';
import '../../../unit/factories/remote_asset_factory.dart';
import '../../../unit/presentation/presentation_context.dart';

/// What the immersive viewer was asked to show in place, for the request [requestId]
typedef _Shown = ({
  int requestId,
  String url,
  bool isVideo,
  String title,
  ImmersiveStereoLayout layout,
  ImmersiveSphereCoverage coverage,
});

class _RecordingImmersiveApi extends ImmersiveApi {
  /// The URLs the viewer was opened with: none here, navigation never starts the viewer
  final opened = <String>[];

  final shown = <_Shown>[];

  /// The transcoded stream given with each media shown, null for none
  final shownFallbackUrls = <String?>[];

  /// What the viewer answers when asked to show a media: false once it no longer waits for the request
  bool answer = true;

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
  ) async => opened.add(url);

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
  ) async {
    shownFallbackUrls.add(fallbackUrl);
    shown.add((
      requestId: requestId,
      url: url,
      isVideo: isVideo,
      title: title,
      layout: stereoLayout,
      coverage: coverage,
    ));
    return answer;
  }
}

class _MockTimelineService extends Mock implements TimelineService {}

class _NoProbes extends SphericalProbeService {
  _NoProbes()
    : super(
        storage: MockStorageRepository(),
        client: () => throw UnimplementedError('no network in these tests'),
        serverEndpoint: () => null,
        headers: () => const {},
      );

  @override
  Future<SphericalProbe?> probe(BaseAsset asset, {File? localFile}) async => null;
}

/// Records where the asset viewer was asked to go, without a viewer behind it
class _RecordingJump extends AssetViewerJump {
  final calls = <String>[];

  /// What a jump throws, when set
  Error? jumpFailure;

  @override
  Future<void> jumpTo(int index) async {
    calls.add('jump $index');
    final failure = jumpFailure;
    if (failure != null) {
      throw failure;
    }
  }

  @override
  Future<void> recenter() async => calls.add('recenter');
}

class _RecordingVideoPlayer extends VideoPlayerNotifier {
  final calls = <String>[];

  @override
  Future<void> resumeAfterExternalPlayer() async => calls.add('resume');

  @override
  Future<void> resumeAfterExternalPlayerAt(Duration position, {required bool play}) async =>
      calls.add('resume at ${position.inMilliseconds} ${play ? 'playing' : 'paused'}');
}

const _server = PresentationContext.serverEndpoint;

const _fullSphere = (layout: StereoLayout.mono, coverage: SphereCoverage.full, coverageGuess: SphereCoverage.full);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late _RecordingImmersiveApi api;
  late ImmersiveSession session;
  var requestId = 0;
  // The opening the session follows, as the viewer sends it back with its events
  var openingId = 0;

  setUp(() async {
    // The store and the settings, which the URLs and the headers of the server come from
    await PresentationContext.create();
    container = ProviderContainer(overrides: [storeServiceProvider.overrideWithValue(StoreService.I)]);
    api = _RecordingImmersiveApi();
    session = ImmersiveSession();
  });

  tearDown(() async {
    container.dispose();
    await StoreService.I.delete(StoreKey.sphereCoverageOverrides);
  });

  /// The viewer of [opening] (the one started last by default) asks for the media [step] places away, showing the
  /// current one with [coverage]
  Future<bool> request(int step, {ImmersiveSphereCoverage coverage = ImmersiveSphereCoverage.full, int? opening}) =>
      session.requestAdjacent(opening ?? openingId, ++requestId, step, ImmersiveStereoLayout.mono, coverage);

  /// The viewer of [opening] (the one started last by default) closes on the media at [url]
  void close(
    String url, {
    ImmersiveSphereCoverage coverage = ImmersiveSphereCoverage.full,
    int positionMs = 0,
    int? opening,
  }) => session.closed(opening ?? openingId, url, ImmersiveStereoLayout.mono, coverage, positionMs);

  group('ImmersiveSession', () {
    test('has no previous or next, and takes a closing, before anything opened', () async {
      expect(await request(1), isFalse);
      close('anything');
      expect(session.isOpen, isFalse);
    });

    test('gives each opening its own id, and forgets an opening that could not open', () {
      final first = session.start(null);
      final second = session.start(null);
      expect(second, isNot(first));
      expect(session.isCurrent(first), isFalse, reason: 'replaced by the second opening');
      expect(session.isCurrent(second), isTrue);

      session.cancel(first);
      expect(session.isOpen, isTrue, reason: 'not the opening followed');
      session.cancel(second);
      expect(session.isOpen, isFalse);
      expect(session.start(null), isNot(anyOf(first, second)), reason: 'an id is never given twice');
    });
  });

  group('TimelineImmersiveNavigator', () {
    late List<BaseAsset> assets;
    late _MockTimelineService timeline;
    late MockStorageRepository storage;
    late _RecordingJump jump;
    // The remote ids asked to the database at once, and the ones it flags as 360°
    late List<Set<String>> queries;
    late Set<String> flagged;
    Completer<void>? queryGate;

    setUp(() {
      assets = [for (var index = 0; index < 10; index++) RemoteAssetFactory.create(id: 'a$index')];
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
      storage = MockStorageRepository();
      jump = _RecordingJump();
      queries = [];
      flagged = {};
      queryGate = null;
    });

    ImmersiveAssetResolver resolver() => ImmersiveAssetResolver(
      api: api,
      stereoLabels: const {},
      coverageOverrides: container.read(sphereCoverageOverridesProvider.notifier),
      storage: storage,
      probeService: _NoProbes(),
      gpanoClient: MockClient((_) async => http.Response('', 404)),
      // Without a probe, no decoder check: the original plays, with the transcoded stream to fall back to
      videoSources: VideoSourceService(VideoDecoderApi()),
    );

    TimelineImmersiveNavigator open(
      int index, {
      Set<String> forced = const {},
      Set<String> localIds = const {},
      VideoPlayerNotifier? player,
      String? fallbackUrl,
    }) {
      final asset = assets[index];
      final navigator = TimelineImmersiveNavigator(
        resolver: resolver(),
        timeline: timeline,
        asset: asset,
        request: ImmersiveRequest(
          url: 'start',
          isVideo: asset.isVideo,
          title: asset.name,
          view: _fullSphere,
          fallbackUrl: fallbackUrl,
        ),
        index: index,
        forced: forced,
        localIds: localIds,
        equirectangularRemoteIds: (ids) async {
          queries.add(ids.toSet());
          await queryGate?.future;
          return flagged.intersection(ids.toSet());
        },
        jump: jump,
        player: player,
      );
      openingId = session.start(navigator);
      return navigator;
    }

    String originalOf(String id) => '$_server/assets/$id/original?edited=true';

    test('shows the nearest 360° asset each way in place, asking the database once per chunk', () async {
      flagged = {'a4', 'a7'};
      final navigator = open(1);

      expect(await request(1), isTrue);
      expect(api.shown.single, (
        requestId: requestId,
        url: originalOf('a4'),
        isVideo: false,
        title: assets[4].name,
        layout: ImmersiveStereoLayout.mono,
        coverage: ImmersiveSphereCoverage.full,
      ));
      expect(queries, [
        {for (var index = 2; index < 10; index++) 'a$index'},
      ]);
      expect(navigator.currentAsset, assets[4]);

      expect(await request(1), isTrue);
      expect(api.shown.last.url, originalOf('a7'));
      expect(await request(1), isFalse, reason: 'no 360° asset after a7');
      expect(navigator.currentAsset, assets[7]);
      expect(await request(-1), isTrue);
      expect(api.shown.last.url, originalOf('a4'));
      expect(api.shown, hasLength(3));
      expect(api.opened, isEmpty, reason: 'navigation never starts the viewer');
    });

    test('has no previous at the start of the timeline', () async {
      flagged = {'a1'};
      open(0);

      expect(await request(-1), isFalse);
      expect(api.shown, isEmpty);
      expect(queries, isEmpty);
    });

    test('takes every asset of the 360° timeline, without asking the database', () async {
      when(() => timeline.origin).thenReturn(TimelineOrigin.panorama360);
      open(5);

      expect(await request(1), isTrue);
      expect(api.shown.single.url, originalOf('a6'));
      expect(await request(-1), isTrue);
      expect(api.shown.last.url, originalOf('a5'));
      expect(queries, isEmpty);
    });

    test('takes the assets chosen as 360° and those found on the device without asking for them', () async {
      assets[5] = RemoteAssetFactory.create(id: 'a5', localId: 'local-5');
      open(1, forced: {'a3'}, localIds: {'local-5'});

      expect(await request(1), isTrue);
      expect(api.shown.single.url, originalOf('a3'));
      expect(queries.single, isNot(contains('a3')));
      expect(queries.single, isNot(contains('a5')));
      expect(await request(1), isTrue);
      expect(api.shown.last.url, originalOf('a5'));
    });

    test('skips an asset without a file to open', () async {
      assets[3] = LocalAsset(
        id: 'local-3',
        name: 'IMG_3.jpg',
        type: .image,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        playbackStyle: .image,
        isEdited: false,
      );
      when(() => storage.getFileForAsset('local-3')).thenAnswer((_) async => null);
      flagged = {'a6'};
      open(1, forced: {'local-3'});

      expect(await request(1), isTrue);
      expect(api.shown.single.url, originalOf('a6'));
    });

    test('counts an asset as shown only once the viewer says it shows it', () async {
      flagged = {'a4', 'a7'};
      final navigator = open(1);
      api.answer = false;

      expect(await request(1), isFalse, reason: 'the viewer no longer waited for this request');
      expect(navigator.currentAsset, assets[1]);

      api.answer = true;
      expect(await request(1), isTrue);
      expect(api.shown.map((shown) => shown.url), [originalOf('a4'), originalOf('a4')]);
      expect(api.shown.map((shown) => shown.requestId), [requestId - 1, requestId]);
      expect(navigator.currentAsset, assets[4]);
    });

    test('a second request cancels the first, which shows nothing', () async {
      flagged = {'a3', 'a5'};
      queryGate = Completer();
      open(1);

      final first = request(1);
      await pumpEventQueue();
      final second = request(1);
      await pumpEventQueue();
      queryGate!.complete();

      expect(await first, isFalse);
      expect(await second, isTrue);
      expect(api.shown.single.url, originalOf('a3'));
      expect(api.shown.single.requestId, requestId);
    });

    test('gives up at the deadline, and shows nothing afterwards', () async {
      session = ImmersiveSession(searchDeadline: const Duration(milliseconds: 50));
      flagged = {'a4'};
      queryGate = Completer();
      open(1);

      expect(await request(1), isFalse);
      queryGate!.complete();
      await pumpEventQueue();

      expect(api.shown, isEmpty);
    });

    test('shows nothing once the viewer closed during the search', () async {
      flagged = {'a4'};
      queryGate = Completer();
      open(1);

      final result = request(1);
      await pumpEventQueue();
      close('start');
      queryGate!.complete();

      expect(await result, isFalse);
      expect(api.shown, isEmpty);
    });

    test('remembers the coverage picked for an asset when the viewer moves on, and when it closes', () async {
      flagged = {'a4'};
      final player = _RecordingVideoPlayer();
      open(1, player: player);
      final coverages = container.read(sphereCoverageOverridesProvider.notifier);

      expect(await request(1, coverage: ImmersiveSphereCoverage.half), isTrue);
      await pumpEventQueue();
      expect(coverages.get(assets[1]), SphereCoverage.half, reason: 'picked before moving on');

      close(originalOf('a4'), coverage: ImmersiveSphereCoverage.half);
      await pumpEventQueue();

      expect(coverages.get(assets[4]), SphereCoverage.half);
      expect(jump.calls.last, 'jump 4', reason: 'the asset viewer shows the asset shown last');
      expect(player.calls, isEmpty, reason: 'the in-app player stays on the asset the viewer opened on');
      expect(session.isOpen, isFalse);
    });

    test('forgets a coverage picked then taken back on the same asset', () async {
      open(1);
      final coverages = container.read(sphereCoverageOverridesProvider.notifier);

      expect(await request(1, coverage: ImmersiveSphereCoverage.half), isFalse, reason: 'no 360° asset ahead');
      await pumpEventQueue();
      expect(coverages.get(assets[1]), SphereCoverage.half);

      close('start');
      await pumpEventQueue();

      expect(coverages.get(assets[1]), isNull, reason: 'back to the guess');
    });

    test('loads the timeline around the asset viewer again after each search, found or not', () async {
      flagged = {'a4'};
      open(1);

      expect(await request(1), isTrue);
      await pumpEventQueue();
      expect(jump.calls, ['recenter']);
      expect(await request(1), isFalse);
      await pumpEventQueue();
      expect(jump.calls, ['recenter', 'recenter']);
    });

    test('searches from where the asset shown is now after the timeline moved', () async {
      flagged = {'a3', 'a4'};
      open(1);
      expect(await request(1), isTrue);
      expect(api.shown.last.url, originalOf('a3'));
      // A sync adds two assets at the start meanwhile: a3 is at 5 now, a4 at 6
      assets.insertAll(0, [RemoteAssetFactory.create(id: 'new-1'), RemoteAssetFactory.create(id: 'new-2')]);

      expect(await request(1), isTrue);
      expect(api.shown.last.url, originalOf('a4'));
      expect(await request(-1), isTrue);
      expect(api.shown.last.url, originalOf('a3'));
    });

    test('the asset viewer follows the asset shown last to its new index after the timeline moved', () async {
      flagged = {'a4'};
      open(1);
      expect(await request(1), isTrue);
      // A sync adds two assets at the start meanwhile
      assets.insertAll(0, [RemoteAssetFactory.create(id: 'new-1'), RemoteAssetFactory.create(id: 'new-2')]);

      close(originalOf('a4'));
      await pumpEventQueue();

      expect(jump.calls.last, 'jump 6');
    });

    test('gives the video it opened on back to the in-app player where the viewer left it', () async {
      assets[2] = RemoteAssetFactory.create(id: 'a2', type: .video);
      final player = _RecordingVideoPlayer();
      open(2, player: player);

      close('start', positionMs: 42000);
      await pumpEventQueue();

      expect(player.calls, ['resume at 42000 paused']);
      expect(jump.calls, ['jump 2'], reason: 'the same page, the timeline loaded around it');
      expect(container.read(sphereCoverageOverridesProvider.notifier).get(assets[2]), isNull);
    });

    test('attributes the closing to the media the viewer says it showed last', () async {
      assets[2] = RemoteAssetFactory.create(id: 'a2', type: .video);
      flagged = {'a4'};
      final player = _RecordingVideoPlayer();
      open(2, player: player);
      expect(await request(1), isTrue);
      await pumpEventQueue();
      jump.calls.clear();

      // The viewer closed on the video it opened on, as it went on showing it
      close('start', coverage: ImmersiveSphereCoverage.half, positionMs: 7000);
      await pumpEventQueue();

      final coverages = container.read(sphereCoverageOverridesProvider.notifier);
      expect(player.calls, ['resume at 7000 paused']);
      expect(coverages.get(assets[2]), SphereCoverage.half);
      expect(coverages.get(assets[4]), isNull);
      expect(jump.calls, ['jump 2']);
    });

    test('attributes the closing on the transcoded stream the viewer switched to, to the video it opened on', () async {
      assets[2] = RemoteAssetFactory.create(id: 'a2', type: .video);
      final player = _RecordingVideoPlayer();
      open(2, player: player, fallbackUrl: 'start, transcoded');

      close('start, transcoded', positionMs: 42000);
      await pumpEventQueue();

      expect(player.calls, ['resume at 42000 paused']);
      expect(jump.calls, ['jump 2']);
    });

    test('shows a video found with the transcoded stream of the server to fall back to', () async {
      assets[4] = RemoteAssetFactory.create(id: 'a4', type: .video);
      flagged = {'a4'};
      open(1);

      expect(await request(1), isTrue);
      expect(api.shown.single.url, '$_server/assets/a4/original');
      expect(api.shownFallbackUrls, ['$_server/assets/a4/video/playback']);
    });

    test('attributes nothing for a media it did not show', () async {
      assets[2] = RemoteAssetFactory.create(id: 'a2', type: .video);
      final player = _RecordingVideoPlayer();
      open(2, player: player);

      close('somewhere else', coverage: ImmersiveSphereCoverage.half, positionMs: 7000);
      await pumpEventQueue();

      expect(player.calls, isEmpty);
      expect(container.read(sphereCoverageOverridesProvider.notifier).get(assets[2]), isNull);
      expect(jump.calls, ['recenter']);
      expect(session.isOpen, isFalse);
    });

    test('loads the timeline around the asset viewer again when it cannot look for the asset it closed on', () async {
      open(1);
      when(() => timeline.getIndex(any())).thenThrow(StateError('the timeline is gone'));

      close('start');
      await pumpEventQueue();

      expect(jump.calls, ['recenter']);
    });

    test('loads the timeline around the asset viewer again when it cannot move to the asset it closed on', () async {
      open(1);
      jump.jumpFailure = StateError('the asset viewer is gone');

      close('start');
      await pumpEventQueue();

      expect(jump.calls, ['jump 1', 'recenter']);
    });

    test('ignores the requests of an opening it no longer follows, without searching', () async {
      flagged = {'a4'};
      queryGate = Completer();
      final first = open(1);
      final stale = openingId;
      final second = open(1);

      final search = request(1);
      await pumpEventQueue();
      expect(await request(1, opening: stale), isFalse);
      expect(await request(1, opening: openingId + 1), isFalse, reason: 'an opening never started');
      expect(queries, hasLength(1), reason: 'only the search of the opening followed');
      queryGate!.complete();

      expect(await search, isTrue, reason: 'the search of the opening followed goes on');
      expect(api.shown.single.url, originalOf('a4'));
      expect(first.currentAsset, assets[1]);
      expect(second.currentAsset, assets[4]);
    });

    test('ignores the closing of an opening it no longer follows, and keeps following the current one', () async {
      assets[2] = RemoteAssetFactory.create(id: 'a2', type: .video);
      flagged = {'a4'};
      queryGate = Completer();
      final player = _RecordingVideoPlayer();
      open(2, player: player);
      final stale = openingId;
      open(2, player: player);
      final coverages = container.read(sphereCoverageOverridesProvider.notifier);

      final search = request(1);
      await pumpEventQueue();
      // The first viewer closes long after the second one opened in its place
      close('start', coverage: ImmersiveSphereCoverage.half, positionMs: 7000, opening: stale);
      queryGate!.complete();
      await pumpEventQueue();

      expect(await search, isTrue, reason: 'the search of the opening followed goes on');
      expect(session.isOpen, isTrue);
      expect(player.calls, isEmpty);
      expect(coverages.get(assets[2]), isNull);
      expect(jump.calls, ['recenter'], reason: 'only the one after the search');

      close(originalOf('a4'));
      await pumpEventQueue();

      expect(jump.calls.last, 'jump 4');
      expect(session.isOpen, isFalse);
    });

    test('has no previous or next for an asset not found in its timeline', () async {
      flagged = {'a4'};
      final asset = RemoteAssetFactory.create(id: 'elsewhere');
      openingId = session.start(
        TimelineImmersiveNavigator(
          resolver: resolver(),
          timeline: timeline,
          asset: asset,
          request: ImmersiveRequest(url: 'start', isVideo: false, title: asset.name, view: _fullSphere),
          index: null,
          forced: const {},
          localIds: const {},
          equirectangularRemoteIds: (ids) async => flagged,
        ),
      );

      expect(await request(1), isFalse);
      expect(api.shown, isEmpty);
    });
  });

  group('FolderImmersiveNavigator', () {
    const source = NetworkSource(id: 'nas', type: NetworkSourceType.smb, name: 'NAS', host: 'nas', share: 'media');
    final bridge = Uri.parse('http://127.0.0.1:1234/token/nas');
    late Map<String, Uint8List> files;
    late List<String> requested;
    // Paths whose reads never answer
    late Set<String> hanging;

    // A JPEG-like file with [xmp] at its head: enough for the GPano tags
    Uint8List photo([String xmp = '']) =>
        Uint8List.fromList([0xff, 0xd8, ...ascii.encode(xmp), ...List.filled(256, 0)]);
    const equirectangular = '<rdf:Description GPano:ProjectionType="equirectangular"/>';

    setUp(() {
      files = {
        '/a.jpg': photo(),
        '/b_vr180.jpg': photo(equirectangular),
        '/c.mp4': Uint8List(512),
        '/d.jpg': photo(equirectangular),
        '/e.mp4': Uint8List(512),
      };
      requested = [];
      hanging = {};
    });

    // The media bridge, with range requests
    http.Client bridgeClient() => MockClient((request) async {
      final path = request.url.path.substring(bridge.path.length);
      requested.add(path);
      if (hanging.contains(path)) {
        return Completer<http.Response>().future;
      }
      final bytes = files[path];
      if (bytes == null) {
        return http.Response('', 404);
      }
      final range = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(request.headers['range'] ?? '');
      final start = math.min(int.parse(range?.group(1) ?? '0'), bytes.length);
      final end = math.min(int.parse(range?.group(2) ?? '${bytes.length - 1}') + 1, bytes.length);
      return http.Response.bytes(bytes.sublist(start, end), 206);
    });

    List<ImmersiveFolderItem> items() => [
      for (final MapEntry(key: path, value: bytes) in files.entries)
        (
          entry: NetworkEntry(sourceId: source.id, path: path, isDirectory: false, size: bytes.length),
          url: bridge.replace(path: '${bridge.path}$path'),
        ),
    ];

    String urlOf(String path) => '$bridge$path';

    FolderImmersiveNavigator open(
      int index, {
      NetworkMediaService? service,
      VideoPlayerNotifier? player,
      SphereView view = _fullSphere,
      Duration fileTimeout = const Duration(seconds: 5),
    }) {
      final all = items();
      final item = all[index];
      final navigator = FolderImmersiveNavigator(
        api: api,
        service: service ?? NetworkMediaService(),
        client: bridgeClient(),
        items: all,
        index: index,
        request: ImmersiveRequest(
          url: item.url.toString(),
          isVideo: item.entry.isVideo,
          title: item.entry.name,
          view: view,
        ),
        player: player,
        fileTimeout: fileTimeout,
      );
      openingId = session.start(navigator);
      return navigator;
    }

    test('shows the nearest file that declares a 360° projection each way, through the media bridge', () async {
      final navigator = open(0);

      expect(await request(1), isTrue);
      expect(api.shown.single, (
        requestId: requestId,
        url: urlOf('/b_vr180.jpg'),
        isVideo: false,
        title: 'b_vr180.jpg',
        layout: ImmersiveStereoLayout.mono,
        coverage: ImmersiveSphereCoverage.half,
      ));
      expect(navigator.currentEntry.name, 'b_vr180.jpg');

      expect(await request(1), isTrue, reason: 'c.mp4 declares nothing');
      expect(api.shown.last.url, urlOf('/d.jpg'));
      expect(api.shown.last.coverage, ImmersiveSphereCoverage.full);
      expect(await request(1), isFalse);
      expect(await request(-1), isTrue);
      expect(api.shown.last.url, urlOf('/b_vr180.jpg'));
      expect(api.shown, hasLength(3));
      expect(api.opened, isEmpty, reason: 'navigation never starts the viewer');
    });

    test('goes back to the file it opened on as it opened, whatever the file declares', () async {
      // Viewed as 360° from the menu, as 3D by its frame size
      open(
        0,
        view: (layout: StereoLayout.topBottom, coverage: SphereCoverage.half, coverageGuess: SphereCoverage.half),
      );

      expect(await request(1), isTrue);
      expect(api.shown.last.url, urlOf('/b_vr180.jpg'));
      expect(await request(-1), isTrue);
      expect(api.shown.last.url, urlOf('/a.jpg'));
      expect(api.shown.last.layout, ImmersiveStereoLayout.topBottom);
      expect(api.shown.last.coverage, ImmersiveSphereCoverage.half);
      expect(requested, isNot(contains('/a.jpg')), reason: 'the file it opened on is not read');
    });

    test('reads a file once, what it declares being kept', () async {
      final service = NetworkMediaService();
      open(1, service: service);

      expect(await request(1), isTrue);
      final reads = requested.length;
      expect(await request(-1), isTrue);
      expect(api.shown.last.url, urlOf('/b_vr180.jpg'));
      expect(requested, hasLength(reads), reason: 'c.mp4 was read already');
      requested.clear();
      open(1, service: service);
      expect(await request(1), isTrue);
      expect(requested, isEmpty);
    });

    test('skips the files known flat without reading them again', () async {
      final service = NetworkMediaService();
      // The browser read c.mp4 for its thumbnail: the head of its moov box, which declares nothing
      final c = items()[2];
      expect(await service.detect(c.entry, httpRangeReader(bridgeClient(), c.url)), isNotNull);
      requested.clear();
      open(1, service: service);

      expect(await request(1), isTrue);
      expect(api.shown.single.url, urlOf('/d.jpg'));
      expect(requested, isNot(contains('/c.mp4')));
    });

    test('skips a file that takes too long to read', () async {
      hanging = {'/c.mp4'};
      open(1, fileTimeout: const Duration(milliseconds: 50));

      expect(await request(1), isTrue);
      expect(api.shown.single.url, urlOf('/d.jpg'));
    });

    test('gives the video it opened on back to the page player where the viewer left it', () async {
      final player = _RecordingVideoPlayer();
      open(2, player: player);

      close(urlOf('/c.mp4'), positionMs: 5000);

      expect(player.calls, ['resume at 5000 paused']);
    });

    test('leaves the page player alone after the viewer went to another file', () async {
      final player = _RecordingVideoPlayer();
      open(2, player: player);
      expect(await request(1), isTrue);

      close(urlOf('/d.jpg'), positionMs: 5000);

      expect(player.calls, isEmpty);
    });

    test('gives the video back when the viewer says it closed on it, and nothing for a file it did not show', () async {
      final player = _RecordingVideoPlayer();
      open(2, player: player);
      expect(await request(1), isTrue);

      close(urlOf('/c.mp4'), positionMs: 5000);
      expect(player.calls, ['resume at 5000 paused']);

      open(2, player: player);
      close(urlOf('/e.mp4'), positionMs: 6000);
      expect(player.calls, ['resume at 5000 paused']);
    });

    test('leaves the page player alone when an opening it no longer follows closes', () async {
      final player = _RecordingVideoPlayer();
      open(2, player: player);
      final stale = openingId;
      open(2, player: player);

      close(urlOf('/c.mp4'), positionMs: 5000, opening: stale);
      expect(player.calls, isEmpty);
      expect(session.isOpen, isTrue);

      close(urlOf('/c.mp4'), positionMs: 6000);
      expect(player.calls, ['resume at 6000 paused']);
    });
  });

  group('NetworkFolderMedia.around', () {
    NetworkEntry file(String path) => NetworkEntry(sourceId: 'nas', path: path, isDirectory: false, size: 10);
    Uri urlOf(String path) => Uri.parse('http://bridge$path');

    test('gives the media of the folder with their URLs, and the index of the file shown', () {
      final entries = [file('/a.jpg'), file('/b.jpg'), file('/c.mp4')];
      final folder = NetworkFolderMedia(
        entries: entries,
        urls: {for (final e in entries) e.path: urlOf(e.path)},
        index: 1,
      );
      final shown = file('/b.jpg');

      final around = folder.around(shown, urlOf('/b.jpg'));

      expect(around.index, 1);
      expect(around.items.map((item) => item.url), [urlOf('/a.jpg'), urlOf('/b.jpg'), urlOf('/c.mp4')]);
      expect(identical(around.items[1].entry, shown), isTrue, reason: 'the page entry for the file it shows');
    });

    test('finds the file by its path, leaves out the files without a URL, and keeps a file alone', () {
      final entries = [file('/a.jpg'), file('/b.jpg'), file('/c.mp4')];
      final folder = NetworkFolderMedia(
        entries: entries,
        urls: {'/b.jpg': urlOf('/b.jpg'), '/c.mp4': urlOf('/c.mp4')},
        index: 0,
      );

      final around = folder.around(file('/c.mp4'), urlOf('/c.mp4'));
      expect(around.index, 1);
      expect(around.items.map((item) => item.entry.name), ['b.jpg', 'c.mp4']);

      final alone = folder.around(file('/other.jpg'), urlOf('/other.jpg'));
      expect(alone.index, 0);
      expect(alone.items.map((item) => item.entry.name), ['other.jpg']);
    });
  });
}
