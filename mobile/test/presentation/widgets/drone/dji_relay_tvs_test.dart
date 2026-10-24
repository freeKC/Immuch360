// The TVs of "Send to a headset or a TV" on the phone (p2/design-tv-2026-10-24.md, 2.4 and 8.1 item 9): "Add a TV" scans
// the code a TV's Drone page shows and the relay welcomes it, the sign in code says where it goes, a typed code is
// checked, each TV is named from its first connection and "Watching" while it is, Remove tells the relay, eight at
// most, all kept on this phone only.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/platform/qr_scan_api.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_send.panel.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';
import 'package:immich_mobile/providers/drone/dji_relay.provider.dart';
import 'package:immich_mobile/providers/pairing/phone_pairing.provider.dart';

import '../../../unit/presentation/presentation_context.dart';
import '../../pages/drone/dji_link_fakes.dart';

/// The scanner of the phone: the results given in order
class _FakeScanner extends QrScanApi {
  _FakeScanner(this.results);

  final List<QrScanResult> results;
  final prompts = <String>[];

  @override
  Future<QrScanResult> scan(String prompt, String cancelLabel) async {
    prompts.add(prompt);
    return results.removeAt(0);
  }
}

QrScanResult _scanned(String text) => QrScanResult(status: QrScanStatus.scanned, text: text);

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  /// The Send panel of the phone, its page in front, so that the relay may start
  Future<ProviderContainer> pumpPanel(
    WidgetTester tester,
    FakeDjiLinkApi api,
    FakeRelayEnvironment relay,
    _FakeScanner scanner,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpTestWidget(
      context,
      const DjiLiveSendPanel(),
      overrides: [
        djiLinkApiProvider.overrideWithValue(api),
        djiLinkEventsSetUpProvider.overrideWithValue((_) {}),
        djiRelayEnvironmentProvider.overrideWithValue(relay.build()),
        qrScanApiProvider.overrideWithValue(scanner),
      ],
    );
    final container = ProviderScope.containerOf(tester.element(find.byType(DjiLiveSendPanel)));
    await container.read(djiRelayProvider.notifier).setPageVisible(true);
    await tester.pumpAndSettle();
    return container;
  }

  FakeDjiLinkApi phone() => FakeDjiLinkApi(environment: fakeEnvironment(flavour: 'phone'));

  testWidgets('Add a TV scans its code, the relay welcomes it, and the TV is kept on this phone only', (tester) async {
    final api = phone();
    final relay = FakeRelayEnvironment();
    final scanner = _FakeScanner([_scanned('IMMUCH360-WATCH:1:MNPQRSTUVW')]);
    final container = await pumpPanel(tester, api, relay, scanner);
    expect(find.text('TVs'), findsOneWidget);
    expect(
      find.text('No TV yet. On the TV, open Immuch360, Library, Drone: it shows a code to scan here.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('dji_live_send_switch')));
    await tester.pumpAndSettle();
    expect(api.relayStarts.single.screenCodes, isEmpty);

    await tester.tap(find.byKey(const Key('dji_live_send_tv_add')));
    await tester.pumpAndSettle();
    expect(scanner.prompts.single, 'Scan the code the TV shows');
    expect(find.text('A TV, not connected yet'), findsOneWidget);
    final pushed = api.relayScreenCodes.single.single;
    expect((pushed.id, pushed.code), ('a1b2c3d4e5f60718', 'MNPQRSTUVW'));
    final kept = jsonDecode(relay.secrets[djiRelayScreensKey]!) as List;
    expect(kept.single, {'id': 'a1b2c3d4e5f60718', 'code': 'MNPQRSTUVW', 'added': 1792862400000});

    // Its first connection names it, and it watches
    container
        .read(djiLinkProvider.notifier)
        .snapshotChanged(
          fakeSnapshot(
            relaySending: fakeSending(
              sending: 'cable',
              headsets: [
                DjiRelayHeadsetRow(
                  address: '192.168.1.50',
                  name: 'Living room TV',
                  connectedForMs: 5000,
                  droppedUnits: 0,
                  megabitsPerSecond: 5.6,
                  screenCodeId: 'a1b2c3d4e5f60718',
                  kind: 'tv',
                ),
              ],
            ),
          ),
        );
    await tester.pumpAndSettle();
    expect(find.text('Living room TV'), findsOneWidget);
    expect(find.text('Watching'), findsOneWidget);
    expect(jsonDecode(relay.secrets[djiRelayScreensKey]!), [
      {'id': 'a1b2c3d4e5f60718', 'code': 'MNPQRSTUVW', 'added': 1792862400000, 'name': 'Living room TV'},
    ]);

    // Remove: the relay is told at once
    await tester.tap(find.byKey(const ValueKey('dji_live_send_tv_remove_a1b2c3d4e5f60718')));
    await tester.pumpAndSettle();
    expect(api.relayScreenCodes.last, isEmpty);
    expect(jsonDecode(relay.secrets[djiRelayScreensKey]!), isEmpty);
    expect(find.text('Living room TV'), findsNothing);
  });

  testWidgets('a sign in code, another code, a refused camera: each says what to do and adds nothing', (tester) async {
    final api = phone();
    final relay = FakeRelayEnvironment();
    final scanner = _FakeScanner([
      _scanned('http://192.168.1.23:8361/p#1.AAECAwQFBgc.AQIDBAUGBwgJCgsMDQ4PEA'),
      _scanned('https://example.com'),
      QrScanResult(status: QrScanStatus.permissionDenied),
      QrScanResult(status: QrScanStatus.cancelled),
    ]);
    await pumpPanel(tester, api, relay, scanner);
    final message = find.byKey(const Key('dji_live_send_tv_message'));

    await tester.tap(find.byKey(const Key('dji_live_send_tv_add')));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(message).data, 'This code signs a TV in: use Settings, Connect a TV or computer.');

    await tester.tap(find.byKey(const Key('dji_live_send_tv_add')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(message).data,
      'This is not the code of a TV\'s Drone page. On the TV, open Library, Drone.',
    );

    await tester.tap(find.byKey(const Key('dji_live_send_tv_add')));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(message).data, 'Allow the camera to scan the code, or enter the code instead.');

    await tester.tap(find.byKey(const Key('dji_live_send_tv_add')));
    await tester.pumpAndSettle();
    expect(message, findsNothing);
    expect(relay.secrets.containsKey(djiRelayScreensKey), isFalse);
    expect(api.relayScreenCodes, isEmpty);
  });

  testWidgets('the TV\'s code typed with the phone\'s keyboard, checked, and eight TVs at most', (tester) async {
    final api = phone();
    final relay = FakeRelayEnvironment()
      ..secrets[djiRelayScreensKey] = jsonEncode([
        for (var index = 0; index < 7; index++) {'id': 'tv$index', 'code': 'ABCDEFGHJ${'KMNPQRS'[index]}', 'added': 1},
        // An entry that is not one of ours is dropped
        {'id': '', 'code': 'nope', 'added': 1},
      ]);
    await pumpPanel(tester, api, relay, _FakeScanner([]));
    await tester.pumpAndSettle();
    expect(find.text('A TV, not connected yet'), findsNWidgets(7));

    await tester.tap(find.byKey(const Key('dji_live_send_tv_type')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('dji_live_send_tv_code')), 'MNPQR STUV0');
    await tester.tap(find.byKey(const Key('dji_live_send_tv_dialog_add')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_live_send_tv_code_error')), findsOneWidget);
    expect(find.textContaining('as the TV shows it'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('dji_live_send_tv_code')), 'mnpqr-stuvw');
    await tester.tap(find.byKey(const Key('dji_live_send_tv_dialog_add')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_live_send_tv_dialog')), findsNothing);
    expect(find.text('A TV, not connected yet'), findsNWidgets(8));
    // Not sending: nothing to tell the relay yet, it gets the list when it starts
    expect(api.relayScreenCodes, isEmpty);

    await tester.tap(find.byKey(const Key('dji_live_send_tv_type')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('dji_live_send_tv_code')), 'WXYZ234567');
    await tester.tap(find.byKey(const Key('dji_live_send_tv_dialog_add')));
    await tester.pumpAndSettle();
    expect(find.text('Eight TVs at most: remove one first.'), findsOneWidget);
    expect(find.text('A TV, not connected yet'), findsNWidgets(8));

    await tester.tap(find.byKey(const Key('dji_live_send_switch')));
    await tester.pumpAndSettle();
    expect(api.relayStarts.single.screenCodes.map((screen) => screen.code), [
      for (var index = 0; index < 7; index++) 'ABCDEFGHJ${'KMNPQRS'[index]}',
      'MNPQRSTUVW',
    ]);
  });
}
