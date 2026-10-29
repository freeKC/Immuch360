// The selection of a folder of a share on a computer (lib/desktop/selection/network_selection.dart), in the real
// browser under the window shell: Control click picks without opening, Shift click picks the range in the order of the
// grid, Control A picks every photo and video, Escape stops picking, a right click opens the menu whose "Upload to
// Immich" sends the picked files in the order of the grid, or says that a server is needed. A folder opens whatever the
// keys; a Shift click finds its anchor again after a refresh brought files above it. A phone, and the remote control
// layout on a computer, keep the browser as it was.

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/desktop/window/desktop_shell.dart';
import 'package:immich_mobile/desktop/window/full_screen.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/upload_record_store.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/pages/network/network_browser.page.dart';
import 'package:immich_mobile/presentation/widgets/network/network_media_tile.widget.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/infrastructure/toast.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/network_selection.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:immich_mobile/services/toast.service.dart';
import 'package:mocktail/mocktail.dart';

import '../../presentation/pages/network/network_viewer_fakes.dart';
import '../../service.mocks.dart';
import 'selection_test_app.dart';

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

/// The record of the files sent, in memory
class _MemoryRecords extends UploadRecordStore {
  _MemoryRecords() : super(() => throw UnimplementedError('in memory'));

  final Map<String, UploadRecord> records = {};

  @override
  Future<Map<String, UploadRecord>> load() async => records;

  @override
  Future<void> add(NetworkEntry entry, String remoteId, {DateTime? sentAt, bool inTrash = false}) async {
    records[UploadRecordStore.keyOf(entry)] = UploadRecord(remoteId: remoteId, sentAt: DateTime.utc(2026, 10, 29));
  }
}

class _Toasts extends ToastService {
  @override
  FutureOr<void> success(String message, {ToastOption? toast}) {}

  @override
  FutureOr<void> error(String message, {ToastOption? toast}) {}
}

