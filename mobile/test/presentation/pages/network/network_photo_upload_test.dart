// The Upload to Immich entry of the menu of the photo page of a share

import 'dart:async';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/upload_record_store.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/pages/network/network_photo.page.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/infrastructure/toast.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:immich_mobile/services/toast.service.dart';
import 'package:mocktail/mocktail.dart';

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
    share = MemoryShare(source, files: {'/flat.jpg': fakePhoto()});
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
  });

  tearDown(() async {
    await store.dispose();
    await db.close();
  });

  Future<void> pumpPhotoPage(WidgetTester tester) async {
    await pumpNetworkRouter(
      tester,
      home: const NetworkPhotoPage(sourceId: 'nas', path: '/flat.jpg'),
      overrides: [
        storeServiceProvider.overrideWithValue(store),
        overrideConnections((ref) => FakeConnections(ref, share)),
        isHorizonOsProvider.overrideWith((ref) async => false),
        networkMediaServiceProvider.overrideWith((ref) => NetworkMediaService()),
        uploadRecordStoreProvider.overrideWithValue(records),
        foregroundUploadServiceProvider.overrideWithValue(uploads),
        toastServiceProvider.overrideWithValue(toasts),
      ],
    );
  }

  testWidgets('sends the photo to the server from the menu, and says so', (tester) async {
    await pumpPhotoPage(tester);

    await tester.tap(find.byTooltip(t.more));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.network_upload_action));
    await tester.pump();

    expect(
      find.text('${t.network_upload_sending_file(name: 'flat.jpg')}\n${t.network_upload_keep_open}'),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
    expect(sent, [
      ['/flat.jpg'],
    ]);
    expect(toasts.successes, [t.network_upload_done(count: 1)]);
    expect(records.records.keys, [UploadRecordStore.keyOf(share.file('/flat.jpg'))]);

    await endRealIo(tester);
  });

  testWidgets('offers no upload without a server', (tester) async {
    await store.put(StoreKey.localSession, true);
    await pumpPhotoPage(tester);

    await tester.tap(find.byTooltip(t.more));
    await tester.pumpAndSettle();

    expect(find.text(t.view_as_360), findsOneWidget);
    expect(find.text(t.network_upload_action), findsNothing);

    await endRealIo(tester);
  });
}
