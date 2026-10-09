// The asset viewer on a computer (design 4.2 and 4.3): chevrons for the mouse at the edges of a photo, which turn the
// page and only show where there is one; Home and End go to the first and the last photo; I opens the details; the
// letters typed in the description of the details never reach the viewer's shortcuts. A phone gets no chevron, and
// its Home and End do nothing.

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_details/description.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_viewer.page.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_keys.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../../unit/presentation/presentation_context.dart';

final _assets = [
  for (var i = 0; i < 3; i++)
    LocalAsset(
      id: 'photo$i',
      name: 'photo$i.jpg',
      type: AssetType.image,
      createdAt: DateTime(2025, 1, 1 + i),
      updatedAt: DateTime(2025, 1, 1 + i),
      playbackStyle: AssetPlaybackStyle.image,
      isEdited: false,
    ),
];

class _SeededAssetViewerNotifier extends AssetViewerStateNotifier {
  @override
  AssetViewerState build() {
    super.build();
    return AssetViewerState(currentAsset: _assets.first);
  }
}

TimelineService _timeline() => TimelineService((
  assetSource: (index, count) async => _assets.skip(index).take(count).toList(),
  bucketSource: () => Stream.value([Bucket(assetCount: _assets.length)]),
  origin: TimelineOrigin.main,
));

void main() {
  late PresentationContext context;

  setUpAll(() => registerFallbackValue(_assets.first));

  setUp(() async {
    context = await PresentationContext.create();
    when(() => context.service.asset.service.watchAsset(any())).thenAnswer((_) => const Stream.empty());
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await context.dispose();
  });

  Future<ProviderContainer> pumpViewer(WidgetTester tester) async {
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
            timelineServiceProvider.overrideWithValue(_timeline()),
            assetViewerProvider.overrideWith(_SeededAssetViewerNotifier.new),
          ],
          child: Builder(
            builder: (context) => MaterialApp(
              debugShowCheckedModeBanner: false,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: const Material(child: AssetViewer(initialIndex: 0)),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    // The photos cannot load without the platform: their errors are not what is tested here
    tester.takeException();
    return ProviderScope.containerOf(tester.element(find.byType(AssetViewer)));
  }

  Future<TestGesture> hover(WidgetTester tester) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(AssetViewer)));
    await tester.pump(const Duration(milliseconds: 300));
    return mouse;
  }

  double opacityOf(WidgetTester tester, String key) => tester
      .widget<AnimatedOpacity>(find.ancestor(of: find.byKey(Key(key)), matching: find.byType(AnimatedOpacity)))
      .opacity;

  testWidgets('the chevrons turn the pages of a computer, and show only where there is one', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final container = await pumpViewer(tester);
    expect(opacityOf(tester, 'desktop_chevron_next'), 0, reason: 'hidden until the mouse moves');

    await hover(tester);
    expect(opacityOf(tester, 'desktop_chevron_previous'), 0, reason: 'the first photo');
    expect(opacityOf(tester, 'desktop_chevron_next'), 1);

    await tester.tap(find.byKey(const Key('desktop_chevron_next')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    tester.takeException();
    expect(container.read(assetViewerProvider).currentAsset?.name, 'photo1.jpg');
    expect(opacityOf(tester, 'desktop_chevron_previous'), 1);

    await tester.tap(find.byKey(const Key('desktop_chevron_next')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    tester.takeException();
    expect(container.read(assetViewerProvider).currentAsset?.name, 'photo2.jpg');
    expect(opacityOf(tester, 'desktop_chevron_next'), 0, reason: 'the last photo');

    // Let the hiding timer end with the test
    await tester.pump(const Duration(seconds: 4));
    tester.takeException();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a phone has no chevron', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pumpViewer(tester);
    expect(find.byKey(const Key('desktop_chevron_next')), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Home and End go to the first and the last photo on a computer', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final container = await pumpViewer(tester);

    expect(await tester.sendKeyEvent(LogicalKeyboardKey.end), isTrue);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    tester.takeException();
    expect(container.read(assetViewerProvider).currentAsset?.name, 'photo2.jpg');

    expect(await tester.sendKeyEvent(LogicalKeyboardKey.home), isTrue);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    tester.takeException();
    expect(container.read(assetViewerProvider).currentAsset?.name, 'photo0.jpg');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Home and End do nothing on a phone', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final container = await pumpViewer(tester);

    expect(await tester.sendKeyEvent(LogicalKeyboardKey.end), isFalse);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    tester.takeException();
    expect(container.read(assetViewerProvider).currentAsset?.name, 'photo0.jpg');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('I opens the details on a computer', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final events = <Event>[];
    final subscription = EventStream.shared.listen<Event>(events.add);
    addTearDown(subscription.cancel);
    await pumpViewer(tester);

    expect(await tester.sendKeyEvent(LogicalKeyboardKey.keyI), isTrue);
    await tester.pump();
    expect(events.whereType<ViewerShowDetailsEvent>(), hasLength(1));
    tester.takeException();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the letters typed in the description never reach the shortcuts', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final asset = RemoteAsset(
      id: 'remote',
      name: 'remote.jpg',
      ownerId: context.currentUser.id,
      checksum: 'checksum',
      type: AssetType.image,
      createdAt: DateTime(2025),
      updatedAt: DateTime(2025),
      isEdited: false,
    );
    var shortcuts = 0;
    // The order of the asset viewer's own handler: the details and seek keys act wherever the focus is in the viewer
    KeyEventResult viewerKeys(FocusNode node, KeyEvent event) {
      final key = event.logicalKey;
      if (remoteDetailsKeys.contains(key) ||
          remoteSeekForwardKeys.contains(key) ||
          remoteSeekBackwardKeys.contains(key)) {
        if (event is KeyDownEvent) {
          shortcuts++;
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    await tester.pumpTestWidget(
      context,
      Focus(
        autofocus: true,
        onKeyEvent: viewerKeys,
        child: SheetAssetDescription(asset: asset, exifInfo: const ExifInfo()),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();

    for (final letter in [LogicalKeyboardKey.keyJ, LogicalKeyboardKey.keyL, LogicalKeyboardKey.keyI]) {
      expect(await tester.sendKeyEvent(letter), isFalse, reason: '${letter.keyLabel} goes to the text');
    }
    await tester.enterText(find.byType(TextField), 'Jill likes Lille in July');
    await tester.pump();
    expect(find.text('Jill likes Lille in July'), findsOneWidget);
    expect(shortcuts, 0);

    // Out of the field, the same letters are shortcuts again
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    final root = find.byWidgetPredicate((widget) => widget is Focus && widget.onKeyEvent == viewerKeys);
    Focus.of(tester.element(find.byType(SheetAssetDescription))).requestFocus();
    await tester.pump();
    expect(root, findsOneWidget);
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.keyJ), isTrue);
    expect(shortcuts, 1);
    debugDefaultTargetPlatformOverride = null;
  });
}
