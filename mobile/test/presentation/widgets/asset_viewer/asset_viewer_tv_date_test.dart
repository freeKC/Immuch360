// The date and time of a photo on a TV (the remote control layout): at the bottom left of the viewer (bottom right in a
// right to left language), shown and hidden with its controls, never over the top centre of the photo, and off with
// "Show photo date and time". A video on a TV and every phone keep them at the top centre, as in Immich. From the TV
// photo date of Michael Cloutier (mlc70).

import 'dart:ui' show Tristate;

import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/extensions/datetime_extensions.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_viewer.page.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/bottom_bar.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_bottom_app_bar.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_top_app_bar.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/view_rotation.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/utils/timezone.dart';
import 'package:mocktail/mocktail.dart';

import '../../../fixtures/asset.stub.dart';
import '../../../unit/presentation/presentation_context.dart';

class _SeededAssetViewerNotifier extends AssetViewerStateNotifier {
  _SeededAssetViewerNotifier(this._asset);

  final BaseAsset _asset;

  @override
  AssetViewerState build() {
    super.build();
    return AssetViewerState(currentAsset: _asset, showingControls: true);
  }
}

void main() {
  late PresentationContext context;
  final photo = LocalAssetStub.image1;
  final video = LocalAssetStub.image1.copyWith(id: 'video1', type: AssetType.video, durationMs: 120000);
  const wakelock = 'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';

  setUpAll(() => registerFallbackValue(photo));

  setUp(() async {
    context = await PresentationContext.create();
    when(() => context.service.asset.service.watchAsset(any())).thenAnswer((_) => const Stream.empty());
    when(() => context.service.asset.service.watchExif(any())).thenAnswer((_) => Stream.value(null));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(
      wakelock,
      (_) async => const StandardMessageCodec().encodeMessage(<Object?>[]),
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(wakelock, null);
    await context.dispose();
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    // The photos cannot load without the platform: their errors are not what is tested here
    tester.takeException();
  }

  Future<ProviderContainer> pumpViewer(
    WidgetTester tester,
    BaseAsset asset, {
    required bool tvMode,
    Locale? locale,
  }) async {
    final timeline = TimelineService((
      assetSource: (index, count) async => [asset].skip(index).take(count).toList(),
      bucketSource: () => Stream.value([const Bucket(assetCount: 1)]),
      origin: TimelineOrigin.main,
    ));
    addTearDown(timeline.dispose);
    // After a failure flutter_test leaves the tree mounted: take it down before the settings are reset (tearDown), or
    // the next test hangs instead of running
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: locales.values.toList(),
        path: translationsPath,
        startLocale: locale ?? locales.values.first,
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

  /// The date and the time the viewer shows for [asset], which has no EXIF here: its creation date
  (String, String) dateAndTimeOf(BaseAsset asset) {
    final (dateTime, _) = resolveAssetDateTime(asset, null);
    return (dateTime.formatDate(), dateTime.formatTime(alwaysUse24HourFormat: false));
  }

  Finder inTopBar(Finder finder) => find.descendant(of: find.byType(ViewerTopAppBar), matching: finder);

  Finder inBottomBar(Finder finder) => find.descendant(of: find.byType(ViewerBottomBar), matching: finder);

  final tvLabel = find.byKey(const Key('viewer_tv_date_time'));

  /// The opacity of the bar around [finder]: the one of the bottom bar, which follows the controls
  double barOpacity(WidgetTester tester, Finder finder) {
    final bar = find.ancestor(of: finder, matching: find.byType(AnimatedOpacity)).first;
    expect(find.ancestor(of: bar, matching: find.byType(ViewerBottomAppBar)), findsOneWidget);
    return tester.widget<AnimatedOpacity>(bar).opacity;
  }

  testWidgets('on a TV the date and time of a photo sit at the bottom left, not over the top centre', (tester) async {
    await pumpViewer(tester, photo, tvMode: true);
    final (date, time) = dateAndTimeOf(photo);

    expect(inTopBar(find.text(date)), findsNothing, reason: 'the top centre of the photo stays clear');
    expect(inBottomBar(find.text(date)), findsOneWidget);
    expect(inBottomBar(find.text(time)), findsOneWidget);
    expect(tvLabel, findsOneWidget);

    final screen = tester.getSize(find.byType(AssetViewer));
    final dateRect = tester.getRect(find.text(date));
    final timeRect = tester.getRect(find.text(time));
    expect(dateRect.left, lessThan(screen.width / 4), reason: 'on the left');
    expect(dateRect.top, greaterThan(screen.height / 2), reason: 'at the bottom');
    expect(timeRect.top, greaterThan(dateRect.top), reason: 'the time under the date');
    expect(timeRect.left, dateRect.left, reason: 'both aligned on the left');
    expect(
      find.descendant(of: tvLabel, matching: find.byType(Focus)),
      findsNothing,
      reason: 'it never takes the focus',
    );
  });

  testWidgets('on a TV the date and time are a node of their own for TalkBack, and Rotate reads only its label', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpViewer(tester, photo, tvMode: true);
    final (date, time) = dateAndTimeOf(photo);
    final rotateButton = find.byKey(const Key('tv_rotate_button'));
    expect(rotateButton, findsOneWidget);

    final rotate = tester.getSemantics(rotateButton);
    expect(rotate.label, 'Rotate 90° clockwise', reason: 'its own label, without the date: ${rotate.label}');
    expect(rotate.flagsCollection.isButton, isTrue);
    final rotateRect = tester.getRect(rotateButton);
    expect(rotate.rect.width, lessThan(rotateRect.width + 1), reason: 'the bounds of the button, not of the bar');

    final dateTime = tester.getSemantics(tvLabel);
    expect(dateTime.id, isNot(rotate.id));
    expect(dateTime.label, contains(date));
    expect(dateTime.label, contains(time));
    final dateRect = tester.getRect(tvLabel);
    expect(dateTime.rect.width, lessThan(dateRect.width + 1), reason: 'the bounds of the date, not of the bar');
    expect(
      dateTime.rect.width,
      lessThan(tester.getRect(find.byType(ViewerBottomBar)).width / 2),
      reason: 'a node of its own, narrower than the bar',
    );

    // With the focus, as Down gives it: the focused node is the button alone
    Focus.of(tester.element(find.descendant(of: rotateButton, matching: find.text('Rotate')))).requestFocus();
    await settle(tester);
    final focused = tester.getSemantics(rotateButton);
    expect(focused.flagsCollection.isFocused, Tristate.isTrue);
    expect(focused.label, 'Rotate 90° clockwise');
    semantics.dispose();
  });

  testWidgets('on a TV in a right to left language they sit at the bottom right', (tester) async {
    await pumpViewer(tester, photo, tvMode: true, locale: const Locale('ar'));

    expect(tvLabel, findsOneWidget);
    expect(Directionality.of(tester.element(tvLabel)), TextDirection.rtl);
    final screen = tester.getSize(find.byType(AssetViewer));
    final label = tester.getRect(tvLabel);
    expect(label.right, greaterThan(screen.width * 3 / 4), reason: 'on the right');
    expect(screen.width - label.right, lessThan(32), reason: 'by the side, the buttons of the row on its left');
    expect(label.top, greaterThan(screen.height / 2), reason: 'at the bottom');
  });

  testWidgets('on a TV they show and hide with the controls', (tester) async {
    final container = await pumpViewer(tester, photo, tvMode: true);
    expect(barOpacity(tester, tvLabel), 1);

    container.read(assetViewerProvider.notifier).setControls(false);
    await settle(tester);
    expect(barOpacity(tester, tvLabel), 0);

    container.read(assetViewerProvider.notifier).setControls(true);
    await settle(tester);
    expect(barOpacity(tester, tvLabel), 1);
  });

  testWidgets('"Show photo date and time" off: no date on a photo of a TV', (tester) async {
    await SettingsRepository.instance.write(SettingsKey.viewerTvShowDateTime, false);
    await pumpViewer(tester, photo, tvMode: true);
    final (date, time) = dateAndTimeOf(photo);

    expect(find.text(date), findsNothing);
    expect(find.text(time), findsNothing);
    expect(tvLabel, findsNothing);
  });

  testWidgets('a video on a TV keeps its date at the top centre', (tester) async {
    await pumpViewer(tester, video, tvMode: true);
    final (date, _) = dateAndTimeOf(video);

    expect(inTopBar(find.text(date)), findsOneWidget);
    expect(inBottomBar(find.text(date)), findsNothing);
    expect(tvLabel, findsNothing);
  });

  testWidgets('a phone keeps the date of a photo at the top centre, the setting changes nothing there', (tester) async {
    await SettingsRepository.instance.write(SettingsKey.viewerTvShowDateTime, false);
    await pumpViewer(tester, photo, tvMode: false);
    final (date, time) = dateAndTimeOf(photo);

    expect(inTopBar(find.text(date)), findsOneWidget);
    expect(inTopBar(find.text(time)), findsOneWidget);
    expect(inBottomBar(find.text(date)), findsNothing);
    expect(tvLabel, findsNothing);
    final screen = tester.getSize(find.byType(AssetViewer));
    expect(tester.getCenter(find.text(date)).dx, closeTo(screen.width / 2, 1), reason: 'centred');
  });
}
