// The Preferences of the settings with a remote on a 1080p TV: Down goes through every setting of the page in turn,
// the share quality choices included, down to the remote control layout, without changing a choice on the way.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/pages/common/settings.page.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_focus_ring.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_shell.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';

import '../../unit/presentation/presentation_context.dart';

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  /// The settings page of a 1080p TV in the remote control layout, as main.dart builds it
  Future<ProviderContainer> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    late ProviderContainer container;
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
            tvModeProvider.overrideWithValue(true),
            videoDecodersProvider.overrideWith((ref) async => []),
          ],
          child: Consumer(
            builder: (context, ref, _) {
              container = ProviderScope.containerOf(context);
              return MaterialApp(
                localizationsDelegates: context.localizationDelegates,
                supportedLocales: context.supportedLocales,
                locale: context.locale,
                builder: (context, child) => TvShell(child: child!),
                home: const SettingsPage(),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  /// The first text of the control that has the focus: the title of a setting
  String? focusedLabel() {
    final focused = FocusManager.instance.primaryFocus?.context as Element?;
    String? label;
    void visit(Element element) {
      if (label != null) {
        return;
      }
      final widget = element.widget;
      if (widget is Text) {
        label = widget.data;
        return;
      }
      element.visitChildren(visit);
    }

    focused?.visitChildren(visit);
    return label;
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  Future<void> openPreferences(WidgetTester tester) async {
    Focus.of(tester.element(find.text('Preferences'))).requestFocus();
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.select);
    expect(find.text('Default share quality'), findsOneWidget);
  }

  const settings = [
    'Automatic (Follow system setting)',
    'Primary color',
    'Colorful interface',
    'Enabled',
    'Use original (large)',
    'Use thumbnail (small)',
    'Automatic',
    'On',
    'Off',
  ];

  testWidgets('Down gives the focus to every setting of the page in turn', (tester) async {
    final container = await pumpSettings(tester);
    await openPreferences(tester);
    Focus.of(tester.element(find.text(settings.first))).requestFocus();
    await tester.pumpAndSettle();

    final visited = [focusedLabel()];
    for (var i = 1; i < settings.length; i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
      visited.add(focusedLabel());
    }

    expect(visited, settings);
    final config = container.read(appConfigProvider);
    expect(config.share.fileType, ShareAssetType.original, reason: 'a move is no choice');
    expect(config.tvLayout, TvLayoutMode.auto);

    for (var i = settings.length - 2; i >= 0; i--) {
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedLabel(), settings[i], reason: 'and Up all the way back');
    }
  });

  testWidgets('Right from Preferences then Down reaches the remote control layout, OK picks a layout', (tester) async {
    final container = await pumpSettings(tester);
    await openPreferences(tester);

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(settings, contains(focusedLabel()), reason: 'a setting of the page');

    for (var i = 0; i < settings.length && focusedLabel() != 'Off'; i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
    }
    expect(focusedLabel(), 'Off');

    await press(tester, LogicalKeyboardKey.select);
    expect(container.read(appConfigProvider).tvLayout, TvLayoutMode.off);
  });

  testWidgets('the focused setting and its ring stay inside the right and bottom margins of the screen', (
    tester,
  ) async {
    await pumpSettings(tester);
    await openPreferences(tester);
    Focus.of(tester.element(find.text(settings.first))).requestFocus();
    await tester.pumpAndSettle();
    const screen = Size(960, 540);
    // How far the ring reaches out of the focused widget, its dark outline included
    const reach = TvFocusRing.gap + TvFocusRing.strokeWidth + 1;
    final ring = tester.state<TvFocusRingState>(find.byType(TvFocusRing));

    for (var i = 0; i < settings.length; i++) {
      if (i > 0) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(focusedLabel(), settings[i]);
      final outer = ring.ringRect!.inflate(reach);
      expect(
        outer.right,
        lessThanOrEqualTo(screen.width - TvShell.overscan.right),
        reason: '${settings[i]}: inside the right margin, not cut by the edge of the screen',
      );
      expect(
        outer.bottom,
        lessThanOrEqualTo(screen.height - TvShell.overscan.bottom),
        reason: '${settings[i]}: scrolled above the bottom margin, not flush with the bottom of the screen',
      );
    }
  });

  testWidgets('down the list of the sections too, the focused row and its ring stay inside the margins', (
    tester,
  ) async {
    await pumpSettings(tester);
    Focus.of(tester.element(find.text('Preferences'))).requestFocus();
    await tester.pumpAndSettle();
    const screen = Size(960, 540);
    const reach = TvFocusRing.gap + TvFocusRing.strokeWidth + 1;
    final ring = tester.state<TvFocusRingState>(find.byType(TvFocusRing));

    for (var press = 0; press < 12 && focusedLabel() != "What's new"; press++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      final outer = ring.ringRect!.inflate(reach);
      final label = focusedLabel();
      expect(outer.left, greaterThanOrEqualTo(TvShell.overscan.left), reason: '$label: inside the left margin');
      expect(outer.right, lessThan(screen.width / 2), reason: '$label: a row of the list of the sections');
      expect(
        outer.bottom,
        lessThanOrEqualTo(screen.height - TvShell.overscan.bottom),
        reason: '$label: scrolled above the bottom margin',
      );
    }
    expect(focusedLabel(), "What's new", reason: 'down to the last row of the list');
  });
}
