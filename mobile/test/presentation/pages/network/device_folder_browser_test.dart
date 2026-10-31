// The share browser on a folder of the device (a folder chosen in the system picker of Android): the same page, tiles,
// viewers and selection bar as for an SMB or WebDAV share, read through DocumentTreeFileSystem.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/device_folder.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/network_video_thumbnail.service.dart';
import 'package:immich_mobile/domain/services/upload_record_store.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/network/document_tree_file_system.dart';
import 'package:immich_mobile/presentation/pages/network/network_browser.page.dart';
import 'package:immich_mobile/presentation/widgets/network/network_media_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/splat/splat_tile.widget.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/media_bridge.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/toast.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:immich_mobile/services/toast.service.dart';
import 'package:mocktail/mocktail.dart';

import '../../../domain/services/video_thumbnail_fakes.dart';
import '../../../fixtures/document_tree.fake.dart';
import '../../../providers/network/fakes.dart';
import '../../../service.mocks.dart';
import 'network_viewer_fakes.dart';

const _treeUri = 'content://com.android.externalstorage.documents/tree/primary%3ADownload%2FQuest';

/// An image that never comes: the tiles stay blank
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

/// The record of the files sent, in memory
class _MemoryRecords extends UploadRecordStore {
  _MemoryRecords() : super(() => throw UnimplementedError('in memory'));

  final Map<String, UploadRecord> records = {};

  @override
  Future<Map<String, UploadRecord>> load() async => records;

  @override
  Future<void> add(NetworkEntry entry, String remoteId, {DateTime? sentAt, bool inTrash = false}) async {
    records[UploadRecordStore.keyOf(entry)] = UploadRecord(remoteId: remoteId, sentAt: DateTime.utc(2026, 10, 31));
  }
}

/// The device folder registered among the import sources, as the list of On this device does before it opens it
class _Sources extends ImportSourcesNotifier {
  _Sources(this.source);

  final NetworkSource source;

  @override
  Map<String, NetworkSource> build() => {source.id: source};
}

class _Toasts extends ToastService {
  final List<String> successes = [];

  @override
  FutureOr<void> success(String message, {ToastOption? toast}) {
    successes.add(message);
  }

  @override
  FutureOr<void> error(String message, {ToastOption? toast}) {}
}

