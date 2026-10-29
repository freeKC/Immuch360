// The page of the viewer for a photo of two eyes side by side (lot A6b): in its view mode on a computer only, flat
// when the user turned it or when a newer version of the format made it.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/ai/sbs_view_modes.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_page.widget.dart';
import 'package:immich_mobile/providers/ai_immersive/flat_stereo.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/view_rotation.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/widgets/photo_view/photo_view.dart';

import '../../../desktop/ai/library/version_fixtures.dart';
import '../../../unit/presentation/presentation_context.dart';

/// A timeline of [asset] alone
class _OneAssetTimeline extends TimelineService {
  _OneAssetTimeline(this.asset)
    : super((
        assetSource: (_, _) async => [],
        bucketSource: () => Stream.value(const [Bucket(assetCount: 1)]),
        origin: TimelineOrigin.main,
      ));

  final BaseAsset asset;

  @override
  int get totalAssets => 1;

  @override
  BaseAsset? getAssetSafe(int index) => index == 0 ? asset : null;
}

/// The viewer on [asset], zoomed in when [zoomed]
class _Viewer extends AssetViewerStateNotifier {
  _Viewer(this.asset, {this.zoomed = false});

  final BaseAsset asset;
  final bool zoomed;

  @override
  AssetViewerState build() {
    super.build();
    return AssetViewerState(currentAsset: asset, isZoomed: zoomed);
  }
}

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });
  tearDown(() async => context.dispose());

  final sbs = LocalAsset(
    id: 'sbs1',
    name: 'salon_3D_LRF_Full_SBS.jpg',
    type: AssetType.image,
    createdAt: DateTime(2026, 10, 27),
    updatedAt: DateTime(2026, 10, 27),
    width: 1600,
    height: 600,
    playbackStyle: AssetPlaybackStyle.image,
    isEdited: false,
  );
  final ours = FlatStereoPhoto(eyes: StereoEyes.full, xmp: versionXmp(Uint8List(4)));
  final sbsView = find.byType(SbsPhotoView);

  /// The photo is shown as any other: the image itself in the view, not a child of ours
  void expectShownAsStored(WidgetTester tester) {
    expect(sbsView, findsNothing);
    final view = tester.widget<PhotoView>(find.byType(PhotoView));
    expect(view.imageProvider, isNotNull);
    expect(view.child, isNull);
  }

  /// [body] with the app on [platform], put back after it even when it fails
  Future<void> on(TargetPlatform platform, Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  /// The page of [sbs], its head read as [photo], turned by the user [quarterTurns] times
  Future<ProviderContainer> pumpPage(
    WidgetTester tester, {
    FlatStereoPhoto? photo,
    int quarterTurns = 0,
    bool zoomed = false,
  }) async {
    final container = ProviderContainer(
      overrides: [
        ...context.overrides,
        timelineServiceProvider.overrideWithValue(_OneAssetTimeline(sbs)),
        assetViewerProvider.overrideWith(() => _Viewer(sbs, zoomed: zoomed)),
        flatStereoProvider(sbs).overrideWith((ref) async => photo),
        displayQuarterTurnsProvider(sbs).overrideWith((ref) => quarterTurns),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: EasyLocalization(
          supportedLocales: locales.values.toList(),
          path: translationsPath,
          startLocale: locales.values.first,
          fallbackLocale: locales.values.first,
          saveLocale: false,
          useFallbackTranslations: true,
          assetLoader: const CodegenLoader(),
          child: Builder(
            builder: (context) => MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: const Material(child: AssetPage(index: 0, heroOffset: 0)),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    // The head of the photo is read once the page is built: one frame more
    await tester.pump();
    return container;
  }

  group('a photo of two eyes side by side', () {
    testWidgets('on a computer, shows in the view mode of the top bar, the left eye at first', (tester) async {
      await on(TargetPlatform.linux, () async {
        await pumpPage(tester, photo: ours);

        expect(sbsView, findsOneWidget);
        expect(tester.widget<SbsPhotoView>(sbsView).mode, SbsViewMode.leftEye);
      });
    });

    testWidgets('on a phone, shows as stored', (tester) async {
      await on(TargetPlatform.android, () async {
        await pumpPage(tester, photo: ours);

        expectShownAsStored(tester);
      });
    });

    testWidgets('turned by the user, shows flat, as turned', (tester) async {
      await on(TargetPlatform.windows, () async {
        await pumpPage(tester, photo: ours, quarterTurns: 1);

        expectShownAsStored(tester);
      });
    });

    testWidgets('made by a newer version of the format, shows flat', (tester) async {
      final newer = FlatStereoPhoto(
        eyes: StereoEyes.full,
        xmp: StereoPhotoXmp.parse(
          versionXmp(Uint8List(4)).toXml().replaceFirst('FormatVersion="1"', 'FormatVersion="2"'),
        ),
      );
      await on(TargetPlatform.macOS, () async {
        await pumpPage(tester, photo: newer);

        expectShownAsStored(tester);
      });
    });
  });

  group('the zoom', () {
    bool zoomed(ProviderContainer container) => container.read(assetViewerProvider).isZoomed;

    testWidgets('is given back when the view mode changes: a new view, contained', (tester) async {
      await on(TargetPlatform.windows, () async {
        final container = await pumpPage(tester, photo: ours, zoomed: true);
        expect(zoomed(container), isTrue);

        container.read(sbsViewModeProvider.notifier).state = SbsViewMode.sideBySide;
        await tester.pump();

        expect(tester.widget<SbsPhotoView>(sbsView).mode, SbsViewMode.sideBySide);
        expect(zoomed(container), isFalse);
      });
    });

    testWidgets('is given back when a photo told by its name alone is shown in a mode', (tester) async {
      await on(TargetPlatform.linux, () async {
        final container = await pumpPage(tester, photo: const FlatStereoPhoto(eyes: StereoEyes.half), zoomed: true);
        expectShownAsStored(tester);
        expect(zoomed(container), isTrue);

        container.read(sbsChosenPhotosProvider.notifier).state = {flatStereoKey(sbs)};
        await tester.pump();

        expect(sbsView, findsOneWidget);
        expect(zoomed(container), isFalse);
      });
    });
  });
}
