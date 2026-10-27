// The "This computer" section of the settings (plan 1.2, design 4.7): its groups and their labels, the Tab order from
// the folders down to the certificates with a visible ring on each stop, and a large text size that still fits; on
// Linux, the notice of secrets kept for the session only while there is no keyring. The files the groups read live in
// a temporary folder. The group of the AI features ("AI and 3D") is tested on its own (test/desktop/ai/ui); here it
// runs on fakes.

import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/ai/creator/desktop_conversion_tools.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/library/generated_album.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/ai/ui/ai_settings_section.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/network/network_choice.dart';
import 'package:immich_mobile/desktop/platform/linux_secret_storage.dart';
import 'package:immich_mobile/desktop/settings/computer_settings.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_focus_ring.widget.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';

import '../../presentation/widgets/ai_immersive/fake_ai_components_service.dart';

class _NoComponents implements AiComponentFiles {
  @override
  Future<File?> verifiedFile(AiComponent component) async => null;

  @override
  AiComponentState stateOf(AiComponent component) => AiComponentState.notInstalled;
}

void main() {
  late Directory folder;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('computer_settings_test');
    DesktopNetworkChoice.forget();
    DesktopNetworkChoice.folder = () async => folder;
    // path_provider answers from the temporary folder: the download folder and the certificates read it
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => folder.path,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    DesktopNetworkChoice.forget();
    folder.deleteSync(recursive: true);
  });

  Future<void> pumpSettings(
    WidgetTester tester, {
    double textScale = 1,
    ValueNotifier<SessionOnlySecrets?>? sessionSecrets,
  }) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
            aiFeaturesEnabledProvider.overrideWith((ref) => true),
            aiPlatformProvider.overrideWithValue(AiPlatform.linuxX64),
            aiComponentsServiceProvider.overrideWithValue(FakeAiComponentsService()),
            desktopAiSettingsStoreProvider.overrideWithValue(
              DesktopAiSettingsStore(settingsDirectory: () async => folder),
            ),
            desktopAiGateProvider.overrideWithValue(
              HardwareGate(
                components: _NoComponents(),
                facts: () => const AiHardwareFacts(abi: Abi.linuxX64, processors: 8, physicalMemory: 16 << 30),
              ),
            ),
            generatedAlbumBackupProvider.overrideWith((ref) => Stream.value(false)),
            aiGpuNameProvider.overrideWith((ref) async => null),
            aiDefaultFolderProvider.overrideWith((ref) async => folder.path),
          ],
          child: Builder(
            builder: (context) => MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!,
              ),
              home: Scaffold(body: ComputerSettings(sessionSecrets: sessionSecrets)),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
  }

  testWidgets('the five groups, named', (tester) async {
    await pumpSettings(tester);
    expect(find.text('AI and 3D'), findsOneWidget);
    expect(find.text('AI components'), findsOneWidget);
    expect(find.text('Folders on this computer'), findsOneWidget);
    expect(find.text('Download folder'), findsOneWidget);
    expect(find.text('Network for discovery and sharing'), findsOneWidget);
    expect(find.text('Automatic'), findsOneWidget);
    expect(find.text('Trusted certificates'), findsOneWidget);
    expect(find.text('Add a certificate (PEM file)'), findsOneWidget);
    expect(find.byTooltip('Change the download folder'), findsOneWidget);
  });

  testWidgets('Tab goes from the folders down to the certificates, with a ring on each stop', (tester) async {
    await pumpSettings(tester);
    final ring = tester.state<TvFocusRingState>(find.byType(TvFocusRing));
    expect(ring.ringRect, isNull, reason: 'no ring before the keyboard is used');

    final stops = <String>[];
    for (var i = 0; i < 6; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      final focused = FocusManager.instance.primaryFocus?.context;
      expect(ring.ringRect, isNotNull, reason: 'stop ${i + 1} shows the ring');
      final keyed =
          focused?.findAncestorWidgetOfExactType<ListTile>()?.key ??
          focused?.findAncestorWidgetOfExactType<IconButton>()?.key;
      if (keyed is ValueKey<String>) {
        stops.add(keyed.value);
      }
    }
    expect(stops.indexOf('desktop_settings_folders'), 0);
    expect(
      stops,
      containsAllInOrder(['desktop_settings_folders', 'desktop_network_adapter', 'desktop_trusted_certificates_add']),
    );
    expect(stops.indexOf('desktop_settings_download_folder'), lessThan(stops.indexOf('desktop_network_adapter')));
  });

  testWidgets('on Linux without a keyring, the secrets are said to be kept for this session only', (tester) async {
    final sessionSecrets = ValueNotifier<SessionOnlySecrets?>(null);
    addTearDown(sessionSecrets.dispose);
    await pumpSettings(tester, sessionSecrets: sessionSecrets);
    expect(find.byKey(const Key('desktop_settings_session_secrets')), findsNothing);

    sessionSecrets.value = const SessionOnlySecrets(keyringRefused: false, detail: 'noService');
    await tester.pumpAndSettle();
    expect(find.text('Secrets kept for this session only'), findsOneWidget);
    expect(find.textContaining('Install gnome-keyring or KWallet to keep them'), findsOneWidget);
    expect(find.text('Folders on this computer'), findsOneWidget);

    sessionSecrets.value = const SessionOnlySecrets(keyringRefused: true, detail: 'Failed to unlock the keyring');
    await tester.pumpAndSettle();
    expect(find.textContaining('The keyring refused them'), findsOneWidget);
  });

  testWidgets('twice the text size still fits', (tester) async {
    await pumpSettings(tester, textScale: 2);
    expect(tester.takeException(), isNull);
    expect(find.text('Trusted certificates'), findsOneWidget);
  });
}
