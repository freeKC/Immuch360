import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/network/network_choice.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:path/path.dart' as p;

void main() {
  late Future<Directory> Function() systemFolder;

  setUpAll(() => systemFolder = DesktopNetworkChoice.folder);

  tearDown(() {
    DesktopNetworkChoice.folder = systemFolder;
    DesktopNetworkChoice.forget();
  });

  group('DesktopNetworkChoice', () {
    late Directory folder;

    setUp(() {
      folder = Directory.systemTemp.createTempSync('desktop_network_choice');
      DesktopNetworkChoice.folder = () async => folder;
      DesktopNetworkChoice.forget();
    });

    tearDown(() => folder.deleteSync(recursive: true));

    test('Automatic until an adapter is chosen, then that adapter at the next start', () async {
      expect(await DesktopNetworkChoice.load(), isNull);

      await DesktopNetworkChoice.save('Wi-Fi');
      expect(await DesktopNetworkChoice.load(), 'Wi-Fi');

      DesktopNetworkChoice.forget();
      expect(await DesktopNetworkChoice.load(), 'Wi-Fi');
      expect(File(p.join(folder.path, DesktopNetworkChoice.fileName)).readAsStringSync(), '{"adapter":"Wi-Fi"}');
      expect(File(p.join(folder.path, '${DesktopNetworkChoice.fileName}.tmp')).existsSync(), isFalse);
    });

    test('back to Automatic', () async {
      await DesktopNetworkChoice.save('Ethernet');
      await DesktopNetworkChoice.save(null);
      DesktopNetworkChoice.forget();
      expect(await DesktopNetworkChoice.load(), isNull);
    });

    test('a damaged file is Automatic', () async {
      File(p.join(folder.path, DesktopNetworkChoice.fileName)).writeAsStringSync('{"adapter": ');
      expect(await DesktopNetworkChoice.load(), isNull);
      DesktopNetworkChoice.forget();
      File(p.join(folder.path, DesktopNetworkChoice.fileName)).writeAsStringSync('["Wi-Fi"]');
      expect(await DesktopNetworkChoice.load(), isNull);
    });

    test('a folder that cannot be written keeps the choice for the session', () async {
      DesktopNetworkChoice.folder = () async => throw const FileSystemException('read only');
      await DesktopNetworkChoice.save('Wi-Fi');
      expect(await DesktopNetworkChoice.load(), 'Wi-Fi');
    });
  });

  group('DesktopNetworkAdapterTile', () {
    // No file in widget tests: the choice lives for the session, which is what the tile shows
    setUp(() => DesktopNetworkChoice.folder = () async => throw const FileSystemException('not in widget tests'));

    Future<void> pump(WidgetTester tester) async {
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
              home: Scaffold(
                body: DesktopNetworkAdapterTile(
                  choices: () async => const [('Ethernet', '192.168.1.42'), ('Wi-Fi', '192.168.50.17')],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('Automatic by default; an adapter picked in the dialog is kept', (tester) async {
      await pump(tester);
      expect(find.text('Network for discovery and sharing'), findsOneWidget);
      expect(find.text('Automatic'), findsOneWidget);

      await tester.tap(find.byKey(const Key('desktop_network_adapter')));
      await tester.pumpAndSettle();
      expect(find.text('The network adapter used to find shares and to share this computer'), findsOneWidget);
      expect(find.text('192.168.50.17'), findsOneWidget);
      await tester.tap(find.text('Wi-Fi'));
      await tester.pumpAndSettle();

      expect(find.byType(SimpleDialog), findsNothing);
      expect(find.text('Wi-Fi'), findsOneWidget);
      expect(await DesktopNetworkChoice.load(), 'Wi-Fi');

      await tester.tap(find.byKey(const Key('desktop_network_adapter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('desktop_network_adapter_automatic')));
      await tester.pumpAndSettle();

      expect(find.text('Automatic'), findsOneWidget);
      expect(await DesktopNetworkChoice.load(), isNull);
    });

    testWidgets('an adapter chosen earlier and not connected now still shows in the dialog', (tester) async {
      await DesktopNetworkChoice.save('USB Ethernet');
      await pump(tester);
      expect(find.text('USB Ethernet'), findsOneWidget);

      await tester.tap(find.byKey(const Key('desktop_network_adapter')));
      await tester.pumpAndSettle();
      expect(find.text('USB Ethernet'), findsNWidgets(2));
    });
  });
}
