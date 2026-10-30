// The months and the years of a timeline on a phone of 402 x 874 dp at 3x: a pinch beyond 6 tiles per row shows one
// block a month without writing the setting, one gesture on shows one block a year, a pinch out comes back to the grid;
// a tap on a month or a cell opens the grid at that month; Back from the months returns to the grid. On a computer Ctrl
// and the mouse wheel step on the same ladder without moving the list, which scrolls again once Ctrl is released. The
// scrubber says the year and the month, the year alone on the years, and slows down under a finger held still, even
// held longer than the long press of the drag selection. A tapped month comes to the top below a band such as the
// memories, a screen reader taps the blocks too, and a climb from 4 tiles per row comes back to 4. After a sync the
// blocks show the assets now at their indexes. Search and the TV keep the grid.

import 'dart:async';
import 'dart:math' as math;

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/timeline_config.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/constants.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/segment_builder.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/overview_blocks.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/overview/timeline_wheel_zoom.dart';
import 'package:immich_mobile/presentation/widgets/timeline/scrubber.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';

import '../../../../fixtures/asset.stub.dart';
import '../../../../unit/presentation/presentation_context.dart';

/// The settings the timeline writes, kept here
class _Settings extends Fake implements SettingsRepository {
  final writes = <Object?>[];

  @override
  Future<void> write<T, U extends T>(SettingsKey<T> key, U value) async => writes.add(value);
}

/// The settings as the app keeps them: tiles per row written come back through the config, and the grid reloads
class _LiveSettings extends _Settings {
  _LiveSettings(int tilesPerRow) : _config = AppConfig(timeline: TimelineConfig(tilesPerRow: tilesPerRow));

  AppConfig _config;
  final _changes = StreamController<AppConfig>.broadcast();

  @override
  AppConfig get appConfig => _config;

  @override
  Stream<AppConfig> watchConfig() => _changes.stream;

  @override
  Future<void> write<T, U extends T>(SettingsKey<T> key, U value) async {
    await super.write(key, value);
    if (key == SettingsKey.timelineTilesPerRow) {
      _config = AppConfig(timeline: TimelineConfig(tilesPerRow: value as int));
      _changes.add(_config);
    }
  }
}

/// Two days a month of three assets each, every month from December 2026 down to January 2024
List<Bucket> _threeYears() => [
  for (var year = 2026; year >= 2024; year--)
    for (var month = 12; month >= 1; month--) ...[
      TimeBucket(date: DateTime(year, month, 20), assetCount: 3),
      TimeBucket(date: DateTime(year, month, 5), assetCount: 3),
    ],
];

/// One day a month of one asset, twenty years of months: a library the scrubber squeezes
List<Bucket> _twentyYears() => [
  for (var year = 2025; year > 2005; year--)
    for (var month = 12; month >= 1; month--) TimeBucket(date: DateTime(year, month, 10), assetCount: 1),
];

const _screen = Size(402, 874);

/// Two fingers across the middle of the timeline, [span] dp apart
class _Pinch {
  _Pinch._(this._tester, this._center, this._left, this._right);

  final WidgetTester _tester;
  final Offset _center;
  final TestGesture _left;
  final TestGesture _right;

  static Future<_Pinch> start(WidgetTester tester, double span) async {
    final center = tester.getCenter(find.byType(Timeline));
    final left = await tester.startGesture(center - Offset(span / 2, 0), pointer: 21);
    final right = await tester.startGesture(center + Offset(span / 2, 0), pointer: 22);
    await tester.pump();
    return _Pinch._(tester, center, left, right);
  }

  /// To [span] dp apart in small moves, as fingers do
  Future<void> to(double span, {double from = 0, int steps = 8}) async {
    final start = from;
    for (var i = 1; i <= steps; i++) {
      final now = start + (span - start) * i / steps;
      await _left.moveTo(_center - Offset(now / 2, 0));
      await _right.moveTo(_center + Offset(now / 2, 0));
      await _tester.pump();
    }
  }

