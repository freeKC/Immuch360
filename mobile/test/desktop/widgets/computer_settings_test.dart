// The "This computer" section of the settings (plan 1.2, design 4.7): its groups and their labels, the Tab order from
// the folders down to the certificates with a visible ring on each stop, and a large text size that still fits. The
// files the groups read live in a temporary folder.

import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/network/network_choice.dart';
import 'package:immich_mobile/desktop/settings/computer_settings.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_focus_ring.widget.dart';

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

  Future<void> pumpSettings(WidgetTester tester, {double textScale = 1}) async {
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
        child: Builder(
          builder: (context) => MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: const Scaffold(body: ComputerSettings()),
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
  }

  testWidgets('the four groups, named', (tester) async {
    await pumpSettings(tester);
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

  testWidgets('twice the text size still fits', (tester) async {
    await pumpSettings(tester, textScale: 2);
    expect(tester.takeException(), isNull);
    expect(find.text('Trusted certificates'), findsOneWidget);
  });
}
