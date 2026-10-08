import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/library/folder_library.dart';
import 'package:immich_mobile/desktop/library/folder_library_controller.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/folders.page.dart';
import 'package:immich_mobile/desktop/library/placeholder_check.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_focus_ring.widget.dart';
import 'package:path/path.dart' as p;

import 'library_fixtures.dart';
import 'library_test_support.dart';

void main() {
  late TestLibrary fixture;
  late FolderLibrary library;
  late String pictures;
  late String footage;
  late int pushes;
  String? picked;

  setUp(() {
    fixture = TestLibrary();
    fixture.probe.mounts[fixture.files.path] = 'win-0000beef';
    pictures = p.join(fixture.files.path, 'Pictures');
    footage = p.join(fixture.files.path, 'Footage');
    fixture
      ..write('Pictures/IMG_1.jpg', jpegBytes(width: 4, height: 3))
      ..write('Pictures/2024/VID_2.mp4', mp4Bytes(width: 16, height: 9, durationMs: 1000))
      ..write('Footage/VID_3.insv', mp4Bytes(width: 16, height: 16, durationMs: 1000));
    library = fixture.library();
    pushes = 0;
    picked = null;
  });
  tearDown(() {
    library.close();
    fixture.dispose();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          folderLibraryProvider.overrideWith((ref) async => library),
          folderSuggestionsProvider.overrideWith((ref) async => [FolderSuggestion(pictures)]),
          libraryChangesPusherProvider.overrideWithValue(() async => pushes++),
          folderPickerProvider.overrideWithValue(() async => picked),
        ],
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
              debugShowCheckedModeBanner: false,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: const FoldersPage(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('before any folder: the way to choose one, with the Pictures folder suggested', (tester) async {
    await pumpPage(tester);

    expect(find.text('Folders on this computer'), findsOneWidget);
    expect(find.text('No folder chosen yet'), findsOneWidget);
    expect(find.text('Suggested folders'), findsOneWidget);
    expect(find.widgetWithText(CheckboxListTile, 'Pictures'), findsOneWidget);
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value, isFalse);
    expect(find.text('Add a folder'), findsOneWidget);
    expect(library.hasRoots, isFalse, reason: 'nothing is scanned before the user chose');
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('a suggestion checked becomes a folder of the library, scanned, and the app is told', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();

    expect(library.roots().single.path, pictures);
    expect(find.textContaining('2 photos and videos'), findsOneWidget);
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value, isTrue);
    expect(pushes, 1);
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('"Add a folder" asks the system for one; giving up adds nothing', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('Add a folder'));
    await tester.pumpAndSettle();
    expect(library.hasRoots, isFalse);

    picked = footage;
    await tester.tap(find.text('Add a folder'));
    await tester.pumpAndSettle();
    expect(library.roots().single.path, footage);
    expect(find.textContaining('1 photo or video'), findsOneWidget);
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('files kept online only are counted, and come in with "Download and include"', (tester) async {
    final cloud = fixture.write('Pictures/cloud.jpg', jpegBytes(width: 1, height: 1));
    fixture.attributes[cloud.path] = fileAttributeRecallOnDataAccess;
    library.addRoot(pictures);
    await fixture.scan();
    await pumpPage(tester);

    expect(find.text('1 file is only in the cloud'), findsOneWidget);
    await tester.tap(find.text('Download and include'));
    await tester.pumpAndSettle();

    expect(find.text('Download and include'), findsNothing);
    expect(find.textContaining('3 photos and videos'), findsOneWidget);
    expect(fixture.opened, contains(cloud.path));
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('removing a folder asks first, and leaves the files where they are', (tester) async {
    library.addRoot(footage);
    await fixture.scan();
    await pumpPage(tester);

    await tester.tap(find.byTooltip('Remove this folder'));
    await tester.pumpAndSettle();
    expect(find.textContaining('The files stay on this computer'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(library.hasRoots, isTrue);

    await tester.tap(find.byTooltip('Remove this folder'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('desktop_folders_remove_confirm')));
    await tester.pumpAndSettle();
    expect(library.hasRoots, isFalse);
    // The scan after it writes nothing, yet the local tables must lose the folder
    expect(pushes, 1);
    expect(find.text('No folder chosen yet'), findsOneWidget);
    expect(fixture.files.listSync(recursive: true).where((entry) => entry.path.endsWith('VID_3.insv')), hasLength(1));
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('Refresh reads every folder, a network folder too', (tester) async {
    final share = Directory(p.join(fixture.dir.path, 'nas'))..createSync();
    fixture.probe.mounts[share.path] = 'net-//nas/photos';
    fixture.write('IMG_1.jpg', jpegBytes(width: 1, height: 1), base: share);
    library.addRoot(share.path);
    await fixture.scan();
    await pumpPage(tester);
    expect(find.textContaining('1 photo or video'), findsOneWidget);

    // The automatic rescans read a share only now and then; the user's Refresh reads it at once
    fixture.write('IMG_2.jpg', jpegBytes(width: 1, height: 1), base: share);
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();

    expect(find.textContaining('2 photos and videos'), findsOneWidget);
    expect(pushes, 1);
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('a drive that is not connected says so', (tester) async {
    library.addRoot(footage);
    await fixture.scan();
    fixture.probe.mounts.clear();
    await fixture.scan();
    await pumpPage(tester);

    expect(find.textContaining('This drive is not connected'), findsOneWidget);
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('Tab goes through the controls in reading order, from the app bar down', (tester) async {
    library.addRoot(footage);
    await fixture.scan();
    await pumpPage(tester);

    final ring = tester.state<TvFocusRingState>(find.byType(TvFocusRing));
    expect(ring.ringRect, isNull, reason: 'no ring before the keyboard is used');
    final tops = <double>[];
    final seen = <FocusNode>{};
    for (var i = 0; i < 8; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      final focus = FocusManager.instance.primaryFocus;
      if (focus == null || focus.context == null || !seen.add(focus)) {
        break;
      }
      expect(ring.ringRect, isNotNull, reason: 'stop ${i + 1} shows the ring');
      tops.add(tester.getTopLeft(find.byElementPredicate((element) => element == focus.context)).dy);
    }
    // Refresh, the folder's remove button, "Add a folder", the suggestion: at least those, top to bottom
    expect(tops.length, greaterThanOrEqualTo(4));
    expect(tops, orderedEquals([...tops]..sort()));
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('the remove dialog has a ring of its own, above its barrier', (tester) async {
    library.addRoot(footage);
    await fixture.scan();
    await pumpPage(tester);

    await tester.tap(find.byTooltip('Remove this folder'));
    await tester.pumpAndSettle();
    final ring = tester.state<TvFocusRingState>(
      find.ancestor(of: find.byType(AlertDialog), matching: find.byType(TvFocusRing)),
    );
    final keys = <Key?>[];
    for (var i = 0; i < 2; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(ring.ringRect, isNotNull, reason: 'stop ${i + 1} shows the ring');
      keys.add(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TextButton>()?.key);
    }
    expect(keys, [const Key('desktop_folders_remove_cancel'), const Key('desktop_folders_remove_confirm')]);
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('every control has a label', (tester) async {
    final semantics = tester.ensureSemantics();
    library.addRoot(footage);
    await fixture.scan();
    await pumpPage(tester);

    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    expect(find.byTooltip('Refresh'), findsOneWidget);
    expect(find.byTooltip('Remove this folder'), findsOneWidget);
    semantics.dispose();
  }, variant: TargetPlatformVariant.desktop());
}
