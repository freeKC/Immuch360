import 'dart:async';
import 'dart:ui' as ui;

import 'package:auto_route/auto_route.dart';
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/plex_server_info.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/network_source_relocator.dart';
import 'package:immich_mobile/domain/services/network_video_thumbnail.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/upload_record_store.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/pages/network/network_browser.page.dart';
import 'package:immich_mobile/presentation/widgets/network/network_media_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/network_upload.widget.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/infrastructure/toast.provider.dart';
import 'package:immich_mobile/providers/network/network_discovery.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:immich_mobile/services/toast.service.dart';
import 'package:mocktail/mocktail.dart';

import '../../../domain/services/spherical_probe_fixtures.dart';
import '../../../domain/services/video_thumbnail_fakes.dart';
import '../../../service.mocks.dart';
import 'network_viewer_fakes.dart';

/// An image that never comes: the thumbnails stay blank, and the test sees which ones were asked for
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

/// Yields [image] once, as a decoded thumbnail would
class _LoadedImage extends ImageProvider<_LoadedImage> {
  const _LoadedImage(this.image, this.id);

  final ui.Image image;
  final int id;

  @override
  Future<_LoadedImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_LoadedImage key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(SynchronousFuture(ImageInfo(image: image.clone())));

  @override
  bool operator ==(Object other) => other is _LoadedImage && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Finds the share at [result] (null: nowhere else), once [answer] completes when set; remembers what it was asked
class _FakeRelocator implements NetworkSourceRelocator {
  final List<NetworkSource> asked = [];
  NetworkSource? result;
  Completer<void>? answer;

  @override
  Future<NetworkSource?> relocate(NetworkSource source, {Duration timeout = const Duration(seconds: 5)}) async {
    asked.add(source);
    await answer?.future;
    return result;
  }
}

/// A share read through its address outside home, or at home, as a Plex server may be
class _RemoteShare extends MemoryShare implements NetworkRemoteEndpoint {
  _RemoteShare(super.source, {super.folders, super.files, required this.isOutsideHome});

  @override
  final bool isOutsideHome;
}

/// The record of the files sent, in memory: widget tests do not wait for real file reads
class _MemoryRecords extends UploadRecordStore {
  _MemoryRecords() : super(() => throw UnimplementedError('in memory'));

  final Map<String, UploadRecord> records = {};

  @override
  Future<Map<String, UploadRecord>> load() async => records;

  @override
  Future<void> add(NetworkEntry entry, String remoteId, {DateTime? sentAt}) async {
    records[UploadRecordStore.keyOf(entry)] = UploadRecord(remoteId: remoteId, sentAt: DateTime.utc(2026, 10, 2));
  }
}

/// The toasts shown
class _Toasts extends ToastService {
  final List<String> successes = [];
  final List<String> errors = [];

  @override
  FutureOr<void> success(String message, {ToastOption? toast}) {
    successes.add(message);
  }

