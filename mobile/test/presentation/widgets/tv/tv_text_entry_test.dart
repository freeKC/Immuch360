// On a TV a text field is typed in through the native text dialog: the field itself is never focused, OK opens the
// dialog with the label and the kind of the field, and what was typed fills it. Out of TV mode the field is untouched.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/platform/tv_api.g.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_focus_ring.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_shell.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_text_entry.widget.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/theme/theme_data.dart';
import 'package:mocktail/mocktail.dart';

class _MockTvApi extends Mock implements TvApi {}

void main() {
  late _MockTvApi api;
  late TextEditingController controller;
  late List<String> submitted;

  setUpAll(() {
    registerFallbackValue(TvTextRequest(title: '', text: '', kind: TvTextKind.text, okLabel: '', cancelLabel: ''));
  });

  setUp(() {
    api = _MockTvApi();
    controller = TextEditingController(text: 'nas.local');
    submitted = [];
  });

  tearDown(() => controller.dispose());

  Future<void> pump(WidgetTester tester, {required bool tvMode, TvTextKind kind = TvTextKind.url}) async {
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
          overrides: [tvModeProvider.overrideWithValue(tvMode), tvApiProvider.overrideWithValue(api)],
          child: Builder(
            builder: (context) => MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: Scaffold(
                body: Column(
                  children: [
                    TvTextEntry(
                      controller: controller,
                      label: 'Server address',
                      kind: kind,
                      onSubmitted: submitted.add,
                      child: TextField(key: const Key('field'), controller: controller),
                    ),
                    ElevatedButton(onPressed: () {}, child: const Text('Next')),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  bool fieldHasFocus(WidgetTester tester) => tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus;

  testWidgets('the arrows never put the focus in the field', (tester) async {
    await pump(tester, tvMode: true);

    for (final key in [LogicalKeyboardKey.tab, LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.arrowUp]) {
      await tester.sendKeyEvent(key);
      await tester.pump();
      expect(fieldHasFocus(tester), isFalse);
    }
    await tester.tap(find.byKey(const Key('field')), warnIfMissed: false);
    await tester.pump();
    expect(fieldHasFocus(tester), isFalse, reason: 'a touch does not reach it either');
    expect(find.text('Press OK to type'), findsOneWidget);
  });

  testWidgets('OK opens the dialog with the label and the kind, and what was typed fills the field', (tester) async {
    when(() => api.editText(any())).thenAnswer((_) async => '192.0.2.20');
    await pump(tester, tvMode: true);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    final request = verify(() => api.editText(captureAny())).captured.single as TvTextRequest;
    expect(request.title, 'Server address');
    expect(request.text, 'nas.local');
    expect(request.kind, TvTextKind.url);
    expect(request.okLabel, 'Ok');
    expect(request.cancelLabel, 'Cancel');
    expect(controller.text, '192.0.2.20');
    expect(controller.selection, const TextSelection.collapsed(offset: 10));
    expect(submitted, ['192.0.2.20']);
  });

  testWidgets('Cancel leaves the field as it was', (tester) async {
    when(() => api.editText(any())).thenAnswer((_) async => null);
    await pump(tester, tvMode: true);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(controller.text, 'nas.local');
    expect(submitted, isEmpty);
  });

  testWidgets('a password is typed again, never shown in the dialog', (tester) async {
    when(() => api.editText(any())).thenAnswer((_) async => 's3cret');
    controller.text = 'stored';
    await pump(tester, tvMode: true, kind: TvTextKind.password);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    final request = verify(() => api.editText(captureAny())).captured.single as TvTextRequest;
    expect(request.text, '');
    expect(request.kind, TvTextKind.password);
    expect(controller.text, 's3cret');
  });

  testWidgets('out of TV mode the field is returned untouched', (tester) async {
    await pump(tester, tvMode: false);

    expect(find.text('Press OK to type'), findsNothing);
    await tester.tap(find.byKey(const Key('field')));
    await tester.pump();
    expect(fieldHasFocus(tester), isTrue);
    verifyNever(() => api.editText(any()));
  });

  testWidgets('can take the focus by itself, and hand it over to the next entry once typed in', (tester) async {
    final nextEntry = FocusNode();
    final second = TextEditingController();
    addTearDown(nextEntry.dispose);
    addTearDown(second.dispose);
    when(() => api.editText(any())).thenAnswer((_) async => 'user@example.org');
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
          overrides: [tvModeProvider.overrideWithValue(true), tvApiProvider.overrideWithValue(api)],
          child: Builder(
            builder: (context) => MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: Scaffold(
                body: Column(
                  children: [
                    TvTextEntry(
                      controller: controller,
                      label: 'Email',
                      kind: TvTextKind.email,
                      autofocus: true,
                      onSubmitted: (_) => nextEntry.requestFocus(),
                      child: TextField(controller: controller),
                    ),
                    TvTextEntry(
                      controller: second,
                      label: 'Password',
                      kind: TvTextKind.password,
                      focusNode: nextEntry,
                      child: TextField(controller: second),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    expect(controller.text, 'user@example.org');
    expect(nextEntry.hasPrimaryFocus, isTrue);
  });

  testWidgets('the focus ring passes around the floating label of an outlined field, never across it', (tester) async {
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final port = TextEditingController(text: '445');
    addTearDown(port.dispose);
    // The fields of the share form: the label floats on the top line of the outline once the field holds a value
    Widget field(TextEditingController controller, String label) => TextField(
      controller: controller,
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
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
          overrides: [tvModeProvider.overrideWithValue(true), tvApiProvider.overrideWithValue(api)],
          child: Builder(
            builder: (context) => MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              theme: getThemeData(
                colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: Brightness.dark),
                locale: const Locale('en'),
                tvMode: true,
              ),
              builder: (context, child) => TvShell(child: child!),
              home: Scaffold(
                body: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    TvTextEntry(
                      controller: controller,
                      label: 'Name',
                      kind: TvTextKind.text,
                      autofocus: true,
                      child: field(controller, 'Name'),
                    ),
                    const SizedBox(height: 16),
                    TvTextEntry(controller: port, label: 'Port', kind: TvTextKind.number, child: field(port, 'Port')),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final ringState = tester.state<TvFocusRingState>(find.byType(TvFocusRing));
    for (final label in ['Name', 'Port']) {
      if (label == 'Port') {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      final focused = ringState.ringRect!;
      // The coloured line runs between these two, its dark outline included
      final inner = focused.inflate(TvFocusRing.gap);
      final outer = focused.inflate(TvFocusRing.gap + TvFocusRing.strokeWidth + 1);
      final labelRect = tester.getRect(find.text(label));
      expect(outer.overlaps(labelRect), isTrue, reason: '$label: the ring is around the field of the label');
      expect(
        labelRect.top,
        greaterThanOrEqualTo(inner.top),
        reason: '$label: the label under the top line of the ring, not across it',
      );
      expect(labelRect.left, greaterThanOrEqualTo(inner.left));
      expect(labelRect.right, lessThanOrEqualTo(inner.right));
    }
  });
}
