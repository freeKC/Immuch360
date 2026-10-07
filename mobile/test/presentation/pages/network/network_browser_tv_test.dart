// The share browser with a remote control: it starts on the first folder (or the first photo when there is no
// folder), the arrows go through the folders then the grid, OK opens a photo, and nothing is picked to be sent: on a
// TV the app is a viewer. Pull to refresh becomes a button.

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/upload_record_store.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/pages/network/network_browser.page.dart';
import 'package:immich_mobile/presentation/widgets/network/network_media_tile.widget.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';
import 'package:immich_mobile/routing/app_navigation_observer.dart';
import 'package:immich_mobile/routing/router.dart';

import 'network_viewer_fakes.dart';

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
        '/flat.jpg': fakePhoto(),
        '/second.jpg': fakePhoto(),
        '/Holidays/beach.jpg': fakePhoto(),
        '/Holidays/sea.jpg': fakePhoto(),
      },
    );
    share.folders['/'] = [
      share.folder('/Holidays'),
      share.folder('/Work/'),
      share.file('/flat.jpg'),
      share.file('/second.jpg'),
    ];
    share.folders['/Holidays'] = [share.file('/Holidays/beach.jpg'), share.file('/Holidays/sea.jpg')];
    share.folders['/Work'] = [];
  });

  tearDown(() async {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await store.dispose();
    await db.close();
  });

  Finder tileOf(String name) =>
      find.byWidgetPredicate((widget) => widget is NetworkMediaTile && widget.entry.name == name);

  bool focusedIn(Finder finder) {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) {
      return false;
    }
    final targets = finder.evaluate().toSet();
    var found = targets.contains(focused);
    focused.visitAncestorElements((element) {
      found = found || targets.contains(element);
      return !found;
    });
    return found;
  }

  List<Override> overrides({bool tvMode = true}) => [
    tvModeProvider.overrideWithValue(tvMode),
    storeServiceProvider.overrideWithValue(store),
    overrideConnections((ref) => FakeConnections(ref, share)),
    networkThumbnailImageProvider.overrideWithValue(_PendingImage.new),
    uploadRecordStoreProvider.overrideWithValue(_NoRecords()),
  ];

  Future<void> pumpBrowser(WidgetTester tester, {String path = '/', bool tvMode = true}) async {
    await pumpNetworkRouter(
      tester,
      home: NetworkBrowserPage(sourceId: source.id, path: path),
      overrides: overrides(tvMode: tvMode),
    );
    await tester.pumpAndSettle();
  }

  /// The browser pushed over a home page as in the app, with its navigation observer, which gives the focus to the
  /// first item of a page that focuses nothing by itself
  Future<RootStackRouter> pumpObservedApp(WidgetTester tester) async {
    final router = RootStackRouter.build(
      routes: [
        AutoRoute(
          path: '/',
          initial: true,
          page: PageInfo('HomeRoute', builder: (_) => const Scaffold(body: Text('home'))),
        ),
        AutoRoute(
          path: '/network-browser',
          page: PageInfo(
            NetworkBrowserRoute.name,
            builder: (data) {
              final args = data.argsAs<NetworkBrowserRouteArgs>();
              return NetworkBrowserPage(sourceId: args.sourceId, path: args.path);
            },
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: locales.values.toList(),
        path: translationsPath,
        startLocale: locales.values.first,
        fallbackLocale: locales.values.first,
        saveLocale: false,
        useFallbackTranslations: true,
        assetLoader: const CodegenLoader(),
        child: ProviderScope(
          overrides: overrides(),
          child: Consumer(
            builder: (context, ref, _) => MaterialApp.router(
              debugShowCheckedModeBanner: false,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              routerConfig: router.config(navigatorObservers: () => [AppNavigationObserver(ref: ref)]),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  testWidgets('starts on the first folder, and the arrows go through the folders, then the grid', (tester) async {
    await pumpBrowser(tester);
    expect(focusedIn(find.widgetWithText(NetworkFolderTile, 'Holidays')), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(focusedIn(find.widgetWithText(NetworkFolderTile, 'Work')), isTrue);

    // Into the grid, on the tile nearest to the middle of the folder row above it
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(focusedIn(tileOf('second.jpg')), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(focusedIn(tileOf('flat.jpg')), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('photo nas /flat.jpg'), findsOneWidget);
  });

  testWidgets('OK on a folder goes into it, where the first photo has the focus', (tester) async {
    await pumpBrowser(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.text('Holidays'), findsOneWidget, reason: 'the title of the folder');
    expect(focusedIn(tileOf('beach.jpg')), isTrue);
  });

  testWidgets('nothing to pick on a TV, and a refresh button instead of the pull', (tester) async {
    await pumpBrowser(tester);

    expect(find.byTooltip('Select'), findsNothing);
    expect(find.byTooltip('Refresh'), findsOneWidget);
    expect(tester.widget<NetworkMediaTile>(tileOf('flat.jpg')).onLongPress, isNull);

    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(NetworkFolderTile, 'Holidays'), findsOneWidget);
  });

  testWidgets('a phone keeps the selection, without a refresh button nor an initial focus', (tester) async {
    await pumpBrowser(tester, tvMode: false);

    expect(find.byTooltip('Select'), findsOneWidget);
    expect(find.byTooltip('Refresh'), findsNothing);
    expect(focusedIn(find.byType(NetworkFolderTile)), isFalse);
    await tester.longPress(tileOf('flat.jpg'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
  });

  testWidgets('a folder listed after the page opened gets the focus from the Back button, and OK opens it', (
    tester,
  ) async {
    final router = await pumpObservedApp(tester);
    // A share answers after a while: the page shows, and its Back button gets the focus meanwhile
    final listed = Completer<void>();
    share.listGate = listed;
    unawaited(router.push(NetworkBrowserRoute(sourceId: source.id, path: '/')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(focusedIn(find.byType(BackButton)), isTrue);

    listed.complete();
    await tester.pumpAndSettle();
    expect(focusedIn(find.widgetWithText(NetworkFolderTile, 'Holidays')), isTrue);

    share.listGate = null;
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('Holidays'), findsOneWidget, reason: 'the title of the folder');
    expect(focusedIn(tileOf('beach.jpg')), isTrue);
  });
}
