// The memories with a remote control: left and right go through the photos, Up reaches Close and Down View in
// timeline, the opposite arrow comes back to the photo, the next and previous keys go through the memories, and the
// last page's Start over is reached with OK.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/memory.model.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/pages/memory.page.dart';
import 'package:immich_mobile/providers/haptic_feedback.provider.dart';

import '../../test_utils.dart';
import '../../unit/presentation/presentation_context.dart';

class _NoHaptics extends HapticNotifier {
  _NoHaptics(super.ref);

  @override
  void selectionClick() {}

  @override
  void mediumImpact() {}
}

Memory _memory(String id, int year, List<RemoteAsset> assets) => Memory(
  id: id,
  createdAt: DateTime(2026, 10, 1),
  updatedAt: DateTime(2026, 10, 1),
  ownerId: 'owner1',
  type: MemoryTypeEnum.onThisDay,
  data: MemoryData(year: year),
  isSaved: false,
  memoryAt: DateTime(2026, 10, 1),
  assets: assets,
);

void main() {
  late PresentationContext context;
  final memories = [
    _memory('first', 2020, [
      TestUtils.createRemoteAsset(id: 'a1', width: 400, height: 300),
      TestUtils.createRemoteAsset(id: 'a2', width: 400, height: 300),
    ]),
    _memory('second', 2021, [TestUtils.createRemoteAsset(id: 'b1', width: 400, height: 300)]),
  ];

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  /// The images cannot load here (no platform channels), which is beside the point
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    tester.takeException();
  }

  Future<void> pumpMemories(WidgetTester tester) async {
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
          overrides: [...context.overrides, hapticFeedbackProvider.overrideWith(_NoHaptics.new)],
          child: Builder(
            builder: (context) => MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: MemoryPage(memories: memories, memoryIndex: 0),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await settle(tester);
  }

  bool focusedIn(Finder finder) {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) {
      return false;
    }
    final targets = finder.evaluate().toSet();
    var found = targets.contains(focused);
    focused.visitAncestorElements((element) {
      found = found || targets.contains(element);
      return !found;
    });
    return found;
  }

  final close = find.ancestor(of: find.byIcon(Icons.close_rounded), matching: find.byType(MaterialButton));
  final viewInTimeline = find.ancestor(of: find.byIcon(Icons.open_in_new), matching: find.byType(MaterialButton));

  testWidgets('Up reaches Close, Down View in timeline, and the opposite arrow comes back to the photo', (
    tester,
  ) async {
    await pumpMemories(tester);

    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusedIn(close), isTrue);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedIn(close), isFalse);
    expect(focusedIn(viewInTimeline), isFalse);

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedIn(viewInTimeline), isTrue);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusedIn(viewInTimeline), isFalse);
    expect(focusedIn(close), isFalse);

    // Back on the photo, Up goes to Close again
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusedIn(close), isTrue);
  });

  testWidgets('the next key goes to the next memory, then to the last page, where OK reaches Start over', (
    tester,
  ) async {
    await pumpMemories(tester);
    final startOver = find.ancestor(of: find.text('Start Over'), matching: find.byType(TextButton));

    await press(tester, LogicalKeyboardKey.mediaTrackNext);
    await press(tester, LogicalKeyboardKey.mediaTrackNext);
    expect(startOver, findsOneWidget);

    await press(tester, LogicalKeyboardKey.select);
    expect(focusedIn(startOver), isTrue);
  });
}
