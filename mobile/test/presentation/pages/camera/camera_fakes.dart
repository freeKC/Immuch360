// Fakes of what the camera pages use (the contract of lib/domain/services/tapo_camera.dart and the live view API),
// and an app with the camera routes under a real router: the pages are tested without a camera nor a platform view.
// Synthetic values only (MAC 02-00-00-00-00-01, addresses in 192.0.2.0/24).

import 'dart:async';
import 'dart:typed_data';

import 'package:auto_route/auto_route.dart';
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/tapo_camera_info.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/camera_live_api.g.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/network/network_discovery.provider.dart';
import 'package:immich_mobile/providers/tapo/tapo_camera.provider.dart';
import 'package:immich_mobile/providers/tapo/tapo_infrastructure.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/secure_storage.service.dart';
import 'package:mocktail/mocktail.dart';

import '../../../providers/network/fakes.dart';

const cameraId = '0123456789abcdef';
const cameraHost = '192.0.2.30';
const cameraMac = '02-00-00-00-00-01';
const cameraCloudPassword = 'synthetic-cloud-password';
const cameraAccountPassword = 'camera-account-pw';

NetworkSource cameraSource({
  String username = 'viewer',
  TapoCameraInfo? camera = const TapoCameraInfo(model: 'C200', firmware: '1.4.6', zoneId: 'Europe/Brussels'),
  String host = cameraHost,
  String? discoveryId = cameraMac,
}) => NetworkSource(
  id: cameraId,
  type: NetworkSourceType.tapo,
  name: 'Garden',
  host: host,
  username: username,
  useTls: true,
  discoveryId: discoveryId,
  camera: camera,
);

TapoClip fakeClip(int start, int end, {TapoClipKind kind = TapoClipKind.motion, String day = '2026-09-18'}) => TapoClip(
  start: DateTime.fromMillisecondsSinceEpoch(start * 1000, isUtc: true),
  end: DateTime.fromMillisecondsSinceEpoch(end * 1000, isUtc: true),
  videoType: 2,
  kind: kind,
  path: '/$day/$start-$end.mov',
);

/// The recordings of a camera in memory
class FakeTapoRecordings implements TapoRecordings {
  FakeTapoRecordings({
    this.info = const TapoCameraInfo(model: 'C200', firmware: '1.4.6', zoneId: 'Europe/Brussels'),
    this.daysList = const ['2026-09-18', '2026-09-17', '2026-08-30'],
    Map<String, List<TapoClip>>? clipsByDay,
    this.daysError,
    this.clipsError,
  }) : clipsByDay = clipsByDay ?? {};

  @override
  TapoCameraInfo info;
  List<String> daysList;
  final Map<String, List<TapoClip>> clipsByDay;
  Exception? daysError;
  Exception? clipsError;

  TapoCardStatus card = const TapoCardStatus(
    state: TapoCardState.normal,
    status: 'normal',
    usedBytes: 64 * 1024 * 1024 * 1024,
    totalBytes: 128 * 1024 * 1024 * 1024,
  );
  final Set<String> fetched = {};
  final List<String> deleted = [];
  int cacheSize = 0;
  int cleared = 0;
  int detailsCalls = 0;
  final List<bool> daysRefreshes = [];
  final List<String> thumbnailsAsked = [];

  /// The fetch in progress: the test drives it
  Completer<void>? fetching;
  void Function(double progress)? fetchProgress;
  Future<void>? fetchCancel;

  @override
  Future<TapoCameraDetails> details() async {
    detailsCalls++;
    return TapoCameraDetails(
      alias: 'Garden',
      model: info.model ?? 'C200',
      firmware: info.firmware ?? '1.4.6',
      mac: cameraMac,
      zoneId: info.zoneId,
    );
  }

  @override
  Future<TapoCardStatus> cardStatus() async => card;

