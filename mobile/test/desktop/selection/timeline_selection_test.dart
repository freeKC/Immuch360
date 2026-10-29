// The selection of a timeline on a computer (lib/desktop/selection/timeline_selection.dart), in a real Timeline under
// the window shell: Control click selects without opening, Shift click adds a range from the last click (or from a long
// press), Control A selects the whole timeline in one change of the selection, Escape clears it, a right click opens
// the menu of the whole selection with "Upload to Immich" first, which sends every photo of the selection; "N selected"
// in the bar; Command on macOS. The assets an album holds already are never taken, and a right click on the page that
// picks them adds. What the user does while Control A loads wins once it ends; a Shift click finds its anchor again
// after photos arrived above it. A phone, the read only mode and the remote control layout on a computer keep the
// timeline as it was.

import 'dart:async';
import 'dart:math' as math;

import 'package:auto_route/auto_route.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/infrastructure/toast.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:mocktail/mocktail.dart';

import '../../fixtures/asset.stub.dart';
import '../../unit/presentation/presentation_context.dart';
import 'selection_test_app.dart';

class _ReadOnly extends ReadOnlyModeNotifier {
  _ReadOnly(this.value);

  final bool value;

  @override
  bool build() => value;
}

void main() {
  late PresentationContext context;
  final t = StaticTranslations.instance;

  setUp(() async {
    context = await PresentationContext.create();
    // The viewer that a click opens follows its asset
    when(() => context.service.asset.service.watchAsset(any())).thenAnswer((_) => const Stream.empty());
  });
  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await context.dispose();
  });

  /// [count] photos of this computer, none on the server yet, named [prefix] and their number
  List<BaseAsset> photos(int count, [String prefix = 'p']) =>
      List<BaseAsset>.generate(count, (i) => LocalAssetStub.image1.copyWith(id: '$prefix$i', name: '$prefix$i.jpg'));

  /// The service of a timeline over what [assets] gives, read again at each event of [changes]; while [gate] gives a
  /// completer, the loads past the first assets wait for it
  TimelineService serviceOf(
    List<BaseAsset> Function() assets, {
    Stream<void>? changes,
    Completer<void>? Function()? gate,
  }) {
    List<Bucket> buckets() => [TimeBucket(date: DateTime(2026, 10, 5), assetCount: assets().length)];
    return TimelineService((
      assetSource: (i, n) async {
        final wait = i > 0 ? gate?.call() : null;
        if (wait != null) {
          await wait.future;
        }
        final all = assets();
        return all.sublist(math.min(i, all.length), math.min(i + n, all.length));
      },
      bucketSource: () => Stream.multi((controller) {
        controller.add(buckets());
        final subscription = changes?.listen((_) => controller.add(buckets()));
        controller.onCancel = () => subscription?.cancel();
      }),
      origin: TimelineOrigin.main,
    ));
  }

  /// The timeline of [assets] on its own page under the window shell (none on a phone), and a viewer to open; [assets]
  /// read again whenever [service] says the timeline changed, when given
  Future<RootStackRouter> pumpTimeline(
    WidgetTester tester, {
    List<BaseAsset> assets = const [],
    TimelineService? service,
    bool shell = true,
    bool tvMode = false,
    bool readOnly = false,
    MultiSelectState? selection,
    TimelineOrigin origin = TimelineOrigin.main,
  }) async {
    tester.view
      ..physicalSize = const Size(1600, 2400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    service ??= TimelineService((
      assetSource: (i, n) async => assets.sublist(i, math.min(i + n, assets.length)),
      bucketSource: () => Stream.value([TimeBucket(date: DateTime(2026, 10, 5), assetCount: assets.length)]),
      origin: origin,
    ));
    addTearDown(service.dispose);

    const timeline = Timeline(
      withScrubber: false,
      groupBy: GroupAssetsBy.day,
      appBar: null,
      bottomSheet: SizedBox(key: Key('sheet')),
    );
    final router = RootStackRouter.build(
      routes: [
        AutoRoute(
          path: '/',
          initial: true,
          page: PageInfo('Grid', builder: (_) => const Focus(autofocus: true, child: timeline)),
        ),
        AutoRoute(
          path: '/viewer',
          page: PageInfo(AssetViewerRoute.name, builder: (_) => const Scaffold(body: Text('viewer'))),
        ),
      ],
    );
    await pumpSelectionApp(
      tester,
      router: router,
      shell: shell,
      overrides: [
        ...context.overrides,
        timelineServiceProvider.overrideWithValue(service),
        appConfigProvider.overrideWithValue(const AppConfig()),
        tvModeProvider.overrideWithValue(tvMode),
        readonlyModeProvider.overrideWith(() => _ReadOnly(readOnly)),
        foregroundUploadServiceProvider.overrideWithValue(context.service.upload),
        toastServiceProvider.overrideWithValue(context.service.toast),
        aiFeaturesEnabledProvider.overrideWith((ref) => false),
        if (selection != null) multiSelectProvider.overrideWith(() => MultiSelectNotifier(selection)),
      ],
    );
    // Segments, then the assets of the rows
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    // The thumbnails of the device do not load in a test
    tester.takeException();
    return router;
  }

  Finder tileNamed(String name) =>
      find.byWidgetPredicate((widget) => widget is ThumbnailTile && widget.asset?.name == '$name.jpg');

  Finder tile(int index) => tileNamed('p$index');

  ProviderContainer container(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(Timeline, skipOffstage: false)));

  Set<String> selected(WidgetTester tester) => {
    for (final asset in container(tester).read(multiSelectProvider).selectedAssets) asset.name.split('.').first,
  };

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    tester.takeException();
  }

  Future<void> clickWith(WidgetTester tester, List<LogicalKeyboardKey> keys, int index) =>
      withKeys(tester, keys, () async {
        await click(tester, tile(index));
        await settle(tester);
      });

  group('on Windows', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.windows);

    testWidgets('Control click selects without opening, then a click adds or takes out; with nothing selected a '
        'click opens', (tester) async {
      final router = await pumpTimeline(tester, assets: photos(30));

      await click(tester, tile(0));
      await settle(tester);
      expect(router.current.name, AssetViewerRoute.name, reason: 'nothing selected: the photo opens');
      await router.maybePop();
      await settle(tester);

      await clickWith(tester, [LogicalKeyboardKey.controlLeft], 1);
      await clickWith(tester, [LogicalKeyboardKey.controlLeft], 2);
      expect(selected(tester), {'p1', 'p2'});
      expect(router.current.name, 'Grid', reason: 'nothing opened');
      expect(find.text(t.selected_count(count: 2)), findsOneWidget, reason: '"2 selected" in the bar');
      expect(find.byTooltip(t.desktop_selection_hint(modifier: 'Ctrl')), findsOneWidget, reason: 'the keys and clicks');

      await click(tester, tile(1));
      await settle(tester);
      expect(selected(tester), {'p2'});
      expect(router.current.name, 'Grid');
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Shift click adds the range from the last click, either way; with no anchor, the photo alone', (
      tester,
    ) async {
      await pumpTimeline(tester, assets: photos(30));

      await clickWith(tester, [LogicalKeyboardKey.shiftLeft], 2);
      expect(selected(tester), {'p2'});
      await clickWith(tester, [LogicalKeyboardKey.controlLeft], 5);
      await clickWith(tester, [LogicalKeyboardKey.shiftLeft], 8);
      expect(selected(tester), {'p2', 'p5', 'p6', 'p7', 'p8'});
      await clickWith(tester, [LogicalKeyboardKey.shiftLeft], 3);
      expect(selected(tester), {'p2', 'p3', 'p4', 'p5', 'p6', 'p7', 'p8'});
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a Shift click finds its anchor again after photos arrived above it', (tester) async {
      var assets = photos(30);
      final changes = StreamController<void>.broadcast();
      addTearDown(changes.close);
      await pumpTimeline(tester, service: serviceOf(() => assets, changes: changes.stream));
      await clickWith(tester, [LogicalKeyboardKey.controlLeft], 5);

      // A copy into the folder, a sync with the server
      assets = [...photos(3, 'n'), ...assets];
      changes.add(null);
      await settle(tester);
      expect(tileNamed('n0'), findsOneWidget, reason: 'the new photos show first');
      await clickWith(tester, [LogicalKeyboardKey.shiftLeft], 8);
      expect(selected(tester), {'p5', 'p6', 'p7', 'p8'});
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a long press still selects, and a Shift click then adds the range from the pressed photo', (
      tester,
    ) async {
      await pumpTimeline(tester, assets: photos(30));

      await tester.longPress(tile(1));
      await settle(tester);
      expect(selected(tester), {'p1'});
      await clickWith(tester, [LogicalKeyboardKey.shiftLeft], 4);
      expect(selected(tester), {'p1', 'p2', 'p3', 'p4'});
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a long press then a drag still selects the photos dragged over, beside the right click', (
      tester,
    ) async {
      await pumpTimeline(tester, assets: photos(30));

      final gesture = await tester.startGesture(tester.getCenter(tile(1)), kind: PointerDeviceKind.mouse);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await gesture.moveTo(tester.getCenter(tile(2)));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(tile(3)));
      await tester.pump();
      await gesture.up();
      await settle(tester);
      expect(selected(tester), {'p1', 'p2', 'p3'});
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Control A selects the whole timeline in one change, twice stays all; Escape clears it', (
      tester,
    ) async {
      await pumpTimeline(tester, assets: photos(3000));
      var changes = 0;
      final subscription = container(tester).listen(multiSelectProvider, (_, _) => changes++);
      addTearDown(subscription.close);

      expect(await withShortcut(tester, LogicalKeyboardKey.keyA), isTrue);
      await settle(tester);
      expect(container(tester).read(multiSelectProvider).selectedAssets, hasLength(3000));
      expect(changes, 1, reason: 'one change of the selection, not one per photo');
      await withShortcut(tester, LogicalKeyboardKey.keyA);
      await settle(tester);
      expect(container(tester).read(multiSelectProvider).selectedAssets, hasLength(3000));
      expect(changes, 1, reason: 'everything was selected already');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(selected(tester), isEmpty);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Escape, or a Control click, while Control A still loads wins once it ends', (tester) async {
      final assets = photos(3000);
      Completer<void>? gate;
      await pumpTimeline(tester, service: serviceOf(() => assets, gate: () => gate));
      await clickWith(tester, [LogicalKeyboardKey.controlLeft], 1);

      gate = Completer<void>();
      await withShortcut(tester, LogicalKeyboardKey.keyA);
      await tester.pump();
      expect(selected(tester), {'p1'}, reason: 'still loading');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(selected(tester), isEmpty);
      gate.complete();
      await settle(tester);
      expect(selected(tester), isEmpty, reason: 'Escape came after Control A');

      gate = Completer<void>();
      await withShortcut(tester, LogicalKeyboardKey.keyA);
      await tester.pump();
      await withKeys(tester, [LogicalKeyboardKey.controlLeft], () async {
        await click(tester, tile(4));
        await tester.pump(const Duration(milliseconds: 400));
      });
      expect(selected(tester), {'p4'});
      gate.complete();
      await settle(tester);
      expect(selected(tester), {'p4'}, reason: 'the Control click came after Control A');

      gate = null;
      await withShortcut(tester, LogicalKeyboardKey.keyA);
      await settle(tester);
      expect(selected(tester), hasLength(3000));
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a right click on the selection opens its menu, "Upload to Immich" first, which sends every photo', (
      tester,
    ) async {
      await pumpTimeline(tester, assets: photos(30));
      for (final index in [1, 2, 3]) {
        await clickWith(tester, [LogicalKeyboardKey.controlLeft], index);
      }

      await rightClick(tester, tile(2));
      await settle(tester);
      expect(selected(tester), {'p1', 'p2', 'p3'}, reason: 'a right click on the selection keeps it');
      final upload = find.byKey(const Key('desktop_selection_upload'));
      expect(find.descendant(of: upload, matching: find.text(t.upload_to_immich(count: 3))), findsOneWidget);
      final share = find.byKey(const Key('desktop_selection_share'));
      expect(share, findsOneWidget);
      expect(tester.getTopLeft(upload).dy, lessThan(tester.getTopLeft(share).dy), reason: 'Upload to Immich first');
      expect(find.byKey(const Key('desktop_selection_download')), findsNothing, reason: 'nothing on the server');
      // "Make 3D (AI)" (absent while the AI features are off, as here) acts on the same selection
      final make3d = find.byType(DesktopMakeImmersiveButton);
      expect(make3d, findsOneWidget);
      final seen = ProviderScope.containerOf(tester.element(make3d)).read(assetsActionProvider(ActionSource.timeline));
      expect({for (final asset in seen.toList()) asset.name}, {'p1.jpg', 'p2.jpg', 'p3.jpg'});

      await tester.tap(upload);
      await tester.pump();
      await tester.pump();
      final sent =
          verify(
                () => context.service.upload.uploadManual(
                  captureAny(),
                  cancelToken: any(named: 'cancelToken'),
                  callbacks: any(named: 'callbacks'),
                ),
              ).captured.single
              as List<LocalAsset>;
      expect({for (final asset in sent) asset.id}, {'p1', 'p2', 'p3'});
      await tester.pump(const Duration(seconds: 3));
      await settle(tester);
      expect(upload, findsNothing, reason: 'the menu closed');
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a right click elsewhere selects that photo alone, with Control it joins; Escape closes the menu, '
        'then clears', (tester) async {
      await pumpTimeline(tester, assets: photos(30));
      await clickWith(tester, [LogicalKeyboardKey.controlLeft], 1);
      await clickWith(tester, [LogicalKeyboardKey.controlLeft], 2);

      await rightClick(tester, tile(5));
      await settle(tester);
      expect(selected(tester), {'p5'});
      expect(find.text(t.upload_to_immich(count: 1)), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.text(t.upload_to_immich(count: 1)), findsNothing);
      expect(selected(tester), {'p5'});

      await withKeys(tester, [LogicalKeyboardKey.controlLeft], () async {
        await rightClick(tester, tile(0));
        await settle(tester);
      });
      expect(selected(tester), {'p0', 'p5'});
      expect(find.text(t.upload_to_immich(count: 2)), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(selected(tester), isEmpty);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('the viewer over the timeline keeps Control A from it', (tester) async {
      final router = await pumpTimeline(tester, assets: photos(30));
      await click(tester, tile(0));
      await settle(tester);
      expect(router.current.name, AssetViewerRoute.name);

      await withShortcut(tester, LogicalKeyboardKey.keyA);
      await settle(tester);
      await router.maybePop();
      await settle(tester);
      expect(selected(tester), isEmpty);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('the photos an album holds already are never taken, and the picker stays a picker', (tester) async {
      final assets = photos(12);
      await pumpTimeline(
        tester,
        assets: assets,
        selection: MultiSelectState(selectedAssets: const {}, lockedSelectionAssets: {assets[2]}, forceEnable: true),
      );

      await clickWith(tester, [LogicalKeyboardKey.controlLeft], 1);
      await clickWith(tester, [LogicalKeyboardKey.shiftLeft], 4);
      expect(selected(tester), {'p1', 'p3', 'p4'});

      await withShortcut(tester, LogicalKeyboardKey.keyA);
      await settle(tester);
      expect(selected(tester), hasLength(11));
      expect(selected(tester), isNot(contains('p2')));

      await rightClick(tester, tile(5));
      await settle(tester);
      expect(find.byKey(const Key('desktop_selection_upload')), findsNothing, reason: 'the picker has its own Done');
      expect(find.byKey(const Key('desktop_selection_select_all')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(selected(tester), isEmpty);
      expect(container(tester).read(multiSelectProvider).forceEnable, isTrue);
      expect(container(tester).read(multiSelectProvider).lockedSelectionAssets, {assets[2]});
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('on the page that picks the photos of an album, a right click adds to the picks; on a photo the album '
        'holds, it does nothing', (tester) async {
      final assets = photos(12);
      await pumpTimeline(
        tester,
        assets: assets,
        selection: MultiSelectState(selectedAssets: const {}, lockedSelectionAssets: {assets[2]}, forceEnable: true),
      );
      for (final index in [1, 3, 4]) {
        await clickWith(tester, [LogicalKeyboardKey.controlLeft], index);
      }

      await rightClick(tester, tile(6));
      await settle(tester);
      expect(selected(tester), {'p1', 'p3', 'p4', 'p6'}, reason: 'the picks stay');
      expect(find.byKey(const Key('desktop_selection_select_all')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);

      await rightClick(tester, tile(2));
      await settle(tester);
      expect(find.byKey(const Key('desktop_selection_select_all')), findsNothing, reason: 'no menu');
      expect(selected(tester), {'p1', 'p3', 'p4', 'p6'});
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('the trash offers no action in the menu, only to select', (tester) async {
      await pumpTimeline(tester, assets: photos(12), origin: TimelineOrigin.trash);
      await rightClick(tester, tile(1));
      await settle(tester);
      expect(selected(tester), {'p1'});
      expect(find.byKey(const Key('desktop_selection_select_all')), findsOneWidget);
      expect(find.text(t.select_all), findsOneWidget);
      expect(find.text(t.unselect_all), findsOneWidget, reason: '"Select all" then "Unselect all", alike');
      expect(
        find.byKey(const Key('desktop_selection_share')),
        findsNothing,
        reason: 'restore or delete, from the sheet',
      );
      expect(find.byKey(const Key('desktop_selection_upload')), findsNothing);
      expect(find.byType(DesktopMakeImmersiveButton), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('the locked folder offers no "Make 3D (AI)" in the menu', (tester) async {
      await pumpTimeline(tester, assets: photos(12), origin: TimelineOrigin.lockedFolder);
      await rightClick(tester, tile(1));
      await settle(tester);
      expect(
        find.byKey(const Key('desktop_selection_share')),
        findsOneWidget,
        reason: 'as the sheet of the locked folder',
      );
      expect(find.byType(DesktopMakeImmersiveButton), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('the read only mode selects nothing with the keys and the mouse', (tester) async {
      final router = await pumpTimeline(tester, assets: photos(30), readOnly: true);

      await rightClick(tester, tile(1));
      await settle(tester);
      await withShortcut(tester, LogicalKeyboardKey.keyA);
      await settle(tester);
      expect(selected(tester), isEmpty);
      expect(find.byKey(const Key('desktop_selection_select_all')), findsNothing);

      await clickWith(tester, [LogicalKeyboardKey.controlLeft], 1);
      expect(router.current.name, AssetViewerRoute.name, reason: 'Control click opens, as a click');
      expect(selected(tester), isEmpty);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('the remote control layout selects nothing with the keys and the mouse', (tester) async {
      final router = await pumpTimeline(tester, assets: photos(30), tvMode: true);

      await rightClick(tester, tile(1));
      await settle(tester);
      await withShortcut(tester, LogicalKeyboardKey.keyA);
      await settle(tester);
      expect(selected(tester), isEmpty);
      expect(find.byKey(const Key('desktop_selection_select_all')), findsNothing);

      await clickWith(tester, [LogicalKeyboardKey.controlLeft], 1);
      expect(router.current.name, AssetViewerRoute.name, reason: 'Control click opens, as a click');
      expect(selected(tester), isEmpty);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  testWidgets('on macOS: Command click selects, Control click opens the menu, Command A selects all', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final router = await pumpTimeline(tester, assets: photos(30));

    await clickWith(tester, [LogicalKeyboardKey.metaLeft], 1);
    expect(selected(tester), {'p1'});
    expect(router.current.name, 'Grid');
    await clickWith(tester, [LogicalKeyboardKey.controlLeft], 1);
    expect(find.text(t.upload_to_immich(count: 1)), findsOneWidget, reason: 'the menu, as a right click');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    await withShortcut(tester, LogicalKeyboardKey.keyA, command: true);
    await settle(tester);
    expect(selected(tester), hasLength(30));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a phone keeps its timeline: Control click opens, a right click does nothing, the bare count', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final router = await pumpTimeline(tester, assets: photos(30), shell: false);

    await clickWith(tester, [LogicalKeyboardKey.controlLeft], 1);
    expect(router.current.name, AssetViewerRoute.name);
    await router.maybePop();
    await settle(tester);

    await tester.longPress(tile(1));
    await settle(tester);
    expect(selected(tester), {'p1'});
    expect(find.text('1'), findsOneWidget, reason: 'the number alone in the bar');
    expect(find.text(t.selected_count(count: 1)), findsNothing);

    await rightClick(tester, tile(3));
    await settle(tester);
    expect(selected(tester), {'p1'});
    expect(find.byKey(const Key('desktop_selection_select_all')), findsNothing);
    await clickWith(tester, [LogicalKeyboardKey.shiftLeft], 4);
    expect(selected(tester), {'p1', 'p4'}, reason: 'a click adds while selecting, Shift or not');
    debugDefaultTargetPlatformOverride = null;
  });
}
