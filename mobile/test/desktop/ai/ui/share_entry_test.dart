// The entries of "Make 3D (AI)" on the pages of a share opened in the app, on a computer: the menu of the page of a
// photo, as the menu of the viewer of a library photo (offered when a type takes the photo, greyed with its reason
// when the gate refuses every type, absent while the AI features are off), and the bar of a selection of the browser,
// next to Upload to Immich, with or without a server. Neither shows on a phone, a TV or a Quest.

import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/desktop_conversion_tools.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/ai/ui/share_conversion.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/network_video_thumbnail.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/upload_record_store.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/pages/network/network_browser.page.dart';
import 'package:immich_mobile/presentation/pages/network/network_photo.page.dart';
import 'package:immich_mobile/presentation/widgets/network/network_media_tile.widget.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';
import 'package:path/path.dart' as p;

import '../../../domain/ai_immersive/stereo_photo_fixtures.dart';
import '../../../domain/services/video_thumbnail_fakes.dart';
import '../../../presentation/pages/network/network_viewer_fakes.dart';
import '../../../presentation/widgets/ai_immersive/fake_ai_components_service.dart';
import '../fakes/fake_gpu_probe.dart';

const _gib = 1 << 30;

/// The files the gate checks, from the states of the fake service
class _GateFiles implements AiComponentFiles {
  _GateFiles(this.service, this.folder);

  final FakeAiComponentsService service;
  final String folder;

  @override
  Future<File?> verifiedFile(AiComponent component) async =>
      stateOf(component) == AiComponentState.installed ? File(p.join(folder, component.id)) : null;

  @override
  AiComponentState stateOf(AiComponent component) => service.statusOf(component).state;
}

/// The record of the files sent, in memory
class _MemoryRecords extends UploadRecordStore {
  _MemoryRecords() : super(() => throw UnimplementedError('in memory'));

  @override
  Future<Map<String, UploadRecord>> load() async => {};
}

/// An image that never comes: the thumbnails stay blank
class _PendingImage extends ImageProvider<_PendingImage> {
  const _PendingImage(this.url);

  final Uri url;

  @override
  Future<_PendingImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_PendingImage key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(Completer<ImageInfo>().future);

