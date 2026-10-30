import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/viewer_config.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/immersive_api.g.dart';
import 'package:immich_mobile/presentation/pages/network/splat.page.dart';
import 'package:immich_mobile/presentation/widgets/splat/splat_button.dart';
import 'package:immich_mobile/providers/ai_immersive/relief_gate.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';

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
    bool gaussianSplats = true,
  }) async {
    opened.add((url: url, title: title, stereoPair: stereoPair, isVideo: isVideo));
  }
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
  }) => [
    storeServiceProvider.overrideWithValue(store),
    overrideConnections((ref) => FakeConnections(ref, share)),
    isHorizonOsProvider.overrideWith((ref) async => true),
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

    testWidgets('greys the button with its reason in the phone APK', (tester) async {
      await pumpPage(tester, '/cash.spz', with_: overrides(flavor: null));
      expect(button(tester).onPressed, isNull);
      expect(find.text('Not in this version of the app'), findsOneWidget);
    });

    testWidgets('greys the button with its reason for a compressed PLY', (tester) async {
      await pumpPage(tester, '/packed.ply');
      expect(button(tester).onPressed, isNull);
      expect(find.text('Compressed PLY is not read here yet: export it as .spz or as a standard .ply'), findsOneWidget);
      expect(immersiveApi.opened, isEmpty);
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
