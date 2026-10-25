// The watch page of the DJI live video on a headset (p2/design-ux-phone-2026-10-24.md, section 6): the observer rule
// and "Watching only" first, the sending phones only, one tap with a remembered code, the code asked once in a dialog
// and again when the phone refuses it, the connection made by itself to the last phone once per opening, the picture
// with the strip, the gated values and the delay, and the flight view of stage 2b with the same values.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/presentation/pages/drone/dji_watch.page.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_video.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_notice.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_transient.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';
import 'package:immich_mobile/providers/drone/dji_relay.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';

import '../../../unit/presentation/presentation_context.dart';
import 'dji_link_fakes.dart';

/// The window of the Quest 3, wide enough for the phones beside the picture
const _quest = Size(1280, 900);

const _phoneId = '3f9c0a1b2c3d4e5f';

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  /// What the page keeps on this install, in memory for each test
  late Map<StoreKey<bool>, bool> memory;

  setUp(() => memory = {});

  FakeDjiLinkApi headset() => FakeDjiLinkApi(
    environment: fakeEnvironment(accessoryFeature: false),
    snapshot: fakeSnapshot(state: DjiLinkState.unsupportedTransport),
  );

  Future<DjiLinkEvents?> openWatch(
    WidgetTester tester,
    FakeDjiLinkApi api, {
    FakeRelayEnvironment? relay,
    bool horizonOs = true,
    bool noticeRead = true,
  }) async {
    DjiLinkEvents? listener;
    await tester.binding.setSurfaceSize(_quest);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpTestWidget(
      context,
      Builder(
        builder: (context) => Center(
          child: TextButton(
            key: const Key('open_watch'),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DjiWatchPage())),
            child: const Text('open'),
          ),
        ),
      ),
      overrides: [
        djiLinkApiProvider.overrideWithValue(api),
        djiLinkEventsSetUpProvider.overrideWithValue((events) => listener = events),
        djiRelayEnvironmentProvider.overrideWithValue((relay ?? FakeRelayEnvironment()).build()),
        djiLiveNoticeReadProvider.overrideWith((ref) => noticeRead),
        djiLiveMemoryProvider.overrideWithValue(
          DjiLiveMemory(read: (key) => memory[key] ?? false, write: (key, value) async => memory[key] = value),
        ),
        isHorizonOsProvider.overrideWith((ref) async => horizonOs),
        djiLinkVideoViewBuilderProvider.overrideWithValue(
          () => const ColoredBox(key: Key('dji_watch_placeholder'), color: Colors.black),
        ),
      ],
    );
    await tester.tap(find.byKey(const Key('open_watch')));
    await tester.pump();
    await tester.pumpAndSettle();
    return listener;
  }

  Future<void> announce(WidgetTester tester, FakeRelayEnvironment relay, String host, Map<String, String> txt) async {
    relay.browsed.add(fakeAnnounced(host, txt));
    await tester.pumpAndSettle();
  }

  Finder phoneRow(String host) => find.byKey(ValueKey('dji_watch_phone_$host:8362'));

  testWidgets('the observer rule and Watching only head the notice, then the page', (tester) async {
    await openWatch(tester, headset(), noticeRead: false);
    final notice = find.byKey(const Key('dji_live_notice'));
    expect(notice, findsOneWidget);
    final observer = tester.getTopLeft(find.byKey(const Key('dji_live_notice_observer')));
    final pilot = tester.getTopLeft(find.textContaining('This tool reads the cable'));
    expect(observer.dy, lessThan(pilot.dy));
    expect(find.byKey(const Key('dji_live_notice_watching')), findsOneWidget);

    await tester.tap(find.byKey(const Key('dji_live_notice_ok')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_watch')), findsOneWidget);
    expect(find.byKey(const Key('dji_link_observer')), findsOneWidget);
    expect(find.byKey(const Key('dji_watch_none')), findsOneWidget);
  });

  testWidgets('lists the sending phones only, and a tap on one whose code is remembered watches at once', (
    tester,
  ) async {
    final relay = FakeRelayEnvironment()..secrets['dji_relay_code.$_phoneId'] = 'ABCDEFGHJK';
    final api = headset();
    await openWatch(tester, api, relay: relay);
    await announce(tester, relay, '192.168.1.21', fakeDroneTxt);
    await announce(tester, relay, '192.168.1.30', {'v': '1', 'kind': 'headset'});
    await announce(tester, relay, '8.8.8.8', {'v': '1', 'kind': 'drone', 'id': 'aaaaaaaaaaaaaaaa'});

    expect(phoneRow('192.168.1.21'), findsOneWidget);
    expect(phoneRow('192.168.1.30'), findsNothing);
    expect(phoneRow('8.8.8.8'), findsNothing);
    expect(find.text('Tap to watch'), findsOneWidget);
    // The last phone watched is not known yet: nothing connects by itself
    expect(api.connects, isEmpty);

    await tester.tap(phoneRow('192.168.1.21'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_watch_code_dialog')), findsNothing);
    expect(api.connects.single, ('192.168.1.21', 8362, 'ABCDEFGHJK', _phoneId, 'Galaxy S24+'));
    expect(find.text('Watching'), findsOneWidget);
  });

  testWidgets('a phone without a code asks for it once, normalised, and refuses O 0 I 1 L', (tester) async {
    final relay = FakeRelayEnvironment();
    final api = headset();
    await openWatch(tester, api, relay: relay);
    await announce(tester, relay, '192.168.1.21', fakeDroneTxt);
    expect(find.text('Code needed'), findsOneWidget);

    await tester.tap(phoneRow('192.168.1.21'));
    await tester.pumpAndSettle();
    expect(find.text('Code shown on Immuch360 on Galaxy S24+'), findsOneWidget);
    expect(find.text('Asked once for this phone.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('dji_watch_code')), 'K7M2Q 9XRT0');
    await tester.tap(find.byKey(const Key('dji_watch_code_watch')));
    await tester.pumpAndSettle();
    expect(api.connects, isEmpty);
    expect(find.textContaining('it never holds O, 0, I, 1 or L'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('dji_watch_code')), 'k7m2q-9xrth');
    await tester.tap(find.byKey(const Key('dji_watch_code_watch')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_watch_code_dialog')), findsNothing);
    expect(api.connects.single, ('192.168.1.21', 8362, 'K7M2Q9XRTH', _phoneId, 'Galaxy S24+'));
    // Remembered for the phone's install id: typed once per phone
    expect(relay.secrets['dji_relay_code.$_phoneId'], 'K7M2Q9XRTH');
  });

  testWidgets('a refused or new code is asked again in the dialog, and forgotten', (tester) async {
    final relay = FakeRelayEnvironment()..secrets['dji_relay_code.$_phoneId'] = 'ABCDEFGHJK';
    final api = headset();
    final listener = await openWatch(tester, api, relay: relay);
    await announce(tester, relay, '192.168.1.21', fakeDroneTxt);
    await tester.tap(phoneRow('192.168.1.21'));
    await tester.pumpAndSettle();

    listener!.snapshotChanged(fakeSnapshot(relayReceiving: fakeReceiving(state: DjiRelayReceiveState.wrongCode)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_watch_code_dialog')), findsOneWidget);
    expect(find.byKey(const Key('dji_watch_code_error')), findsOneWidget);
    expect(relay.secrets.containsKey('dji_relay_code.$_phoneId'), isFalse);

    await tester.enterText(find.byKey(const Key('dji_watch_code')), 'MNPQR STUVW');
    await tester.tap(find.byKey(const Key('dji_watch_code_watch')));
    await tester.pumpAndSettle();
    expect(api.connects.last.$3, 'MNPQRSTUVW');
  });

  testWidgets('connects by itself to the last phone watched, once per opening, and not after Stop watching', (
    tester,
  ) async {
    final relay = FakeRelayEnvironment()
      ..secrets['dji_relay_code.$_phoneId'] = 'ABCDEFGHJK'
      ..secrets[djiRelayLastPhoneKey] = _phoneId;
    final api = headset();
    await openWatch(tester, api, relay: relay);
    expect(api.connects, isEmpty);

    await announce(tester, relay, '192.168.1.21', fakeDroneTxt);
    expect(api.connects.single.$1, '192.168.1.21');

    await tester.tap(find.byKey(const Key('dji_watch_stop')));
    await tester.pumpAndSettle();
    expect(api.disconnects, 1);
    // The same phone announced at another address: no connection by itself after Stop watching
    await announce(tester, relay, '192.168.1.22', fakeDroneTxt);
    expect(api.connects, hasLength(1));
  });

  testWidgets('a phone it receives from becomes the last phone watched', (tester) async {
    final relay = FakeRelayEnvironment()..secrets['dji_relay_code.$_phoneId'] = 'ABCDEFGHJK';
    final listener = await openWatch(tester, headset(), relay: relay);
    await announce(tester, relay, '192.168.1.21', fakeDroneTxt);
    await tester.tap(phoneRow('192.168.1.21'));
    await tester.pumpAndSettle();
    expect(relay.secrets[djiRelayLastPhoneKey], isNull);

    listener!.snapshotChanged(fakeSnapshot(decode: fakeDecode(), relayReceiving: fakeReceiving()));
    await tester.pumpAndSettle();
    expect(relay.secrets[djiRelayLastPhoneKey], _phoneId);
  });

  testWidgets('a typed address watches a phone that is not listed', (tester) async {
    final api = headset();
    await openWatch(tester, api);
    await tester.tap(find.text('Phone not listed? Type its address'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('dji_watch_address_field')), '8.8.8.8');
    await tester.tap(find.byKey(const Key('dji_watch_address_watch')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Type the address the phone shows'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('dji_watch_address_field')), '10.0.2.2');
    await tester.tap(find.byKey(const Key('dji_watch_address_watch')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('dji_watch_code')), 'K7M2Q9XRTH');
    await tester.tap(find.byKey(const Key('dji_watch_code_watch')));
    await tester.pumpAndSettle();
    expect(api.connects.single, ('10.0.2.2', 8362, 'K7M2Q9XRTH', null, 'Galaxy S24+'));
  });

  testWidgets('the picture with the strip over it, the state, the gated values and the delay', (tester) async {
    final listener = await openWatch(tester, headset());
    listener!.snapshotChanged(
      fakeSnapshot(
        decode: fakeDecode(),
        relayReceiving: fakeReceiving(phoneSource: 'cable'),
        telemetryValues: fakeTelemetry(percent: 34, motorTimeS: 41.6),
        liveFrame: fakeFrame(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('dji_watch_placeholder')), findsOneWidget);
    final strip = find.byKey(const Key('dji_link_receive_strip'));
    expect(
      find.descendant(of: strip, matching: find.text('Receiving from Galaxy S24+: live from the remote')),
      findsOneWidget,
    );
    expect(find.descendant(of: strip, matching: find.textContaining('Watching only')), findsOneWidget);
    expect(
      find.descendant(of: strip, matching: find.textContaining('an observer standing next to you')),
      findsOneWidget,
    );
    // The values under the picture, each a small label over a number, the same gate as the phone's bands
    final values = find.byKey(const Key('dji_watch_values'));
    expect(find.descendant(of: values, matching: find.text('Drone battery')), findsOneWidget);
    expect(find.descendant(of: values, matching: find.text('34 %')), findsOneWidget);
    expect(find.descendant(of: values, matching: find.text('Motor time')), findsOneWidget);
    expect(find.descendant(of: values, matching: find.text('0:41')), findsOneWidget);
    expect(find.descendant(of: values, matching: find.text('50 %')), findsNothing);
    // On the ground: no height and no speed (the native side gives them in the air only)
    expect(find.descendant(of: values, matching: find.textContaining('Height')), findsNothing);
    expect(find.text('Delay from the phone: about 24 ms'), findsOneWidget);
    expect(find.byKey(const Key('dji_link_receive_strip_stale')), findsNothing);
    // In the air: the flight values first, proven by the flights of 25 October
    listener.flightChanged(
      fakeFrame(atMs: 2000, motorsOn: true, heightM: 0.8, verticalSpeedMps: 1.5, speedMps: 1.2, distanceBelowM: 1.476),
    );
    await tester.pumpAndSettle();
    for (final text in ['Height', '0.8 m', 'Vertical', '↑ 1.5 m/s', 'Speed', '1.2 m/s', 'Below', '1.48 m']) {
      expect(find.descendant(of: values, matching: find.text(text)), findsOneWidget, reason: text);
    }

    listener.snapshotChanged(
      fakeSnapshot(decode: fakeDecode(lastOutputAgoMs: 900), relayReceiving: fakeReceiving(lastPictureAgoMs: 900)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_link_receive_strip_stale')), findsOneWidget);

    listener.snapshotChanged(
      fakeSnapshot(
        relayReceiving: fakeReceiving(state: DjiRelayReceiveState.lost, reconnectInMs: 1500, failures: 3),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_watch_placeholder')), findsNothing);
    expect(
      find.text('Still trying. Check that the phone and the headset are on the same Wi-Fi.'),
      findsOneWidget,
    );
  });

  testWidgets('the warnings over the window come for five seconds, fade, and come back with a tap', (tester) async {
    final listener = await openWatch(tester, headset());
    listener!.snapshotChanged(
      fakeSnapshot(
        decode: fakeDecode(),
        relayReceiving: fakeReceiving(phoneSource: 'cable'),
        liveFrame: fakeFrame(),
      ),
    );
    await tester.pumpAndSettle();
    final strip = find.byKey(const Key('dji_link_receive_strip'));
    final state = find.byKey(const Key('dji_link_receive_strip_state'));
    final watching = find.byKey(const Key('dji_link_receive_strip_watching'));
    final observer = find.byKey(const Key('dji_link_observer'));
    expect(state, findsOneWidget);
    expect(watching, findsOneWidget);
    expect(observer, findsOneWidget);

    // Five seconds, then a fade of 0.8 s: gone from the window, the plate with them; the values and the delay stay
    await tester.pump(djiTransientHold);
    await tester.pumpAndSettle();
    expect(state, findsNothing);
    expect(watching, findsNothing);
    expect(observer, findsNothing);
    expect(tester.getSize(strip), Size.zero);
    expect(find.text('Delay from the phone: about 24 ms'), findsOneWidget);
    expect(find.byKey(const Key('dji_watch_values')), findsOneWidget);

    // A tap anywhere brings them back
    await tester.tapAt(tester.getCenter(find.byKey(const Key('dji_watch_placeholder'))));
    await tester.pumpAndSettle();
    expect(state, findsOneWidget);
    expect(watching, findsOneWidget);
    expect(observer, findsOneWidget);

    // The picture stops: its red line comes by itself, and stays while the window shows no picture
    await tester.pump(djiTransientHold);
    await tester.pumpAndSettle();
    listener.snapshotChanged(
      fakeSnapshot(decode: fakeDecode(lastOutputAgoMs: 900), relayReceiving: fakeReceiving(lastPictureAgoMs: 900)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_link_receive_strip_stale')), findsOneWidget);
    await tester.pump(djiTransientHold);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_link_receive_strip_stale')), findsNothing);
    listener.snapshotChanged(
      fakeSnapshot(
        decode: fakeDecode(lastOutputAgoMs: 2500),
        relayReceiving: fakeReceiving(lastPictureAgoMs: 2500),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(djiTransientHold * 2);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_link_receive_strip_stale')), findsOneWidget);

    // An error that needs an action stays
    listener.snapshotChanged(fakeSnapshot(relayReceiving: fakeReceiving(state: DjiRelayReceiveState.otherVersion)));
    await tester.pumpAndSettle();
    await tester.pump(djiTransientHold * 2);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: strip, matching: find.text('The phone runs another version of Immuch360: update both.')),
      findsOneWidget,
    );
  });

  testWidgets('opens the flight view on Horizon OS only, while pictures come, with the same values', (tester) async {
    final api = headset();
    final listener = await openWatch(tester, api);
    final button = find.byKey(const Key('dji_link_flight_view_open'));
    expect(tester.widget<ButtonStyleButton>(button).onPressed, isNull);

    listener!.snapshotChanged(fakeSnapshot(decode: fakeDecode(), relayReceiving: fakeReceiving()));
    await tester.pumpAndSettle();
    expect(tester.widget<ButtonStyleButton>(button).onPressed, isNotNull);
    await tester.tap(button);
    await tester.pumpAndSettle();
    final labels = api.flightViews.single;
    expect(labels['cell.droneBattery.label'], 'Drone battery');
    expect(labels['cell.droneBattery.value'], '{value} %');
    expect(labels['cell.motorTime.label'], 'Motor time');
    expect(labels['cell.motorTime.value'], '{value}');
    expect(labels['delay'], 'Delay from the phone: about {ms} ms');
    // Before the clocks are aligned the delay is an estimate, said apart; a late picture is a warning on the strip
    expect(labels['delayEstimate'], 'Delay from the phone: about {ms} ms, smoothing buffer not counted');
    expect(labels['delayHigh'], 'The picture is {ms} ms behind the phone');
    // The flight values of the left column, proven by the flights of 25 October
    expect(labels['cell.height.label'], 'Height');
    expect(labels['cell.height.value'], '{value} m');
    expect(labels['cell.verticalSpeed.label'], 'Vertical');
    expect(labels['cell.verticalSpeed.value'], '{value} m/s');
    expect(labels['cell.speed.label'], 'Speed');
    expect(labels['cell.speed.value'], '{value} m/s');
    expect(labels['cell.distanceBelow.label'], 'Below');
    expect(labels['cell.distanceBelow.value'], '{value} m');
    for (final hidden in ['remoteBattery', 'signal', 'heading', 'satellites', 'distanceHome', 'obstacle']) {
      expect(labels.containsKey('cell.$hidden.value'), isFalse, reason: hidden);
    }
    // The obstacle ring writes only its distance, by the glow when asked; none of the banner's words is left
    expect(labels['obstacleDistance'], '{distance} m');
    for (final gone in ['obstacleClose', 'obstacleClosePlain', 'obstacleStopped', 'obstacleAhead', 'obstacleUnconfirmed']) {
      expect(labels.containsKey(gone), isFalse, reason: gone);
    }
    expect(labels['batteryLow'], 'low');
    expect(labels['observer'], contains('an observer standing next to you'));
    expect(labels['watching'], contains('Watching only'));
    expect(labels['flyNote'], 'Not compared with DJI Fly yet: do not fly by these numbers.');
    expect(labels['stale'], 'No new picture for {seconds} s');
    expect(labels['ended'], 'No picture comes any more: B or Y, back to the window.');
    expect(labels['wrongCode'], 'The code does not match: type it again.');
    expect(labels['noValues'], 'No flight data has arrived.');
    expect(labels['valuesStale'], 'These values are no longer updated');
    expect(labels['hint'], contains('A: show or hide the numbers beside the picture'));

    listener.snapshotChanged(fakeSnapshot(decode: fakeDecode(lastOutputAgoMs: 5000), relayReceiving: fakeReceiving()));
    await tester.pumpAndSettle();
    expect(tester.widget<ButtonStyleButton>(button).onPressed, isNull);
  });

  testWidgets('no flight view button off Horizon OS', (tester) async {
    final listener = await openWatch(tester, headset(), horizonOs: false);
    listener!.snapshotChanged(fakeSnapshot(decode: fakeDecode(), relayReceiving: fakeReceiving()));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_link_flight_view_open')), findsNothing);
  });

  testWidgets('leaving the page stops receiving with it, and the frames and the screen kept on with it', (
    tester,
  ) async {
    final relay = FakeRelayEnvironment();
    final api = headset();
    await openWatch(tester, api, relay: relay);
    expect(api.frameStreams, [true]);
    expect(relay.screen.last, isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_watch')), findsNothing);
    expect(api.stops, 1);
    expect(api.frameStreams, [true, false]);
    expect(relay.screen.last, isFalse);
  });

  Future<void> menu(WidgetTester tester, Key item) async {
    await tester.tap(find.byKey(const Key('dji_watch_menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(item));
    await tester.pumpAndSettle();
  }

  testWidgets('"Save a reception record" writes it and names it, or says nothing was received', (tester) async {
    final api = headset();
    await openWatch(tester, api);
    await menu(tester, const Key('dji_watch_save_record'));
    expect(api.receptionExports, 1);
    expect(find.text('Saved in Download/Immuch360/dji-link: dji-relay-20261024-171200'), findsOneWidget);

    api.receptionResult = DjiLinkExport(ok: true, bytes: 0, nothing: true);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await menu(tester, const Key('dji_watch_save_record'));
    expect(find.text('Nothing received yet: nothing to save.'), findsOneWidget);
  });

  testWidgets('the lowest delay: on by default, a choice of the headset kept and told to the native side', (
    tester,
  ) async {
    final api = headset();
    await openWatch(tester, api);
    // Every experimental switch on by default (FreeKC's rule of 25 October)
    expect(api.lowestDelays.last, isTrue);
    await tester.tap(find.byKey(const Key('dji_watch_menu')));
    await tester.pumpAndSettle();
    final item = find.byKey(const Key('dji_watch_lowest_delay'));
    expect(tester.widget<CheckedPopupMenuItem<String>>(item).checked, isTrue);
    await tester.tap(item);
    await tester.pumpAndSettle();
    expect(api.lowestDelays.last, isFalse);
    expect(memory[StoreKey.djiHeadsetLowestDelayOff], isTrue);
    await menu(tester, const Key('dji_watch_lowest_delay'));
    expect(api.lowestDelays.last, isTrue);
    expect(memory[StoreKey.djiHeadsetLowestDelayOff], isFalse);
  });

  testWidgets('the headset keeps its own ring, sound, number, shape and sample; the ring follows the phone', (
    tester,
  ) async {
    final api = headset();
    final listener = await openWatch(tester, api);
    // All on by default on the headset; whether the phone offers the ring comes from its record
    expect(api.obstacleRings.last.offered, isTrue);
    expect(api.obstacleRings.last.sound, isTrue);
    expect(api.obstacleRings.last.numbers, isTrue);
    expect(api.obstacleRings.last.frame, isFalse);
    await tester.tap(find.byKey(const Key('dji_watch_menu')));
    await tester.pumpAndSettle();
    // The old test switch is gone; the ring on this headset's own screens, on by default, can only turn it off here
    expect(find.byKey(const Key('dji_watch_obstacle')), findsNothing);
    final here = find.byKey(const Key('dji_watch_obstacle_here'));
    expect(tester.widget<CheckedPopupMenuItem<String>>(here).checked, isTrue);
    expect(find.byKey(const Key('dji_watch_obstacle_sound')), findsOneWidget);
    expect(find.byKey(const Key('dji_watch_obstacle_sound_test')), findsOneWidget);
    expect(find.byKey(const Key('dji_watch_obstacle_numbers')), findsOneWidget);
    expect(find.text('Obstacle indicator: Circle around the centre'), findsOneWidget);
    await tester.tap(find.byKey(const Key('dji_watch_obstacle_sound')));
    await tester.pumpAndSettle();
    expect(api.obstacleRings.last.sound, isFalse);
    expect(memory[StoreKey.djiObstacleSoundOff], isTrue);
    await menu(tester, const Key('dji_watch_obstacle_here'));
    expect(api.obstacleRings.last.offered, isFalse);
    expect(memory[StoreKey.djiObstacleRingOff], isTrue);
    await menu(tester, const Key('dji_watch_obstacle_here'));
    expect(api.obstacleRings.last.offered, isTrue);
    await menu(tester, const Key('dji_watch_obstacle_shape'));
    expect(api.obstacleRings.last.frame, isTrue);
    expect(memory[StoreKey.djiObstacleShapeFrame], isTrue);
    await tester.tap(find.byKey(const Key('dji_watch_menu')));
    await tester.pumpAndSettle();
    expect(find.text('Obstacle indicator: Frame at the edges'), findsOneWidget);
    await tester.tap(find.byKey(const Key('dji_watch_obstacle_shape')));
    await tester.pumpAndSettle();
    expect(api.obstacleRings.last.frame, isFalse);
    await menu(tester, const Key('dji_watch_obstacle_sound_test'));
    expect(api.obstacleTests, 1);
    await menu(tester, const Key('dji_watch_obstacle_numbers'));
    expect(api.obstacleRings.last.numbers, isFalse);
    expect(memory[StoreKey.djiObstacleNumbersOff], isTrue);
    await menu(tester, const Key('dji_watch_obstacle_numbers'));
    expect(api.obstacleRings.last.numbers, isTrue);
    expect(memory[StoreKey.djiObstacleNumbersOff], isFalse);
    await menu(tester, const Key('dji_watch_obstacle_sample'));
    expect(api.obstacleSamples, 1);
    api.sampleRefused = true;
    await menu(tester, const Key('dji_watch_obstacle_sample'));
    expect(find.text('Not while the motors run.'), findsOneWidget);

    // What the native side decided shows over the picture: the glow, and the number now asked
    listener!.snapshotChanged(
      fakeSnapshot(
        decode: fakeDecode(),
        relayReceiving: fakeReceiving(phoneSource: 'cable'),
        liveFrame: fakeFrame(alert: fakeDecision(on: true, arcs: [fakeArc(1.84)])),
      ),
    );
    await tester.pumpAndSettle();
    final ring = find.byKey(const Key('dji_live_obstacle_ring'));
    expect(ring, findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('dji_watch_picture')), matching: ring), findsOneWidget);
    expect(find.byKey(const Key('dji_live_obstacle_circle')), findsOneWidget);
    expect(find.text('1.8 m'), findsOneWidget);
    expect(find.text('Obstacle close: 1.8 m'), findsNothing);
    expect(find.text('Not confirmed yet'), findsNothing);
  });
}
