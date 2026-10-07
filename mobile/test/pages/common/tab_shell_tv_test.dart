// The left navigation pattern of the TV guidelines in the tab shell: Back from the content of a tab goes to its
// destination in the rail, from there to Photos, from Photos out of the app. Never a loop, never a confirmation. A
// phone keeps its bottom bar as before, hidden during a selection even when it turns.

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/pages/common/tab_shell.page.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_shell.widget.dart';
import 'package:immich_mobile/providers/haptic_feedback.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/routing/router.dart';

class _NotReadOnly extends ReadOnlyModeNotifier {
  @override
  bool build() => false;
}

class _WithoutServer extends LocalSessionNotifier {
  @override
  bool build() => true;
}

class _NoHaptics extends HapticNotifier {
  _NoHaptics(super.ref);

  @override
  void selectionClick() {}
}

void main() {
  late int systemPops;

  setUp(() {
    systemPops = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemNavigator.pop') {
          systemPops++;
        }
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

  Future<void> pumpShell(WidgetTester tester, {required bool tvMode, Size size = const Size(1920, 1080)}) async {
    // A TV screen: landscape, so the tabs are a navigation rail
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    Widget content(String name) => Center(
      child: ElevatedButton(onPressed: () {}, child: Text('$name content')),
    );
    AutoRoute tab(String name, String path, {bool initial = false}) => AutoRoute(
      path: path,
      initial: initial,
      page: PageInfo(name, builder: (_) => content(path)),
    );
    final router = RootStackRouter.build(
      routes: [
        AutoRoute(
          path: '/',
          initial: true,
          page: PageInfo(TabShellRoute.name, builder: (_) => const TabShellPage()),
          children: [
            tab(MainTimelineRoute.name, 'photos', initial: true),
            tab(SearchRoute.name, 'search'),
            tab(LibraryRoute.name, 'library'),
            tab(AlbumsRoute.name, 'albums'),
          ],
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
            tvModeProvider.overrideWithValue(tvMode),
            readonlyModeProvider.overrideWith(_NotReadOnly.new),
            localSessionProvider.overrideWith(_WithoutServer.new),
            hapticFeedbackProvider.overrideWith(_NoHaptics.new),
          ],
          child: Builder(
            builder: (context) => MaterialApp.router(
              // As main.dart does
              builder: (context, child) => tvMode ? TvShell(child: child!) : child!,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              routerConfig: router.config(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  bool hasFocus(WidgetTester tester, String text) => Focus.of(tester.element(find.text(text))).hasPrimaryFocus;

  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  Future<void> openLibraryAndFocusItsContent(WidgetTester tester) async {
    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
    expect(find.text('library content'), findsOneWidget);
    Focus.of(tester.element(find.text('library content'))).requestFocus();
    await tester.pumpAndSettle();
  }

  testWidgets('Back: the rail, then Photos, then out of the app, in three presses', (tester) async {
    await pumpShell(tester, tvMode: true);
    await openLibraryAndFocusItsContent(tester);

    await back(tester);
    expect(hasFocus(tester, 'Library'), isTrue, reason: 'the destination of the tab in the rail');
    expect(find.text('library content'), findsOneWidget);
    expect(systemPops, 0);

    await back(tester);
    expect(find.text('photos content'), findsOneWidget);
    expect(hasFocus(tester, 'Photos'), isTrue);
    expect(systemPops, 0);

    await back(tester);
    expect(systemPops, 1, reason: 'out to the TV home, without a confirmation');
  });

  testWidgets('Back from the content of Photos goes to the rail first', (tester) async {
    await pumpShell(tester, tvMode: true);
    Focus.of(tester.element(find.text('photos content'))).requestFocus();
    await tester.pumpAndSettle();

    await back(tester);
    expect(hasFocus(tester, 'Photos'), isTrue);
    expect(systemPops, 0);

    await back(tester);
    expect(systemPops, 1);
  });

  testWidgets('the arrows go from the rail to the content and back', (tester) async {
    await pumpShell(tester, tvMode: true);
    Focus.of(tester.element(find.text('Photos'))).requestFocus();
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(hasFocus(tester, 'photos content'), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    final focused = FocusManager.instance.primaryFocus!.context!;
    expect(focused.findAncestorWidgetOfExactType<NavigationRail>(), isNotNull, reason: 'a destination of the rail');
  });

  testWidgets('out of the remote control layout Back works as before: Photos, then out', (tester) async {
    await pumpShell(tester, tvMode: false);
    await openLibraryAndFocusItsContent(tester);

    await back(tester);
    expect(find.text('photos content'), findsOneWidget, reason: 'straight to Photos, not to the rail');
    expect(systemPops, 0);

    await back(tester);
    expect(systemPops, 1);
  });

  testWidgets('a phone that turns during a selection keeps its bottom bar hidden', (tester) async {
    const portrait = Size(1080, 1920);
    await pumpShell(tester, tvMode: false, size: portrait);
    expect(find.byType(NavigationBar), findsOneWidget);

    EventStream.shared.emit(const MultiSelectToggleEvent(true));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsNothing);

    tester.view.physicalSize = const Size(1920, 1080);
    await tester.pumpAndSettle();
    tester.view.physicalSize = portrait;
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsNothing, reason: 'still selecting');

    EventStream.shared.emit(const MultiSelectToggleEvent(false));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
  });
}
