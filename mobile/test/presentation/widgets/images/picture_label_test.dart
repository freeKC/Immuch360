// The labels over a picture keep a WCAG contrast of 4.5:1 at least for their small text on a white, a black and a busy
// picture, in the light and the dark themes, computed from the colours the widgets draw (no golden image): the shared
// scrim and pill, the duration of a video of the timeline, the year cells of the overview of the timeline, the title of
// a memory. The scrim is never an opaque bar, and a long file name is cut in its middle.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/memory.model.dart';
import 'package:immich_mobile/domain/models/watch_progress.dart';
import 'package:immich_mobile/infrastructure/repositories/watch_progress.repository.dart';
import 'package:immich_mobile/presentation/widgets/images/picture_label.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/memory/memory_lane.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/overview_asset_loader.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/overview_blocks.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/overview_model.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/watch_progress.provider.dart';

import '../../../test_utils.dart';
import '../../../test_utils/picture_label_contrast.dart';
import '../../../unit/factories/remote_asset_factory.dart';
import '../../../unit/presentation/presentation_context.dart';

class _NoRows extends Fake implements WatchProgressRepository {
  @override
  Future<List<WatchProgress>> load({int maxRows = watchProgressMaxRows}) async => const [];
}

void main() {
  group('the numbers', () {
    test('white text under the lightest black of the scrim: 4.5:1 at least on any picture', () {
      final white = pictureLabelContrast(Colors.white);
      final black = pictureLabelContrast(Colors.black);
      // 1 - 0.62 of white is a grey of sRGB 0.38: luminance 0.120, (1 + 0.05) / (0.120 + 0.05) = 6.2
      expect(white, closeTo(6.2, 0.1));
      expect(black, closeTo(21, 0.01));
      for (final pixel in busyPicture) {
        expect(pictureLabelContrast(pixel), greaterThanOrEqualTo(smallTextContrast), reason: '$pixel');
      }
      // The pill of a badge, lighter: 5.7:1 on white
      expect(pictureLabelContrast(Colors.white, shade: PictureLabelShade.badge), closeTo(5.7, 0.1));
    });

    test('the old ways fail where the picture is light: a shadow alone, the primary colour, a 20 % darkening', () {
      // White on a white sky with no scrim, primary blue on a black night, white on 20 % black over white
      expect(contrastRatio(Colors.white, Colors.white), 1);
      expect(contrastRatio(const Color(0xFF4250AF), Colors.black), lessThan(smallTextContrast));
      expect(pictureLabelContrast(Colors.white, shade: 0.2), lessThan(smallTextContrast));
    });

    test('a name too long for its width is cut in the middle, one that fits is left whole', () {
      const style = TextStyle(fontSize: 11);
      expect(middleEllipsis('IMG_1.jpg', maxWidth: 200, style: style), 'IMG_1.jpg');
      final cut = middleEllipsis('PXL_20261012_143522123_PORTRAIT.jpg', maxWidth: 100, style: style);
      expect(cut, contains(MiddleEllipsisText.ellipsis));
      expect(cut, startsWith('PXL'));
      expect(cut, endsWith('.jpg'));
      final painter = TextPainter(
        text: TextSpan(text: cut, style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      expect(painter.width, lessThanOrEqualTo(100));
      painter.dispose();
    });
  });

  group('the widgets', () {
    late PresentationContext context;

    setUp(() async {
      context = await PresentationContext.create();
    });

    tearDown(() async {
      await context.dispose();
    });

    Widget onPicture(Color picture, Brightness brightness, Widget child, {double size = 160}) => Theme(
      data: ThemeData(brightness: brightness),
      child: Center(
        child: SizedBox.square(
          dimension: size,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: picture),
              child,
            ],
          ),
        ),
      ),
    );

    for (final brightness in Brightness.values) {
      for (final (picture, what) in [(Colors.white, 'white'), (Colors.black, 'black')]) {
        testWidgets('a label and a badge on a $what picture, ${brightness.name} theme', (tester) async {
          await tester.pumpTestWidget(
            context,
            onPicture(
              picture,
              brightness,
              const Stack(
                fit: StackFit.expand,
                children: [
                  PictureLabel(key: Key('label'), child: Text('IMG_2041.jpg')),
                  Align(
                    alignment: Alignment.topRight,
                    child: PictureBadge(key: Key('badge'), child: Text('3D')),
                  ),
                ],
              ),
            ),
          );
          for (final key in ['label', 'badge']) {
            final label = find.byKey(Key(key));
            expect(textColorsIn(tester, label), everyElement(Colors.white), reason: key);
            expect(lowestContrast(tester, label, picture: [picture]), greaterThanOrEqualTo(smallTextContrast));
            expect(lowestContrast(tester, label), greaterThanOrEqualTo(smallTextContrast), reason: key);
          }
          final fade = tester.widget<DecoratedBox>(find.byKey(PictureLabel.fadeKey)).decoration as BoxDecoration;
          expect(fade.gradient!.colors.first.a, 0, reason: 'the picture shows through at the top of the scrim');
        });
      }
    }

    testWidgets('the duration of a video of the timeline on its pill', (tester) async {
      final video = RemoteAssetFactory.create(type: AssetType.video);
      await tester.pumpTestWidget(
        context,
        SizedBox.square(dimension: 120, child: ThumbnailTile(video)),
        overrides: [
          watchProgressRepositoryProvider.overrideWithValue(_NoRows()),
          appConfigProvider.overrideWithValue(const AppConfig()),
          tvModeProvider.overrideWithValue(false),
        ],
      );
      final pill = find.byKey(PictureBadge.pillKey);
      expect(pill, findsOneWidget);
      expect(textColorsIn(tester, pill), everyElement(Colors.white));
      expect(lowestContrast(tester, pill), greaterThanOrEqualTo(smallTextContrast));
    });

    testWidgets('the name of a month in the years of the overview, on its cover and on the tint before it', (
      tester,
    ) async {
      for (final brightness in Brightness.values) {
        await tester.pumpTestWidget(
          context,
          Theme(
            data: ThemeData(brightness: brightness),
            child: Center(
              child: OverviewYearCell(
                year: 2024,
                month: 3,
                content: const OverviewMonth(year: 2024, month: 3, assetCount: 12, firstAssetIndex: 0),
                largest: 12,
                side: 48,
                host: OverviewHost(loader: OverviewAssetLoader((_, _) async => const <BaseAsset>[]), onOpen: (_) {}),
              ),
            ),
          ),
        );
        final label = find.byType(PictureLabel);
        expect(label, findsOneWidget);
        // The tint of the count in the primary colour of the theme, under the scrim as a cover would be
        final tint = Theme.of(tester.element(label)).colorScheme.primary.withValues(alpha: 0.62);
        final tinted = Color.alphaBlend(tint, Theme.of(tester.element(label)).scaffoldBackgroundColor);
        expect(
          lowestContrast(tester, label, picture: [...busyPicture, tinted]),
          greaterThanOrEqualTo(smallTextContrast),
        );
      }
    });

    testWidgets('the title of a memory in the band of the timeline', (tester) async {
      final memory = Memory(
        id: 'm1',
        createdAt: DateTime(2026, 10, 1),
        updatedAt: DateTime(2026, 10, 1),
        ownerId: 'owner1',
        type: MemoryTypeEnum.onThisDay,
        data: const MemoryData(year: 2020),
        isSaved: false,
        memoryAt: DateTime(2026, 10, 1),
        assets: [TestUtils.createRemoteAsset(id: 'a1', width: 400, height: 300)],
      );
      await tester.pumpTestWidget(
        context,
        Center(
          child: SizedBox(width: 170, height: 200, child: MemoryCard(memory: memory)),
        ),
        expectSettle: false,
      );
      final label = find.byType(PictureLabel);
      expect(label, findsOneWidget);
      expect(textColorsIn(tester, label), everyElement(Colors.white));
      // Under the 20 % darkening of the card too, which only adds black
      expect(lowestContrast(tester, label), greaterThanOrEqualTo(smallTextContrast));
    });
  });
}
