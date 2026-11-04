// The AV2 gate in the asset viewer of a computer (av2_gate.dart, Av2ViewerScreen): a video opens with the bars of the
// viewer hidden, and the view that a tap shows them through is what the gate replaces with its card. The card of the
// decoder, here "Not in this version of the app" (no sums in that catalogue), must leave the mouse a way out: the bars
// show with it, Back closes the viewer, and a tap beside the card hides and shows the bars as a tap on a video does.

import 'dart:async';
import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/video/av2_decoder.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_viewer.page.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../../../presentation/widgets/ai_immersive/fake_ai_components_service.dart';
import '../../../unit/presentation/presentation_context.dart';
import 'av2_test_components.dart';

final _clip = LocalAsset(
  id: 'cosmos',
  name: 'cosmos.ivf',
  type: AssetType.video,
  createdAt: DateTime(2026, 11, 3),
  updatedAt: DateTime(2026, 11, 3),
  width: 256,
  height: 144,
  playbackStyle: AssetPlaybackStyle.video,
  isEdited: false,
);

/// The viewer as AssetViewer.setAsset leaves it for a video: its file set, the bars hidden
class _VideoOpened extends AssetViewerStateNotifier {
  @override
  AssetViewerState build() {
    super.build();
    return AssetViewerState(currentAsset: _clip, showingControls: false);
  }
}

/// The file of the clip: the 8-bit AV2 fixture
class _Files extends StorageRepository {
  @override
  Future<File?> getFileForAsset(String assetId) async =>
      assetId == _clip.id ? File('test/fixtures/av2/av2-256x144-8bit.ivf') : null;
}

void main() {
  late PresentationContext context;

  setUpAll(() => registerFallbackValue(_clip));

  setUp(() async {
    context = await PresentationContext.create();
    when(() => context.service.asset.service.watchAsset(any())).thenAnswer((_) => const Stream.empty());
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await context.dispose();
  });

  /// The library page, then the viewer opened on the clip over it; the container of the viewer
  Future<ProviderContainer> openClip(WidgetTester tester) async {
    final router = RootStackRouter.build(
      routes: [
        AutoRoute(
          path: '/',
          initial: true,
          page: PageInfo('Library', builder: (_) => const Scaffold(body: Text('the library'))),
        ),
        AutoRoute(
          path: '/viewer',
          page: PageInfo('Viewer', builder: (_) => const AssetViewer(initialIndex: 0)),
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
          overrides: [
            ...context.overrides,
            timelineServiceProvider.overrideWithValue(
              TimelineService((
                assetSource: (index, count) async => [_clip].skip(index).take(count).toList(),
                bucketSource: () => Stream.value(const [Bucket(assetCount: 1)]),
                origin: TimelineOrigin.main,
              )),
            ),
            assetViewerProvider.overrideWith(_VideoOpened.new),
            storageRepositoryProvider.overrideWithValue(_Files()),
            // A version of the app without the sums of the decoder: the card says it is not in this version
            av2DecoderProvider.overrideWith(
              (ref) => Av2Decoder(FakeAiComponentsService(catalogue: av2IncompleteCatalogue), AiPlatform.windowsX64),
            ),
          ],
          child: Builder(
            builder: (context) => MaterialApp.router(
              debugShowCheckedModeBanner: false,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              routerConfig: router.config(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    unawaited(router.pushPath('/viewer'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    // The thumbnail of the clip cannot load without the platform: not what is tested here
    tester.takeException();
    return ProviderScope.containerOf(tester.element(find.byType(AssetViewer)));
  }

  Finder back() => find.byIcon(Icons.arrow_back_rounded).hitTestable();

  testWidgets('the card of the decoder comes with the bars of the viewer, and Back closes it', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final container = await openClip(tester);
    expect(find.text('Not in this version of the app'), findsOneWidget);
    expect(container.read(assetViewerProvider).showingControls, isTrue, reason: 'a video opens with them hidden');
    await tester.pump(const Duration(milliseconds: 300));
    expect(back(), findsOneWidget);

    await tester.tap(back());
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    tester.takeException();
    expect(find.byType(AssetViewer), findsNothing);
    expect(find.text('the library'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a tap beside the card hides the bars and the next one shows them, as on a video', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final container = await openClip(tester);
    expect(container.read(assetViewerProvider).showingControls, isTrue);

    // Above the card, under the top bar, in the middle of the width: neither a button nor a side that turns the page
    final screen = tester.getRect(find.byKey(const Key('av2_viewer_screen')));
    final card = tester.getRect(
      find.descendant(of: find.byKey(const Key('av2_install_card')), matching: find.byType(Card)),
    );
    final beside = Offset(screen.center.dx, (screen.top + 60 + card.top) / 2);
    expect(beside.dy, lessThan(card.top));
    await tester.tapAt(beside);
    await tester.pump(const Duration(milliseconds: 300));
    expect(container.read(assetViewerProvider).showingControls, isFalse);
    expect(back(), findsNothing);

    await tester.tapAt(beside);
    await tester.pump(const Duration(milliseconds: 300));
    expect(container.read(assetViewerProvider).showingControls, isTrue);
    expect(back(), findsOneWidget);
    tester.takeException();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the notice of the setting turned off comes with the bars too', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await SettingsRepository.instance.write(.viewerAv2Videos, false);
    final container = await openClip(tester);
    expect(find.byKey(const Key('av2_notice_off')), findsOneWidget);
    expect(container.read(assetViewerProvider).showingControls, isTrue);
    await tester.pump(const Duration(milliseconds: 300));
    expect(back(), findsOneWidget);
    tester.takeException();
    debugDefaultTargetPlatformOverride = null;
  });
}
