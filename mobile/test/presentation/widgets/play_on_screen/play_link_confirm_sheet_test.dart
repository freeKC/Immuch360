// "Let this phone play films on Living room TV?": the sheet the phone shows before it links a screen

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/infrastructure/network/pairing/pairing_client.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/play_link_confirm.sheet.dart';

import '../../../test_utils.dart';
import '../../system_navigation_bar.dart';
import 'play_on_test_app.dart';

void main() {
  setUpAll(TestUtils.init);

  testWidgets('keeps Cancel and Link above the navigation bar of the phone, and Link answers yes', (tester) async {
    screenWithNavigationBar(tester);
    final answers = <bool>[];
    await pumpPlayOn(
      tester,
      playOnOpener(
        (context) async => answers.add(
          await showPlayLinkConfirmSheet(
            context,
            device: const PairingScreenDevice(
              label: 'Living room TV',
              kind: PairingScreenKind.tv,
              os: 'Android',
              app: '3.4.0',
            ),
            address: '192.168.1.23',
            check: '048213',
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Let this phone play films on Living room TV?'), findsOneWidget);
    final link = find.byKey(const Key('play_link_confirm_button'));
    await tester.ensureVisible(link);
    await tester.pumpAndSettle();
    expectAboveNavigationBar(tester, link);
    expectAboveNavigationBar(tester, find.text('Cancel'));
    await tester.tap(link);
    await tester.pumpAndSettle();
    expect(answers, [true]);
  });
}