  @override
  FutureOr<void> error(String message, {ToastOption? toast}) {
    errors.add(message);
  }
}

void main() {
  late Drift db;
  late StoreService store;
  late MemoryShare share;
  late FakeConnections connections;
  late List<Uri> thumbnails;
  late FakeVideoThumbnailHost videoHost;
  late Completer<void>? photosLoading;
  late _MemoryRecords records;
  late _Toasts toasts;
  late MockForegroundUploadService uploads;

  setUpAll(() {
    registerFallbackValue(Completer<void>());
    registerFallbackValue(const SourceUploadCallbacks());
  });

  const source = NetworkSource(
    id: 'nas',
    type: NetworkSourceType.smb,
    name: 'Home NAS',
    host: 'nas.local',
    share: 'media',
  );

  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    await store.put(StoreKey.networkSources, NetworkSource.encodeList(const [source]));
    thumbnails = [];
    videoHost = FakeVideoThumbnailHost();
    photosLoading = null;
    records = _MemoryRecords();
    toasts = _Toasts();
    uploads = MockForegroundUploadService();
    share = MemoryShare(
      source,
      files: {
        '/pano.jpg': fakePhoto(equirectangularXmp),
        '/flat.jpg': fakePhoto(),
        '/trip.mp4': mp4File(
          mp4Moov([
            mp4VideoTrack([mp4Sv3dEquirectangular()]),
          ]),
        ),
        '/notes.txt': fakePhoto(),
        '/Holidays/beach.jpg': fakePhoto(),
      },
    );
    share.folders['/'] = [
      share.folder('/Holidays'),
      share.folder('/Work/'),
      share.file('/flat.jpg'),
      share.file('/notes.txt'),
      share.file('/pano.jpg'),
      share.file('/trip.mp4'),
    ];
    share.folders['/Holidays'] = [share.file('/Holidays/beach.jpg')];
    share.folders['/Work'] = [share.file('/notes.txt')];
  });

  tearDown(() async {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await store.dispose();
    await db.close();
  });

  /// The tile of the photo or video named [name]
  Finder tileOf(String name) =>
      find.byWidgetPredicate((widget) => widget is NetworkMediaTile && widget.entry.name == name);

  /// The frame shown in the tile of the video at [path]
  Finder videoFrameOf(String path) => find.descendant(
    of: tileOf(path.substring(1)),
    matching: find.byWidgetPredicate((widget) => widget is Image && widget.image is NetworkVideoThumbnailImage),
  );

  Future<RootStackRouter> pumpBrowser(
    WidgetTester tester, {
    String path = '/',
    bool settle = true,
    Map<String, Widget Function(RouteData data)> pages = const {},
    List<Override> overrides = const [],
  }) {
    return pumpNetworkRouter(
      tester,
      home: NetworkBrowserPage(sourceId: source.id, path: path),
      settle: settle,
      pages: pages,
      overrides: [
        ...overrides,
        storeServiceProvider.overrideWithValue(store),
        overrideConnections((ref) => connections = FakeConnections(ref, share)),
        networkThumbnailImageProvider.overrideWithValue((url) {
          thumbnails.add(url);
          return _PendingImage(url);
        }),
        networkVideoThumbnailServiceProvider.overrideWith(
          (_) => NetworkVideoThumbnailService(
            api: videoHost,
            waitForPhotos: () async => photosLoading?.future,
            retryDelay: Duration.zero,
          ),
        ),
        uploadRecordStoreProvider.overrideWithValue(records),
        foregroundUploadServiceProvider.overrideWithValue(uploads),
        toastServiceProvider.overrideWithValue(toasts),
      ],
    );
  }

  testWidgets('shows the folders first, then a grid of the photos and videos, without the other files', (tester) async {
    await pumpBrowser(tester);

    expect(find.text('Home NAS'), findsOneWidget, reason: 'the share name at its start folder');
    expect(find.widgetWithText(NetworkFolderTile, 'Holidays'), findsOneWidget);
    expect(find.widgetWithText(NetworkFolderTile, 'Work'), findsOneWidget);
    expect(find.byType(NetworkMediaTile), findsNWidgets(3));
    expect(tileOf('notes.txt'), findsNothing);
    expect(
      tester.getTopLeft(find.text('Work')).dy,
      lessThan(tester.getTopLeft(tileOf('flat.jpg')).dy),
      reason: 'folders first',
    );
    expect(share.listed, ['/']);
  });

  testWidgets('shows photo thumbnails and frames of the videos through the media bridge', (tester) async {
    await pumpBrowser(tester);

    expect(thumbnails.toSet(), {
      Uri.parse('http://127.0.0.1:1234/token/nas/flat.jpg'),
      Uri.parse('http://127.0.0.1:1234/token/nas/pano.jpg'),
    });
    expect(videoHost.urls, ['http://127.0.0.1:1234/token/nas/trip.mp4']);
    final frame = videoFrameOf('/trip.mp4');
    expect(frame, findsOneWidget);
    final image = tester.widget<Image>(frame).image as NetworkVideoThumbnailImage;
    expect(image.key, networkMediaKey(share.file('/trip.mp4')));
    expect(image.bytes, videoHost.frameOf('http://127.0.0.1:1234/token/nas/trip.mp4'));
    expect(
      find.descendant(of: tileOf('trip.mp4'), matching: find.byIcon(Icons.play_circle_outline_rounded)),
      findsOneWidget,
    );
  });

  testWidgets('shows the placeholder of a video until its frame comes, after the photo thumbnails', (tester) async {
    photosLoading = Completer<void>();
    videoHost.gated = true;
    await pumpBrowser(tester);

    expect(thumbnails.toSet(), hasLength(2));
    expect(videoHost.calls, isEmpty, reason: 'the photos on screen first');
    expect(find.descendant(of: tileOf('trip.mp4'), matching: find.byIcon(Icons.movie_outlined)), findsOneWidget);
    expect(find.descendant(of: tileOf('trip.mp4'), matching: find.text('trip.mp4')), findsOneWidget);

    photosLoading!.complete();
    await tester.pumpAndSettle();
    expect(videoHost.urls, ['http://127.0.0.1:1234/token/nas/trip.mp4']);
    expect(videoFrameOf('/trip.mp4'), findsNothing);

    videoHost.answer('http://127.0.0.1:1234/token/nas/trip.mp4');
    await tester.pumpAndSettle();
    expect(videoFrameOf('/trip.mp4'), findsOneWidget);
  });

  testWidgets('keeps the placeholder of a video whose frame cannot be taken', (tester) async {
    videoHost.frameOf = (_) => null;
    await pumpBrowser(tester);

    expect(videoHost.calls, hasLength(2), reason: 'tried once more');
    expect(videoFrameOf('/trip.mp4'), findsNothing);
    expect(find.descendant(of: tileOf('trip.mp4'), matching: find.byIcon(Icons.movie_outlined)), findsOneWidget);
  });

  testWidgets('tries a video that had no frame again when the folder is pulled down', (tester) async {
    final frame = videoHost.frameOf;
    videoHost.frameOf = (_) => null;
    await pumpBrowser(tester);
    expect(videoFrameOf('/trip.mp4'), findsNothing);

    videoHost.frameOf = frame;
    await tester.fling(find.text('Holidays'), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();

    expect(videoHost.calls, hasLength(3));
    expect(videoFrameOf('/trip.mp4'), findsOneWidget);
  });

  testWidgets('shows a video frame still in memory without taking it again', (tester) async {
    final image = (await tester.runAsync(() => createTestImage(width: 4, height: 4)))!;
    addTearDown(image.dispose);
    final key = networkMediaKey(share.file('/trip.mp4'));
    PaintingBinding.instance.imageCache.putIfAbsent(
      NetworkVideoThumbnailImage(key),
      () => OneFrameImageStreamCompleter(SynchronousFuture(ImageInfo(image: image.clone()))),
    );

    await pumpBrowser(tester);

    expect(videoHost.calls, isEmpty);
    expect(videoFrameOf('/trip.mp4'), findsOneWidget);
    expect(find.descendant(of: tileOf('trip.mp4'), matching: find.byIcon(Icons.movie_outlined)), findsNothing);
  });

  testWidgets('a photo too large to stream for a thumbnail gets a placeholder', (tester) async {
    share.folders['/'] = [
      NetworkEntry(sourceId: source.id, path: '/huge.jpg', isDirectory: false, size: networkThumbnailMaxFileSize + 1),
    ];
    await pumpBrowser(tester);

    expect(thumbnails, isEmpty);
    expect(find.text('huge.jpg'), findsOneWidget);
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
  });

  testWidgets('puts a 360° badge on the photos and videos that declare a 360° projection', (tester) async {
    await pumpBrowser(tester);

    Finder badgeOf(String name) =>
        find.descendant(of: tileOf(name), matching: find.byKey(const Key('network_media_360_badge')));
    expect(badgeOf('pano.jpg'), findsOneWidget);
    expect(badgeOf('trip.mp4'), findsOneWidget);
    expect(badgeOf('flat.jpg'), findsNothing);
    expect(share.reads.map((read) => read.$1).toSet(), {'/flat.jpg', '/pano.jpg', '/trip.mp4'});
  });

  testWidgets('goes into a folder', (tester) async {
    final router = await pumpBrowser(tester);

    await tester.tap(find.text('Holidays'));
    await tester.pumpAndSettle();

    expect(router.current.name, NetworkBrowserRoute.name);
    expect(router.current.argsAs<NetworkBrowserRouteArgs>().path, '/Holidays');
    expect(find.text('Holidays'), findsOneWidget, reason: 'the folder name as the title');
    expect(tileOf('beach.jpg'), findsOneWidget);
    expect(share.listed, ['/', '/Holidays']);
  });

  testWidgets('goes into a folder listed with a slash at the end', (tester) async {
    final router = await pumpBrowser(tester);

    await tester.tap(find.text('Work'));
    await tester.pumpAndSettle();

    expect(router.current.argsAs<NetworkBrowserRouteArgs>().path, '/Work');
    expect(find.text('This folder is empty'), findsOneWidget, reason: 'only a file that is no photo or video');
  });

  testWidgets('opens a photo in the photo page and a video in the video page', (tester) async {
    final router = await pumpBrowser(tester);

    await tester.tap(tileOf('pano.jpg'));
    await tester.pumpAndSettle();
    expect(find.text('photo nas /pano.jpg'), findsOneWidget);

    await router.maybePop();
    await tester.pumpAndSettle();
    await tester.tap(tileOf('trip.mp4'));
    await tester.pumpAndSettle();
    expect(find.text('video nas /trip.mp4'), findsOneWidget);
  });

  testWidgets('gives the photo and video pages the media of the folder around the file, for the immersive viewer', (
    tester,
  ) async {
    String describe(String kind, NetworkFolderMedia? folder) {
      if (folder == null) {
        return '$kind alone';
      }
      final names = folder.entries.map((entry) => entry.name).join(',');
      final urls = folder.entries.map((entry) => folder.urls[entry.path]?.path).join(',');
      return '$kind ${folder.index} of $names at $urls';
    }

    final router = await pumpBrowser(
      tester,
      pages: {
        NetworkPhotoRoute.name: (data) => Text(describe('photo', data.argsAs<NetworkPhotoRouteArgs>().folder)),
        NetworkVideoRoute.name: (data) => Text(describe('video', data.argsAs<NetworkVideoRouteArgs>().folder)),
      },
    );

    await tester.tap(tileOf('pano.jpg'));
    await tester.pumpAndSettle();
    final base = connections.baseUrl.path;
    final urls = [
      for (final name in ['flat.jpg', 'pano.jpg', 'trip.mp4']) '$base/$name',
    ].join(',');
    expect(find.text('photo 1 of flat.jpg,pano.jpg,trip.mp4 at $urls'), findsOneWidget);

    await router.maybePop();
    await tester.pumpAndSettle();
    await tester.tap(tileOf('trip.mp4'));
    await tester.pumpAndSettle();
    expect(find.text('video 2 of flat.jpg,pano.jpg,trip.mp4 at $urls'), findsOneWidget);
  });

  testWidgets('tells an empty folder', (tester) async {
    share.folders['/'] = [];
    await pumpBrowser(tester);

    expect(find.text('This folder is empty'), findsOneWidget);
    expect(find.byType(NetworkMediaTile), findsNothing);
  });

  testWidgets('tells while the folder is read', (tester) async {
    share.listGate = Completer<void>();
    await pumpBrowser(tester, settle: false);
    await tester.pump();

    expect(find.text('Reading the folder'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    share.listGate!.complete();
    await tester.pumpAndSettle();

    expect(find.text('Reading the folder'), findsNothing);
    expect(find.text('Holidays'), findsOneWidget);
  });

  testWidgets('tells why the folder could not be read, and tries again', (tester) async {
    share.error = const NetworkFileSystemException('The share refused the credentials', isAuthentication: true);
    await pumpBrowser(tester);

    expect(find.text('Could not open this file: The share refused the credentials'), findsOneWidget);
    expect(find.byType(NetworkMediaTile), findsNothing);

    share.error = null;
    await tester.tap(find.widgetWithText(OutlinedButton, 'Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Holidays'), findsOneWidget);
    expect(share.listed, ['/', '/']);
  });

  testWidgets('tells a share that cannot be reached', (tester) async {
    await pumpBrowser(tester);
    connections.openError = const NetworkFileSystemException('nas.local does not answer');

    await tester.fling(find.text('Holidays'), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();

    expect(find.text('Could not open this file: nas.local does not answer'), findsOneWidget);
  });

  testWidgets('reads the folder again when pulled down, keeping it on screen meanwhile', (tester) async {
    await pumpBrowser(tester);
    share.folders['/'] = [...share.folders['/']!, share.folder('/New')];
    share.listGate = Completer<void>();

    await tester.fling(find.text('Holidays'), const Offset(0, 400), 1000);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Holidays'), findsOneWidget);
    expect(find.text('Reading the folder'), findsNothing);

    share.listGate!.complete();
    await tester.pumpAndSettle();

    expect(find.text('New'), findsOneWidget);
    expect(share.listed, ['/', '/']);
  });

  testWidgets('names a folder after its last segment', (tester) async {
    await pumpBrowser(tester, path: '/Holidays');

    expect(find.text('Holidays'), findsOneWidget);
    expect(find.text('Home NAS'), findsNothing);
  });

  group('upload to Immich', () {
    final t = StaticTranslations.instance;

    /// The paths sent by each upload, answered by [answer] for each file: a new asset by default
    List<List<String>> stubUploads({
      Completer<void>? until,
      UploadResult Function(String path)? answer,
      void Function(Completer<void> cancelToken)? onStart,
    }) {
      final sent = <List<String>>[];
      when(
        () => uploads.uploadNetworkFiles(
          any(),
          cancelToken: any(named: 'cancelToken'),
          callbacks: any(named: 'callbacks'),
        ),
      ).thenAnswer((invocation) async {
        final items = invocation.positionalArguments.single as List<NetworkUploadItem>;
        final callbacks = invocation.namedArguments[#callbacks] as SourceUploadCallbacks;
        onStart?.call(invocation.namedArguments[#cancelToken] as Completer<void>);
        sent.add([for (final item in items) item.entry.path]);
        for (final item in items) {
          callbacks.onProgress?.call(item.id, 50, 100);
          if (until != null) {
            await until.future;
          }
          final result = answer?.call(item.entry.path) ?? UploadResult.success(remoteAssetId: 'remote');
          if (result.isSuccess) {
            callbacks.onSuccess?.call(item.id, result.remoteAssetId!, isDuplicate: result.isDuplicate);
          } else if (!result.isCancelled) {
            callbacks.onError?.call(item.id, result.errorMessage!);
          }
        }
      });
      return sent;
    }

    Finder selectedMarkOf(String name) =>
        find.descendant(of: tileOf(name), matching: find.byKey(const Key('network_media_selected')));

    Finder sentBadgeOf(String name) =>
        find.descendant(of: tileOf(name), matching: find.byKey(const Key('network_media_sent_badge')));

    testWidgets('a long press picks a file, then a tap picks another instead of opening it', (tester) async {
      final router = await pumpBrowser(tester);

      await tester.longPress(tileOf('flat.jpg'));
      await tester.pumpAndSettle();
      expect(find.text(t.network_upload_selected(count: 1)), findsOneWidget);
      expect(selectedMarkOf('flat.jpg'), findsOneWidget);
      expect(find.byKey(const Key('network_media_unselected')), findsNWidgets(2));

      await tester.tap(tileOf('trip.mp4'));
      await tester.pumpAndSettle();
      expect(find.text(t.network_upload_selected(count: 2)), findsOneWidget);
      expect(router.current.name, 'HomeRoute', reason: 'nothing opened');

      await tester.tap(tileOf('flat.jpg'));
      await tester.pumpAndSettle();
      expect(find.text(t.network_upload_selected(count: 1)), findsOneWidget);
      expect(selectedMarkOf('flat.jpg'), findsNothing);
    });

    testWidgets('Select starts picking, and every photo and video of the folder can be picked at once', (tester) async {
      await pumpBrowser(tester);

      await tester.tap(find.byTooltip(t.network_upload_select));
      await tester.pumpAndSettle();
      expect(find.text(t.network_upload_selected(count: 0)), findsOneWidget);
      final upload = find.widgetWithText(FilledButton, t.network_upload_action);
      expect(tester.widget<FilledButton>(upload).onPressed, isNull, reason: 'nothing picked yet');

      await tester.tap(find.byTooltip(t.network_upload_select_all));
      await tester.pumpAndSettle();
      expect(find.text(t.network_upload_selected(count: 3)), findsOneWidget);
      expect(tester.widget<FilledButton>(upload).onPressed, isNotNull);

      await tester.tap(find.byTooltip(t.network_upload_select_all));
      await tester.pumpAndSettle();
      expect(find.text(t.network_upload_selected(count: 0)), findsOneWidget, reason: 'all were picked: none now');
    });

    testWidgets('closing the selection, or going back, stops picking', (tester) async {
      await pumpBrowser(tester);
      await tester.longPress(tileOf('flat.jpg'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip(t.cancel));
      await tester.pumpAndSettle();
      expect(find.text('Home NAS'), findsOneWidget);
      expect(find.byKey(const Key('network_media_unselected')), findsNothing);

      await tester.longPress(tileOf('flat.jpg'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Home NAS'), findsOneWidget);
      expect(find.byKey(const Key('network_media_unselected')), findsNothing);
      expect(tileOf('flat.jpg'), findsOneWidget, reason: 'still on the browser');
    });

    testWidgets('sends the picked files, says how it went, and marks them as sent', (tester) async {
      final sent = stubUploads(
        answer: (path) => path == '/trip.mp4'
            ? UploadResult.success(remoteAssetId: 'old', isDuplicate: true)
            : UploadResult.success(remoteAssetId: 'new'),
      );
      await pumpBrowser(tester);
      await tester.longPress(tileOf('flat.jpg'));
      await tester.tap(tileOf('trip.mp4'));
      await tester.pumpAndSettle();

      await tester.tap(find.text(t.network_upload_action));
      await tester.pumpAndSettle();

      expect(sent, [
        ['/flat.jpg', '/trip.mp4'],
      ]);
      expect(toasts.successes, ['${t.network_upload_done(count: 1)} · ${t.network_upload_duplicates(count: 1)}']);
      expect(sentBadgeOf('flat.jpg'), findsOneWidget);
      expect(sentBadgeOf('trip.mp4'), findsOneWidget);
      expect(sentBadgeOf('pano.jpg'), findsNothing);
      expect(find.byKey(const Key('network_media_unselected')), findsNothing, reason: 'no longer picking');
    });

    testWidgets('shows the progress over the tiles, and a line with a cancel button while sending', (tester) async {
      final until = Completer<void>();
      Completer<void>? cancelToken;
      stubUploads(until: until, onStart: (token) => cancelToken = token);
      await pumpBrowser(tester);
      await tester.longPress(tileOf('flat.jpg'));
      await tester.tap(tileOf('pano.jpg'));
      await tester.pumpAndSettle();

      await tester.tap(find.text(t.network_upload_action));
      await tester.pump();
      await tester.pump();

      expect(find.descendant(of: tileOf('flat.jpg'), matching: find.text('50%')), findsOneWidget);
      expect(
        find.descendant(of: tileOf('pano.jpg'), matching: find.text('0%')),
        findsOneWidget,
        reason: 'waiting',
      );
      expect(find.text(t.network_upload_progress(done: 1, total: 2)), findsOneWidget);
      expect(find.text(t.network_upload_keep_open), findsOneWidget);
      expect(find.byType(NetworkUploadProgressBar), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, t.cancel));
      expect(cancelToken?.isCompleted, isTrue);
      until.complete();
      await tester.pumpAndSettle();

      expect(find.text(t.network_upload_keep_open), findsNothing);
      expect(find.byType(NetworkUploadProgressOverlay), findsNothing);
    });

    testWidgets('marks a file that could not be sent, and tells why', (tester) async {
      stubUploads(answer: (_) => UploadResult.error(errorMessage: 'Quota has been exceeded!'));
      await pumpBrowser(tester);
      await tester.longPress(tileOf('flat.jpg'));
      await tester.pumpAndSettle();

      await tester.tap(find.text(t.network_upload_action));
      await tester.pumpAndSettle();

      expect(toasts.errors, [t.network_upload_error(error: 'Quota has been exceeded!')]);
      expect(find.descendant(of: tileOf('flat.jpg'), matching: find.byIcon(Icons.error_outline)), findsOneWidget);
      expect(sentBadgeOf('flat.jpg'), findsNothing);
    });

    testWidgets('marks the files sent before', (tester) async {
      await records.add(share.file('/pano.jpg'), 'earlier');

      await pumpBrowser(tester);

      expect(sentBadgeOf('pano.jpg'), findsOneWidget);
      expect(sentBadgeOf('flat.jpg'), findsNothing);
    });

    testWidgets('without a server, says that one is needed instead of offering to send', (tester) async {
      await store.put(StoreKey.localSession, true);
      await pumpBrowser(tester);

      await tester.longPress(tileOf('flat.jpg'));
      await tester.pumpAndSettle();

      expect(find.text(t.network_upload_needs_server), findsOneWidget);
      expect(find.text(t.network_upload_action), findsNothing);
    });
  });

  testWidgets('shows the picture a media server gives for a file, else the bridge picture or video frame', (
    tester,
  ) async {
    const art = 'http://192.168.1.10:8200/AlbumArt/22-1.jpg';
    NetworkEntry withArt(NetworkEntry entry, String? url) => NetworkEntry(
      sourceId: entry.sourceId,
      path: entry.path,
      isDirectory: false,
      size: entry.size,
      modified: entry.modified,
      thumbnailUrl: url,
    );
    share.folders['/'] = [
      withArt(share.file('/flat.jpg'), art),
      withArt(share.file('/pano.jpg'), null),
      withArt(share.file('/trip.mp4'), 'http://192.168.1.10:8200/AlbumArt/23-1.jpg'),
      // Too large for a thumbnail read through the bridge
      NetworkEntry(
        sourceId: source.id,
        path: '/huge.jpg',
        isDirectory: false,
        size: networkThumbnailMaxFileSize + 1,
        thumbnailUrl: 'http://192.168.1.10:8200/AlbumArt/24-1.jpg',
      ),
    ];
    // Not settled: the server pictures and the bridge one stay pending, as on a slow network
    await pumpBrowser(tester, settle: false);
    await tester.pump();
    await tester.pump();

    final server = find.byKey(const Key('network_media_server_thumbnail'));
    expect(server, findsNWidgets(3));
    expect(find.descendant(of: tileOf('huge.jpg'), matching: server), findsOneWidget);
    final image = tester.widget<Image>(find.descendant(of: tileOf('flat.jpg'), matching: server)).image as ResizeImage;
    expect(image.width, 256);
    expect((image.imageProvider as NetworkImage).url, art);
    expect(thumbnails, [
      Uri.parse('http://127.0.0.1:1234/token/nas/pano.jpg'),
    ], reason: 'no bridge read for the others');
    expect(videoHost.urls, isEmpty, reason: 'no frame taken while the server picture comes');
  });

  group('the address outside home and refused credentials', () {
    testWidgets('marks a share read through its address outside home', (tester) async {
      share = _RemoteShare(source, folders: share.folders, files: share.files, isOutsideHome: true);
      await pumpBrowser(tester);

      expect(find.byKey(const Key('network_browser_remote_endpoint')), findsOneWidget);
      expect(find.byIcon(Icons.public), findsOneWidget);
      expect(find.byTooltip('Connected through the address outside home'), findsOneWidget);
    });

    testWidgets('no mark at home, nor for a share that has no address outside home', (tester) async {
      share = _RemoteShare(source, folders: share.folders, files: share.files, isOutsideHome: false);
      await pumpBrowser(tester);
      expect(find.byKey(const Key('network_browser_remote_endpoint')), findsNothing);
    });

    testWidgets('offers to edit a share whose credentials were refused', (tester) async {
      share.error = const NetworkFileSystemException('Wrong user name or password', isAuthentication: true);
      await pumpBrowser(tester);

      expect(find.byKey(const Key('network_error_edit_source')), findsOneWidget);
      await tester.tap(find.byKey(const Key('network_error_edit_source')));
      await tester.pumpAndSettle();
      expect(find.text('edit Home NAS'), findsOneWidget);
    });

    testWidgets('offers a new token to a Plex server that refused its token', (tester) async {
      const plex = NetworkSource(
        id: 'nas',
        type: NetworkSourceType.plex,
        name: 'Test Plex',
        host: '192.0.2.20',
        useTls: true,
        plex: PlexServerInfo(hash: '0123456789abcdef0123456789abcdef'),
      );
      await store.delete(StoreKey.networkSources);
      await store.put(StoreKey.networkSourcesExtra, NetworkSource.encodeList(const [plex]));
      share.error = const NetworkFileSystemException('The Plex server refused this token', isAuthentication: true);
      await pumpBrowser(tester);

      expect(find.text('Paste a new token'), findsOneWidget);
      await tester.tap(find.byKey(const Key('network_error_edit_source')));
      await tester.pumpAndSettle();
      expect(find.text('plex edit Test Plex token'), findsOneWidget);
    });

    testWidgets('no edit button when the share could not be reached', (tester) async {
      share.error = const NetworkFileSystemException('Cannot reach nas.local');
      await pumpBrowser(tester);

      expect(find.byKey(const Key('network_error_edit_source')), findsNothing);
    });
  });

  group('a share found on the network, at a new address', () {
    const found = NetworkSource(
      id: 'nas',
      type: NetworkSourceType.dlna,
      name: 'Home NAS',
      host: '192.168.1.10',
      port: 8200,
      share: '/rootDesc.xml',
      discoveryId: 'uuid:nas',
    );
    late _FakeRelocator relocator;

    setUp(() async {
      await store.put(StoreKey.networkSources, NetworkSource.encodeList(const [found]));
      relocator = _FakeRelocator();
    });

    List<NetworkSource> stored() => NetworkSource.decodeList(store.tryGet(StoreKey.networkSources));

    Future<void> pump(WidgetTester tester, {bool settle = true}) =>
        pumpBrowser(tester, settle: settle, overrides: [networkSourceRelocatorProvider.overrideWithValue(relocator)]);

    testWidgets('is looked for once its first reading failed, saved at its new address and read there', (tester) async {
      share.error = const NetworkFileSystemException('Cannot reach 192.168.1.10: No route to host');
      relocator
        ..answer = Completer<void>()
        ..result = found.copyWith(host: '192.168.1.11', port: 8201);
      await pump(tester, settle: false);
      await tester.pump();
      await tester.pump();

      expect(find.text('Looking for Home NAS on the network'), findsOneWidget);
      expect(relocator.asked.single.host, '192.168.1.10');

      share.error = null;
      relocator.answer!.complete();
      await tester.pumpAndSettle();

      expect(find.text('Holidays'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing, reason: 'a media server sends no credentials: nothing to ask');
      expect(share.listed, ['/', '/']);
      final saved = stored().single;
      expect(saved.host, '192.168.1.11');
      expect(saved.port, 8201);
      expect(saved.discoveryId, 'uuid:nas');
    });

    testWidgets('tells why the folder could not be read when it is not found elsewhere, and is looked for once', (
      tester,
    ) async {
      share.error = const NetworkFileSystemException('Cannot reach 192.168.1.10: No route to host');
      await pump(tester);

      expect(relocator.asked, hasLength(1));
      expect(find.text('Could not open this file: Cannot reach 192.168.1.10: No route to host'), findsOneWidget);
      expect(stored().single.host, '192.168.1.10');

      await tester.tap(find.widgetWithText(OutlinedButton, 'Retry'));
      await tester.pumpAndSettle();
      expect(relocator.asked, hasLength(1), reason: 'once per page');
    });

    testWidgets('is not looked for when its credentials are refused or its folder is missing', (tester) async {
      share.error = const NetworkFileSystemException('Refused', isAuthentication: true);
      await pump(tester);
      expect(relocator.asked, isEmpty);
    });

    testWidgets('a Plex server is moved without a question: only its own certificate ever gets the token', (
      tester,
    ) async {
      const plex = NetworkSource(
        id: 'nas',
        type: NetworkSourceType.plex,
        name: 'Test Plex',
        host: '192.0.2.20',
        useTls: true,
        discoveryId: '0000000000000000000000000000000000000001',
        plex: PlexServerInfo(hash: '0123456789abcdef0123456789abcdef'),
      );
      await store.delete(StoreKey.networkSources);
      await store.put(StoreKey.networkSourcesExtra, NetworkSource.encodeList(const [plex]));
      share.error = const NetworkFileSystemException('Cannot reach 192.0.2.20: No route to host');
      relocator
        ..answer = Completer<void>()
        ..result = plex.copyWith(host: '192.0.2.21');
      await pump(tester, settle: false);
      await tester.pump();
      await tester.pump();

      share.error = null;
      relocator.answer!.complete();
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Holidays'), findsOneWidget);
      final saved = NetworkSource.decodeList(store.tryGet(StoreKey.networkSourcesExtra)).single;
      expect(saved.host, '192.0.2.21');
      expect(saved.plex?.hash, '0123456789abcdef0123456789abcdef');
    });

    testWidgets('a share typed by hand is not looked for', (tester) async {
      await store.put(StoreKey.networkSources, NetworkSource.encodeList([found.copyWith(clearDiscoveryId: true)]));
      share.error = const NetworkFileSystemException('Cannot reach 192.168.1.10: No route to host');
      await pump(tester);
      expect(relocator.asked, isEmpty);
    });

    group('with a user name and a password', () {
      const phone = NetworkSource(
        id: 'nas',
        type: NetworkSourceType.webdav,
        name: 'Pixel',
        host: '192.168.1.56',
        port: 8361,
        share: '/',
        username: 'phone1234',
        discoveryId: '0f1e2d3c4b5a6978',
      );
      const question =
          'Pixel no longer answers at http://192.168.1.56:8361/, and a device of the network that announces it '
          'answers at http://192.168.1.57:8361/. Saving this address sends the user name and password of the share to '
          'that device: only do it if you trust it.';

      setUp(() async {
        await store.put(StoreKey.networkSources, NetworkSource.encodeList(const [phone]));
        share.error = const NetworkFileSystemException('Cannot reach 192.168.1.56: No route to host');
        relocator.result = phone.copyWith(host: '192.168.1.57');
      });

      /// Up to the question; not settled, the page waiting behind it
      Future<void> pumpToQuestion(WidgetTester tester) async {
        await pump(tester, settle: false);
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      testWidgets('is moved once the user accepts the new address, which the question names', (tester) async {
        await pumpToQuestion(tester);

        expect(find.text('Use the new address?'), findsOneWidget);
        expect(find.text(question), findsOneWidget);
        expect(stored().single.host, '192.168.1.56', reason: 'nothing saved before the answer');

        share.error = null;
        await tester.tap(find.widgetWithText(TextButton, 'Save'));
        await tester.pumpAndSettle();

        expect(find.text('Holidays'), findsOneWidget);
        expect(stored().single.host, '192.168.1.57');
        expect(stored().single.username, 'phone1234');
      });

      testWidgets('stays where it was when the user declines, and tells why it could not be read', (tester) async {
        await pumpToQuestion(tester);

        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await tester.pumpAndSettle();

        expect(find.text(question), findsNothing);
        expect(find.text('Could not open this file: Cannot reach 192.168.1.56: No route to host'), findsOneWidget);
        expect(stored().single.host, '192.168.1.56');
        expect(share.listed, ['/'], reason: 'not read at the new address');
      });
    });
  });

  group('NetworkThumbnailCache', () {
    testWidgets('keeps the last thumbnails decoded, whatever the image cache drops', (tester) async {
      final image = (await tester.runAsync(() => createTestImage(width: 4, height: 4)))!;
      addTearDown(image.dispose);
      final cache = NetworkThumbnailCache(maxEntries: 2);
      addTearDown(cache.clear);
      final images = [for (var id = 0; id < 3; id++) _LoadedImage(image, id)];

      for (final provider in images) {
        final stream = provider.resolve(ImageConfiguration.empty);
        final listener = ImageStreamListener((info, _) => info.dispose());
        stream.addListener(listener);
        await tester.pump();
        cache.retain(provider);
        stream.removeListener(listener);
      }
      // Shown again: the most recently shown now
      cache.retain(images[1]);
      PaintingBinding.instance.imageCache.clear();

      expect(cache.length, 2);
      final imageCache = PaintingBinding.instance.imageCache;
      expect(imageCache.statusForKey(images[0]).live, isFalse, reason: 'the least recently shown is dropped');
      expect(imageCache.statusForKey(images[1]).live, isTrue);
      expect(imageCache.statusForKey(images[2]).live, isTrue);

      cache.clear();
      expect(imageCache.statusForKey(images[2]).live, isFalse);
    });
  });
}
