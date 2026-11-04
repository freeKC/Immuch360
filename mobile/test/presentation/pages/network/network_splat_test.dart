import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/viewer_config.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/splat/splat_computer.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/splat_viewer_files.dart';
import 'package:immich_mobile/domain/services/splat_viewer_service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/immersive_api.g.dart';
import 'package:immich_mobile/presentation/pages/network/splat.page.dart';
import 'package:immich_mobile/presentation/widgets/splat/splat_button.dart';
import 'package:immich_mobile/providers/ai_immersive/relief_gate.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/network/network_splat.provider.dart';
import 'package:immich_mobile/providers/splat/splat_viewer.provider.dart';

import 'network_viewer_fakes.dart';

/// Records what the immersive viewer is asked to open
class _RecordingImmersiveApi extends ImmersiveApi {
  final List<({String url, String title, String? stereoPair, bool isVideo})> opened = [];

  @override
  Future<bool> isHorizonOs() async => true;

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
  }) async {
    opened.add((url: url, title: title, stereoPair: stereoPair, isVideo: isVideo));
  }
}

/// Records the viewings the splat viewer of a phone or a computer is asked for, and ends each as [endings] say in
/// turn, then as [ending] says. With [answers], the answer each viewing gives in turn ([answering]) is written there
/// for the file, as the service does when the page posts it
class _Viewings implements SplatViewerService {
  final List<({SplatViewerSource source, SplatHead head, int fileBytes, int cap, SplatViewerLook look, bool watch})>
  shown = [];
  SplatViewerOutcome ending = const SplatViewerOutcome(SplatViewerEnd.closed);
  final List<SplatViewerOutcome> endings = [];
  SplatAnswerStore? answers;
  final List<SplatFrameAnswer?> answering = [];

