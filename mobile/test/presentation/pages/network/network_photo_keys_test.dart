// The photo page of a share with a remote control: the Back button of its app bar leaves the page, where Back from
// the app bar only returns to the photo, and a photo that cannot be had shows Retry, which Down and OK reach. A flat
// photo turns with the one-key rotation (OK then OK, R, the yellow and blue keys), kept on the device for its file;
// a 360° or 3D one, or one not read yet, never does. A photo named like a 3D one (street_TB.jpg) turns as any other,
// but on a Meta Quest with "3D by file name (experimental)" on, which offers it in 3D.

import 'dart:async';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/viewer_config.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/raw/raw_360_detection.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/pages/network/network_browser.page.dart';
import 'package:immich_mobile/presentation/pages/network/network_photo.page.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
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

/// Tells what [info] says of every file, once [gate] (when given) is done
class _Detection extends NetworkMediaService {
  _Detection(this.info, {this.gate});

  final NetworkMediaInfo info;
  final Completer<void>? gate;

  @override
  Future<NetworkMediaInfo?> detect(
    NetworkEntry entry,
    ByteRangeReader read, {
    bool thorough = false,
    bool Function()? isWanted,
  }) async {
    await gate?.future;
    return info;
  }
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

  /// The page of [path] opened from a folder, so that its app bar has a Back button; [detection] tells what the file
  /// is; on a Meta Quest with [horizonOs], with the settings of [appConfig] when given
  Future<void> pumpPhoto(
    WidgetTester tester, {
    NetworkMediaService? detection,
    String path = '/a.jpg',
    bool horizonOs = false,
    AppConfig? appConfig,
  }) async {
    final page = NetworkPhotoPage(sourceId: 'nas', path: path);
    final router = await pumpNetworkRouter(
      tester,
      home: const Scaffold(body: Text('folder')),
      pages: {NetworkPhotoRoute.name: (_) => page},
      settle: false,
      overrides: [
        tvModeProvider.overrideWithValue(true),
        storeServiceProvider.overrideWithValue(store),
        overrideConnections((ref) => FakeConnections(ref, share)),
        isHorizonOsProvider.overrideWith((ref) async => horizonOs),
        networkMediaServiceProvider.overrideWith((ref) => detection ?? _NoDetection()),
        if (appConfig != null) appConfigProvider.overrideWithValue(appConfig),
      ],
    );
    unawaited(router.push(NetworkPhotoRoute(sourceId: 'nas', path: path)));
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

  testWidgets('right opens the next photo of the folder in a page of its own, which shows that photo', (tester) async {
    share = MemoryShare(_source, files: {'/a.jpg': fakePhoto(), '/b.jpg': fakePhoto()});
    share.folders['/'] = [share.file('/a.jpg'), share.file('/b.jpg')];
    final entries = share.folders['/']!;
    final folder = NetworkFolderMedia(
      entries: entries,
      urls: {for (final entry in entries) entry.path: Uri.parse('http://127.0.0.1:1234/token/nas${entry.path}')},
      index: 0,
    );
    final router = await pumpNetworkRouter(
      tester,
      home: const Scaffold(body: Text('folder')),
      pages: {
        NetworkPhotoRoute.name: (data) {
          final args = data.argsAs<NetworkPhotoRouteArgs>();
          return NetworkPhotoPage(key: args.key, sourceId: args.sourceId, path: args.path, folder: args.folder);
        },
      },
      settle: false,
      overrides: [
        tvModeProvider.overrideWithValue(true),
        storeServiceProvider.overrideWithValue(store),
        overrideConnections((ref) => FakeConnections(ref, share)),
        isHorizonOsProvider.overrideWith((ref) async => false),
        networkMediaServiceProvider.overrideWith((ref) => _NoDetection()),
      ],
    );
    unawaited(router.push(NetworkPhotoRoute(sourceId: 'nas', path: '/a.jpg', folder: folder)));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final first = tester.state(find.byType(NetworkPhotoPage));

    await press(tester, LogicalKeyboardKey.arrowRight);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(tester.widget<NetworkPhotoPage>(find.byType(NetworkPhotoPage)).path, '/b.jpg');
    expect(identical(tester.state(find.byType(NetworkPhotoPage)), first), isFalse);
    final shown = tester
        .widgetList<Image>(find.byType(Image))
        .map((image) => image.image)
        .whereType<ResizeImage>()
        .map((image) => (image.imageProvider as NetworkImage).url)
        .toList();
    expect(shown, ['http://127.0.0.1:1234/token/nas/b.jpg'], reason: 'the next photo, not the first one');
  });

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

  int turnsOnScreen(WidgetTester tester) => tester
      .widget<RotatedBox>(find.descendant(of: find.byType(NetworkPhotoPage), matching: find.byType(RotatedBox)))
      .quarterTurns;

  Future<void> pressColour(WidgetTester tester, LogicalKeyboardKey key) async {
    // No physical key in the simulator's maps for the colour keys of a remote
    await tester.sendKeyEvent(
      key,
      physicalKey: key == LogicalKeyboardKey.colorF2Yellow ? PhysicalKeyboardKey.f23 : PhysicalKeyboardKey.f24,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('a flat photo turns with R and the colour keys, and turns again when the page opens again', (
    tester,
  ) async {
    await pumpPhoto(tester, detection: _Detection(const NetworkMediaInfo()));
    expect(turnsOnScreen(tester), 0);

    await press(tester, LogicalKeyboardKey.keyR);
    expect(turnsOnScreen(tester), 1);
    await pressColour(tester, LogicalKeyboardKey.colorF2Yellow);
    expect(turnsOnScreen(tester), 2);
    await pressColour(tester, LogicalKeyboardKey.colorF3Blue);
    expect(turnsOnScreen(tester), 1);
    final modified = MemoryShare.modified.millisecondsSinceEpoch;
    expect(
      store.tryGet(StoreKey.viewRotations),
      '{"n:nas:/a.jpg":{"t":1,"s":${share.files['/a.jpg']!.length},"m":$modified}}',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await pumpPhoto(tester, detection: _Detection(const NetworkMediaInfo()));
    expect(turnsOnScreen(tester), 1, reason: 'kept on the device for that file');
  });

  testWidgets('on a TV OK from the photo lands on Rotate, and each OK turns the photo again', (tester) async {
    await pumpPhoto(tester, detection: _Detection(const NetworkMediaInfo()));
    // The focus of the button, through its icon
    final rotate = find.descendant(of: find.byKey(const Key('network_photo_rotate')), matching: find.byType(Icon));
    expect(rotate, findsOneWidget);

    await press(tester, LogicalKeyboardKey.select);
    expect(hasFocus(tester, rotate), isTrue);
    await press(tester, LogicalKeyboardKey.select);
    expect(turnsOnScreen(tester), 1);
    await press(tester, LogicalKeyboardKey.select);
    expect(turnsOnScreen(tester), 2);
    expect(hasFocus(tester, rotate), isTrue);
  });

  testWidgets('nothing turns a photo not read yet, nor a 360° or raw one', (tester) async {
    final gate = Completer<void>();
    await pumpPhoto(tester, detection: _Detection(const NetworkMediaInfo(), gate: gate));
    expect(find.byKey(const Key('network_photo_rotate')), findsNothing);
    await press(tester, LogicalKeyboardKey.keyR);
    expect(turnsOnScreen(tester), 0, reason: 'what the file is, is not known yet');
    gate.complete();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const Key('network_photo_rotate')), findsOneWidget);

    for (final info in const [
      NetworkMediaInfo(cameraEquirect: true),
      NetworkMediaInfo(rawKind: RawMediaKind.insta360Photo),
    ]) {
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpPhoto(tester, detection: _Detection(info));
      expect(find.byKey(const Key('network_photo_rotate')), findsNothing);
      await press(tester, LogicalKeyboardKey.keyR);
      await pressColour(tester, LogicalKeyboardKey.colorF2Yellow);
      expect(turnsOnScreen(tester), 0, reason: '$info');
    }
    expect(store.tryGet(StoreKey.viewRotations), isNull);
  });

  testWidgets('a photo named like a 3D one turns off a Meta Quest, and on one with "3D by file name" off', (
    tester,
  ) async {
    share.files['/street_TB.jpg'] = fakePhoto();
    share.folders['/'] = [share.file('/a.jpg'), share.file('/street_TB.jpg')];
    final rotate = find.byKey(const Key('network_photo_rotate'));
    final view3d = find.byKey(const Key('apple_spatial_view_3d'));
    Future<void> open({bool horizonOs = false, AppConfig? appConfig}) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpPhoto(
        tester,
        path: '/street_TB.jpg',
        horizonOs: horizonOs,
        appConfig: appConfig,
        detection: _Detection(const NetworkMediaInfo()),
      );
    }

    // A phone, a TV or a computer: an ordinary photo, which turns and keeps its turn
    await open();
    expect(rotate, findsOneWidget);
    expect(view3d, findsNothing);
    await press(tester, LogicalKeyboardKey.keyR);
    expect(turnsOnScreen(tester), 1);
    await open();
    expect(turnsOnScreen(tester), 1, reason: 'kept on the device for that file');

    // A Meta Quest with the switch off: the same, the turn kept applies
    const off = AppConfig(viewer: ViewerConfig(flat3dByName: false));
    await open(horizonOs: true, appConfig: off);
    expect(rotate, findsOneWidget);
    expect(view3d, findsNothing);
    expect(turnsOnScreen(tester), 1);
    await pressColour(tester, LogicalKeyboardKey.colorF2Yellow);
    expect(turnsOnScreen(tester), 2);

    // A Meta Quest with the switch on, as it comes: "View in 3D", the eyes stay where they are
    await open(horizonOs: true, appConfig: const AppConfig());
    expect(view3d, findsOneWidget);
    expect(rotate, findsNothing);
    expect(turnsOnScreen(tester), 0);
    await press(tester, LogicalKeyboardKey.keyR);
    expect(turnsOnScreen(tester), 0);
  });
}
