// The Upload to Immich entry of the menu of the video page of a share

import 'dart:async';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/viewer_config.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/upload_record_store.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/pages/network/network_video.page.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/infrastructure/toast.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:immich_mobile/services/toast.service.dart';
import 'package:mocktail/mocktail.dart';

import '../../../domain/services/spherical_probe_fixtures.dart';
import '../../../service.mocks.dart';
import 'network_viewer_fakes.dart';

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

class _Toasts extends ToastService {
  final List<String> successes = [];

  @override
  FutureOr<void> success(String message, {ToastOption? toast}) {
    successes.add(message);
  }
}

void main() {
  const source = NetworkSource(id: 'nas', type: NetworkSourceType.smb, name: 'Home NAS', host: 'nas.local');
  const wakelock = 'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';
  final t = StaticTranslations.instance;
  late Drift db;
  late StoreService store;
  late MemoryShare share;
  late MockForegroundUploadService uploads;
  late _MemoryRecords records;
  late _Toasts toasts;
  late List<List<String>> sent;

  setUpAll(() {
    registerFallbackValue(Completer<void>());
    registerFallbackValue(const SourceUploadCallbacks());
  });

  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    await store.put(StoreKey.networkSources, NetworkSource.encodeList(const [source]));
    share = MemoryShare(
      source,
      files: {
        '/holiday.mp4': mp4File(mp4Moov([mp4VideoTrack(const [])])),
      },
    );
    uploads = MockForegroundUploadService();
    records = _MemoryRecords();
    toasts = _Toasts();
    sent = [];
    when(
      () => uploads.uploadNetworkFiles(
        any(),
        cancelToken: any(named: 'cancelToken'),
        callbacks: any(named: 'callbacks'),
      ),
    ).thenAnswer((invocation) async {
      final items = invocation.positionalArguments.single as List<NetworkUploadItem>;
      final callbacks = invocation.namedArguments[#callbacks] as SourceUploadCallbacks;
      sent.add([for (final item in items) item.entry.path]);
      for (final item in items) {
        callbacks.onSuccess?.call(item.id, 'remote', isDuplicate: false);
      }
    });
    // The native video view: created, with nothing behind it
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (call) async {
      return switch (call.method) {
        'create' => 0,
        'resize' => {'width': (call.arguments as Map)['width'], 'height': (call.arguments as Map)['height']},
        _ => null,
      };
    });
    messenger.setMockMessageHandler(wakelock, (_) async => const StandardMessageCodec().encodeMessage(<Object?>[]));
  });

  tearDown(() async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    messenger.setMockMessageHandler(wakelock, null);
    await store.dispose();
    await db.close();
  });

  Future<void> pumpVideoPage(WidgetTester tester) async {
    await pumpNetworkRouter(
      tester,
      home: const NetworkVideoPage(sourceId: 'nas', path: '/holiday.mp4'),
      settle: false,
      overrides: [
        storeServiceProvider.overrideWithValue(store),
        overrideConnections((ref) => FakeConnections(ref, share)),
        // Neither 360° nor Spatial 2.5D here: the menu is there for the upload alone
        appConfigProvider.overrideWithValue(const AppConfig(viewer: ViewerConfig(spatial25d: false))),
        isHorizonOsProvider.overrideWith((ref) async => false),
        panorama360VideoSupportedProvider.overrideWithValue(false),
        videoPlayerProvider('network:nas:/holiday.mp4').overrideWith((ref) => VideoPlayerNotifier()),
        networkMediaServiceProvider.overrideWith((ref) => NetworkMediaService()),
        uploadRecordStoreProvider.overrideWithValue(records),
        foregroundUploadServiceProvider.overrideWithValue(uploads),
        toastServiceProvider.overrideWithValue(toasts),
      ],
    );
    // The loading spinner turns as long as no native player is ready, which never comes here: no pumpAndSettle
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('sends the video to the server from the menu, and says so', (tester) async {
    await pumpVideoPage(tester);

    await tester.tap(find.byTooltip(t.more));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text(t.network_upload_action));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(sent, [
      ['/holiday.mp4'],
    ]);
    expect(toasts.successes, [t.network_upload_done(count: 1)]);
    expect(records.records.keys, [UploadRecordStore.keyOf(share.file('/holiday.mp4'))]);

    await endRealIo(tester);
  });

  testWidgets('offers no menu without a server, when the upload is all it would have', (tester) async {
    await store.put(StoreKey.localSession, true);
    await pumpVideoPage(tester);

    expect(find.byTooltip(t.more), findsNothing);

    await endRealIo(tester);
  });
}