  Future<void> up() async {
    await _left.up();
    await _right.up();
    await _tester.pump();
  }
}

void main() {
  late PresentationContext context;
  late _Settings settings;

  // The store and the settings that the thumbnails and the haptics read
  setUp(() async {
    context = await PresentationContext.create();
    settings = _Settings();
  });
  tearDown(() => context.dispose());

  /// The timeline on the phone, with [buckets] of three assets each; or [service]. [band] dp between the bar and the
  /// list, as the memories of the Photos tab. [liveSettings] write the tiles per row back to the config.
  Future<TimelineService> pumpTimeline(
    WidgetTester tester, {
    List<Bucket>? buckets,
    TimelineService? service,
    int tilesPerRow = 6,
    bool withScrubber = true,
    bool tvMode = false,
    double band = 0,
    bool liveSettings = false,
  }) async {
    tester.view
      ..physicalSize = Size(_screen.width * 3, _screen.height * 3)
      ..devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    var timelineService = service;
    if (timelineService == null) {
      final shownBuckets = buckets ?? _threeYears();
      final total = shownBuckets.fold<int>(0, (sum, bucket) => sum + bucket.assetCount);
      final assets = List<BaseAsset>.generate(total, (i) => LocalAssetStub.image1.copyWith(id: 'a$i'));
      timelineService = TimelineService((
        assetSource: (i, n) async => assets.sublist(math.min(i, assets.length), math.min(i + n, assets.length)),
        bucketSource: () => Stream.value(shownBuckets),
        origin: TimelineOrigin.main,
      ));
      addTearDown(timelineService.dispose);
    }
    if (liveSettings) {
      settings = _LiveSettings(tilesPerRow);
    }

    final router = RootStackRouter.build(
      routes: [
        AutoRoute(
          initial: true,
          page: PageInfo(
            'Timeline',
            builder: (_) => Timeline(
              withScrubber: withScrubber,
              readOnly: true,
              groupBy: GroupAssetsBy.day,
              appBar: const SliverToBoxAdapter(child: SizedBox(height: kToolbarHeight)),
              topSliverWidget: band > 0 ? SliverToBoxAdapter(child: SizedBox(height: band)) : null,
              topSliverWidgetHeight: band > 0 ? band : null,
            ),
          ),
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
            timelineServiceProvider.overrideWithValue(timelineService),
            if (!liveSettings)
              appConfigProvider.overrideWithValue(AppConfig(timeline: TimelineConfig(tilesPerRow: tilesPerRow))),
            settingsProvider.overrideWithValue(settings),
            tvModeProvider.overrideWithValue(tvMode),
          ],
          child: Builder(
            builder: (context) => MaterialApp.router(
              routerConfig: router.config(),
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
            ),
          ),
        ),
      ),
    );
    // The translations, the segments, then the assets of the rows
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    // The thumbnails of the device do not load in a test
    tester.takeException();
    return timelineService;
  }

  Finder monthBlocks() => find.byType(OverviewMonthBlock);
  Finder yearBlocks() => find.byType(OverviewYearBlock);
  Finder tiles() => find.byType(ThumbnailTile);

  ScrollPosition position(WidgetTester tester) => tester
      .state<ScrollableState>(find.descendant(of: find.byType(Timeline), matching: find.byType(Scrollable)).first)
      .position;

  /// The scroll offset of the first day of [month] on the grid of [columns] per row
  double gridOffsetOf(DateTime month, {List<Bucket>? buckets, int columns = 6}) {
    final segments = FixedSegmentBuilder(
      buckets: buckets ?? _threeYears(),
      tileHeight: (_screen.width - (columns - 1) * kTimelineSpacing) / columns,
      columnCount: columns,
      groupBy: GroupAssetsBy.day,
    ).generate();
    return segments.firstWhere((segment) {
      final date = (segment.bucket as TimeBucket).date;
      return date.year == month.year && date.month == month.month;
    }).startOffset;
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    tester.takeException();
  }

  group('the pinch', () {
    testWidgets('beyond 6 per row: the months without writing the setting, then the years, then back', (tester) async {
      await pumpTimeline(tester);
      expect(tiles(), findsWidgets);
      expect(monthBlocks(), findsNothing);

      final pinch = await _Pinch.start(tester, 400);
      await pinch.to(280, from: 400);
      expect(monthBlocks(), findsWidgets, reason: 'a squeeze of 30 % from 6 per row');
      expect(tiles(), findsNothing);
      expect(find.text('December 2026'), findsOneWidget, reason: 'the newest month first, with its year');
      expect(find.text('6 items'), findsWidgets, reason: 'the count of each month');

      await pinch.to(170, from: 280);
      expect(yearBlocks(), findsWidgets, reason: 'the same gesture goes on to the years');
      expect(monthBlocks(), findsNothing);
      await pinch.up();
      await settle(tester);
      expect(find.text('2026'), findsWidgets);
      expect(find.text('72 items'), findsWidgets, reason: 'the count of each year');
      expect(settings.writes, isEmpty, reason: 'the months and the years are not a setting');

      final out = await _Pinch.start(tester, 120);
      await out.to(320, from: 120, steps: 12);
      await out.up();
      await settle(tester);
      expect(yearBlocks(), findsNothing);
      expect(monthBlocks(), findsNothing);
      expect(tiles(), findsWidgets, reason: 'pinched out to the grid');
      expect(settings.writes, isEmpty, reason: 'back at the 6 per row of the setting');
    });

    testWidgets('the badge says Months, then fades', (tester) async {
      await pumpTimeline(tester);
      final pinch = await _Pinch.start(tester, 400);
      await pinch.to(280, from: 400);
      await pinch.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('timeline_zoom_level_chip')), findsOneWidget);
      expect(find.text('Months'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);
      final opacity = tester.widget<AnimatedOpacity>(
        find
            .ancestor(of: find.byKey(const Key('timeline_zoom_level_chip')), matching: find.byType(AnimatedOpacity))
            .first,
      );
      expect(opacity.opacity, 0, reason: 'gone after a moment');
    });

    testWidgets('a search keeps the grid', (tester) async {
      await pumpTimeline(tester, withScrubber: false);
      final pinch = await _Pinch.start(tester, 400);
      await pinch.to(150, from: 400);
      await pinch.up();
      await settle(tester);
      expect(monthBlocks(), findsNothing, reason: 'no scrubber: a search, a map');
      expect(tiles(), findsWidgets);
    });

    testWidgets('the TV keeps the grid', (tester) async {
      await pumpTimeline(tester, tvMode: true);
      final pinch = await _Pinch.start(tester, 400);
      await pinch.to(150, from: 400);
      await pinch.up();
      await settle(tester);
      expect(monthBlocks(), findsNothing);
      expect(yearBlocks(), findsNothing);
    });
  });

  group('a tap and Back', () {
    Future<void> toMonths(WidgetTester tester) async {
      final pinch = await _Pinch.start(tester, 400);
      await pinch.to(280, from: 400);
      await pinch.up();
      await settle(tester);
      expect(monthBlocks(), findsWidgets);
    }

    testWidgets('a tap on a month opens the grid with that month at the top', (tester) async {
      await pumpTimeline(tester);
      await toMonths(tester);
      await tester.tap(find.text('October 2026'));
      await settle(tester);
      expect(monthBlocks(), findsNothing);
      expect(tiles(), findsWidgets);
      final scroll = position(tester);
      expect(scroll.pixels, moreOrLessEquals(math.min(gridOffsetOf(DateTime(2026, 10)), scroll.maxScrollExtent)));
      expect(scroll.pixels, greaterThan(0));
      expect(settings.writes, isEmpty, reason: 'the tiles per row of the setting');
    });

    testWidgets('a tap on a month of a year opens the grid at that month', (tester) async {
      await pumpTimeline(tester);
      final pinch = await _Pinch.start(tester, 400);
      await pinch.to(170, from: 400);
      await pinch.up();
      await settle(tester);
      expect(yearBlocks(), findsWidgets);

      final march2025 = find.descendant(of: find.byKey(const ValueKey(2025)), matching: find.text('Mar'));
      await tester.tap(march2025);
      await settle(tester);
      expect(yearBlocks(), findsNothing);
      final scroll = position(tester);
      expect(scroll.pixels, moreOrLessEquals(math.min(gridOffsetOf(DateTime(2025, 3)), scroll.maxScrollExtent)));
    });

    testWidgets('Back from the months returns to the grid, at the month at the top', (tester) async {
      await pumpTimeline(tester);
      await toMonths(tester);
      // Down to about the fourth month
      position(tester).jumpTo(3 * tester.getSize(monthBlocks().first).height + 4);
      await settle(tester);

      final handled = await tester.binding.handlePopRoute();
      await settle(tester);
      expect(handled, isTrue, reason: 'the page stays');
      expect(monthBlocks(), findsNothing);
      expect(tiles(), findsWidgets);
      final scroll = position(tester);
      expect(scroll.pixels, moreOrLessEquals(math.min(gridOffsetOf(DateTime(2026, 9)), scroll.maxScrollExtent)));
    });

    /// Where the header of October 2026 lands on the grid after a tap on its month, [band] dp between bar and list
    Future<double> tappedMonthTop(WidgetTester tester, {double band = 0}) async {
      await pumpTimeline(tester, band: band);
      await toMonths(tester);
      await tester.tap(find.text('October 2026'));
      await settle(tester);
      expect(monthBlocks(), findsNothing);
      // The header of the month on the grid, without the year in the current one
      final header = find.byWidgetPredicate(
        (widget) => widget is RichText && RegExp(r'^October( 2026)?$').hasMatch(widget.text.toPlainText()),
      );
      return tester.getTopLeft(header.first).dy;
    }

    testWidgets('a band above the list, as the memories: the tapped month still comes to the top', (tester) async {
      final plain = await tappedMonthTop(tester);
      expect(plain, lessThan(kToolbarHeight + 40), reason: 'under the bar');
      final banded = await tappedMonthTop(tester, band: 200);
      expect(banded, closeTo(plain, 1), reason: 'the band scrolled away, not 200 dp lower');
    });

    testWidgets('at the top of a page with a band, the months and back keep the band in view', (tester) async {
      await pumpTimeline(tester, band: 200);
      await toMonths(tester);
      expect(position(tester).pixels, 0);
      final out = await _Pinch.start(tester, 200);
      await out.to(400, from: 200, steps: 10);
      await out.up();
      await settle(tester);
      expect(tiles(), findsWidgets);
      expect(position(tester).pixels, 0);
    });

    testWidgets('below a band, the months and back keep the month at the top', (tester) async {
      await pumpTimeline(tester, band: 200);
      // The band gone, September 2026 at the top
      position(tester).jumpTo(200 + gridOffsetOf(DateTime(2026, 9)));
      await settle(tester);
      await toMonths(tester);
      final september = tester.getTopLeft(find.text('September 2026').first).dy;
      expect(september, lessThan(kToolbarHeight + 40), reason: 'the block of September at the top, under the bar');
      final out = await _Pinch.start(tester, 200);
      await out.to(400, from: 200, steps: 10);
      await out.up();
      await settle(tester);
      expect(tiles(), findsWidgets);
      expect(position(tester).pixels, moreOrLessEquals(200 + gridOffsetOf(DateTime(2026, 9))));
    });

    testWidgets('a screen reader taps the blocks, the cells and the years too', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpTimeline(tester);
      await toMonths(tester);
      bool canTap(SemanticsFinder finder) => finder.evaluate().single.getSemanticsData().hasAction(SemanticsAction.tap);

      final october = find.semantics.byLabel(RegExp('^October 2026, '));
      expect(canTap(october), isTrue, reason: 'the double tap of TalkBack');
      tester.semantics.tap(october);
      await settle(tester);
      expect(monthBlocks(), findsNothing);
      expect(position(tester).pixels, moreOrLessEquals(gridOffsetOf(DateTime(2026, 10))));

      final pinch = await _Pinch.start(tester, 400);
      await pinch.to(170, from: 400);
      await pinch.up();
      await settle(tester);
      expect(yearBlocks(), findsWidgets);
      expect(canTap(find.semantics.byLabel(RegExp(r'^2025, '))), isTrue, reason: 'the header of a year');
      final march = find.semantics.byLabel(RegExp('^March 2025, '));
      expect(canTap(march), isTrue, reason: 'a month of a year');
      tester.semantics.tap(march);
      await settle(tester);
      expect(yearBlocks(), findsNothing);
      final scroll = position(tester);
      expect(scroll.pixels, moreOrLessEquals(math.min(gridOffsetOf(DateTime(2025, 3)), scroll.maxScrollExtent)));
      semantics.dispose();
    });
  });

  group('Ctrl and the mouse wheel on a computer', () {
    // One notch of a mouse on Windows at 300 %: 100 physical pixels
    const notch = 100 / 3;

    Future<void> wheel(WidgetTester tester, double dy) async {
      final mouse = TestPointer(31, PointerDeviceKind.mouse);
      final at = tester.getCenter(find.byType(Timeline));
      await tester.sendEventToBinding(mouse.hover(at));
      await tester.sendEventToBinding(mouse.scroll(Offset(0, dy)));
      await tester.pump();
    }

    testWidgets('one notch a rung without moving the list; without Ctrl the wheel scrolls, and the drag works again', (
      tester,
    ) async {
      await pumpTimeline(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      await wheel(tester, notch);
      await settle(tester);
      expect(monthBlocks(), findsWidgets, reason: 'towards the user: farther, from 6 per row to the months');
      expect(position(tester).pixels, 0, reason: 'the list did not scroll');

      await wheel(tester, notch);
      await settle(tester);
      expect(yearBlocks(), findsWidgets);

      await wheel(tester, -notch);
      await settle(tester);
      expect(monthBlocks(), findsWidgets, reason: 'away from the user: closer');
      expect(position(tester).pixels, 0);

      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await wheel(tester, 300);
      await settle(tester);
      expect(monthBlocks(), findsWidgets, reason: 'no zoom without Ctrl');
      expect(position(tester).pixels, greaterThan(0), reason: 'the wheel scrolls the list again');

      final before = position(tester).pixels;
      await tester.drag(find.byType(Timeline), const Offset(0, -200));
      await settle(tester);
      expect(position(tester).pixels, greaterThan(before), reason: 'the drag works once Ctrl is released');
      expect(settings.writes, isEmpty);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('from 4 per row up to the months, a tap or Back gives back the 4 per row', (tester) async {
      await pumpTimeline(tester, tilesPerRow: 4, liveSettings: true);
      Future<void> climb() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        for (var i = 0; i < 3; i++) {
          await wheel(tester, notch);
          await settle(tester);
        }
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(monthBlocks(), findsWidgets);
      }

      double tileWidth() => tester.getSize(tiles().first).width;
      final fourPerRow = (_screen.width - 3 * kTimelineSpacing) / 4;
      expect(tileWidth(), closeTo(fourPerRow, 1));

      await climb();
      expect(settings.writes, [5, 6], reason: '5, 6, then the months, as on a phone');
      await tester.tap(find.text('October 2026'));
      await settle(tester);
      expect(settings.writes, [5, 6, 4]);
      expect(tileWidth(), closeTo(fourPerRow, 1), reason: 'the grid from before, not the 6 per row on the way');
      final scroll = position(tester);
      expect(
        scroll.pixels,
        moreOrLessEquals(math.min(gridOffsetOf(DateTime(2026, 10), columns: 4), scroll.maxScrollExtent)),
        reason: 'October at the top',
      );

      await climb();
      expect(await tester.binding.handlePopRoute(), isTrue);
      await settle(tester);
      expect(monthBlocks(), findsNothing);
      expect(settings.writes, [5, 6, 4, 5, 6, 4]);
      expect(tileWidth(), closeTo(fourPerRow, 1));
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    test('the notches of a fine wheel add up, three at most a move', () {
      final counter = WheelNotchCounter();
      expect(counter.add(10, 40), 0);
      expect(counter.add(10, 40), 0);
      expect(counter.add(25, 40), 1, reason: '45 of 40');
      expect(counter.add(-50, 40), -1, reason: '5-50 = -45');
      expect(counter.add(400, 40), 3);
      counter.reset();
      expect(counter.add(39, 40), 0);
      expect(counter.add(0, 40), 0);
      expect(counter.add(10, 0), 0);
    });

    test('the physics refuse the user while Ctrl is held, and only then', () {
      const parent = ClampingScrollPhysics();
      expect(timelineWheelZoomPhysics(parent, held: false), same(parent));
      expect(timelineWheelZoomPhysics(null, held: false), isNull);
      final held = timelineWheelZoomPhysics(parent, held: true)!;
      expect(held, isA<TimelineWheelZoomPhysics>());
      expect(held.parent, same(parent));
      final metrics = FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 1000,
        pixels: 0,
        viewportDimension: 800,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 3,
      );
      expect(held.shouldAcceptUserOffset(metrics), isFalse);
    });
  });

  group('the scrubber', () {
    Finder thumb() => find.byWidgetPredicate((widget) => widget.runtimeType.toString() == '_CircularThumb');

    testWidgets('the year and the month on the grid and the months, the year alone on the years', (tester) async {
      await pumpTimeline(tester);
      // The thumb and its label come with a scroll
      await tester.drag(find.byType(Timeline), const Offset(0, -40));
      await tester.pumpAndSettle();
      expect(find.text('Dec 2026'), findsOneWidget);

      final pinch = await _Pinch.start(tester, 400);
      await pinch.to(280, from: 400);
      await pinch.up();
      await settle(tester);
      await tester.drag(find.byType(Timeline), const Offset(0, -40));
      await tester.pumpAndSettle();
      expect(find.text('Dec 2026'), findsOneWidget, reason: 'the months');

      final farther = await _Pinch.start(tester, 400);
      await farther.to(250, from: 400);
      await farther.up();
      await settle(tester);
      expect(yearBlocks(), findsWidgets);
      await tester.drag(find.byType(Timeline), const Offset(0, -40));
      await tester.pumpAndSettle();
      expect(find.text('2026'), findsWidgets, reason: 'the header of the year, and the label');
      expect(find.text('Dec 2026'), findsNothing, reason: 'the label of the years says the year alone');
    });

    /// The finger on the thumb, still for [hold], then 100 dp down
    Future<void> slowDrag(WidgetTester tester, Duration hold) async {
      final buckets = _twentyYears();
      await pumpTimeline(tester, buckets: buckets);
      await tester.drag(find.byType(Timeline), const Offset(0, -300));
      // The thumb comes with the scroll, and fades 800 ms after it
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(thumb(), findsOneWidget);

      final before = tester.getTopLeft(thumb()).dy;
      final finger = await tester.startGesture(tester.getCenter(thumb()));
      await tester.pump(hold);
      expect(find.byKey(kScrubberSlowIconKey), findsOneWidget, reason: 'the label says the thumb is slow');

      for (var i = 0; i < 10; i++) {
        await finger.moveBy(const Offset(0, 10));
        await tester.pump();
      }
      final after = tester.getTopLeft(thumb()).dy;
      // The scrubber spans the screen less the bar, its margin and the thumb
      final scrubber = tester.widget<Scrubber>(find.byType(Scrubber));
      final height = scrubber.timelineHeight - scrubber.topPadding - scrubber.bottomPadding;
      final factor = scrubberSlowFactor(monthCount: 240, scrubberHeight: height);
      expect(factor, greaterThan(4));
      expect(after - before, closeTo(100 / factor, 4), reason: 'a month is some 3 dp of the scrubber: the snap');

      await finger.up();
      await tester.pump();
      expect(find.byKey(kScrubberSlowIconKey), findsNothing, reason: 'until the finger lets go');
      await settle(tester);
    }

    testWidgets('a finger held still on the thumb slows it down, some 16 dp a month', (tester) async {
      await slowDrag(tester, const Duration(milliseconds: 350));
    });

    testWidgets('held longer than the long press of the drag selection, the thumb still follows', (tester) async {
      // The slow mode comes at 300 ms and invites to wait; the long press that selects by dragging comes at 500 ms
      await slowDrag(tester, const Duration(milliseconds: 650));
    });
  });

  group('a sync', () {
    /// The months of [_threeYears], then a sync gives the library [library] and the buckets [buckets]; the service
    /// reloads its buffer for six frames. The first thumbnail of November 2026 once all is done.
    Future<String> novemberAfterSync(
      WidgetTester tester, {
      required List<BaseAsset> Function(List<BaseAsset> before) library,
      required List<Bucket> Function(List<Bucket> before) buckets,
    }) async {
      var shownBuckets = _threeYears();
      var assets = List<BaseAsset>.generate(216, (i) => LocalAssetStub.image1.copyWith(id: 'a$i'));
      final bucketStream = StreamController<List<Bucket>>.broadcast();
      addTearDown(bucketStream.close);
      Completer<void>? reload;
      final service = TimelineService((
        assetSource: (i, n) async {
          final gate = reload;
          // The service asks its whole buffer back after new buckets; the blocks ask for a few
          if (gate != null && n >= 216) {
            await gate.future;
          }
          return assets.sublist(math.min(i, assets.length), math.min(i + n, assets.length));
        },
        bucketSource: () => Stream.multi((controller) {
          controller.add(shownBuckets);
          final subscription = bucketStream.stream.listen(controller.add);
          controller.onCancel = subscription.cancel;
        }),
        origin: TimelineOrigin.main,
      ));
      addTearDown(service.dispose);
      await pumpTimeline(tester, service: service);
      final pinch = await _Pinch.start(tester, 400);
      await pinch.to(280, from: 400);
      await pinch.up();
      await settle(tester);

      String firstOf(String month) {
        final block = find.ancestor(of: find.text(month), matching: find.byType(OverviewMonthBlock));
        final thumbnails = find.descendant(of: block, matching: find.byType(OverviewThumbnail));
        return (tester.widget<OverviewThumbnail>(thumbnails.first).asset as LocalAsset).id;
      }

      expect(firstOf('November 2026'), 'a6');
      assets = library(assets);
      shownBuckets = buckets(shownBuckets);
      reload = Completer<void>();
      bucketStream.add(shownBuckets);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      reload.complete();
      await settle(tester);
      return firstOf('November 2026');
    }

    testWidgets('one asset more at the top: November starts one further', (tester) async {
      final first = await novemberAfterSync(
        tester,
        library: (before) => [LocalAssetStub.image1.copyWith(id: 'new'), ...before],
        buckets: (before) => [TimeBucket(date: DateTime(2026, 12, 20), assetCount: 4), ...before.skip(1)],
      );
      expect(first, 'a6', reason: 'at index 7 now');
    });

    testWidgets('one asset less in December and one more in October: as many, November one closer', (tester) async {
      final first = await novemberAfterSync(
        tester,
        // December 20 loses a0; October 5 (indexes 15 to 17 before) gains one at its start
        library: (before) => [...before.sublist(1, 15), LocalAssetStub.image1.copyWith(id: 'new'), ...before.skip(15)],
        buckets: (before) => [
          TimeBucket(date: DateTime(2026, 12, 20), assetCount: 2),
          ...before.sublist(1, 5),
          TimeBucket(date: DateTime(2026, 10, 5), assetCount: 4),
          ...before.skip(6),
        ],
      );
      expect(first, 'a6', reason: 'at index 5 now, which the buffer being reloaded still gave as a5');
    });
  });
}
