// The 360° files of the network shares in the 360° list: a share folder shown once is enough for its 360° files to
// come in a row of the 360° list, after a new start too, flat files staying out; a tile opens its file in the share's
// photo or video page, and a remote goes along the row and opens with OK.

import 'dart:async';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/network_panorama_file.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/upload_record_store.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/pages/network/network_browser.page.dart';
import 'package:immich_mobile/presentation/widgets/network/network_media_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/panorama_360/panorama_360_shares.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.state.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';
import 'package:immich_mobile/routing/router.dart';

import '../../pages/network/network_viewer_fakes.dart';

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

/// No file was sent before: in memory, widget tests do not wait for real file reads
class _NoRecords extends UploadRecordStore {
  _NoRecords() : super(() => throw UnimplementedError('in memory'));

  @override
  Future<Map<String, UploadRecord>> load() async => {};

  @override
  Future<void> add(NetworkEntry entry, String remoteId, {DateTime? sentAt}) async {}
}

void main() {
  late Drift db;
  late StoreService store;
  late MemoryShare share;

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
    share = MemoryShare(
      source,
      files: {
        '/pano.jpg': fakePhoto(equirectangularXmp),
        '/flat.jpg': fakePhoto(),
        '/beach.jpg': fakePhoto(equirectangularXmp),
      },
    );
    share.folders['/'] = [share.file('/beach.jpg'), share.file('/flat.jpg'), share.file('/pano.jpg')];
  });

  tearDown(() async {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await store.dispose();
    await db.close();
  });

  List<Override> overrides({bool tvMode = false}) => [
    tvModeProvider.overrideWithValue(tvMode),
    storeServiceProvider.overrideWithValue(store),
    overrideConnections((ref) => FakeConnections(ref, share)),
    networkThumbnailImageProvider.overrideWithValue(_PendingImage.new),
    uploadRecordStoreProvider.overrideWithValue(_NoRecords()),
  ];

  /// The row as the 360° page shows it, under a grid of six tiles per row (a 1080p TV)
  Future<void> pumpSection(WidgetTester tester, {bool tvMode = false}) async {
    await pumpNetworkRouter(
      tester,
      home: ProviderScope(
        overrides: [
          timelineArgsProvider.overrideWithValue(const TimelineArgs(maxWidth: 864, maxHeight: 400, columnCount: 6)),
        ],
        child: const Scaffold(body: CustomScrollView(slivers: [Panorama360SharesSection()])),
      ),
      overrides: overrides(tvMode: tvMode),
      pages: {
        // Tells the 360° files of the share the page goes through with previous and next
        NetworkPhotoRoute.name: (data) {
          final args = data.argsAs<NetworkPhotoRouteArgs>();
          return Text(
            'photo ${args.sourceId} ${args.path} among ${args.folder?.entries.map((e) => e.name).join(', ')}',
          );
        },
      },
    );
  }

  Future<void> remember(List<String> paths) => store.put(
    StoreKey.networkPanoramaFiles,
    NetworkPanoramaFile.encodeList([for (final path in paths) NetworkPanoramaFile.of(share.file(path))]),
  );

  Finder tileOf(String name) =>
      find.byWidgetPredicate((widget) => widget is NetworkMediaTile && widget.entry.name == name);

  testWidgets('the 360° files of a share folder shown once come in the row of the 360° list, the flat ones not', (
    tester,
  ) async {
    await pumpNetworkRouter(
      tester,
      home: NetworkBrowserPage(sourceId: source.id, path: '/'),
      overrides: overrides(),
    );
    expect(tileOf('pano.jpg'), findsOneWidget);
    // The reads of the 360° badges end
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('network_media_360_badge')), findsNWidgets(2));

    // A new start of the app, on the 360° list
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpSection(tester);

    expect(find.text('In the network shares'), findsOneWidget);
    expect(tileOf('pano.jpg'), findsOneWidget);
    expect(tileOf('beach.jpg'), findsOneWidget);
    expect(tileOf('flat.jpg'), findsNothing);
  });

  testWidgets('a tile opens its file in the photo page of its share', (tester) async {
    await remember(['/pano.jpg']);
    await pumpSection(tester);

    await tester.tap(tileOf('pano.jpg'));
    await tester.pumpAndSettle();

    expect(find.text('photo nas /pano.jpg among pano.jpg'), findsOneWidget);
  });

  testWidgets('nothing shows while no 360° file of a share was found', (tester) async {
    await pumpSection(tester);

    expect(find.text('In the network shares'), findsNothing);
    expect(find.byType(NetworkMediaTile), findsNothing);
  });

  testWidgets('a remote arrives on the first file of the row, a phone on nothing', (tester) async {
    await remember(['/beach.jpg', '/pano.jpg']);
    FocusNode focusOf(String name) =>
        Focus.of(tester.element(find.descendant(of: tileOf(name), matching: find.byType(ClipRRect))));

    await pumpSection(tester, tvMode: true);
    expect(focusOf('pano.jpg').hasPrimaryFocus, isTrue, reason: 'the first of the row');

    await tester.pumpWidget(const SizedBox.shrink());
    await pumpSection(tester);
    expect(focusOf('pano.jpg').hasFocus, isFalse);
  });

  testWidgets('a remote goes along the row with the arrows and opens a file with OK', (tester) async {
    await remember(['/beach.jpg', '/pano.jpg']);
    await pumpSection(tester, tvMode: true);
    final row = [
      for (final tile in tester.widgetList<NetworkMediaTile>(find.byType(NetworkMediaTile))) tile.entry.name,
    ];
    expect(row, ['pano.jpg', 'beach.jpg'], reason: 'of the same date, the one found last first');
    Focus.of(tester.element(find.descendant(of: tileOf('pano.jpg'), matching: find.byType(ClipRRect)))).requestFocus();
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    expect(find.text('photo nas /beach.jpg among pano.jpg, beach.jpg'), findsOneWidget);
  });
}
