import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/network_upload.service.dart';
import 'package:immich_mobile/domain/services/network_video_thumbnail.service.dart';
import 'package:immich_mobile/domain/services/upload_record_store.dart';
import 'package:immich_mobile/domain/services/video_location.service.dart';
import 'package:immich_mobile/infrastructure/network/document_tree_file_system.dart';
import 'package:immich_mobile/platform/document_tree_api.g.dart';
import 'package:immich_mobile/presentation/pages/drone/drone_import.page.dart';
import 'package:immich_mobile/presentation/widgets/drone/drone_import_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/network_media_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/network_upload.widget.dart';
import 'package:immich_mobile/providers/drone/drone_import.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/media_bridge.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';

import '../../../domain/services/video_thumbnail_fakes.dart';
import '../../../fixtures/document_tree.fake.dart';
import '../../../fixtures/raw/insta360.stub.dart';
import '../../../infrastructure/repository.mock.dart';
import '../../../providers/network/fakes.dart';
import '../network/network_viewer_fakes.dart';

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
}

/// The folders picked before, in memory: widget tests do not wait for real file reads
class _MemoryRecents extends DroneRecentStore {
  _MemoryRecents() : super(() async => null);

  List<RecentTree> trees = [];

  @override
  Future<List<RecentTree>> load() async => trees;

  @override
  Future<void> save(List<RecentTree> trees) async => this.trees = trees;
}

/// No place to set: the page only goes through the pending list when it opens
class _NoPlaces implements VideoLocationApi {
  @override
  Future<AssetPlaceState?> placeState(String assetId) async => null;

  @override
  Future<void> setLocation(String assetId, double latitude, double longitude) async {}
}

const _photo = '/DCIM/DJI_001/DJI_20261021143000_0001_D.JPG';
const _sphere = '/DCIM/DJI_001/DJI_20261021150000_0042_D.JPG';
const _video = '/DCIM/DJI_001/DJI_20261021143100_0002_D.MP4';
const _osv = '/DCIM/DJI_001/CAM_20261021143200_0003_D.OSV';

