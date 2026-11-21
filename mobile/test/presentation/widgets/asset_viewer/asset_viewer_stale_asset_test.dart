// The asset viewer moved on while it read the asset of a page: the reply for the page left behind, which came last,
// does not replace the asset of the page on screen (fast presses of a remote, quick swipes)

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_viewer.page.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
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
    return AssetViewerState(currentAsset: _asset);
  }
}

/// A timeline whose asset at [slowIndex] is read only once [gate] completes
class _SlowTimeline extends TimelineService {
  _SlowTimeline(super.query, {required this.slowIndex});

  final int slowIndex;
  final gate = Completer<void>();

  @override
  Future<BaseAsset?> getAssetAsync(int index) async {
    if (index == slowIndex) {
      await gate.future;
    }
    return super.getAssetAsync(index);
  }
}

void main() {
  late PresentationContext context;
  final photos = <BaseAsset>[
    LocalAssetStub.image1,
    LocalAssetStub.image2,
    LocalAssetStub.image1.copyWith(id: 'local-third'),
  ];

  setUp(() async {
    context = await PresentationContext.create();
    when(() => context.service.asset.service.watchAsset(any())).thenAnswer((_) => const Stream.empty());
  });

  tearDown(() async {
    await context.dispose();
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    tester.takeException();
  }

  for (final tvMode in [true, false]) {
    testWidgets('the reply for a page left behind does not replace the asset on screen (TV: $tvMode)', (tester) async {
      final timeline = _SlowTimeline((
        assetSource: (index, count) async => photos.skip(index).take(count).toList(),
        bucketSource: () => Stream.value([Bucket(assetCount: photos.length)]),
        origin: TimelineOrigin.main,
      ), slowIndex: 1);
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
              assetViewerProvider.overrideWith(() => _SeededAssetViewerNotifier(photos[0])),
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
      final container = ProviderScope.containerOf(tester.element(find.byType(AssetViewer)));

      // Two quick presses: the asset of the second page is still on its way when the third one shows
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await settle(tester);
      expect(container.read(assetViewerJumpProvider).currentIndex, 2);
      expect(container.read(assetViewerProvider).currentAsset, photos[2]);

      timeline.gate.complete();
      await settle(tester);

      expect(container.read(assetViewerProvider).currentAsset, photos[2]);
    });
  }
}
