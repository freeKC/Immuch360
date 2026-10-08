import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/files/download_folder.dart';
import 'package:immich_mobile/desktop/files/download_folder_tile.dart';
import 'package:immich_mobile/desktop/files/file_pickers.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';

/// The setting kept in memory, so that the widget test does no file work
class _MemoryFolder extends DownloadFolder {
  @override
  Future<String> currentPath() async => chosen.value ?? r'C:\Users\Example\Downloads\Immuch360';

  @override
  Future<void> choose(String? path) async => chosen.value = path;
}

class _Pickers implements FilePickers {
  String? answer;
  String? confirmText;

  @override
  Future<String?> folder({String? initialDirectory, String? confirmButtonText}) async {
    confirmText = confirmButtonText;
    return answer;
  }

  @override
  Future<String?> saveLocation({
    required String suggestedName,
    String? initialDirectory,
    String? typeLabel,
    List<String> extensions = const [],
  }) async => null;
}

void main() {
  late _Pickers pickers;

  setUp(() => filePickers = pickers = _Pickers());

  tearDown(() => filePickers = const SystemFilePickers());

  Future<void> pumpTile(WidgetTester tester, DownloadFolder folder) async {
    await tester.pumpWidget(
      EasyLocalization(
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
            home: Scaffold(body: DownloadFolderTile(folder: folder)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows where the downloads go, with a labelled button that changes it', (tester) async {
    final folder = _MemoryFolder();
    await pumpTile(tester, folder);

    expect(find.text('Download folder'), findsOneWidget);
    expect(find.textContaining(r'C:\Users\Example\Downloads\Immuch360'), findsOneWidget);
    expect(find.byTooltip('Change the download folder'), findsOneWidget);

    pickers.answer = r'D:\Photos\From the server';
    await tester.tap(find.byKey(const Key('desktop_settings_download_folder_change')));
    await tester.pumpAndSettle();

    expect(pickers.confirmText, 'Change the download folder');
    expect(find.textContaining(r'D:\Photos\From the server'), findsOneWidget);
  });

  testWidgets('closing the dialog changes nothing', (tester) async {
    final folder = _MemoryFolder();
    await pumpTile(tester, folder);
    await tester.tap(find.byKey(const Key('desktop_settings_download_folder')));
    await tester.pumpAndSettle();
    expect(folder.chosen.value, isNull);
    expect(find.textContaining(r'C:\Users\Example\Downloads\Immuch360'), findsOneWidget);
  });

  testWidgets('the tile, then its button, are reached with Tab', (tester) async {
    await pumpTile(tester, _MemoryFolder());

    bool focusedInside(Key key) {
      final focused = FocusManager.instance.primaryFocus?.context;
      var inside = false;
      focused?.visitAncestorElements((element) {
        inside = element.widget.key == key;
        return !inside;
      });
      return inside;
    }

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(focusedInside(const Key('desktop_settings_download_folder')), isTrue);
    expect(focusedInside(const Key('desktop_settings_download_folder_change')), isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(focusedInside(const Key('desktop_settings_download_folder_change')), isTrue);
  });
}
