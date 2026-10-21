// The one-key rotation in the asset viewer: R and Shift R of a keyboard, the yellow and blue keys of a remote, the
// Rotate button of the bottom row on a phone, the one of the bottom bar on a TV (OK from the photo lands on it, each OK
// turns again and the focus stays), the one of the top bar on a computer. Nothing of it for a video or a photo viewed
// in 360°, whose keys go on as if unread; and R typed into a text field stays a letter.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_viewer.page.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/rotate_button.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_keys.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/view_rotation.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../../../fixtures/asset.stub.dart';
import '../../../unit/presentation/presentation_context.dart';

class _SeededAssetViewerNotifier extends AssetViewerStateNotifier {
  _SeededAssetViewerNotifier(this._asset);

  final BaseAsset _asset;

  @override
  AssetViewerState build() {
    super.build();
    return AssetViewerState(currentAsset: _asset, showingControls: false);
  }
}

/// Presses [key]. The colour keys of a remote have no physical key in the simulator's maps: they come with one of
/// their own, as the Android embedder sends them with the scan code of the remote.
Future<bool> sendKey(WidgetTester tester, LogicalKeyboardKey key) => tester.sendKeyEvent(
  key,
  physicalKey: switch (key) {
    LogicalKeyboardKey.colorF2Yellow => PhysicalKeyboardKey.f23,
    LogicalKeyboardKey.colorF3Blue => PhysicalKeyboardKey.f24,
    _ => null,
  },
);