  @override
  Future<List<String>> days({bool refresh = false}) async {
    daysRefreshes.add(refresh);
    final error = daysError;
    if (error != null) {
      throw error;
    }
    return daysList;
  }

  @override
  Future<List<TapoClip>> clips(String day, {bool refresh = false}) async {
    final error = clipsError;
    if (error != null) {
      throw error;
    }
    return clipsByDay[day] ?? const [];
  }

  @override
  Future<Uint8List?> thumbnail(TapoClip clip) async {
    thumbnailsAsked.add(clip.path);
    return null;
  }

  @override
  bool isFetched(TapoClip clip) => fetched.contains(clip.path);

  @override
  Future<void> fetch(TapoClip clip, {void Function(double progress)? onProgress, Future<void>? cancel}) {
    final completer = fetching = Completer<void>();
    fetchProgress = onProgress;
    fetchCancel = cancel;
    unawaited(
      cancel?.then((_) {
        if (!completer.isCompleted) {
          completer.completeError(const TapoCameraException(TapoErrorKind.cancelled));
        }
      }),
    );
    return completer.future.then((_) => fetched.add(clip.path));
  }

  @override
  Future<void> deleteCopy(TapoClip clip) async {
    deleted.add(clip.path);
    fetched.remove(clip.path);
  }

  @override
  Future<int> cacheBytes() async => cacheSize;

  @override
  Future<void> clearCache() async {
    cleared++;
    cacheSize = 0;
    fetched.clear();
  }
}

/// The live view API: what the pages ask of the platform views
class FakeCameraLiveApi extends Mock implements CameraLiveApi {
  final List<(int, CameraLiveSource)> sources = [];
  final List<(int, bool)> mutes = [];
  final List<int> stops = [];

  @override
  Future<void> setSource(int viewId, CameraLiveSource source) async => sources.add((viewId, source));

  @override
  Future<void> setMuted(int viewId, bool muted) async => mutes.add((viewId, muted));

  @override
  Future<void> stop(int viewId) async => stops.add(viewId);
}

/// A stand in for the platform view: created at once with [cameraViewId]
const cameraViewId = 7;

Widget fakeCameraPlatformView(ValueChanged<int> onCreated) => _FakePlatformView(onCreated: onCreated);

class _FakePlatformView extends StatefulWidget {
  const _FakePlatformView({required this.onCreated});

  final ValueChanged<int> onCreated;

  @override
  State<_FakePlatformView> createState() => _FakePlatformViewState();
}

class _FakePlatformViewState extends State<_FakePlatformView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onCreated(cameraViewId));
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand(key: Key('camera_platform_view'));
}

/// A discovery that finds [servers] at once
NetworkDiscoveryService fakeDiscovery(List<DiscoveredServer> servers) =>
    NetworkDiscoveryService(probes: [(request) => Stream.fromIterable(servers)]);

/// The store and the secure storage of a test, with [sources] stored and the camera's secrets
class CameraTestStorage {
  CameraTestStorage._(this.db, this.store, this.secureStorage);

  static Future<CameraTestStorage> create({
    List<NetworkSource> sources = const [],
    String? cloudPassword = cameraCloudPassword,
    String? accountPassword = cameraAccountPassword,
  }) async {
    final db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    final store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    final secureStorage = FakeSecureStorage();
    final extra = sources.where((source) => !source.type.inLegacyList).toList();
    if (extra.isNotEmpty) {
      await store.put(StoreKey.networkSourcesExtra, NetworkSource.encodeList(extra));
    }
    for (final source in sources) {
      if (cloudPassword != null) {
        secureStorage.values[source.secretKey] = cloudPassword;
      }
      if (accountPassword != null) {
        secureStorage.values[source.cameraSecretKey] = accountPassword;
      }
    }
    return CameraTestStorage._(db, store, secureStorage);
  }

  final Drift db;
  final StoreService store;
  final FakeSecureStorage secureStorage;

