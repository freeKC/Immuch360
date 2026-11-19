// The gyroscope choice of the 360° viewers (issue 20): one setting for the 360° photo viewer and the 360° video player.
// The photo viewer opens with the choice made last, photo or video, stores the one its button makes, and a TV or a
// device whose gyroscope fails never turns it on nor stores anything.

import 'dart:ui' as ui;

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/viewer_config.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';

/// Yields [image] once, as an image from the network would
class _TestImageProvider extends ImageProvider<_TestImageProvider> {
  const _TestImageProvider(this.image);

  final ui.Image image;

  @override
  Future<_TestImageProvider> obtainKey(ImageConfiguration configuration) => Future.value(this);

  @override
  ImageStreamCompleter loadImage(_TestImageProvider key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(Future.value(ImageInfo(image: image.clone())));
}

/// The stored choice, and what the viewer stored
class _Choice implements PanoramaGyroscopeChoice {
  _Choice(this.enabled);

  @override
  bool enabled;

  final stored = <bool>[];

  @override
  Future<void> remember(bool enabled) async {
    stored.add(enabled);
    this.enabled = enabled;
  }
}

const _gyroscopeChannel = EventChannel('dev.fluttercommunity.plus/sensors/gyroscope');
const _accelerometerChannel = EventChannel('dev.fluttercommunity.plus/sensors/accelerometer');
const _sensorsMethods = MethodChannel('dev.fluttercommunity.plus/sensors/method');
const _wakelock = 'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';

void main() {
  late Drift db;
  late StoreService store;
  // How many times the viewer listened to the gyroscope
  late int gyroscopeListens;

  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    gyroscopeListens = 0;
  });

  tearDown(() async {
    await store.dispose();
    await db.close();
  });

  /// The sensors and the wake lock of the device; [gyroscopeFails] stands for a device without a gyroscope
  void mockDevice(WidgetTester tester, {bool gyroscopeFails = false}) {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockStreamHandler(
      _gyroscopeChannel,
      MockStreamHandler.inline(
        onListen: (_, events) {
          gyroscopeListens++;
          if (gyroscopeFails) {
            events.error(code: 'NO_SENSOR', message: 'No gyroscope');
          }
        },
      ),
    );
    messenger.setMockStreamHandler(_accelerometerChannel, MockStreamHandler.inline(onListen: (_, _) {}));
    messenger.setMockMethodCallHandler(_sensorsMethods, (_) async => null);
    messenger.setMockMessageHandler(_wakelock, (_) async => const StandardMessageCodec().encodeMessage(<Object?>[]));
    addTearDown(() {
      messenger.setMockStreamHandler(_gyroscopeChannel, null);
      messenger.setMockStreamHandler(_accelerometerChannel, null);
      messenger.setMockMethodCallHandler(_sensorsMethods, null);
      messenger.setMockMessageHandler(_wakelock, null);
    });
  }

  Future<void> pumpViewer(WidgetTester tester, _Choice choice, {bool tvMode = false}) async {
    final image = (await tester.runAsync(() => createTestImage(width: 64, height: 32)))!;
    addTearDown(image.dispose);
    final PanoramaSource source = (image: _TestImageProvider(image), name: 'trip.jpg', length: null, read: null);
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
          overrides: [
            storeServiceProvider.overrideWithValue(store),
            isHorizonOsProvider.overrideWith((ref) => false),
            tvModeProvider.overrideWithValue(tvMode),
            panoramaGyroscopeChoiceProvider.overrideWithValue(choice),
          ],
          child: Builder(
            builder: (context) => MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: PanoramaViewerPage.source(source: source),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final gyroscopeButton = find.byWidgetPredicate((widget) => widget is IconButton && widget.tooltip == 'Gyroscope');

  bool gyroscopeOn(WidgetTester tester) => tester.widget<IconButton>(gyroscopeButton).isSelected ?? false;

  testWidgets('off as stored: the button turns it on, and the choice is stored for the 360° video player too', (
    tester,
  ) async {
    mockDevice(tester);
    final choice = _Choice(false);
    await pumpViewer(tester, choice);

    expect(gyroscopeOn(tester), isFalse);
    expect(gyroscopeListens, 0, reason: 'off, the motion of the phone is not even read');
    expect(choice.stored, isEmpty);

    await tester.tap(gyroscopeButton);
    await tester.pumpAndSettle();
    expect(gyroscopeOn(tester), isTrue);
    expect(gyroscopeListens, 1);
    expect(choice.stored, [true]);

    await tester.tap(gyroscopeButton);
    await tester.pumpAndSettle();
    expect(gyroscopeOn(tester), isFalse);
    expect(choice.stored, [true, false]);
  });

  testWidgets('on as stored, by the 360° video player or an earlier photo: the viewer opens with it on', (
    tester,
  ) async {
    mockDevice(tester);
    final choice = _Choice(true);
    await pumpViewer(tester, choice);

    expect(gyroscopeOn(tester), isTrue);
    expect(gyroscopeListens, 1);
    // Opening with the choice stores nothing
    expect(choice.stored, isEmpty);
  });

  testWidgets('a TV has no gyroscope button and never turns it on, whatever is stored', (tester) async {
    mockDevice(tester);
    final choice = _Choice(true);
    await pumpViewer(tester, choice, tvMode: true);

    expect(gyroscopeButton, findsNothing);
    expect(gyroscopeListens, 0);
    expect(choice.stored, isEmpty);
  });

  testWidgets('a gyroscope that fails turns the mode off without changing the stored choice', (tester) async {
    mockDevice(tester, gyroscopeFails: true);
    final choice = _Choice(true);
    await pumpViewer(tester, choice);

    expect(gyroscopeOn(tester), isFalse);
    expect(find.text('No gyroscope on this device'), findsOneWidget);
    expect(choice.stored, isEmpty);
  });

  group('the setting', () {
    test('is off by default, as the photo viewer always opened, and a stored on wins', () {
      expect(const AppConfig().viewer.panoramaGyroscope, isFalse);
      expect(defaultConfig.read(SettingsKey.viewerPanoramaGyroscope), isFalse);
      final config = AppConfig.fromEntries({SettingsKey.viewerPanoramaGyroscope: true});
      expect(config.viewer.panoramaGyroscope, isTrue);
      expect(config.write(SettingsKey.viewerPanoramaGyroscope, false).viewer.panoramaGyroscope, isFalse);
      // Its own key: the stabilisation keeps its setting
      expect(config.viewer.stabilizeVideos, const ViewerConfig().stabilizeVideos);
    });
  });
}
