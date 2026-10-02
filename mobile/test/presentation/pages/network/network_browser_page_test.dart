import 'dart:async';
import 'dart:ui' as ui;

import 'package:auto_route/auto_route.dart';
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/pages/network/network_browser.page.dart';
import 'package:immich_mobile/presentation/widgets/network/network_media_tile.widget.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/routing/router.dart';

import '../../../domain/services/spherical_probe_fixtures.dart';
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

void main() {
  late Drift db;
  late StoreService store;
  late MemoryShare share;
  late FakeConnections connections;
  late List<Uri> thumbnails;

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
    await store.dispose();
    await db.close();
  });

  /// The tile of the photo or video named [name]
  Finder tileOf(String name) =>
      find.byWidgetPredicate((widget) => widget is NetworkMediaTile && widget.entry.name == name);

  Future<RootStackRouter> pumpBrowser(WidgetTester tester, {String path = '/', bool settle = true}) {
    return pumpNetworkRouter(
      tester,
      home: NetworkBrowserPage(sourceId: source.id, path: path),
      settle: settle,
      overrides: [
        storeServiceProvider.overrideWithValue(store),
        overrideConnections((ref) => connections = FakeConnections(ref, share)),
        networkThumbnailImageProvider.overrideWithValue((url) {
          thumbnails.add(url);
          return _PendingImage(url);
        }),
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

  testWidgets('shows photo thumbnails through the media bridge, and a placeholder for videos', (tester) async {
    await pumpBrowser(tester);

    expect(thumbnails.toSet(), {
      Uri.parse('http://127.0.0.1:1234/token/nas/flat.jpg'),
      Uri.parse('http://127.0.0.1:1234/token/nas/pano.jpg'),
    });
    final video = find.ancestor(of: find.text('trip.mp4'), matching: find.byType(NetworkMediaTile));
    expect(video, findsOneWidget);
    expect(find.descendant(of: video, matching: find.byIcon(Icons.movie_outlined)), findsOneWidget);
    expect(find.descendant(of: video, matching: find.byIcon(Icons.play_circle_outline_rounded)), findsOneWidget);
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
