// The photo page of a share with a remote control: the Back button of its app bar leaves the page, where Back from
// the app bar only returns to the photo, and a photo that cannot be had shows Retry, which Down and OK reach.

import 'dart:async';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/pages/network/network_photo.page.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/routing/router.dart';

import 'network_viewer_fakes.dart';

/// Reads nothing from the file: a flat photo
class _NoDetection extends NetworkMediaService {
  @override
  Future<NetworkMediaInfo?> detect(
    NetworkEntry entry,
    ByteRangeReader read, {
    bool thorough = false,
    bool Function()? isWanted,
  }) async => null;
}

const _source = NetworkSource(id: 'nas', type: NetworkSourceType.smb, name: 'Home NAS', host: 'nas', share: 'media');

void main() {
  late Drift db;
  late StoreService store;
  late MemoryShare share;

  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    await store.put(StoreKey.networkSources, NetworkSource.encodeList(const [_source]));
    share = MemoryShare(_source, files: {'/a.jpg': fakePhoto()});
    share.folders['/'] = [share.file('/a.jpg')];
  });

  tearDown(() async {
    await store.dispose();
    await db.close();
  });

  /// The page opened from a folder, so that its app bar has a Back button
  Future<void> pumpPhoto(WidgetTester tester) async {
    const page = NetworkPhotoPage(sourceId: 'nas', path: '/a.jpg');
    final router = await pumpNetworkRouter(
      tester,
      home: const Scaffold(body: Text('folder')),
      pages: {NetworkPhotoRoute.name: (_) => page},
      settle: false,
      overrides: [
        tvModeProvider.overrideWithValue(true),
        storeServiceProvider.overrideWithValue(store),
        overrideConnections((ref) => FakeConnections(ref, share)),
        isHorizonOsProvider.overrideWith((ref) async => false),
        networkMediaServiceProvider.overrideWith((ref) => _NoDetection()),
      ],
    );
    unawaited(router.push(NetworkPhotoRoute(sourceId: 'nas', path: '/a.jpg')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  bool hasFocus(WidgetTester tester, Finder finder) => Focus.of(tester.element(finder)).hasPrimaryFocus;

  testWidgets('the Back button of the app bar leaves the page, where Back only leaves the app bar', (tester) async {
    await pumpPhoto(tester);
    final back = find.byType(BackButtonIcon);

    // OK goes to the menu, Left from there to the Back button
    await press(tester, LogicalKeyboardKey.select);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(hasFocus(tester, back), isTrue);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(NetworkPhotoPage), findsOneWidget, reason: 'the Back key returns to the photo first');
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Network photo');

    // Down from the app bar goes back to the photo too
    await press(tester, LogicalKeyboardKey.select);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Network photo');

    await press(tester, LogicalKeyboardKey.select);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    await press(tester, LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byType(NetworkPhotoPage), findsNothing);
    expect(find.text('folder'), findsOneWidget);
  });

  testWidgets('a photo that cannot be had: Down and OK reach Retry, which tries again', (tester) async {
    share.error = const NetworkFileSystemException('nas does not answer');
    await pumpPhoto(tester);
    final retry = find.text('Retry');
    expect(retry, findsOneWidget);

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(hasFocus(tester, retry), isTrue);

    // Up from Retry goes back to the page, Up again to the app bar, and Down from there to Retry
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Network photo');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(hasFocus(tester, find.byType(BackButtonIcon)), isTrue);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(hasFocus(tester, retry), isTrue);

    // OK from the page goes there too
    await press(tester, LogicalKeyboardKey.arrowUp);
    await press(tester, LogicalKeyboardKey.select);
    expect(hasFocus(tester, retry), isTrue);

    share.error = null;
    await press(tester, LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 50));
    expect(retry, findsNothing);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Network photo', reason: 'the page takes the keys again');
  });
}