void main() {
  late PresentationContext context;
  final photo = LocalAssetStub.image1;
  final video = LocalAssetStub.image1.copyWith(id: 'video1', type: AssetType.video, durationMs: 120000);

  setUpAll(() => registerFallbackValue(photo));

  setUp(() async {
    context = await PresentationContext.create();
    when(() => context.service.asset.service.watchAsset(any())).thenAnswer((_) => const Stream.empty());
    when(() => context.service.asset.service.watchExif(any())).thenAnswer((_) => Stream.value(null));
    ViewRotations.resetPrune();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      (_) async => const StandardMessageCodec().encodeMessage(<Object?>[]),
    );
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      null,
    );
    await StoreService.I.delete(StoreKey.viewRotations);
    await StoreService.I.delete(StoreKey.forcedPanoramaAssets);
    await context.dispose();
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    // The photos cannot load without the platform: their errors are not what is tested here
    tester.takeException();
  }

  Future<ProviderContainer> pumpViewer(WidgetTester tester, BaseAsset asset, {bool tvMode = false}) async {
    final timeline = TimelineService((
      assetSource: (index, count) async => [asset].skip(index).take(count).toList(),
      bucketSource: () => Stream.value([const Bucket(assetCount: 1)]),
      origin: TimelineOrigin.main,
    ));
    addTearDown(timeline.dispose);
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
            ...context.overrides,
            tvModeProvider.overrideWithValue(tvMode),
            assetViewerProvider.overrideWith(() => _SeededAssetViewerNotifier(asset)),
            viewRotationAssetIdsProvider.overrideWithValue((_) async => null),
          ],
          child: Builder(
            builder: (context) => MaterialApp(
              debugShowCheckedModeBanner: false,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: Material(child: AssetViewerPage(initialIndex: 0, timelineService: timeline)),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    return ProviderScope.containerOf(tester.element(find.byType(AssetViewer)));
  }

  int turnsOf(ProviderContainer container, BaseAsset asset) =>
      container.read(viewRotationsProvider.notifier).assetTurns(asset);

  Future<bool> press(WidgetTester tester, LogicalKeyboardKey key, {bool shift = false}) async {
    if (shift) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    }
    final handled = await sendKey(tester, key);
    if (shift) {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    }
    await settle(tester);
    return handled;
  }

  testWidgets('R and the yellow key turn a flat photo clockwise, Shift R and the blue key the other way', (
    tester,
  ) async {
    final container = await pumpViewer(tester, photo);

    expect(await press(tester, LogicalKeyboardKey.keyR), isTrue);
    expect(turnsOf(container, photo), 1);
    expect(container.read(displayQuarterTurnsProvider(photo)), 1);
    await press(tester, LogicalKeyboardKey.colorF2Yellow);
    expect(turnsOf(container, photo), 2);
    await press(tester, LogicalKeyboardKey.colorF3Blue);
    expect(turnsOf(container, photo), 1);
    await press(tester, LogicalKeyboardKey.keyR, shift: true);
    expect(turnsOf(container, photo), 0);
    expect(StoreService.I.tryGet(StoreKey.viewRotations), isNull, reason: 'back to no turn, nothing kept');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.keyR), isFalse, reason: 'Control R is left to others');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(turnsOf(container, photo), 0);
  });

  testWidgets('a held key does not spin the photo', (tester) async {
    final container = await pumpViewer(tester, photo);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyR);
    await settle(tester);
    expect(turnsOf(container, photo), 1);
  });

  testWidgets('nothing turns a photo viewed in 360°, nor a video: their keys go on unread', (tester) async {
    final container = await pumpViewer(tester, video);
    expect(await press(tester, LogicalKeyboardKey.keyR), isFalse);
    expect(await press(tester, LogicalKeyboardKey.colorF2Yellow), isFalse);
    expect(turnsOf(container, video), 0);
    expect(find.byIcon(Icons.rotate_90_degrees_cw_rounded), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    final sphere = LocalAssetStub.image2;
    await StoreService.I.put(StoreKey.forcedPanoramaAssets, '["${sphere.id}"]');
    final viewer = await pumpViewer(tester, sphere);
    expect(viewer.read(isForcedPanoramaProvider(sphere)), isTrue);
    expect(await press(tester, LogicalKeyboardKey.keyR), isFalse);
    expect(await press(tester, LogicalKeyboardKey.colorF3Blue), isFalse);
    expect(turnsOf(viewer, sphere), 0);
    viewer.read(assetViewerProvider.notifier).setControls(true);
    await settle(tester);
    expect(find.byIcon(Icons.rotate_90_degrees_cw_rounded), findsNothing);
  });

  testWidgets('the Rotate button of a phone turns clockwise, and a long press counter clockwise', (tester) async {
    final container = await pumpViewer(tester, photo);
    container.read(assetViewerProvider.notifier).setControls(true);
    await settle(tester);

    final button = find.text('Rotate');
    expect(button, findsOneWidget);
    await tester.tap(button);
    await settle(tester);
    expect(turnsOf(container, photo), 1);
    await tester.tap(button);
    await settle(tester);
    expect(turnsOf(container, photo), 2, reason: 'never disabled by the previous press');
    await tester.longPress(button);
    await settle(tester);
    expect(turnsOf(container, photo), 1);
  });

  testWidgets('on a TV OK from the photo lands on Rotate, and each OK turns again, the focus staying', (tester) async {
    final container = await pumpViewer(tester, photo, tvMode: true);
    expect(find.byType(TvRotateButton), findsOneWidget);

    await press(tester, LogicalKeyboardKey.select);
    expect(container.read(assetViewerProvider).showingControls, isTrue);
    bool rotateHasFocus() =>
        FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TvRotateButton>() != null;
    expect(rotateHasFocus(), isTrue);

    await press(tester, LogicalKeyboardKey.select);
    expect(turnsOf(container, photo), 1);
    expect(rotateHasFocus(), isTrue);
    await press(tester, LogicalKeyboardKey.select);
    expect(turnsOf(container, photo), 2);
    expect(rotateHasFocus(), isTrue);

    // The colour keys from there too
    await press(tester, LogicalKeyboardKey.colorF3Blue);
    expect(turnsOf(container, photo), 1);
  });

  testWidgets('a computer has the rotation in the top bar, not in the bottom row', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final container = await pumpViewer(tester, photo);
    container.read(assetViewerProvider.notifier).setControls(true);
    await settle(tester);

    expect(find.text('Rotate'), findsNothing);
    final button = find.byTooltip('Rotate 90° clockwise');
    expect(button, findsOneWidget);
    await tester.tap(button);
    await settle(tester);
    expect(turnsOf(container, photo), 1);
    await press(tester, LogicalKeyboardKey.keyR);
    expect(turnsOf(container, photo), 2);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('R typed into a text field stays a letter', (tester) async {
    var rotations = 0;
    KeyEventResult viewerKeys(FocusNode node, KeyEvent event) {
      if (isRemoteRotateClockwise(event) || isRemoteRotateCounterClockwise(event)) {
        if (isRemotePress(event)) {
          rotations++;
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: Focus(onKeyEvent: viewerKeys, child: const TextField()),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.keyR), isFalse);
    expect(rotations, 0);
    // The yellow key types nothing: it turns the photo from there too
    expect(await sendKey(tester, LogicalKeyboardKey.colorF2Yellow), isTrue);
    expect(rotations, 1);
  });
}
