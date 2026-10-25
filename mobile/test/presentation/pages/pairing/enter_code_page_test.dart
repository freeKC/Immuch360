// "Enter a code instead": the screens announced nearby are listed, and a phone that sends a drone's picture to
// headsets (DJI link, kind=drone under the same DNS-SD type) is not one of them

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/infrastructure/network/network_discovery_probes.dart';
import 'package:immich_mobile/presentation/pages/pairing/enter_code.page.dart';

import '../../../test_utils.dart';

void main() {
  setUpAll(TestUtils.init);

  Future<void> pump(WidgetTester tester, List<MdnsService> announced) async {
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
          overrides: [pairingBrowseProvider.overrideWithValue((type, until) => Stream.fromIterable(announced))],
          child: Builder(
            builder: (context) => MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: const EnterCodePage(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists the screens and skips a phone that sends a drone picture', (tester) async {
    await pump(tester, const [
      MdnsService(
        name: 'Immuch360 on Living room TV',
        type: '_immuch360-pair._tcp',
        host: '192.168.1.20',
        port: 8361,
        attributes: {'v': '1', 'kind': 'tv'},
      ),
      MdnsService(
        name: 'Immuch360 on Galaxy S24+',
        type: '_immuch360-pair._tcp',
        host: '192.168.1.21',
        port: 8362,
        attributes: {'v': '1', 'kind': 'drone', 'rv': '1', 'id': '3f9c0a1b2c3d4e5f'},
      ),
    ]);

    expect(find.byKey(const ValueKey('pairing_found_192.168.1.20:8361')), findsOneWidget);
    expect(find.byKey(const ValueKey('pairing_found_192.168.1.21:8362')), findsNothing);
    expect(find.text('Immuch360 on Galaxy S24+'), findsNothing);

    // The page looks for screens for two minutes at most: its timer ends with it
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 3));
  });
}