  @override
  bool operator ==(Object other) => other is _PendingImage && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

void main() {
  const source = NetworkSource(id: 'nas', type: NetworkSourceType.smb, name: 'Home NAS', host: 'nas.local');
  final t = StaticTranslations.instance;
  late Directory root;
  late Drift db;
  late StoreService store;
  late MemoryShare share;
  late TestMediaServer server;
  late bool enabled;
  late int memory;
  late List<ConversionKind> kinds;
  late List<List<String>> opened;
  late bool launches;
  HttpOverrides? previousOverrides;

  setUpAll(() {
    // Real HTTP to the test bridge: the widget tests answer every request with an error otherwise
    previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
  });

  tearDownAll(() => HttpOverrides.global = previousOverrides);

  setUp(() async {
    root = Directory.systemTemp.createTempSync('share_entry');
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    await store.put(StoreKey.networkSources, NetworkSource.encodeList(const [source]));
    share = MemoryShare(
      source,
      files: {
        '/flat.jpg': fakePhoto(),
        '/pano.jpg': fakePhoto(equirectangularXmp),
        '/cuisine.jpg': fakePhoto(),
        '/clip.mp4': fakePhoto(),
      },
    );
    share.folders['/'] = [share.file('/clip.mp4'), share.file('/cuisine.jpg'), share.file('/flat.jpg')];
    server = await TestMediaServer.start(share);
    enabled = true;
    memory = 16 * _gib;
    kinds = [ConversionKind.sbsFromPhoto, ConversionKind.stereoPanoramaFromPanorama];
    opened = [];
    launches = true;
  });

  tearDown(() async {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await store.dispose();
    await db.close();
    await server.close();
    root.deleteSync(recursive: true);
  });

  List<Override> overrides() {
    final service = FakeAiComponentsService(
      states: {for (final component in aiComponentsFor(AiPlatform.linuxX64)) component: AiComponentState.installed},
    );
    return [
      storeServiceProvider.overrideWithValue(store),
      overrideConnections((ref) => FakeConnections(ref, share, baseUrl: server.baseUrl)),
      isHorizonOsProvider.overrideWith((ref) async => false),
      networkMediaServiceProvider.overrideWith((ref) => NetworkMediaService()),
      uploadRecordStoreProvider.overrideWithValue(_MemoryRecords()),
      networkThumbnailImageProvider.overrideWithValue(_PendingImage.new),
      networkVideoThumbnailServiceProvider.overrideWith(
        (_) => NetworkVideoThumbnailService(api: FakeVideoThumbnailHost(), retryDelay: Duration.zero),
      ),
      aiFeaturesEnabledProvider.overrideWith((ref) => enabled),
      offeredConversionKindsProvider.overrideWith((ref) => kinds),
      aiComponentsServiceProvider.overrideWithValue(service),
      desktopAiGateProvider.overrideWithValue(
        HardwareGate(
          components: _GateFiles(service, root.path),
          facts: () => AiHardwareFacts(abi: Abi.linuxX64, processors: 8, physicalMemory: memory),
          loadRuntime: (path) async => (version: '1.31.0', error: null),
          catalogue: aiComponents,
          heldGroups: aiHeldFeatureGroups,
          gpu: FakeGpuProbe.of(FakeGpuReports.rtx4060),
        ),
      ),
      shareConversionOpenerProvider.overrideWithValue((context, entries) async {
        opened.add([for (final entry in entries) entry.path]);
        return launches;
      }),
    ];
  }

  /// Runs [body] as on a Windows computer
  Future<void> onComputer(Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  /// Lets the reads of the page and of the gate end
  Future<void> settle(WidgetTester tester) async {
    for (var step = 0; step < 20; step++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  }

  Future<void> pumpPhoto(WidgetTester tester, String path, {bool Function()? read}) async {
    await pumpNetworkRouter(
      tester,
      home: NetworkPhotoPage(sourceId: 'nas', path: path),
      settle: false,
      overrides: overrides(),
    );
    await settle(tester);
    if (read != null) {
      await pumpRealIo(tester, read);
    }
  }

  bool shows360Button() => find.byTooltip('360°').evaluate().isNotEmpty;

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byTooltip(t.more));
    await tester.pumpAndSettle();
  }

  group('the menu of the page of a photo of a share', () {
    testWidgets('offers Make 3D (AI) on a computer, which opens the dialog on that photo', (tester) async {
      await onComputer(() async {
        await pumpPhoto(tester, '/flat.jpg');
        await openMenu(tester);

        expect(find.text('Make 3D (AI)'), findsOneWidget);
        await tester.tap(find.text('Make 3D (AI)'));
        await tester.pumpAndSettle();

        expect(opened, [
          ['/flat.jpg'],
        ]);
        await endRealIo(tester);
      });
    });

    testWidgets('a 360° photo has it for its 3D version, and not once this build lacks that type', (tester) async {
      await onComputer(() async {
        await pumpPhoto(tester, '/pano.jpg', read: shows360Button);
        await openMenu(tester);
        expect(find.text('Make 3D (AI)'), findsOneWidget);
        await endRealIo(tester);

        kinds = [ConversionKind.sbsFromPhoto, ConversionKind.sceneFromPhoto];
        await pumpPhoto(tester, '/pano.jpg', read: shows360Button);
        expect(shows360Button(), isTrue, reason: 'its file read through the bridge');
        await openMenu(tester);
        expect(find.text(t.network_upload_action), findsOneWidget);
        expect(find.text('Make 3D (AI)'), findsNothing, reason: 'the flat types leave a 360° photo');
        await endRealIo(tester);
      });
    });

    testWidgets('is greyed with its reason when the gate refuses every type', (tester) async {
      memory = 2 * _gib;
      await onComputer(() async {
        await pumpPhoto(tester, '/flat.jpg');
        await openMenu(tester);

        final item = tester.widget<PopupMenuItem<void>>(find.byKey(const Key('ai_make_3d')));
        expect(item.enabled, isFalse);
        expect(find.text('Not enough memory'), findsOneWidget);
        await endRealIo(tester);
      });
    });

    testWidgets('is absent while the AI features are off, and on a phone', (tester) async {
      enabled = false;
      await onComputer(() async {
        await pumpPhoto(tester, '/flat.jpg');
        await openMenu(tester);
        expect(find.text('Make 3D (AI)'), findsNothing);
        await endRealIo(tester);
      });

      enabled = true;
      await pumpPhoto(tester, '/flat.jpg');
      await openMenu(tester);
      expect(find.text(t.view_as_360), findsOneWidget);
      expect(find.text('Make 3D (AI)'), findsNothing, reason: 'a phone');
      await endRealIo(tester);
    });
  });

  test('the types that take a photo of a share follow the rule of the plan, with what its page read of it', () {
    const all = conversionDialogKinds;
    const entry = NetworkEntry(sourceId: 'nas', path: '/flat.jpg', isDirectory: false, size: 1000);
    const sphere = NetworkEntry(sourceId: 'nas', path: '/beach.jpg', isDirectory: false, size: 1000);
    const flat = [ConversionKind.sbsFromPhoto, ConversionKind.sceneFromPhoto, ConversionKind.panoramaFromPhoto];

    expect(shareConversionKinds(entry, null, all, width: 4000, height: 3000), flat, reason: 'not read yet: flat');
    expect(shareConversionKinds(entry, const NetworkMediaInfo(), all, width: 4000, height: 3000), flat);
    expect(shareConversionKinds(entry, const NetworkMediaInfo(), all, width: 8192, height: 4096), all, reason: '2:1');
    expect(shareConversionKinds(sphere, const NetworkMediaInfo(cameraEquirect: true), all, width: 6000, height: 3000), [
      ConversionKind.stereoPanoramaFromPanorama,
    ]);
    final ours = NetworkMediaInfo(
      stereoPhoto: FlatStereoPhoto(eyes: StereoEyes.full, xmp: ourXmp()),
    );
    expect(shareConversionKinds(entry, ours, all, width: 6000, height: 3000), isEmpty, reason: 'a 3D photo of ours');
    const scene = NetworkMediaInfo(scene: SceneXmp(origin: ImmersiveOrigin.reconstructedFromPhoto));
    expect(shareConversionKinds(entry, scene, all, width: 4000, height: 3000), isEmpty, reason: 'a 3D scene of ours');
    const clip = NetworkEntry(sourceId: 'nas', path: '/clip.mp4', isDirectory: false);
    expect(shareConversionKinds(clip, null, all), isEmpty);
  });

  group('the bar of a selection of the browser', () {
    Future<void> pumpBrowser(WidgetTester tester, {bool server = true}) async {
      if (!server) {
        await store.put(StoreKey.localSession, true);
      }
      await pumpNetworkRouter(
        tester,
        home: const NetworkBrowserPage(sourceId: 'nas', path: '/'),
        overrides: overrides(),
      );
      await settle(tester);
    }

    Finder tileOf(String name) =>
        find.byWidgetPredicate((widget) => widget is NetworkMediaTile && widget.entry.name == name);

    testWidgets('has Make 3D (AI) next to Upload to Immich, on the photos picked', (tester) async {
      await onComputer(() async {
        await pumpBrowser(tester);
        await tester.longPress(tileOf('flat.jpg'));
        await tester.pump();
        await tester.tap(tileOf('cuisine.jpg'));
        await tester.pump();

        expect(find.text(t.network_upload_action), findsOneWidget);
        expect(find.text('Make 3D (AI)'), findsOneWidget);
        await tester.tap(find.text('Make 3D (AI)'));
        await tester.pumpAndSettle();

        expect(opened, [
          ['/cuisine.jpg', '/flat.jpg'],
        ]);
        expect(find.text('Make 3D (AI)'), findsNothing, reason: 'the selection ends once the photos are in the queue');
        await endRealIo(tester);
      });
    });

    testWidgets('keeps the selection when the dialog closes without converting', (tester) async {
      launches = false;
      await onComputer(() async {
        await pumpBrowser(tester);
        await tester.longPress(tileOf('flat.jpg'));
        await tester.pump();
        await tester.tap(find.text('Make 3D (AI)'));
        await tester.pumpAndSettle();

        expect(opened, hasLength(1));
        expect(find.text('Make 3D (AI)'), findsOneWidget);
        await endRealIo(tester);
      });
    });

    testWidgets('has it without a server too, and none for a video alone', (tester) async {
      await onComputer(() async {
        await pumpBrowser(tester, server: false);
        await tester.longPress(tileOf('flat.jpg'));
        await tester.pump();

        expect(find.text(t.network_upload_needs_server), findsOneWidget);
        expect(find.text('Make 3D (AI)'), findsOneWidget);

        await tester.tap(tileOf('flat.jpg'));
        await tester.tap(tileOf('clip.mp4'));
        await tester.pump();
        final button = tester.widget<FilledButton>(find.byKey(const Key('ai_make_3d')));
        expect(button.onPressed, isNull, reason: 'a video alone: nothing to make');
        await endRealIo(tester);
      });
    });

    testWidgets('has nothing more on a phone', (tester) async {
      await pumpBrowser(tester);
      await tester.longPress(tileOf('flat.jpg'));
      await tester.pump();

      expect(find.text(t.network_upload_action), findsOneWidget);
      expect(find.text('Make 3D (AI)'), findsNothing);
      await endRealIo(tester);
    });
  });
}