void main() {
  late Drift db;
  late StoreService store;
  late MemoryShare share;
  late MockForegroundUploadService uploads;
  late List<List<String>> sent;
  final t = StaticTranslations.instance;

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
    uploads = MockForegroundUploadService();
    sent = [];
    share = MemoryShare(
      source,
      files: {
        '/a.jpg': fakePhoto(),
        '/b.jpg': fakePhoto(),
        '/c.jpg': fakePhoto(),
        '/d.jpg': fakePhoto(),
        '/Trip/e.jpg': fakePhoto(),
      },
    );
    share.folders['/'] = [
      share.folder('/Trip'),
      share.file('/a.jpg'),
      share.file('/b.jpg'),
      share.file('/c.jpg'),
      share.file('/d.jpg'),
    ];
    share.folders['/Trip'] = [share.file('/Trip/e.jpg')];
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
        callbacks.onSuccess?.call(item.id, 'remote-${item.entry.name}', isDuplicate: false);
      }
    });
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await store.dispose();
    await db.close();
  });

  Future<RootStackRouter> pumpBrowser(WidgetTester tester, {bool shell = true, bool tvMode = false}) =>
      pumpNetworkRouter(
        tester,
        home: NetworkBrowserPage(sourceId: source.id, path: '/'),
        builder: shell ? (context, child) => DesktopShell(child: child!) : null,
        overrides: [
          desktopWindowProvider.overrideWithValue(FakeSelectionWindow()),
          storeServiceProvider.overrideWithValue(store),
          overrideConnections((ref) => FakeConnections(ref, share)),
          networkThumbnailImageProvider.overrideWithValue(_PendingImage.new),
          uploadRecordStoreProvider.overrideWithValue(_MemoryRecords()),
          foregroundUploadServiceProvider.overrideWithValue(uploads),
          toastServiceProvider.overrideWithValue(_Toasts()),
          tvModeProvider.overrideWithValue(tvMode),
        ],
      );

  Finder tileOf(String name) =>
      find.byWidgetPredicate((widget) => widget is NetworkMediaTile && widget.entry.name == name);

  NetworkSelection picked(WidgetTester tester) => ProviderScope.containerOf(
    tester.element(find.byType(NetworkBrowserPage)),
  ).read(networkSelectionProvider((sourceId: source.id, path: '/')));

  Future<void> clickWith(WidgetTester tester, List<LogicalKeyboardKey> keys, Finder finder) =>
      withKeys(tester, keys, () async {
        await click(tester, finder);
        await tester.pumpAndSettle();
      });

  group('on Windows', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.windows);

    testWidgets('Control click picks without opening, a second one adds, then a click adds or takes out', (
      tester,
    ) async {
      final router = await pumpBrowser(tester);

      await clickWith(tester, [LogicalKeyboardKey.controlLeft], tileOf('a.jpg'));
      expect(picked(tester).isActive, isTrue);
      expect(picked(tester).paths, {'/a.jpg'});
      expect(router.current.name, 'HomeRoute', reason: 'nothing opened');
      await clickWith(tester, [LogicalKeyboardKey.controlLeft], tileOf('c.jpg'));
      expect(picked(tester).paths, {'/a.jpg', '/c.jpg'});
      expect(find.text(t.network_upload_selected(count: 2)), findsOneWidget);

      await click(tester, tileOf('a.jpg'));
      await tester.pumpAndSettle();
      expect(picked(tester).paths, {'/c.jpg'});
      expect(router.current.name, 'HomeRoute');
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Shift click picks the range in the order of the grid; a folder opens, Control or not', (tester) async {
      final router = await pumpBrowser(tester);

      await clickWith(tester, [LogicalKeyboardKey.controlLeft], tileOf('d.jpg'));
      await clickWith(tester, [LogicalKeyboardKey.shiftLeft], tileOf('b.jpg'));
      expect(picked(tester).paths, {'/b.jpg', '/c.jpg', '/d.jpg'});

      await clickWith(tester, [LogicalKeyboardKey.controlLeft], find.text('Trip'));
      expect(router.current.name, NetworkBrowserRoute.name);
      expect(router.current.argsAs<NetworkBrowserRouteArgs>().path, '/Trip');
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a Shift click finds its anchor again after a refresh brought a file above it', (tester) async {
      await pumpBrowser(tester);
      await clickWith(tester, [LogicalKeyboardKey.controlLeft], tileOf('c.jpg'));

      share.files['/0.jpg'] = fakePhoto();
      share.folders['/'] = [share.folder('/Trip'), share.file('/0.jpg'), ...share.folders['/']!.skip(1)];
      unawaited(tester.state<RefreshIndicatorState>(find.byType(RefreshIndicator)).show());
      await tester.pumpAndSettle();
      expect(tileOf('0.jpg'), findsOneWidget, reason: 'the new file shows first');
      expect(picked(tester).paths, {'/c.jpg'});

      await clickWith(tester, [LogicalKeyboardKey.shiftLeft], tileOf('d.jpg'));
      expect(picked(tester).paths, {'/c.jpg', '/d.jpg'}, reason: 'from c.jpg, not from what is where it was');
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Control A picks every photo and video of the folder, Escape stops picking', (tester) async {
      await pumpBrowser(tester);

      expect(await withShortcut(tester, LogicalKeyboardKey.keyA), isTrue);
      await tester.pumpAndSettle();
      expect(picked(tester).paths, {'/a.jpg', '/b.jpg', '/c.jpg', '/d.jpg'});
      expect(find.text(t.network_upload_selected(count: 4)), findsOneWidget);
      await withShortcut(tester, LogicalKeyboardKey.keyA);
      await tester.pumpAndSettle();
      expect(picked(tester).paths, hasLength(4), reason: 'twice stays all');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(picked(tester).isActive, isFalse);
      expect(find.byKey(const Key('network_media_unselected')), findsNothing);
      expect(find.text('Home NAS'), findsOneWidget, reason: 'the bar of the folder is back');
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a right click opens the menu; "Upload to Immich" sends the picked files in the order of the grid', (
      tester,
    ) async {
      await pumpBrowser(tester);
      await clickWith(tester, [LogicalKeyboardKey.controlLeft], tileOf('c.jpg'));
      await clickWith(tester, [LogicalKeyboardKey.controlLeft], tileOf('a.jpg'));

      await rightClick(tester, tileOf('a.jpg'));
      await tester.pumpAndSettle();
      expect(picked(tester).paths, {'/a.jpg', '/c.jpg'}, reason: 'a right click on a picked file keeps the others');
      final upload = find.byKey(const Key('desktop_selection_upload'));
      expect(find.descendant(of: upload, matching: find.text(t.network_upload_action)), findsOneWidget);

      await tester.tap(upload);
      await tester.pumpAndSettle();
      expect(sent, [
        ['/a.jpg', '/c.jpg'],
      ]);
      expect(picked(tester).isActive, isFalse, reason: 'picking ends with the upload, as with the bar');
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a right click on a file not picked picks it alone, with Control it joins', (tester) async {
      await pumpBrowser(tester);
      await clickWith(tester, [LogicalKeyboardKey.controlLeft], tileOf('a.jpg'));

      await rightClick(tester, tileOf('d.jpg'));
      await tester.pumpAndSettle();
      expect(picked(tester).paths, {'/d.jpg'});
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('desktop_selection_upload')), findsNothing, reason: 'Escape closed the menu');
      expect(picked(tester).paths, {'/d.jpg'});

      await withKeys(tester, [LogicalKeyboardKey.controlLeft], () async {
        await rightClick(tester, tileOf('b.jpg'));
        await tester.pumpAndSettle();
      });
      expect(picked(tester).paths, {'/b.jpg', '/d.jpg'});
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('without a server, the menu says that one is needed, greyed', (tester) async {
      await store.put(StoreKey.localSession, true);
      await pumpBrowser(tester);

      await rightClick(tester, tileOf('b.jpg'));
      await tester.pumpAndSettle();
      final line = find.byKey(const Key('desktop_selection_needs_server'));
      expect(find.descendant(of: line, matching: find.text(t.network_upload_needs_server)), findsOneWidget);
      expect(
        tester.widget<MenuItemButton>(find.descendant(of: line, matching: find.byType(MenuItemButton))).onPressed,
        isNull,
      );
      expect(find.byKey(const Key('desktop_selection_upload')), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('the remote control layout keeps the browser as it was', (tester) async {
      await pumpBrowser(tester, tvMode: true);

      await withShortcut(tester, LogicalKeyboardKey.keyA);
      await rightClick(tester, tileOf('b.jpg'));
      await tester.pumpAndSettle();
      expect(picked(tester).isActive, isFalse);
      expect(find.byKey(const Key('desktop_selection_upload')), findsNothing);

      await clickWith(tester, [LogicalKeyboardKey.controlLeft], tileOf('a.jpg'));
      expect(find.text('photo nas /a.jpg'), findsOneWidget, reason: 'Control click opens, as a click');
      debugDefaultTargetPlatformOverride = null;
    });
  });

  testWidgets('a phone keeps the browser: Control click opens, a right click does nothing', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final router = await pumpBrowser(tester, shell: false);

    await rightClick(tester, tileOf('b.jpg'));
    await tester.pumpAndSettle();
    expect(picked(tester).isActive, isFalse);

    await clickWith(tester, [LogicalKeyboardKey.controlLeft], tileOf('a.jpg'));
    expect(find.text('photo nas /a.jpg'), findsOneWidget);
    await router.maybePop();
    await tester.pumpAndSettle();

    await tester.longPress(tileOf('a.jpg'));
    await tester.pumpAndSettle();
    await clickWith(tester, [LogicalKeyboardKey.shiftLeft], tileOf('c.jpg'));
    expect(picked(tester).paths, {'/a.jpg', '/c.jpg'}, reason: 'a click adds while picking, Shift or not');
    debugDefaultTargetPlatformOverride = null;
  });
}