void main() {
  late FakeDocumentTreeApi api;
  late DocumentTreeEvents? events;
  late _MemoryRecords records;
  late Directory directory;
  late MockSettingsRepository settings;

  Uint8List bytes(int length) => Uint8List(length);

  setUp(() {
    directory = Directory.systemTemp.createTempSync('drone_import_page');
    api = FakeDocumentTreeApi(
      {
        _photo: Uint8List.fromList([
          ...insta360PhotoHead(make: 'Hasselblad', model: 'L2D-20c', pixelWidth: 4000, pixelHeight: 3000),
          ...bytes(64),
        ]),
        _sphere: Uint8List.fromList([
          ...insta360PhotoHead(make: 'Hasselblad', model: 'L2D-20c', pixelWidth: 8192, pixelHeight: 4096),
          ...bytes(64),
        ]),
        for (var i = 1; i <= 3; i++) '/DCIM/PANORAMA/001_0042/DJI_2026102114590${i}_000${i}_D.JPG': bytes(100),
        _video: bytes(200),
        '/DCIM/DJI_001/DJI_20261021143100_0002_D.LRF': bytes(50),
        '/DCIM/DJI_001/DJI_20261021143100_0002_D.SRT': bytes(20),
        '/DCIM/DJI_001/DJI_20261021143100_0002_D.m4a': bytes(20),
        _osv: bytes(200),
        '/MISC/log.db': bytes(5),
      },
      dates: {_osv: DateTime.utc(2026, 10, 21, 12)},
    );
    events = null;
    records = _MemoryRecords();
    settings = MockSettingsRepository();
  });

  tearDown(() {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    directory.deleteSync(recursive: true);
  });

  Finder tileOf(String path) =>
      find.byWidgetPredicate((widget) => widget is NetworkMediaTile && widget.entry.path == path);

  Future<void> pumpPage(WidgetTester tester) async {
    await pumpNetworkRouter(
      tester,
      home: const DroneImportPage(),
      overrides: [
        documentTreeApiProvider.overrideWithValue(api),
        documentTreeEventsSetUpProvider.overrideWithValue((listener) => events = listener),
        droneRecentStoreProvider.overrideWithValue(_MemoryRecents()),
        networkFileSystemOpenersProvider.overrideWithValue({
          NetworkSourceType.documentTree: (source, _) async =>
              DocumentTreeFileSystem(source, api, unpluggedMessage: () => 'The drone or card was unplugged'),
        }),
        mediaBridgeProvider.overrideWithValue(FakeMediaBridge()),
        networkMediaServiceProvider.overrideWithValue(NetworkMediaService()),
        networkThumbnailImageProvider.overrideWithValue(_PendingImage.new),
        networkVideoThumbnailServiceProvider.overrideWith(
          (_) => NetworkVideoThumbnailService(api: FakeVideoThumbnailHost(), retryDelay: Duration.zero),
        ),
        uploadRecordStoreProvider.overrideWithValue(records),
        videoLocationServiceProvider.overrideWithValue(VideoLocationService(_NoPlaces(), () async => null)),
        hasServerProvider.overrideWithValue(true),
        appConfigProvider.overrideWithValue(const AppConfig()),
        settingsProvider.overrideWithValue(settings),
      ],
    );
  }

  Future<void> chooseDrone(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('drone_import_choose')));
    await tester.pumpAndSettle();
  }

  testWidgets('asks to plug in and choose, then lists the photos and videos without their companion files', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(find.byKey(const Key('drone_import_choose')), findsOneWidget);
    expect(api.watching, [true], reason: 'told when USB devices come and go');

    await chooseDrone(tester);

    expect(find.byKey(const Key('drone_import_tree')), findsOneWidget);
    for (final path in [_sphere, _photo, _video]) {
      expect(tileOf(path), findsOneWidget, reason: path);
    }
    // Scroll to the end of the grid to see the last tile
    await tester.scrollUntilVisible(tileOf(_osv), 200);
    expect(tileOf(_osv), findsOneWidget);
    for (final name in ['.LRF', '.SRT', '.m4a', 'log.db']) {
      expect(
        find.byWidgetPredicate((widget) => widget is NetworkMediaTile && widget.entry.name.endsWith(name)),
        findsNothing,
        reason: name,
      );
    }
    // The sphere sources stay folded under the sphere
    expect(find.byKey(const Key('drone_tile_source')), findsNothing);
    expect(api.listed.where((id) => id == '/MISC'), isEmpty, reason: 'MISC is not gone into');
  });

  testWidgets('the sphere shows its sources on demand, the 360 badge, the sound note and the refused chip', (
    tester,
  ) async {
    await pumpPage(tester);
    await chooseDrone(tester);

    expect(
      find.descendant(
        of: find.ancestor(of: tileOf(_sphere), matching: find.byType(Stack)).first,
        matching: find.text('+3'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tileOf(_sphere), matching: find.byKey(const Key('network_media_360_badge'))),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tileOf(_photo), matching: find.byKey(const Key('network_media_360_badge'))),
      findsNothing,
    );
    expect(find.byKey(const Key('drone_tile_sound_apart')), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('drone_tile_refused')), 200);
    expect(find.byKey(const Key('drone_tile_refused')), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('drone_tile_sources')), -200);

    await tester.tap(find.byKey(const Key('drone_tile_sources')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('drone_tile_source')), findsNWidgets(3));
  });

  testWidgets('"Select all new" leaves out the files sent earlier, the sphere sources and the refused files', (
    tester,
  ) async {
    records.records[UploadRecordStore.keyOf(
      NetworkEntry(sourceId: 'tree:any', path: _photo, isDirectory: false, size: api.files[_photo]!.length),
    )] = UploadRecord(
      remoteId: 'earlier',
      sentAt: DateTime.utc(2026, 10, 21),
    );
    await pumpPage(tester);
    await chooseDrone(tester);
    await tester.tap(find.byKey(const Key('drone_tile_sources')));
    await tester.pumpAndSettle();

    expect(
      find.descendant(of: tileOf(_photo), matching: find.byKey(const Key('network_media_sent_badge'))),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('drone_import_select')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drone_import_select_new')));
    await tester.pumpAndSettle();

    final selected = find.byKey(const Key('network_media_selected'));
    final selectedPaths = [
      for (final element in selected.evaluate()) element.findAncestorWidgetOfExactType<NetworkMediaTile>()!.entry.path,
    ];
    expect(selectedPaths, unorderedEquals([_sphere, _video]));
  });

  testWidgets('keeps a video on the device after a warning about its flight data', (tester) async {
    await pumpPage(tester);
    await chooseDrone(tester);

    await tester.longPress(tileOf(_video));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drone_import_keep')));
    await tester.pumpAndSettle();

    expect(find.text('Videos kept on the device lose the place from their flight data'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Keep on the device').last);
    await tester.pumpAndSettle();

    expect(api.copies.single.path, _video);
    expect(api.copies.single.album, 'Immuch360 import');
    expect(api.copies.single.mimeType, 'video/mp4');
    expect(api.copies.single.takenAtMs, DateTime(2026, 10, 21, 14, 31).millisecondsSinceEpoch);
    expect(find.textContaining('saved in the gallery, album Immuch360 import'), findsOneWidget);
  });

  testWidgets('the upload sheet offers the 360 tags, off by default, when a sphere is among the files', (tester) async {
    await pumpPage(tester);
    await chooseDrone(tester);

    await tester.longPress(tileOf(_sphere));
    await tester.pumpAndSettle();
    await tester.tap(tileOf(_video));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drone_import_upload')));
    await tester.pumpAndSettle();

    final tags = tester.widget<SwitchListTile>(find.byKey(const Key('upload_sheet_tag_spheres')));
    expect(tags.value, isFalse);
    expect(find.byKey(const Key('upload_sheet_flight_data')), findsOneWidget);
    expect(find.textContaining('2 files'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('upload_sheet_tag_spheres')), findsNothing);
  });

  testWidgets('says when the drone is unplugged, and reads it again once plugged back', (tester) async {
    await pumpPage(tester);
    await chooseDrone(tester);

    api.unplugged = true;
    events!.onUsbChanged(false);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('drone_import_unplugged')), findsOneWidget);

    api.unplugged = false;
    events!.onUsbChanged(true);
    await tester.pumpAndSettle();

    expect(tileOf(_sphere), findsOneWidget);
  });

  testWidgets('offers the folder picked before, and tells when it is not plugged in', (tester) async {
    await pumpPage(tester);
    await chooseDrone(tester);
    await tester.tap(find.text('Choose another'));
    await tester.pumpAndSettle();

    expect(find.byKey(Key('drone_import_recent_${api.treeUri}')), findsOneWidget);
    expect(find.text('USB drive or card'), findsOneWidget);

    api.unplugged = true;
    await tester.tap(find.byKey(Key('drone_import_recent_${api.treeUri}')));
    await tester.pumpAndSettle();

    expect(find.text('Not plugged in'), findsOneWidget);
  });

  group('upload sheet', () {
    Future<List<NetworkUploadOptions?>> pumpSheet(WidgetTester tester, NetworkUploadSheet sheet) async {
      final chosen = <NetworkUploadOptions?>[];
      await pumpNetworkRouter(
        tester,
        overrides: const [],
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => chosen.add(
                await showModalBottomSheet<NetworkUploadOptions>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => sheet,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return chosen;
    }

    testWidgets('has no 360 option without a sphere, and warns on mobile data', (tester) async {
      await pumpSheet(
        tester,
        const NetworkUploadSheet(
          count: 3,
          totalBytes: 600 * 1024 * 1024,
          spheres: 0,
          hasFlightData: false,
          onMobileData: true,
          tagSpheres: false,
        ),
      );

      expect(find.byKey(const Key('upload_sheet_tag_spheres')), findsNothing);
      expect(find.byKey(const Key('upload_sheet_mobile_data')), findsOneWidget);
      expect(find.byKey(const Key('upload_sheet_flight_data')), findsNothing);
      expect(find.text('3 files, 600.0 MiB'), findsOneWidget);
    });

    testWidgets('gives the 360 option chosen', (tester) async {
      final chosen = await pumpSheet(
        tester,
        const NetworkUploadSheet(
          count: 1,
          totalBytes: 1000,
          spheres: 1,
          hasFlightData: true,
          onMobileData: false,
          tagSpheres: false,
        ),
      );

      await tester.tap(find.byKey(const Key('upload_sheet_tag_spheres')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('upload_sheet_send')));
      await tester.tap(find.byKey(const Key('upload_sheet_send')));
      await tester.pumpAndSettle();

      expect(chosen.single?.tagSpheres, isTrue);
    });
  });

  group('the DJI drone tile', () {
    Future<void> pumpTile(WidgetTester tester, List<Override> overrides) => pumpNetworkRouter(
      tester,
      home: const Scaffold(body: Column(children: [DroneImportTile()])),
      overrides: overrides,
    );

    testWidgets('shows once the setting is on where the page is offered', (tester) async {
      await pumpTile(tester, [droneImportEnabledProvider.overrideWithValue(true)]);

      expect(find.byKey(const Key('drone_import_tile')), findsOneWidget);
      expect(find.text('DJI drone'), findsOneWidget);
    });

    testWidgets('is hidden with the setting off', (tester) async {
      await pumpTile(tester, [droneImportEnabledProvider.overrideWithValue(false)]);

      expect(find.byKey(const Key('drone_import_tile')), findsNothing);
    });

    testWidgets('is hidden off Android whatever the setting', (tester) async {
      // The tests run on a computer: not an Android phone
      await pumpTile(tester, [appConfigProvider.overrideWithValue(const AppConfig(djiImportEnabled: true))]);

      expect(find.byKey(const Key('drone_import_tile')), findsNothing);
    });
  });
}
