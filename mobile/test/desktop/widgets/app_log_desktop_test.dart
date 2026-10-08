// "Save logs to a file" on the log page of a computer (Design 1.10): a button of its own on every desktop, the share
// button kept where a share sheet exists (Windows, macOS) and gone on Linux, where saving is the export. The phones
// keep their page as it was.

import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/files/file_pickers.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/log.model.dart';
import 'package:immich_mobile/domain/services/log.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/pages/common/app_log.page.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;

import '../../infrastructure/repository.mock.dart';

/// The save dialog of the system, answered by the test
class _Pickers implements FilePickers {
  String? answer;
  final suggested = <String>[];

  @override
  Future<String?> folder({String? initialDirectory, String? confirmButtonText}) async => null;

  @override
  Future<String?> saveLocation({
    required String suggestedName,
    String? initialDirectory,
    String? typeLabel,
    List<String> extensions = const [],
  }) async {
    suggested.add(suggestedName);
    return answer;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late _Pickers pickers;
  late LogService logService;
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(() async {
    final logRepository = MockLogRepository();
    final settingsRepository = MockSettingsRepository();
    registerFallbackValue(LogMessage(message: '', level: LogLevel.info, createdAt: DateTime(2026)));
    when(() => logRepository.truncate(limit: any(named: 'limit'))).thenAnswer((_) async {});
    when(() => logRepository.insert(any())).thenAnswer((_) async => true);
    when(() => logRepository.getAll()).thenAnswer(
      (_) async => [
        LogMessage(
          message: 'A line of the log',
          level: LogLevel.info,
          createdAt: DateTime(2026, 10, 8, 10),
          logger: 'Test',
        ),
      ],
    );
    when(() => settingsRepository.appConfig).thenReturn(const AppConfig(logLevel: LogLevel.info));
    logService = await LogService.init(
      logRepository: logRepository,
      settingsRepository: settingsRepository,
      shouldBuffer: false,
    );
  });

  tearDownAll(() => logService.dispose());

  setUp(() {
    root = Directory.systemTemp.createTempSync('immuch360-app-log');
    filePickers = pickers = _Pickers();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProvider,
      (call) async => switch (call.method) {
        'getTemporaryDirectory' => (Directory(p.join(root.path, 'Temp'))..createSync()).path,
        // No crash report folder in there: the log is saved alone
        'getApplicationCacheDirectory' => (Directory(p.join(root.path, 'Cache'))..createSync()).path,
        _ => null,
      },
    );
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    filePickers = const SystemFilePickers();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pathProvider, null);
    root.deleteSync(recursive: true);
  });

  Future<void> pumpPage(WidgetTester tester) async {
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
            scaffoldMessengerKey: scaffoldMessengerKey,
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            home: const AppLogPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final platform in const [TargetPlatform.windows, TargetPlatform.macOS]) {
    testWidgets('${platform.name}: "Save logs to a file" writes the log where the user chose, sharing stays', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      await pumpPage(tester);

      expect(find.byTooltip('Save logs to a file'), findsOneWidget);
      expect(find.byIcon(Icons.share_rounded), findsOneWidget);

      final kept = p.join(root.path, 'kept.log');
      pickers.answer = kept;
      final temporary = Directory(p.join(root.path, 'Temp'));
      bool done() => File(kept).existsSync() && temporary.existsSync() && temporary.listSync().isEmpty;
      // The file work is real: outside the fake clock of the widget test, until the temporary log is removed, the
      // last step
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Save logs to a file'));
        for (var wait = 0; wait < 300 && !done(); wait++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump();

      expect(pickers.suggested.single, startsWith('Immich_log_'));
      expect(pickers.suggested.single, endsWith('.log'));
      expect(pickers.suggested.single, isNot(contains(':')), reason: 'Windows refuses colons in a file name');
      expect(File(kept).readAsStringSync(), contains('A line of the log'));
      expect(find.text('Logs saved'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('linux: the save button is the export, no share button without a share sheet', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await pumpPage(tester);
    expect(find.byTooltip('Save logs to a file'), findsOneWidget);
    expect(find.byIcon(Icons.share_rounded), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a phone keeps its page: sharing only', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pumpPage(tester);
    expect(find.byTooltip('Save logs to a file'), findsNothing);
    expect(find.byIcon(Icons.share_rounded), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
