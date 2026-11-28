// A pinch on a computer's touchpad in the photo page of a share or a folder (28 November 2026). The pinch always
// zoomed there, but it took the pan Windows sends with it as a move of the picture: a pinch that doubles, in the
// middle of the window, threw the photo to its corner. Now a pinch zooms around the pointer and its pan moves nothing;
// two fingers pan a zoomed photo; Control and the wheel, and a scale signal, zoom too.

import 'dart:async';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/desktop/window/desktop_photo_zoom.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/pages/network/network_photo.page.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/routing/router.dart';

import '../../../desktop/window/trackpad_pinch_sequences.dart';
import 'network_viewer_fakes.dart';

/// A flat photo of 4000 x 2000 pixels
class _Detection extends NetworkMediaService {
  @override
  Future<NetworkMediaInfo?> detect(
    NetworkEntry entry,
    ByteRangeReader read, {
    bool thorough = false,
    bool Function()? isWanted,
  }) async => const NetworkMediaInfo(frameWidth: 4000, frameHeight: 2000);
}

const _source = NetworkSource(id: 'nas', type: NetworkSourceType.smb, name: 'Home NAS', host: 'nas', share: 'media');

void main() {
  late Drift db;
  late StoreService store;
  late MemoryShare share;
  const window = Size(1600, 960);
  final middle = Offset(window.width / 2, window.height / 2);
  final lower = Offset(window.width / 2, window.height * 0.8);

  // One database for the file: the settings a computer reads as the page opens are a singleton bound to the first
  setUpAll(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    await SettingsRepository.ensureInitialized(db);
    await store.put(StoreKey.networkSources, NetworkSource.encodeList(const [_source]));
  });

  tearDownAll(() async {
    await store.dispose();
    await db.close();
  });

  setUp(() {
    share = MemoryShare(_source, files: {'/a.jpg': fakePhoto()});
    share.folders['/'] = [share.file('/a.jpg')];
  });

  Future<DesktopZoomController> open(WidgetTester tester) async {
    tester.view.physicalSize = window * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    const page = NetworkPhotoPage(sourceId: 'nas', path: '/a.jpg');
    final router = await pumpNetworkRouter(
      tester,
      home: const Scaffold(body: Text('folder')),
      pages: {NetworkPhotoRoute.name: (_) => page},
      settle: false,
      overrides: [
        tvModeProvider.overrideWithValue(false),
        storeServiceProvider.overrideWithValue(store),
        overrideConnections((ref) => FakeConnections(ref, share)),
        isHorizonOsProvider.overrideWith((ref) async => false),
        networkMediaServiceProvider.overrideWith((ref) => _Detection()),
      ],
    );
    unawaited(router.push(NetworkPhotoRoute(sourceId: 'nas', path: '/a.jpg')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final zoom = tester.widget<DesktopZoomView>(find.byType(DesktopZoomView)).controller;
    expect(zoom.frame, isNotNull);
    return zoom;
  }

  Future<void> on(TargetPlatform platform, WidgetTester tester, Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body();
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  Future<void> settle(WidgetTester tester) => tester.pump(const Duration(milliseconds: 600));

  /// Where a pinch of [steps] around [at] (window coordinates) leaves the photo from the fit, as the wheel zooms
  Offset around(DesktopZoomController zoom, Offset at, List<PanZoomStep> steps) {
    final frame = zoom.frame!;
    final focal = at - frame.viewport.center(Offset.zero);
    var shown = (scale: frame.fitScale, position: Offset.zero);
    var previous = 1.0;
    for (final step in steps) {
      shown = desktopZoomAround(frame, shown.scale, shown.position, shown.scale * step.scale / previous, focal);
      previous = step.scale;
    }
    return shown.position;
  }

  testWidgets('Windows: a pinch in the middle zooms two times and keeps the photo in the middle', (tester) async {
    await on(TargetPlatform.windows, tester, () async {
      final zoom = await open(tester);
      await sendPanZoom(tester, middle, windowsPinch(2, middle));
      await settle(tester);
      expect(zoom.scale, closeTo(2, 0.01));
      final expected = around(zoom, middle, windowsPinch(2, middle));
      expect((zoom.position - expected).distance, lessThan(1), reason: 'not thrown to its corner');
    });
  });

  testWidgets('Windows: a pinch low in the window zooms around the pointer, fast fingers too', (tester) async {
    await on(TargetPlatform.windows, tester, () async {
      final zoom = await open(tester);
      final pinch = fastWindowsPinch(2, lower);
      await sendPanZoom(tester, lower, pinch);
      await settle(tester);
      expect(zoom.scale, closeTo(2, 0.01));
      final expected = around(zoom, lower, pinch);
      expect(expected.dy, lessThan(-100));
      expect((zoom.position - expected).distance, lessThan(1));
    });
  });

  testWidgets('zoomed in, two fingers pan the photo; at fit they move nothing', (tester) async {
    await on(TargetPlatform.windows, tester, () async {
      final zoom = await open(tester);
      await sendPanZoom(tester, middle, scroll(const Offset(-200, 0)));
      await settle(tester);
      expect(zoom.position, Offset.zero);
      expect(tester.widget<NetworkPhotoPage>(find.byType(NetworkPhotoPage)).path, '/a.jpg');
      await sendPanZoom(tester, middle, windowsPinch(2, middle));
      await settle(tester);
      final before = zoom.position;
      await sendPanZoom(tester, middle, scroll(const Offset(0, -100)));
      await settle(tester);
      expect(zoom.position.dy, closeTo(before.dy - 100, 1));
      expect(zoom.scale, closeTo(2, 0.01));
    });
  });

  testWidgets('macOS and Linux: a pinch zooms two times around the pointer', (tester) async {
    for (final platform in [TargetPlatform.macOS, TargetPlatform.linux]) {
      await on(platform, tester, () async {
        final zoom = await open(tester);
        final pinch = platform == TargetPlatform.macOS ? macPinch(2) : linuxPinch(2);
        await sendPanZoom(tester, middle, pinch);
        await settle(tester);
        expect(zoom.scale, closeTo(2, 0.01), reason: '$platform');
        expect(zoom.position.distance, lessThan(1), reason: '$platform');
      });
    }
  });

  testWidgets('Control and the wheel, and a scale signal, zoom', (tester) async {
    await on(TargetPlatform.windows, tester, () async {
      final zoom = await open(tester);
      final mouse = TestPointer(61, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(middle));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      for (var i = 0; i < 8; i++) {
        await tester.sendEventToBinding(mouse.scroll(const Offset(0, -15)));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      final afterWheel = zoom.scale;
      expect(afterWheel, greaterThan(1.2));
      final pad = TestPointer(62, PointerDeviceKind.trackpad);
      await tester.sendEventToBinding(pad.hover(middle));
      await tester.sendEventToBinding(pad.scale(1.5));
      await settle(tester);
      expect(zoom.scale, closeTo(afterWheel * 1.5, 0.01));
    });
  });
}
