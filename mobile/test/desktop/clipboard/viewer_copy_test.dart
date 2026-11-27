// Copy in the viewers of a computer (lib/desktop/clipboard/viewer_copy.dart): a right click on the item shown opens
// Copy and Copy name, Escape closes it; Copy copies the item, Copy name puts its file name as text, and Control C
// copies too while the viewer is shown, never under a dialog. The remote control layout and the phones keep their
// viewers as they were.

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/clipboard/clipboard_copy.dart';
import 'package:immich_mobile/desktop/clipboard/viewer_copy.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';

import '../selection/selection_test_app.dart';
import 'recording_copier.dart';

const _name = 'RatEX_motion_paysage_16x9 (1).mp4';

void main() {
  final t = StaticTranslations.instance;
  late FakeDesktopClipboard clipboard;
  late int copies;

  setUp(() {
    clipboard = FakeDesktopClipboard();
    copies = 0;
  });

  final item = find.byKey(const Key('viewer_item'));

  Future<void> pumpViewer(WidgetTester tester, {bool tvMode = false, bool shell = true}) async {
    final router = RootStackRouter.build(
      routes: [
        AutoRoute(
          path: '/',
          initial: true,
          page: PageInfo(
            'Viewer',
            builder: (_) => Focus(
              autofocus: true,
              child: withDesktopViewerCopy(
                copy: (context) async => copies++,
                name: () => _name,
                child: const ColoredBox(
                  color: Colors.black,
                  child: SizedBox.expand(key: Key('viewer_item')),
                ),
              ),
            ),
          ),
        ),
      ],
    );
    await pumpSelectionApp(
      tester,
      router: router,
      shell: shell,
      overrides: [
        desktopClipboardCopierProvider.overrideWithValue(ClipboardCopier(clipboard: clipboard)),
        tvModeProvider.overrideWithValue(tvMode),
      ],
    );
    await tester.pumpAndSettle();
  }

  for (final platform in [TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.macOS]) {
    testWidgets('${platform.name}: a right click offers Copy and Copy name, Control C copies', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      await pumpViewer(tester);

      await rightClick(tester, item);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('desktop_viewer_copy')), findsOneWidget);
      expect(find.text(t.desktop_copy), findsOneWidget);
      expect(find.text(t.desktop_copy_name), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('desktop_viewer_copy')), findsNothing, reason: 'Escape closes the menu');
      expect(copies, 0);

      await rightClick(tester, item);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('desktop_viewer_copy')));
      await tester.pumpAndSettle();
      expect(copies, 1);

      await rightClick(tester, item);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('desktop_viewer_copy_name')));
      await tester.pumpAndSettle();
      expect(clipboard.texts, [_name]);
      expect(clipboard.writes, isEmpty, reason: 'the name goes as text');

      final mac = platform == TargetPlatform.macOS;
      expect(await withShortcut(tester, LogicalKeyboardKey.keyC, command: mac), isTrue);
      await tester.pumpAndSettle();
      expect(copies, 2);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('Control C leaves a dialog over the viewer alone', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pumpViewer(tester);
    unawaited(
      showDialog<void>(
        context: tester.element(item),
        builder: (_) => const AlertDialog(content: Text('a dialog')),
      ),
    );
    await tester.pumpAndSettle();
    await withShortcut(tester, LogicalKeyboardKey.keyC);
    await tester.pumpAndSettle();
    expect(copies, 0);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the remote control layout of a computer has no copy', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pumpViewer(tester, tvMode: true);
    await rightClick(tester, item);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('desktop_viewer_copy')), findsNothing);
    expect(await withShortcut(tester, LogicalKeyboardKey.keyC), isFalse);
    expect(copies, 0);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a phone keeps its viewer as it was', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pumpViewer(tester, shell: false);
    expect(find.byType(DesktopViewerCopy), findsNothing);
    await rightClick(tester, item);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('desktop_viewer_copy')), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
}