void main() {
  final t = StaticTranslations.instance;
  late FakeDocumentTreeApi api;
  late NetworkSource source;
  late _MemoryRecords records;
  late _Toasts toasts;
  late MockForegroundUploadService uploads;
  late FakeMediaBridge bridge;

  setUpAll(() {
    registerFallbackValue(Completer<void>());
    registerFallbackValue(const SourceUploadCallbacks());
  });

  setUp(() {
    api = FakeDocumentTreeApi(
      {
        '/beach.jpg': fakePhoto(),
        '/pano.jpg': fakePhoto(equirectangularXmp),
        '/trip.mp4': Uint8List(400),
        '/notes.txt': Uint8List(10),
        '/.thumbnails/beach.jpg': Uint8List(10),
        '/Holidays/2026/ride.insv': Uint8List(50),
        '/Holidays/raw.dng': Uint8List(20),
        '/Immuch360-splats/cash.spz': File('test/fixtures/splat/cash_register_head.spz').readAsBytesSync(),
        '/Immuch360-splats/axes.ply': File('test/fixtures/splat/axes.ply').readAsBytesSync(),
        '/Immuch360-splats/cube.ply': File('test/fixtures/splat/mesh_cube.ply').readAsBytesSync(),
      },
      treeUri: _treeUri,
      title: 'Internal shared storage',
      kind: 'internal',
      emptyFolders: {'/Empty'},
    );
    source = deviceFolderSource(treeUri: _treeUri, folderName: 'Quest', kind: 'internal');
    records = _MemoryRecords();
    toasts = _Toasts();
    uploads = MockForegroundUploadService();
    bridge = FakeMediaBridge();
  });

  tearDown(() {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  Finder tileOf(String name) =>
      find.byWidgetPredicate((widget) => widget is NetworkMediaTile && widget.entry.name == name);
  Finder folderTileOf(String name) => find.widgetWithText(NetworkFolderTile, name);
  Finder splatTileOf(String name) =>
      find.byWidgetPredicate((widget) => widget is SplatTile && widget.entry.name == name);

  /// A Meta Quest in a GitHub build, Gaussian splats on as by default
  List<Override> onQuest() => [
    isHorizonOsProvider.overrideWith((ref) async => true),
    splatsInThisBuildProvider.overrideWith((ref) async => true),
  ];

  Future<void> pumpBrowser(
    WidgetTester tester, {
    String path = '/',
    bool hasServer = true,
    List<Override> overrides = const [],
  }) async {
    await pumpNetworkRouter(
      tester,
      home: NetworkBrowserPage(sourceId: source.id, path: path),
      overrides: [
        ...overrides,
        importSourcesProvider.overrideWith(() => _Sources(source)),
        networkFileSystemOpenersProvider.overrideWithValue({
          NetworkSourceType.deviceFolder: (source, _) async => DocumentTreeFileSystem.deviceFolder(source, api),
        }),
        mediaBridgeProvider.overrideWithValue(bridge),
        networkMediaServiceProvider.overrideWithValue(NetworkMediaService()),
        networkThumbnailImageProvider.overrideWithValue(_PendingImage.new),
        networkVideoThumbnailServiceProvider.overrideWith(
          (_) => NetworkVideoThumbnailService(api: FakeVideoThumbnailHost(), retryDelay: Duration.zero),
        ),
        uploadRecordStoreProvider.overrideWithValue(records),
        foregroundUploadServiceProvider.overrideWithValue(uploads),
        toastServiceProvider.overrideWithValue(toasts),
        hasServerProvider.overrideWithValue(hasServer),
        appConfigProvider.overrideWithValue(const AppConfig()),
      ],
    );
  }

  testWidgets('shows every subfolder, then the photos and videos, under the name of the folder chosen', (tester) async {
    await pumpBrowser(tester);

    expect(find.text('Quest'), findsOneWidget);
    for (final name in ['Empty', 'Holidays', 'Immuch360-splats']) {
      expect(folderTileOf(name), findsOneWidget, reason: '$name, with or without media');
    }
    expect(find.byType(NetworkMediaTile), findsNWidgets(3));
    for (final name in ['beach.jpg', 'pano.jpg', 'trip.mp4']) {
      expect(tileOf(name), findsOneWidget, reason: name);
    }
    expect(tileOf('notes.txt'), findsNothing, reason: 'files of other kinds are left out');
    expect(folderTileOf('.thumbnails'), findsNothing, reason: 'hidden folders are left out');
    expect(
      tester.getTopLeft(folderTileOf('Immuch360-splats')).dy,
      lessThan(tester.getTopLeft(tileOf('beach.jpg')).dy),
      reason: 'folders first',
    );
    expect(bridge.registered.keys, [source.id], reason: 'the files play through the media bridge');
  });

  testWidgets('puts the 360° badge on a photo whose head declares it, as on a share', (tester) async {
    await pumpBrowser(tester);

    expect(
      find.descendant(of: tileOf('pano.jpg'), matching: find.byKey(const Key('network_media_360_badge'))),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tileOf('beach.jpg'), matching: find.byKey(const Key('network_media_360_badge'))),
      findsNothing,
    );
  });

  testWidgets('goes into a subfolder and deeper, and back up', (tester) async {
    await pumpBrowser(tester);

    await tester.tap(folderTileOf('Holidays'));
    await tester.pumpAndSettle();
    expect(find.text('Holidays'), findsOneWidget, reason: 'named after its last segment');
    expect(folderTileOf('2026'), findsOneWidget);
    expect(tileOf('raw.dng'), findsOneWidget);

    await tester.tap(folderTileOf('2026'));
    await tester.pumpAndSettle();
    expect(tileOf('ride.insv'), findsOneWidget, reason: 'a raw 360° video of a camera');

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Quest'), findsOneWidget);
  });

  testWidgets('an empty folder says so', (tester) async {
    await pumpBrowser(tester, path: '/Empty');

    expect(find.text(t.network_share_empty_folder), findsOneWidget);
  });

  testWidgets('opens a photo and a video in the viewers of the shares, with the folder around them', (tester) async {
    NetworkFolderMedia? around;
    await pumpNetworkRouter(
      tester,
      home: NetworkBrowserPage(sourceId: source.id, path: '/'),
      pages: {
        NetworkPhotoRoute.name: (data) {
          final args = data.argsAs<NetworkPhotoRouteArgs>();
          around = args.folder;
          return Text('photo ${args.path}');
        },
      },
      overrides: [
        importSourcesProvider.overrideWith(() => _Sources(source)),
        networkFileSystemOpenersProvider.overrideWithValue({
          NetworkSourceType.deviceFolder: (source, _) async => DocumentTreeFileSystem.deviceFolder(source, api),
        }),
        mediaBridgeProvider.overrideWithValue(bridge),
        networkMediaServiceProvider.overrideWithValue(NetworkMediaService()),
        networkThumbnailImageProvider.overrideWithValue(_PendingImage.new),
        networkVideoThumbnailServiceProvider.overrideWith(
          (_) => NetworkVideoThumbnailService(api: FakeVideoThumbnailHost(), retryDelay: Duration.zero),
        ),
        uploadRecordStoreProvider.overrideWithValue(records),
        hasServerProvider.overrideWithValue(true),
        appConfigProvider.overrideWithValue(const AppConfig()),
      ],
    );

    await tester.tap(tileOf('pano.jpg'));
    await tester.pumpAndSettle();
    expect(find.text('photo /pano.jpg'), findsOneWidget);
    expect(around!.entries.map((entry) => entry.name), ['beach.jpg', 'pano.jpg', 'trip.mp4']);
    expect(around!.index, 1, reason: 'previous and next within the folder');
    expect(around!.urls['/trip.mp4'], Uri.parse('http://127.0.0.1:1234/token/${source.id}/trip.mp4'));

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(tileOf('trip.mp4'));
    await tester.pumpAndSettle();
    expect(find.text('video ${source.id} /trip.mp4'), findsOneWidget);
  });

  group('Gaussian splats on a Meta Quest', () {
    testWidgets('lists the splats of the folder after its media, with their badge, never a mesh', (tester) async {
      await pumpBrowser(tester, path: '/Immuch360-splats', overrides: onQuest());

      expect(splatTileOf('cash.spz'), findsOneWidget);
      expect(splatTileOf('axes.ply'), findsOneWidget);
      expect(splatTileOf('cube.ply'), findsNothing, reason: 'a mesh is no splat');
      expect(find.text('3D splat'), findsNWidgets(2));
      expect(find.text('47,819 gaussians'), findsOneWidget);
      expect(find.text(t.network_share_empty_folder), findsNothing);
    });

    testWidgets('opens the page of a splat of the folder', (tester) async {
      await pumpBrowser(tester, path: '/Immuch360-splats', overrides: onQuest());

      await tester.tap(splatTileOf('cash.spz'));
      await tester.pumpAndSettle();

      expect(find.text('splat ${source.id} /Immuch360-splats/cash.spz 65536'), findsOneWidget);
    });

    testWidgets('lists none on a phone', (tester) async {
      await pumpBrowser(
        tester,
        path: '/Immuch360-splats',
        overrides: [isHorizonOsProvider.overrideWith((ref) async => false)],
      );

      expect(find.byType(SplatTile), findsNothing);
    });
  });

  group('upload to Immich', () {
    testWidgets('the selection bar sends the picked files through the upload of the shares', (tester) async {
      final sent = <NetworkUploadItem>[];
      when(
        () => uploads.uploadNetworkFiles(
          any(),
          cancelToken: any(named: 'cancelToken'),
          callbacks: any(named: 'callbacks'),
        ),
      ).thenAnswer((invocation) async {
        final items = invocation.positionalArguments.single as List<NetworkUploadItem>;
        final callbacks = invocation.namedArguments[#callbacks] as SourceUploadCallbacks;
        sent.addAll(items);
        for (final item in items) {
          callbacks.onSuccess?.call(item.id, 'remote-${item.entry.name}', isDuplicate: false);
        }
      });
      await pumpBrowser(tester);

      await tester.longPress(tileOf('beach.jpg'));
      await tester.pumpAndSettle();
      expect(find.text(t.network_upload_selected(count: 1)), findsOneWidget);
      await tester.tap(find.byTooltip(t.network_upload_select_all));
      await tester.pumpAndSettle();
      expect(find.text(t.network_upload_selected(count: 3)), findsOneWidget);
      await tester.tap(tileOf('pano.jpg'));
      await tester.pumpAndSettle();
      expect(find.text(t.network_upload_selected(count: 2)), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, t.network_upload_action));
      await tester.pumpAndSettle();

      expect(sent.map((item) => (item.entry.sourceId, item.entry.path)), [
        (source.id, '/beach.jpg'),
        (source.id, '/trip.mp4'),
      ]);
      expect(sent.map((item) => networkDeviceAssetId(item.entry)), everyElement(startsWith('import-')));
      expect(toasts.successes, [t.network_upload_done(count: 2)]);
      expect(
        find.descendant(of: tileOf('beach.jpg'), matching: find.byKey(const Key('network_media_sent_badge'))),
        findsOneWidget,
      );
    });

    testWidgets('without a server, the selection bar says that one is needed', (tester) async {
      await pumpBrowser(tester, hasServer: false);

      await tester.longPress(tileOf('beach.jpg'));
      await tester.pumpAndSettle();

      expect(find.text(t.network_upload_needs_server), findsOneWidget);
      expect(find.widgetWithText(FilledButton, t.network_upload_action), findsNothing);
    });
  });
}