  @override
  Future<SplatViewerOutcome> show({
    required SplatViewerSource source,
    required SplatHead head,
    required int fileBytes,
    required int cap,
    required SplatViewerLook look,
    void Function(SplatPrepareStep step, double done)? progress,
    SplatPrepareCancel? cancel,
    void Function()? onOpening,
    bool watchFrames = false,
  }) async {
    shown.add((source: source, head: head, fileBytes: fileBytes, cap: cap, look: look, watch: watchFrames));
    onOpening?.call();
    final answer = answering.isEmpty ? null : answering.removeAt(0);
    if (answer != null) {
      unawaited(answers?.writeAnswer(source.name, fileBytes, answer));
    }
    return endings.isEmpty ? ending : endings.removeAt(0);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A viewing held at "Preparing 30 %" until [release]; then it opens the viewer unless it was cancelled meanwhile, as
/// the service does
class _HeldViewings implements SplatViewerService {
  final _release = Completer<void>();
  SplatPrepareCancel? cancel;
  bool opened = false;

  void release() => _release.complete();

  @override
  Future<SplatViewerOutcome> show({
    required SplatViewerSource source,
    required SplatHead head,
    required int fileBytes,
    required int cap,
    required SplatViewerLook look,
    void Function(SplatPrepareStep step, double done)? progress,
    SplatPrepareCancel? cancel,
    void Function()? onOpening,
    bool watchFrames = false,
  }) async {
    this.cancel = cancel;
    progress?.call(SplatPrepareStep.reduce, 0.3);
    await Future.any([_release.future, if (cancel != null) cancel.whenCancelled]);
    if (cancel?.isCancelled ?? false) {
      return const SplatViewerOutcome(SplatViewerEnd.cancelled);
    }
    opened = true;
    onOpening?.call();
    return const SplatViewerOutcome(SplatViewerEnd.closed);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _source = NetworkSource(id: 'nas', type: NetworkSourceType.smb, name: 'Home NAS', host: 'nas', share: 'media');

Uint8List _fixture(String name) => File('test/fixtures/splat/$name').readAsBytesSync();

/// The gzip stream of an SPZ of version 3 whose header says [count] points: its head is all the probe reads
Uint8List _spzHead(int count) {
  final header = ByteData(16)
    ..setUint32(0, 0x5053474e, Endian.little)
    ..setUint32(4, 3, Endian.little)
    ..setUint32(8, count, Endian.little)
    ..setUint8(13, 12);
  return Uint8List.fromList(gzip.encode([...header.buffer.asUint8List(), ...List.filled(64, 0)]));
}

void main() {
  late Drift db;
  late StoreService store;
  late MemoryShare share;
  late _RecordingImmersiveApi immersiveApi;

  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    await store.put(StoreKey.networkSources, NetworkSource.encodeList(const [_source]));
    immersiveApi = _RecordingImmersiveApi();
    share = MemoryShare(
      _source,
      files: {
        '/photo.jpg': fakePhoto(),
        '/cash.spz': _fixture('cash_register_head.spz'),
        '/axes.ply': _fixture('axes.ply'),
        '/cube.ply': _fixture('mesh_cube.ply'),
        '/packed.ply': _fixture('compressed.ply'),
        '/cactus.spz': _spzHead(452451),
        '/axes_v4.spz': _fixture('axes_v4.spz'),
        '/notes.txt': fakePhoto(),
      },
    );
    share.folders['/'] = [
      share.file('/axes.ply'),
      share.file('/cash.spz'),
      share.file('/cube.ply'),
      share.file('/notes.txt'),
      share.file('/photo.jpg'),
    ];
  });

  tearDown(() async {
    await store.dispose();
    await db.close();
  });

  List<Override> overrides({
    AppConfig config = const AppConfig(),
    String? flavor = 'quest',
    String device = 'eureka',
    bool storeBuild = false,
  }) => [
    storeServiceProvider.overrideWithValue(store),
    overrideConnections((ref) => FakeConnections(ref, share)),
    isHorizonOsProvider.overrideWith((ref) async => true),
    splatsInThisBuildProvider.overrideWith((ref) async => !storeBuild),
    immersiveApiProvider.overrideWithValue(immersiveApi),
    appConfigProvider.overrideWithValue(config),
    appFlavorProvider.overrideWithValue(flavor),
    reliefDeviceFactsProvider.overrideWith((ref) async => ReliefDeviceFacts(device: device, memoryMiB: 7600)),
  ];

  test('a splat is never a media of the folder, nor sent to the server', () {
    final entry = share.file('/cash.spz');
    expect(entry.isSplatCandidate, isTrue);
    expect(entry.isMedia, isFalse);
    expect(share.file('/photo.jpg').isSplatCandidate, isFalse);
  });

  group('the page of a splat', () {
    Future<void> pumpPage(WidgetTester tester, String path, {List<Override>? with_}) => pumpNetworkRouter(
      tester,
      home: SplatPage(sourceId: _source.id, path: path, size: share.files[path]!.length),
      overrides: with_ ?? overrides(),
    );

    testWidgets('says what the file is and opens it in the immersive viewer with its request', (tester) async {
      await pumpPage(tester, '/cash.spz');

      expect(find.text('cash.spz'), findsWidgets);
      expect(find.text('47,819 gaussians, SPZ version 3'), findsOneWidget);
      expect(find.byKey(splatRefusalKey), findsNothing);
      await tester.tap(find.byKey(exploreSplatButtonKey));
      await tester.pumpAndSettle();

      expect(immersiveApi.opened, hasLength(1));
      final opened = immersiveApi.opened.single;
      expect(opened.isVideo, isFalse);
      expect(opened.url, 'http://127.0.0.1:1234/token/nas/cash.spz');
      expect(jsonDecode(opened.stereoPair!), {
        'kind': 'gaussianSplat',
        'version': 1,
        'format': 'spz',
        'formatVersion': 3,
        'gaussians': 47819,
        'shDegree': 0,
        'fileBytes': 65536,
        'maxGaussians': 50000,
        'tool': null,
        'name': 'cash.spz',
      });
    });

    testWidgets('says that Meta neither supports nor warrants the API of the splats', (tester) async {
      await pumpPage(tester, '/cash.spz');

      expect(
        tester.widget<Text>(find.byKey(const Key('splat_page_disclaimer'))).data,
        'Gaussian splats use an experimental API of the Meta Spatial SDK, which Meta neither supports nor warrants: '
        "any defect is Immuch360's own.",
      );
    });

    testWidgets('a version 4 SPZ says its version and opens like the others', (tester) async {
      // FreeKC's report of 1 November 2026: this file of his kit said the headset does not read version 4
      await pumpPage(tester, '/axes_v4.spz');

      expect(find.text('686 gaussians, SPZ version 4'), findsOneWidget);
      expect(find.byKey(splatRefusalKey), findsNothing);
      await tester.tap(find.byKey(exploreSplatButtonKey));
      await tester.pumpAndSettle();
      final request = jsonDecode(immersiveApi.opened.single.stereoPair!) as Map<String, dynamic>;
      expect(request['formatVersion'], 4);
      expect(request['gaussians'], 686);
    });

    testWidgets('a version 4 SPZ of a share that does not give its size opens too', (tester) async {
      // A WebDAV server without getcontentlength (review of 1 November 2026): the page has no size for the file
      await pumpNetworkRouter(
        tester,
        home: SplatPage(sourceId: _source.id, path: '/axes_v4.spz'),
        overrides: overrides(),
      );

      expect(find.text('686 gaussians, SPZ version 4'), findsOneWidget);
      expect(find.byKey(splatRefusalKey), findsNothing);
      await tester.tap(find.byKey(exploreSplatButtonKey));
      await tester.pumpAndSettle();
      final request = jsonDecode(immersiveApi.opened.single.stereoPair!) as Map<String, dynamic>;
      expect(request['formatVersion'], 4);
      // The headset reads the file again with its real length
      expect(request['fileBytes'], 1);
    });

    testWidgets('a PLY says the tool its comment names', (tester) async {
      await pumpPage(tester, '/axes.ply');

      expect(find.text('686 gaussians, PLY, made with make_splat_fixtures.py'), findsOneWidget);
    });

    testWidgets('a splat beyond the count says the headset keeps its 50,000 strongest gaussians by default', (
      tester,
    ) async {
      await pumpPage(tester, '/cactus.spz');

      expect(find.text('452,451 gaussians, SPZ version 3'), findsOneWidget);
      expect(find.text('The headset keeps its 50,000 strongest gaussians'), findsOneWidget);
      await tester.tap(find.byKey(exploreSplatButtonKey));
      await tester.pumpAndSettle();
      expect(jsonDecode(immersiveApi.opened.single.stereoPair!)['maxGaussians'], 50000);
    });

    testWidgets('with Large splats turned on, the headset keeps 150,000', (tester) async {
      await pumpPage(
        tester,
        '/cactus.spz',
        with_: overrides(config: const AppConfig(viewer: ViewerConfig(largeSplats: true))),
      );

      expect(find.text('The headset keeps its 150,000 strongest gaussians'), findsOneWidget);
      await tester.tap(find.byKey(exploreSplatButtonKey));
      await tester.pumpAndSettle();
      expect(jsonDecode(immersiveApi.opened.single.stereoPair!)['maxGaussians'], 150000);
    });

    FilledButton button(WidgetTester tester) => tester.widget<FilledButton>(find.byKey(exploreSplatButtonKey));

    testWidgets('greys the button with its reason on a Quest 2', (tester) async {
      await pumpPage(tester, '/cash.spz', with_: overrides(device: 'hollywood'));
      expect(button(tester).onPressed, isNull);
      expect(find.text('Gaussian splats need a Meta Quest 3 or 3S'), findsOneWidget);
    });

    testWidgets('greys the button in the build of the Meta Horizon Store, which never reaches this page', (
      tester,
    ) async {
      await pumpPage(tester, '/cash.spz', with_: overrides(storeBuild: true));
      expect(button(tester).onPressed, isNull);
      expect(find.text('Not in this version of the app'), findsOneWidget);
    });

    testWidgets('greys the button with its reason in the phone APK', (tester) async {
      await pumpPage(tester, '/cash.spz', with_: overrides(flavor: null));
      expect(button(tester).onPressed, isNull);
      expect(find.text('Not in this version of the app'), findsOneWidget);
    });

    testWidgets('greys the button with its reason for a compressed PLY', (tester) async {
      await pumpPage(tester, '/packed.ply');
      expect(button(tester).onPressed, isNull);
      expect(find.text('Compressed PLY: export it as .spz or as a standard .ply to open it here'), findsOneWidget);
      expect(immersiveApi.opened, isEmpty);
    });

    group('in the splat viewer of a phone, a tablet or a computer', () {
      late _Viewings viewings;

      setUp(() {
        viewings = _Viewings();
        share.files['/huge.spz'] = _spzHead(5000000);
      });

      /// An Android phone or tablet (Android has said this is no headset), a computer under a Windows target platform,
      /// whose chip and memory are [computer] when given
      List<Override> flat({AppConfig config = const AppConfig(), SplatComputer? computer}) => [
        ...overrides(config: config, flavor: null),
        isHorizonOsProvider.overrideWith((ref) async => false),
        splatViewerServiceProvider.overrideWithValue(viewings),
        if (computer != null) splatComputerReaderProvider.overrideWithValue(() async => computer),
      ];

      testWidgets('Explore opens the file of the share with the cap of a phone, without the words on Meta', (
        tester,
      ) async {
        await pumpPage(tester, '/cash.spz', with_: flat());

        expect(find.text('47,819 gaussians, SPZ version 3'), findsOneWidget);
        expect(find.byKey(const Key('splat_page_disclaimer')), findsNothing);
        expect(find.byKey(splatRefusalKey), findsNothing);
        await tester.tap(find.byKey(exploreSplatButtonKey));
        await tester.pumpAndSettle();

        expect(immersiveApi.opened, isEmpty);
        final viewing = viewings.shown.single;
        expect(viewing.source.sourceId, 'nas');
        expect(viewing.source.path, '/cash.spz');
        expect(viewing.fileBytes, 65536);
        expect(viewing.cap, 150000);
        expect(viewing.look.device, 'phone');
        expect(viewing.look.maxStdDev, closeTo(2.236, 0.001));
        expect(viewing.look.pixelRatioMax, 1);
        expect(viewing.look.texts['countLine'], '47,819 gaussians');
        expect(viewing.look.texts.containsKey('reducedLine'), isFalse);
      });

      testWidgets('a splat above the cap of a phone says what this device keeps, and shows that many', (tester) async {
        await pumpPage(tester, '/cactus.spz', with_: flat());

        expect(find.text('This device keeps its 150,000 strongest gaussians'), findsOneWidget);
        await tester.tap(find.byKey(exploreSplatButtonKey));
        await tester.pumpAndSettle();

        final viewing = viewings.shown.single;
        expect(viewing.cap, 150000);
        expect(viewing.look.texts['countLine'], '150,000 gaussians');
        expect(viewing.look.texts['reducedLine'], 'Reduced to 150,000 of 452,451 gaussians');
      });

      testWidgets('with Large splats, a phone keeps 500,000', (tester) async {
        await pumpPage(
          tester,
          '/cactus.spz',
          with_: flat(config: const AppConfig(viewer: ViewerConfig(largeSplats: true))),
        );

        expect(find.text('This device keeps its 500,000 strongest gaussians'), findsNothing);
        await tester.tap(find.byKey(exploreSplatButtonKey));
        await tester.pumpAndSettle();
        expect(viewings.shown.single.cap, 500000);
      });

      testWidgets('a computer shows up to a million gaussians, with the cut of its own', (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        await pumpPage(tester, '/cactus.spz', with_: flat());

        expect(find.textContaining('strongest gaussians'), findsNothing);
        await tester.tap(find.byKey(exploreSplatButtonKey));
        await tester.pumpAndSettle();
        final viewing = viewings.shown.single;
        expect(viewing.cap, 1000000);
        expect(viewing.look.device, 'computer');
        expect(viewing.look.gyroscope, isFalse);
        expect(viewing.look.maxStdDev, closeTo(2.828, 0.001));
        debugDefaultTargetPlatformOverride = null;
      });

      group('a computer with a dedicated graphics card (lot SVC)', () {
        const rtx = SplatComputer(
          gpu: SplatGpu(SplatGpuKind.dedicated, name: 'NVIDIA GeForce RTX 4060 Laptop GPU', memory: 8188 << 20),
          physicalMemory: 16013 << 20,
        );

        testWidgets('shows a splat of 5 million whole, says so, and its page watches the first frames', (tester) async {
          debugDefaultTargetPlatformOverride = TargetPlatform.windows;
          addTearDown(() => debugDefaultTargetPlatformOverride = null);
          await pumpPage(tester, '/huge.spz', with_: flat(computer: rtx));
          await tester.pumpAndSettle();

          expect(find.textContaining('strongest gaussians'), findsNothing);
          expect(find.byKey(splatRefusalKey), findsNothing);
          await tester.tap(find.byKey(exploreSplatButtonKey));
          await tester.pumpAndSettle();
          final viewing = viewings.shown.single;
          expect(viewing.cap, 5000000);
          expect(viewing.watch, isTrue);
          expect(viewing.look.texts['countLine'], '5,000,000 gaussians');
          expect(viewing.look.texts['wholeLine'], 'Shown whole: all 5,000,000 gaussians');
          expect(viewing.look.texts.containsKey('reducedLine'), isFalse);
          expect(viewing.look.texts['slowReduce'], 'Show {kept} of the {total} gaussians');
          debugDefaultTargetPlatformOverride = null;
        });

        testWidgets('nothing is offered nor refused until the chip is known', (tester) async {
          debugDefaultTargetPlatformOverride = TargetPlatform.windows;
          addTearDown(() => debugDefaultTargetPlatformOverride = null);
          final known = Completer<SplatComputer>();
          await pumpPage(
            tester,
            '/huge.spz',
            with_: [...flat(), splatComputerReaderProvider.overrideWithValue(() => known.future)],
          );
          await tester.pump();

          expect(find.byKey(exploreSplatButtonKey), findsNothing);
          expect(find.byKey(splatRefusalKey), findsNothing, reason: 'never "too large" first');
          known.complete(rtx);
          await tester.pumpAndSettle();
          expect(find.byKey(exploreSplatButtonKey), findsOneWidget);
          expect(find.byKey(splatRefusalKey), findsNothing);
          debugDefaultTargetPlatformOverride = null;
        });

        testWidgets('the reduced copy taken in the page opens at once, not watched again', (tester) async {
          debugDefaultTargetPlatformOverride = TargetPlatform.windows;
          addTearDown(() => debugDefaultTargetPlatformOverride = null);
          viewings.endings.add(const SplatViewerOutcome(SplatViewerEnd.reduce, keep: 1710000));
          await pumpPage(tester, '/huge.spz', with_: flat(computer: rtx));
          await tester.pumpAndSettle();

          await tester.tap(find.byKey(exploreSplatButtonKey));
          await tester.pumpAndSettle();
          expect(viewings.shown.map((viewing) => viewing.cap), [5000000, 1710000]);
          expect(viewings.shown.last.watch, isFalse);
          expect(viewings.shown.last.look.texts['reducedLine'], 'Reduced to 1,710,000 of 5,000,000 gaussians');
          expect(find.byType(SnackBar), findsNothing);
          debugDefaultTargetPlatformOverride = null;
        });

        testWidgets('the answer given in the viewer counts at the next Explore of the same page', (tester) async {
          // Review of 4 November 2026: the page kept the answer it read first, so the reduced copy taken was ignored
          // and the file opened whole and watched again; this is the page the files given to the program open on
          debugDefaultTargetPlatformOverride = TargetPlatform.windows;
          addTearDown(() => debugDefaultTargetPlatformOverride = null);
          // The app's store, its file out of reach in a widget test: the answers stay in its memory
          final answers = SplatAnswerStore(() async => throw const FileSystemException('no support folder'));
          viewings
            ..answers = answers
            ..answering.add(const SplatFrameAnswer.reduce(1710000))
            ..endings.add(const SplatViewerOutcome(SplatViewerEnd.reduce, keep: 1710000));
          await pumpPage(
            tester,
            '/huge.spz',
            with_: [
              ...flat(computer: rtx),
              splatAnswerStoreProvider.overrideWithValue(answers),
            ],
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(exploreSplatButtonKey));
          await tester.pumpAndSettle();
          expect(viewings.shown.map((viewing) => viewing.cap), [5000000, 1710000]);
          expect(find.text('This device keeps its 1,710,000 strongest gaussians'), findsOneWidget);

          await tester.tap(find.byKey(exploreSplatButtonKey));
          await tester.pumpAndSettle();
          expect(viewings.shown.last.cap, 1710000, reason: 'the reduced copy the user took for this file');
          expect(viewings.shown.last.watch, isFalse);
          debugDefaultTargetPlatformOverride = null;
        });

        testWidgets('keep them all is not offered again at the next Explore of the same page', (tester) async {
          debugDefaultTargetPlatformOverride = TargetPlatform.windows;
          addTearDown(() => debugDefaultTargetPlatformOverride = null);
          final answers = SplatAnswerStore(() async => throw const FileSystemException('no support folder'));
          viewings
            ..answers = answers
            ..answering.add(const SplatFrameAnswer.whole());
          await pumpPage(
            tester,
            '/huge.spz',
            with_: [
              ...flat(computer: rtx),
              splatAnswerStoreProvider.overrideWithValue(answers),
            ],
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(exploreSplatButtonKey));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(exploreSplatButtonKey));
          await tester.pumpAndSettle();
          expect(viewings.shown.map((viewing) => (viewing.cap, viewing.watch)), [(5000000, true), (5000000, false)]);
          debugDefaultTargetPlatformOverride = null;
        });

        testWidgets('a file of a share that does not give its size keeps its answer too', (tester) async {
          // Review of 4 November 2026: the answer was written under 0 bytes and read under 1
          debugDefaultTargetPlatformOverride = TargetPlatform.windows;
          addTearDown(() => debugDefaultTargetPlatformOverride = null);
          final answers = SplatAnswerStore(() async => throw const FileSystemException('no support folder'));
          viewings
            ..answers = answers
            ..answering.add(const SplatFrameAnswer.reduce(1710000))
            ..endings.add(const SplatViewerOutcome(SplatViewerEnd.reduce, keep: 1710000));
          await pumpNetworkRouter(
            tester,
            home: SplatPage(sourceId: _source.id, path: '/huge.spz'),
            overrides: [
              ...flat(computer: rtx),
              splatAnswerStoreProvider.overrideWithValue(answers),
            ],
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(exploreSplatButtonKey));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(exploreSplatButtonKey));
          await tester.pumpAndSettle();
          expect(viewings.shown.map((viewing) => viewing.cap), [5000000, 1710000, 1710000]);
          expect(viewings.shown.last.watch, isFalse);
          debugDefaultTargetPlatformOverride = null;
        });

        group('a whole splat that stopped the viewer last time (review of 4 November 2026)', () {
          late SplatAnswerStore answers;

          Future<void> pumpDied(WidgetTester tester) async {
            debugDefaultTargetPlatformOverride = TargetPlatform.windows;
            addTearDown(() => debugDefaultTargetPlatformOverride = null);
            answers = SplatAnswerStore(() async => throw const FileSystemException('no support folder'));
            await answers.writeAnswer(
              'huge.spz',
              share.files['/huge.spz']!.length,
              const SplatFrameAnswer.died(1000000, SplatDeath.memory),
            );
            viewings.answers = answers;
            await pumpPage(
              tester,
              '/huge.spz',
              with_: [
                ...flat(computer: rtx),
                splatAnswerStoreProvider.overrideWithValue(answers),
              ],
            );
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(exploreSplatButtonKey));
            await tester.pumpAndSettle();
            expect(viewings.shown, isEmpty, reason: 'the offer comes first');
            expect(find.text('This splat needed more memory than this device gives it'), findsOneWidget);
          }

          testWidgets('its reduced copy is offered before it opens, and kept once taken', (tester) async {
            await pumpDied(tester);
            await tester.tap(find.text('Show 1,000,000 of the 5,000,000 gaussians'));
            await tester.pumpAndSettle();
            expect(viewings.shown.map((viewing) => (viewing.cap, viewing.watch)), [(1000000, false)]);
            expect(
              await answers.answer('huge.spz', share.files['/huge.spz']!.length),
              const SplatFrameAnswer.reduce(1000000),
            );
            debugDefaultTargetPlatformOverride = null;
          });

          testWidgets('keep them all opens it whole, not watched, and is kept', (tester) async {
            await pumpDied(tester);
            await tester.tap(find.text('Keep them all'));
            await tester.pumpAndSettle();
            expect(viewings.shown.map((viewing) => (viewing.cap, viewing.watch)), [(5000000, false)]);
            expect(await answers.answer('huge.spz', share.files['/huge.spz']!.length), const SplatFrameAnswer.whole());
            debugDefaultTargetPlatformOverride = null;
          });

          testWidgets('the offer dismissed opens nothing', (tester) async {
            await pumpDied(tester);
            await tester.tapAt(const Offset(4, 4));
            await tester.pumpAndSettle();
            expect(viewings.shown, isEmpty);
            debugDefaultTargetPlatformOverride = null;
          });
        });

        testWidgets('a computer with too little memory refuses it with the numbers', (tester) async {
          debugDefaultTargetPlatformOverride = TargetPlatform.windows;
          addTearDown(() => debugDefaultTargetPlatformOverride = null);
          await pumpPage(
            tester,
            '/huge.spz',
            with_: flat(
              computer: const SplatComputer(gpu: SplatGpu(SplatGpuKind.dedicated), physicalMemory: 4 << 30),
            ),
          );
          await tester.pumpAndSettle();

          expect(tester.widget<FilledButton>(find.byKey(exploreSplatButtonKey)).onPressed, isNull);
          expect(
            find.text('Too large for this computer (5,000,000 gaussians): its memory holds about 2,016,372'),
            findsOneWidget,
          );
          debugDefaultTargetPlatformOverride = null;
        });

        testWidgets('the integrated chip keeps 1,000,000, and every gaussian with the setting', (tester) async {
          debugDefaultTargetPlatformOverride = TargetPlatform.windows;
          addTearDown(() => debugDefaultTargetPlatformOverride = null);
          const intel = SplatComputer(gpu: SplatGpu(SplatGpuKind.integrated), physicalMemory: 16013 << 20);
          await pumpPage(
            tester,
            '/cactus.spz',
            with_: flat(
              computer: intel,
              config: const AppConfig(viewer: ViewerConfig(keepAllGaussians: true)),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(exploreSplatButtonKey));
          await tester.pumpAndSettle();
          expect(viewings.shown.single.cap, 452451);
          expect(viewings.shown.single.watch, isTrue);
          debugDefaultTargetPlatformOverride = null;
        });
      });

      group('a splat given to the program (a computer)', () {
        late Directory folder;

        setUp(() => folder = Directory.systemTemp.createTempSync('splat-given'));
        tearDown(() => folder.deleteSync(recursive: true));

        Future<ProviderContainer> pumpGiven(WidgetTester tester, File file, {String? expected}) async {
          debugDefaultTargetPlatformOverride = TargetPlatform.windows;
          addTearDown(() => debugDefaultTargetPlatformOverride = null);
          await pumpNetworkRouter(
            tester,
            home: SplatPage(path: file.path, size: file.lengthSync()),
            overrides: [...flat(), splatExploreAtOnceProvider.overrideWith((ref) => file.path)],
            settle: false,
          );
          // The file is read off the test zone, the page waiting meanwhile
          for (var i = 0; i < 20 && find.byKey(exploreSplatButtonKey).evaluate().isEmpty; i++) {
            await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
            await tester.pump();
          }
          await tester.pumpAndSettle();
          return ProviderScope.containerOf(tester.element(find.byType(SplatPage)));
        }

        testWidgets('opens the scene at once, as a tap does, the page staying under it; once', (tester) async {
          // Plan decision 6: the splat page stays for the files the gate refuses
          final file = File('${folder.path}/axes_v3.spz')..writeAsBytesSync(_fixture('axes_v3.spz'));
          final container = await pumpGiven(tester, file);

          expect(viewings.shown, hasLength(1));
          expect(viewings.shown.single.source.path, file.path);
          expect(viewings.shown.single.source.sourceId, isNull);
          expect(viewings.shown.single.look.device, 'computer');
          expect(viewings.shown.single.look.pixelRatioMax, 2);
          expect(container.read(splatExploreAtOnceProvider), isNull);
          expect(find.byKey(exploreSplatButtonKey), findsOneWidget);
          // Built again, the page opens nothing more
          await tester.pump();
          await tester.pumpAndSettle();
          expect(viewings.shown, hasLength(1));
          debugDefaultTargetPlatformOverride = null;
        });

        testWidgets('a file the gate refuses stays on its page with the reason', (tester) async {
          final file = File('${folder.path}/packed.ply')..writeAsBytesSync(_fixture('compressed.ply'));
          await pumpGiven(tester, file);

          expect(viewings.shown, isEmpty);
          expect(button(tester).onPressed, isNull);
          expect(find.byKey(splatRefusalKey), findsOneWidget);
          debugDefaultTargetPlatformOverride = null;
        });
      });

      testWidgets('on Linux, a window closed without a picture names the variable of WebKitGTK', (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        viewings.ending = const SplatViewerOutcome(SplatViewerEnd.closed, noPicture: true);
        await pumpPage(tester, '/cash.spz', with_: flat());

        await tester.tap(find.byKey(exploreSplatButtonKey));
        await tester.pumpAndSettle();
        expect(
          find.text(
            'The splat viewer drew nothing. With an NVIDIA graphics card, start Immuch360 with '
            'WEBKIT_DISABLE_DMABUF_RENDERER=1',
          ),
          findsOneWidget,
        );
        debugDefaultTargetPlatformOverride = null;
      });

      group('while a splat above the cap is prepared', () {
        late _HeldViewings held;

        Future<void> explore(WidgetTester tester) async {
          held = _HeldViewings();
          await pumpPage(
            tester,
            '/cactus.spz',
            with_: [
              ...overrides(flavor: null),
              isHorizonOsProvider.overrideWith((ref) async => false),
              splatViewerServiceProvider.overrideWithValue(held),
            ],
          );
          await tester.tap(find.byKey(exploreSplatButtonKey));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          expect(find.byKey(const Key('splat_prepare_cancel')), findsOneWidget);
          expect(find.text('Preparing the splat: 30%'), findsOneWidget);
        }

        testWidgets('the system Back cancels the preparation: the dialog goes and the viewer never opens', (
          tester,
        ) async {
          // Review of 2 November 2026: Back hid the dialog, the copy and the reduction went on, then the viewer
          // opened over whatever page the user had gone to
          await explore(tester);

          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();

          expect(held.cancel?.isCancelled, isTrue);
          expect(find.byKey(const Key('splat_prepare_cancel')), findsNothing);
          expect(find.byKey(exploreSplatButtonKey), findsOneWidget, reason: 'the splat page stays');
          held.release();
          await tester.pumpAndSettle();
          expect(held.opened, isFalse);
          expect(find.byType(SnackBar), findsNothing);
        });

        testWidgets('a route change that takes the dialog away stops it the same way', (tester) async {
          // Second review of 3 November 2026: a splat dropped on the window or given by a later start replaces the
          // routes while the dialog shows; the dialog went without a cancel, the reduction went on, and the first
          // viewer opened over the second file's page
          await explore(tester);

          final dialog = ModalRoute.of(tester.element(find.byKey(const Key('splat_prepare_cancel'))))!;
          dialog.navigator!.removeRoute(dialog);
          await tester.pumpAndSettle();

          expect(held.cancel?.isCancelled, isTrue);
          expect(find.byKey(const Key('splat_prepare_cancel')), findsNothing);
          expect(find.byKey(exploreSplatButtonKey), findsOneWidget, reason: 'only the dialog went');
          held.release();
          await tester.pumpAndSettle();
          expect(held.opened, isFalse);
        });

        testWidgets('Cancel stops it the same way', (tester) async {
          await explore(tester);

          await tester.tap(find.byKey(const Key('splat_prepare_cancel')));
          await tester.pumpAndSettle();

          expect(held.cancel?.isCancelled, isTrue);
          expect(find.byKey(const Key('splat_prepare_cancel')), findsNothing);
          held.release();
          await tester.pumpAndSettle();
          expect(held.opened, isFalse);
        });

        testWidgets('left alone, the viewer opens once the splat is ready, and the dialog goes', (tester) async {
          await explore(tester);

          held.release();
          await tester.pumpAndSettle();

          expect(held.cancel?.isCancelled, isFalse);
          expect(held.opened, isTrue);
          expect(find.byKey(const Key('splat_prepare_cancel')), findsNothing);
        });
      });

      testWidgets('a splat beyond what this device can reduce is greyed, in the words of a device', (tester) async {
        await pumpPage(tester, '/huge.spz', with_: flat());

        expect(button(tester).onPressed, isNull);
        expect(find.text('Too large for this device (5,000,000 gaussians)'), findsOneWidget);
      });

      testWidgets('a viewing that ended for want of memory or stalled says so; a Back says nothing', (tester) async {
        viewings.ending = const SplatViewerOutcome(SplatViewerEnd.rendererGone);
        await pumpPage(tester, '/cash.spz', with_: flat());

        await tester.tap(find.byKey(exploreSplatButtonKey));
        await tester.pumpAndSettle();
        expect(find.text('This splat needed more memory than this device gives it'), findsOneWidget);

        await tester.pump(const Duration(seconds: 10));
        await tester.pumpAndSettle();
        viewings.ending = const SplatViewerOutcome(SplatViewerEnd.stalled);
        await tester.tap(find.byKey(exploreSplatButtonKey));
        await tester.pumpAndSettle();
        expect(find.text('The graphics of this device stopped drawing the splat'), findsOneWidget);

        await tester.pump(const Duration(seconds: 10));
        await tester.pumpAndSettle();
        viewings.ending = const SplatViewerOutcome(SplatViewerEnd.closed);
        await tester.tap(find.byKey(exploreSplatButtonKey));
        await tester.pumpAndSettle();
        expect(find.byType(SnackBar), findsNothing);
      });
    });

    testWidgets('a file of a Windows computer is named by its file name, not its whole path', (tester) async {
      await pumpNetworkRouter(
        tester,
        home: const SplatPage(path: r'D:\splats\owner-test\cactus.spz'),
        overrides: overrides(),
        settle: false,
      );
      await tester.pump();

      expect(find.descendant(of: find.byType(AppBar), matching: find.text('cactus.spz')), findsOneWidget);
      expect(find.textContaining(r'D:\splats'), findsNothing);
    });

    testWidgets('a file of the headset opens from where the picker copied it', (tester) async {
      final folder = Directory.systemTemp.createTempSync('splat-page');
      addTearDown(() => folder.deleteSync(recursive: true));
      final file = File('${folder.path}/axes_v3.spz')..writeAsBytesSync(_fixture('axes_v3.spz'));

      await pumpNetworkRouter(
        tester,
        home: SplatPage(path: file.path),
        overrides: overrides(),
        settle: false,
      );
      // The file is read off the test zone, the page waiting meanwhile
      for (var i = 0; i < 20 && find.text('686 gaussians, SPZ version 3').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      await tester.pumpAndSettle();

      expect(find.text('686 gaussians, SPZ version 3'), findsOneWidget);
      await tester.tap(find.byKey(exploreSplatButtonKey));
      await tester.pumpAndSettle();
      expect(immersiveApi.opened.single.url, Uri.file(file.path).toString());
      expect(jsonDecode(immersiveApi.opened.single.stereoPair!)['fileBytes'], file.lengthSync());
    });
  });
}