  List<NetworkSource> get storedSources => NetworkSource.decodeList(store.tryGet(StoreKey.networkSourcesExtra));

  List<Override> get overrides => [
    storeServiceProvider.overrideWithValue(store),
    secureStorageServiceProvider.overrideWithValue(secureStorage),
  ];

  Future<void> dispose() async {
    await store.dispose();
    await db.close();
  }
}

/// The overrides of the camera pages: [recordings] for every camera, the live view API and its stand in
List<Override> cameraOverrides({
  FakeTapoRecordings? recordings,
  FakeCameraLiveApi? live,
  TapoCameraTester? tester,
  TapoCertificateReader? certificateReader,
  List<DiscoveredServer> found = const [],
  void Function(String sourceId)? forgetRefusals,
}) => [
  // As the real one: nothing without the TP-Link password
  if (recordings != null)
    tapoRecordingsProvider.overrideWith(
      (ref, id) async => await ref.watch(tapoCameraHasCloudPasswordProvider(id).future) ? recordings : null,
    ),
  cameraLiveApiProvider.overrideWithValue(live ?? FakeCameraLiveApi()),
  cameraLivePlatformViewProvider.overrideWithValue(fakeCameraPlatformView),
  tapoCameraTesterProvider.overrideWithValue(tester ?? (request) async => const TapoTestResult()),
  tapoCertificateReaderProvider.overrideWithValue(certificateReader ?? (host) async => null),
  tapoRefusalsForgetterProvider.overrideWithValue(forgetRefusals ?? (_) {}),
  networkDiscoveryServiceProvider.overrideWithValue(fakeDiscovery(found)),
  isHorizonOsProvider.overrideWith((ref) async => false),
];

/// Pumps [home] under a real router whose camera routes render a stub telling where they were opened, or the real
/// page for the routes in [pages]
Future<RootStackRouter> pumpCameraApp(
  WidgetTester tester, {
  required Widget home,
  required List<Override> overrides,
  Map<String, Widget Function(RouteData data)> pages = const {},
}) async {
  // A tall screen: the lists of the pages build everything they hold
  tester.view
    ..physicalSize = const Size(1200, 4000)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  AutoRoute route(String path, String name, Widget Function(RouteData data) stub) => AutoRoute(
    path: path,
    page: PageInfo(name, builder: pages[name] ?? stub),
  );

  final router = RootStackRouter.build(
    routes: [
      AutoRoute(
        path: '/',
        initial: true,
        page: PageInfo('HomeRoute', builder: (_) => home),
      ),
      route('/camera', CameraRoute.name, (data) => Text('camera ${data.argsAs<CameraRouteArgs>().sourceId}')),
      route('/camera-day', CameraDayRoute.name, (data) {
        final args = data.argsAs<CameraDayRouteArgs>();
        return Text('day ${args.sourceId} ${args.day}');
      }),
      route('/camera-edit', CameraEditRoute.name, (data) {
        final args = data.argsAs<CameraEditRouteArgs>(orElse: () => const CameraEditRouteArgs());
        return Text('camera edit ${args.source?.name ?? args.server?.host ?? 'new'}');
      }),
      route('/network-video', NetworkVideoRoute.name, (data) {
        final args = data.argsAs<NetworkVideoRouteArgs>();
        return Text('video ${args.sourceId} ${args.path} ${args.folder == null ? 'alone' : 'in folder'}');
      }),
    ],
  );

  await tester.pumpWidget(
    EasyLocalization(
      supportedLocales: locales.values.toList(),
      path: translationsPath,
      startLocale: locales.values.first,
      fallbackLocale: locales.values.first,
      saveLocale: false,
      useFallbackTranslations: true,
      assetLoader: const CodegenLoader(),
      child: ProviderScope(
        overrides: overrides,
        child: Builder(
          builder: (context) => MaterialApp.router(
            debugShowCheckedModeBanner: false,
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            routerConfig: router.config(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}
