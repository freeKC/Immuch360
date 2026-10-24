// The live screen of the DJI live video on a phone (p2/design-ux-phone-2026-10-24.md): the safety notice once per run
// of the app, a step card for each stage of the link, the picture with the gated values and nothing in it that takes a
// touch, Back that asks once a picture showed, the cards that say to fly with the remote once the drone was seen, Send
// to a headset and Advanced from the right, the offer to open on the plug, and the screen kept on.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/presentation/pages/drone/dji_live.page.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_video.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_notice.widget.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';
import 'package:immich_mobile/providers/drone/dji_relay.provider.dart';

import '../../../unit/presentation/presentation_context.dart';
import 'dji_link_fakes.dart';

/// The Galaxy S24+ in landscape, 2340 by 1080 pixels at 2.625: a 16:9 picture leaves a band of 80 dp on each side
const _s24 = Size(891, 411);

/// A large landscape screen, for the panels whose items are listed one under the other
const _large = Size(2000, 1100);

/// What the live screen keeps on this install, in memory
class _Memory {
  final values = <StoreKey<bool>, bool>{};

  DjiLiveMemory build() =>
      DjiLiveMemory(read: (key) => values[key] ?? false, write: (key, value) async => values[key] = value);
}

void main() {
  late PresentationContext context;
  late _Memory memory;

  setUp(() async {
    context = await PresentationContext.create();
    memory = _Memory();
  });

  tearDown(() async {
    await context.dispose();
  });

  DjiLinkSnapshot live({
    DjiLiveFrame? frame,
    DjiLinkTelemetry? telemetry,
    DjiLinkDecode? decode,
    int captureBytes = 4096,
  }) => fakeSnapshot(
    state: DjiLinkState.videoReady,
    reason: DjiLinkReason.videoDecoded,
    decode: decode ?? fakeDecode(),
    telemetryValues: telemetry ?? fakeTelemetry(percent: 34, motorTimeS: 41.6),
    liveFrame: frame ?? fakeFrame(),
    captureBytes: captureBytes,
  );

  /// Opens the live screen from a page under it, so that Back has somewhere to go; returns the events listener
  Future<DjiLinkEvents?> openLive(
    WidgetTester tester,
    FakeDjiLinkApi api, {
    FakeRelayEnvironment? relay,
    bool noticeRead = true,
    Size size = _s24,
  }) async {
    DjiLinkEvents? listener;
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpTestWidget(
      context,
      Builder(
        builder: (context) => Center(
          child: TextButton(
            key: const Key('open_live'),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DjiLivePage())),
            child: const Text('open'),
          ),
        ),
      ),
      overrides: [
        djiLinkApiProvider.overrideWithValue(api),
        djiLinkEventsSetUpProvider.overrideWithValue((events) => listener = events),
        djiRelayEnvironmentProvider.overrideWithValue((relay ?? FakeRelayEnvironment()).build()),
        djiLiveNoticeReadProvider.overrideWith((ref) => noticeRead),
        djiLiveMemoryProvider.overrideWithValue(memory.build()),
        // No platform view under flutter test: a placeholder stands where the picture is
        djiLinkVideoViewBuilderProvider.overrideWithValue(
          () => const ColoredBox(key: Key('dji_live_placeholder'), color: Colors.black),
        ),
      ],
    );
    await tester.tap(find.byKey(const Key('open_live')));
    await tester.pump();
    await tester.pumpAndSettle();
    return listener;
  }

  Future<void> push(WidgetTester tester, DjiLinkEvents? listener, DjiLinkSnapshot snapshot) async {
    listener!.snapshotChanged(snapshot);
    await tester.pumpAndSettle();
  }

  FakeDjiLinkApi phone({DjiLinkSnapshot? snapshot, bool djiFly = false}) => FakeDjiLinkApi(
    environment: fakeEnvironment(flavour: 'phone', djiInstalled: djiFly),
    snapshot: snapshot ?? fakeSnapshot(state: DjiLinkState.absent, reason: DjiLinkReason.looking),
  );

  Finder cardTitle(String text) =>
      find.descendant(of: find.byKey(const Key('dji_live_card_title')), matching: find.text(text), matchRoot: true);

  testWidgets('the safety notice shows once per run of the app, and Back on it leaves the screen', (tester) async {
    final api = phone();
    // Large enough for the whole notice: on the S24+ in landscape it scrolls above its button
    await openLive(tester, api, noticeRead: false, size: _large);
    expect(find.byKey(const Key('dji_live_notice')), findsOneWidget);
    expect(find.text('You are the pilot'), findsOneWidget);
    expect(find.text('Not compared with DJI Fly yet: do not fly by these numbers.'), findsOneWidget);
    // The link starts behind it: reading it costs no time
    expect(api.starts, 1);

    await tester.tap(find.byKey(const Key('dji_live_notice_ok')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_live_notice')), findsNothing);
    expect(find.byKey(const Key('dji_live')), findsOneWidget);

    // Leave and open again in the same run: no notice
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_live')), findsNothing);
    await tester.tap(find.byKey(const Key('open_live')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_live_notice')), findsNothing);
    expect(find.byKey(const Key('dji_live')), findsOneWidget);
  });

  testWidgets('Back on the safety notice leaves the live screen, whose notice keeps its button in sight', (
    tester,
  ) async {
    await openLive(tester, phone(), noticeRead: false);
    // On the S24+ in landscape the notice scrolls; "I understand" stays on the screen
    final ok = tester.getRect(find.byKey(const Key('dji_live_notice_ok')));
    expect(ok.bottom, lessThanOrEqualTo(_s24.height));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_live_notice')), findsNothing);
    expect(find.byKey(const Key('dji_live')), findsNothing);
  });

  testWidgets('the screen starts the link and the capture, and stays on while it is in front', (tester) async {
    final relay = FakeRelayEnvironment();
    final api = phone();
    await openLive(tester, api, relay: relay);
    expect(api.starts, 1);
    // No remote open yet: the last session's capture stays until one opens, the native side forgets it then
    expect(api.clears, 0);
    expect(api.captureStarts, 1);
    expect(relay.screen.last, isTrue);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(api.stops, 1);
    expect(relay.screen.last, isFalse);
  });

  testWidgets('with a remote open at once, the capture starts fresh', (tester) async {
    final api = phone(snapshot: fakeSnapshot(state: DjiLinkState.accessoryOpen));
    await openLive(tester, api);
    expect(api.clears, 1);
    expect(api.captureStarts, 1);
  });

  testWidgets('the plug step says what to do, with DJI Fly beside, and checks the cable after 20 s', (tester) async {
    await openLive(tester, phone(djiFly: true));
    expect(cardTitle('Plug in the remote'), findsOneWidget);
    expect(
      find.text('Turn on the drone and the remote, then plug the remote into this phone with its cable.'),
      findsOneWidget,
    );
    expect(
      find.text('DJI Fly and Immuch360 cannot read the remote at the same time: close DJI Fly first.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('dji_live_dot_0_off')), findsOneWidget);
    expect(find.text('Nothing yet?'), findsNothing);
    // No offer without a previous session that showed a picture
    expect(find.byKey(const Key('dji_live_offer')), findsNothing);

    await tester.pump(const Duration(seconds: 21));
    expect(find.text('Nothing yet?'), findsOneWidget);
    expect(
      find.text('Check the cable at both ends. If Android asks for a USB mode, choose charging only.'),
      findsOneWidget,
    );
  });

  testWidgets('each step of the link has its card, and the remote unplugged after it was open says so', (tester) async {
    final api = phone();
    final listener = await openLive(tester, api);
    final untested = DjiLinkProfile(id: 'model-logiclink', label: 'model string', capabilities: const []);

    await push(tester, listener, fakeSnapshot(state: DjiLinkState.accessoryDetected, profile: untested));
    expect(cardTitle('Remote found'), findsOneWidget);
    expect(find.textContaining('choose Immuch360. Tick Always only if you do not use DJI Fly'), findsOneWidget);
    expect(find.textContaining('Only the DJI RC-N3 with a Neo 2 was tried so far.'), findsOneWidget);
    expect(find.byKey(const Key('dji_live_dot_0_on')), findsOneWidget);

    await push(tester, listener, fakeSnapshot(state: DjiLinkState.permissionPending));
    expect(cardTitle('Allow Immuch360'), findsOneWidget);

    await push(
      tester,
      listener,
      fakeSnapshot(state: DjiLinkState.permissionDenied, reason: DjiLinkReason.permissionRefused),
    );
    expect(cardTitle('Not allowed'), findsOneWidget);
    await tester.tap(find.byKey(const Key('dji_live_retry')));
    await tester.pumpAndSettle();
    expect(api.retries, 1);

    await push(tester, listener, fakeSnapshot(state: DjiLinkState.permissionDenied, reason: DjiLinkReason.openFailed));
    expect(cardTitle('Another app has the remote'), findsOneWidget);

    await push(tester, listener, fakeSnapshot(state: DjiLinkState.controllerIdentified));
    expect(cardTitle('Remote connected'), findsOneWidget);
    await tester.pump(const Duration(seconds: 16));
    expect(find.textContaining('The remote answers, but no drone does.'), findsOneWidget);

    await push(tester, listener, fakeSnapshot(state: DjiLinkState.aircraftLinked));
    expect(cardTitle('Drone found'), findsOneWidget);
    expect(find.byKey(const Key('dji_live_dot_1_on')), findsOneWidget);
    expect(find.byKey(const Key('dji_live_dot_2_off')), findsOneWidget);

    // The drone was found in this session: a lost cable link says first to fly with the remote
    await push(tester, listener, fakeSnapshot(state: DjiLinkState.linkLost, reason: DjiLinkReason.readsFailed));
    expect(cardTitle('This phone lost the cable link'), findsOneWidget);
    expect(find.text('Look at the drone and fly with the remote.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('dji_live_retry')));
    await tester.pumpAndSettle();
    expect(api.retries, 2);

    // Reads failed, then nothing listed: the remote was unplugged
    await push(tester, listener, fakeSnapshot(state: DjiLinkState.absent, reason: DjiLinkReason.nothingListed));
    expect(cardTitle('Remote unplugged'), findsOneWidget);
    expect(find.text('Plug it in again to go on.'), findsOneWidget);

    await push(tester, listener, fakeSnapshot(state: DjiLinkState.unsupportedProtocol));
    expect(cardTitle('Immuch360 cannot read this remote yet.'), findsOneWidget);
  });

  testWidgets('a phone that cannot read a remote says so', (tester) async {
    final api = FakeDjiLinkApi(
      environment: fakeEnvironment(accessoryFeature: false, flavour: 'phone'),
      snapshot: fakeSnapshot(state: DjiLinkState.unsupportedTransport),
    );
    await openLive(tester, api);
    expect(cardTitle('This phone cannot read a DJI remote'), findsOneWidget);
    expect(api.starts, 0);
  });

  testWidgets('the picture fills the screen with Live and the gated values, and nothing in it takes a touch', (
    tester,
  ) async {
    final api = phone();
    final listener = await openLive(tester, api);
    await push(tester, listener, live());

    expect(find.byKey(const Key('dji_live_placeholder')), findsOneWidget);
    expect(find.byKey(const Key('dji_live_card_title')), findsNothing);
    expect(find.byKey(const Key('dji_live_picture_live')), findsOneWidget);
    expect(find.text('Live'), findsOneWidget);
    expect(find.text('Drone battery'), findsOneWidget);
    expect(find.text('34 %'), findsOneWidget);
    expect(find.text('Motor time'), findsOneWidget);
    expect(find.text('0:41'), findsOneWidget);
    // Behind the gate: the remote's battery, the signal, the heading and the height are not over the picture
    expect(find.text('50 %'), findsNothing);
    expect(find.text('90'), findsNothing);
    expect(find.textContaining('127'), findsNothing);
    expect(find.textContaining('Height'), findsNothing);
    expect(find.textContaining('-0.5'), findsNothing);
    // The frames come ten times a second while this screen is in front
    expect(api.frameStreams, [true]);
    // A picture was seen on this install: the next sessions may offer to open on the plug
    expect(memory.values[StoreKey.djiLivePictureSeen], isTrue);

    // The buttons sit in the band beside the 16:9 picture, outside it
    final area = tester.getRect(find.byKey(const Key('dji_live_picture_area')));
    expect(area.left, closeTo(80, 1));
    expect(tester.getRect(find.byKey(const Key('dji_live_back'))).right, lessThanOrEqualTo(area.left));
    expect(tester.getRect(find.byKey(const Key('dji_live_advanced'))).right, lessThanOrEqualTo(area.left));
    // A tap in the middle of the picture reaches nothing
    await tester.tapAt(area.center);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_live_leave_dialog')), findsNothing);
    expect(find.byKey(const Key('dji_live_advanced_panel')), findsNothing);
    expect(find.byKey(const Key('dji_live_send_panel')), findsNothing);
    expect(find.byKey(const Key('dji_live')), findsOneWidget);
  });

  testWidgets('a stale group disappears, and the picture state follows the decoder', (tester) async {
    final listener = await openLive(tester, phone());
    await push(tester, listener, live(frame: fakeFrame(percent: null)));
    expect(find.text('34 %'), findsNothing);
    expect(find.text('0:41'), findsOneWidget);

    await push(tester, listener, live(decode: fakeDecode(lastOutputAgoMs: 900)));
    expect(find.text('No new picture for 0.9 s'), findsOneWidget);
    await push(tester, listener, live(decode: fakeDecode(picturesPerSecond: 12)));
    expect(find.text('Weak picture'), findsOneWidget);
    await push(tester, listener, live(decode: fakeDecode(lostPictures: 3)));
    expect(find.text('Weak picture'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await push(tester, listener, live(decode: fakeDecode(lostPictures: 3)));
    expect(find.text('Live'), findsOneWidget);

    // No picture for 2 s: black, and what to do
    await push(tester, listener, live(decode: fakeDecode(lastOutputAgoMs: 2500)));
    expect(find.byKey(const Key('dji_live_placeholder')), findsNothing);
    expect(cardTitle('No picture'), findsOneWidget);
    expect(find.text('Look at the drone and fly with the remote.'), findsOneWidget);
    await push(
      tester,
      listener,
      live(decode: fakeDecode(lastOutputAgoMs: 2500), telemetry: fakeTelemetry(aircraftPresent: false)),
    );
    expect(find.text('Nothing comes from the drone. Look at it and fly with the remote.'), findsOneWidget);
  });

  testWidgets('Back while the picture is live asks; Stay keeps the screen, Leave goes', (tester) async {
    final api = phone();
    final listener = await openLive(tester, api);
    await push(tester, listener, live());

    await tester.tap(find.byKey(const Key('dji_live_back')));
    await tester.pumpAndSettle();
    expect(find.text('Leave the live video?'), findsOneWidget);
    expect(find.text('The picture stops on this phone. The remote still flies the drone.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('dji_live_stay')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_live')), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('dji_live_leave')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_live')), findsNothing);
    expect(api.stops, 1);
  });

  testWidgets('Back on any other step leaves at once, and closes an open panel first', (tester) async {
    await openLive(tester, phone());
    await tester.tap(find.byKey(const Key('dji_live_advanced')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_live_advanced_panel')), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_live_advanced_panel')), findsNothing);
    expect(find.byKey(const Key('dji_live')), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_live_leave_dialog')), findsNothing);
    expect(find.byKey(const Key('dji_live')), findsNothing);
  });

  testWidgets('a lost cable link and an unplug after a picture say to fly with the remote, and Back asks', (
    tester,
  ) async {
    final api = phone();
    final listener = await openLive(tester, api);
    await push(tester, listener, live());

    await push(tester, listener, fakeSnapshot(state: DjiLinkState.linkLost, reason: DjiLinkReason.readsFailed));
    expect(cardTitle('This phone lost the cable link'), findsOneWidget);
    expect(find.text('Look at the drone and fly with the remote.'), findsOneWidget);
    expect(
      find.text('This phone tries again. Once landed, if it lasts, unplug the remote and plug it in again.'),
      findsOneWidget,
    );
    // Never the advice to touch the cable at once while the drone may be flying
    expect(find.text('Trying again. If it lasts, unplug the remote and plug it in again.'), findsNothing);
    expect(find.byKey(const Key('dji_live_retry')), findsOneWidget);

    // Back by reflex on that card asks first
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_live_leave_dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('dji_live_stay')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_live')), findsOneWidget);

    await push(tester, listener, fakeSnapshot(state: DjiLinkState.absent, reason: DjiLinkReason.detached));
    expect(cardTitle('Remote unplugged'), findsOneWidget);
    expect(find.text('Look at the drone and fly with the remote.'), findsOneWidget);
    expect(find.text('Plug it in again to go on.'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_live_leave_dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('dji_live_leave')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_live')), findsNothing);
  });

  testWidgets('a lost cable link before the drone answered keeps the plain advice', (tester) async {
    final listener = await openLive(tester, phone());
    await push(tester, listener, fakeSnapshot(state: DjiLinkState.controllerIdentified));
    await push(tester, listener, fakeSnapshot(state: DjiLinkState.linkLost, reason: DjiLinkReason.readsFailed));
    expect(cardTitle('This phone lost the cable link'), findsOneWidget);
    expect(find.text('Trying again. If it lasts, unplug the remote and plug it in again.'), findsOneWidget);
    expect(find.text('Look at the drone and fly with the remote.'), findsNothing);
  });

  testWidgets('a start that failed says so, and Try again starts again', (tester) async {
    final api = phone()..startError = StateError('no bridge');
    await openLive(tester, api);
    expect(cardTitle('The live video could not start'), findsOneWidget);
    expect(find.text('Try again. If it lasts, Diagnostics, in Advanced, says why.'), findsOneWidget);

    api.startError = null;
    await tester.tap(find.byKey(const Key('dji_live_retry')));
    await tester.pumpAndSettle();
    expect(api.starts, 2);
    expect(cardTitle('Plug in the remote'), findsOneWidget);
  });

  testWidgets('Send to a headset: one switch, one line, the code while on, the helps folded', (tester) async {
    final relay = FakeRelayEnvironment();
    final api = phone();
    final listener = await openLive(tester, api, relay: relay, size: _large);
    await tester.tap(find.byKey(const Key('dji_live_send')));
    await tester.pumpAndSettle();
    expect(find.text('Off. Turn it on to watch the drone\'s picture on a Meta Quest with Immuch360.'), findsOneWidget);
    expect(find.byKey(const Key('dji_live_send_code')), findsNothing);
    expect(find.textContaining('an observer standing next to you'), findsOneWidget);

    await tester.tap(find.byKey(const Key('dji_live_send_switch')));
    await tester.pumpAndSettle();
    expect(api.relayStarts, hasLength(1));
    expect(find.text('K7M2Q 9XRTH'), findsOneWidget);
    expect(find.text('On, but there is nothing to send yet: plug in the remote.'), findsOneWidget);
    // Announced: the addresses stay folded
    expect(find.text('192.168.1.23:8362'), findsNothing);
    await tester.tap(find.text('The headset does not list this phone?'));
    await tester.pumpAndSettle();
    expect(find.text('192.168.1.23:8362'), findsOneWidget);
    expect(find.text("192.168.43.1:8362 (this phone's hotspot)"), findsOneWidget);

    await push(tester, listener, fakeSnapshot(relaySending: fakeSending(sending: 'cable')));
    // The name the headset lists
    expect(
      find.text('On. On the headset, open Immuch360, Library, Drone, and pick Immuch360 on Galaxy S24+.'),
      findsOneWidget,
    );
    await push(
      tester,
      listener,
      fakeSnapshot(
        relaySending: fakeSending(
          sending: 'cable',
          headsets: [
            DjiRelayHeadsetRow(
              address: '192.168.1.40',
              name: 'Quest 3',
              connectedForMs: 75000,
              droppedUnits: 0,
              megabitsPerSecond: 5.6,
            ),
          ],
        ),
      ),
    );
    expect(find.text('Watching now: Quest 3'), findsOneWidget);
    expect(find.text('1 headset watching'), findsOneWidget);

    await tester.tap(find.byKey(const Key('dji_live_send_new_code')));
    await tester.pumpAndSettle();
    expect(api.relayCodes, ['ABCDEFGHJK']);
    expect(find.text('ABCDE FGHJK'), findsOneWidget);

    listener!.relayStopRequested();
    await tester.pumpAndSettle();
    expect(
      find.text('Sending stopped, from the notification or after 10 minutes with nothing to send.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('dji_live_send_code')), findsNothing);
  });

  testWidgets('a phone that could not announce itself opens the addresses by itself', (tester) async {
    final relay = FakeRelayEnvironment()..advertiseFails = true;
    await openLive(tester, phone(), relay: relay, size: _large);
    await tester.tap(find.byKey(const Key('dji_live_send')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('dji_live_send_switch')));
    await tester.pumpAndSettle();
    expect(find.text('192.168.1.23:8362'), findsOneWidget);
  });

  testWidgets('leaving while sending keeps sending and says so', (tester) async {
    final api = phone();
    await openLive(tester, api, size: _large);
    await tester.tap(find.byKey(const Key('dji_live_send')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('dji_live_send_switch')));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_live')), findsNothing);
    expect(find.text('Still sending to the headset. Stop it from the notification.'), findsOneWidget);
    expect(api.relayStops, 0);
  });

  testWidgets('Advanced: open on the plug, a capture for a bug report, and the values behind the gate', (tester) async {
    final api = phone(djiFly: true);
    final listener = await openLive(tester, api, size: _large);
    await push(tester, listener, live());
    await tester.tap(find.byKey(const Key('dji_live_advanced')));
    await tester.pumpAndSettle();

    final openOnPlug = find.byKey(const Key('dji_live_open_on_plug'));
    expect(tester.widget<SwitchListTile>(openOnPlug).value, isFalse);
    await tester.tap(openOnPlug);
    await tester.pumpAndSettle();
    expect(api.openOnPlugSets, [true]);
    expect(tester.widget<SwitchListTile>(openOnPlug).value, isTrue);

    await tester.tap(find.byKey(const Key('dji_live_save_capture')));
    await tester.pumpAndSettle();
    final notes = api.exports.single;
    expect([notes.cable, notes.port, notes.remoteState, notes.aircraftState, notes.note], everyElement(isNull));
    expect(find.text('Exported to Download/Immuch360/dji-link/dji-link-20261022-120000.bin'), findsOneWidget);
    expect(find.textContaining('Keep the files to yourself.'), findsOneWidget);

    expect(find.text('Heading (zero not checked against north)'), findsOneWidget);
    expect(find.text('127°'), findsOneWidget);
    expect(find.text('Drone battery voltage'), findsOneWidget);
    expect(find.text('6.18 V'), findsOneWidget);
    // The values our captures only make likely: under "Not confirmed yet", with a question mark
    await tester.scrollUntilVisible(
      find.byKey(const Key('dji_live_values_pending')),
      100,
      scrollable: find.descendant(
        of: find.byKey(const Key('dji_live_advanced_panel')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.byKey(const Key('dji_live_values_unconfirmed')), findsOneWidget);
    expect(find.text('Remote battery?'), findsOneWidget);
    expect(find.text('50 %'), findsOneWidget);
    expect(find.text('Height above the take off point?'), findsOneWidget);
    expect(find.text('-0.5 m'), findsOneWidget);
    expect(find.text('Vertical speed?'), findsOneWidget);
    expect(find.text('↓ 0.2 m/s'), findsOneWidget);
    expect(find.text('Signal bars?'), findsOneWidget);
    expect(find.text('Height, speeds and distance from home show once our flight captures prove them.'), findsOneWidget);
    expect(find.byKey(const Key('dji_live_no_dji_warnings')), findsOneWidget);
    expect(find.byKey(const Key('dji_live_diagnostics')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('dji_live_to_dji_fly')),
      100,
      scrollable: find.descendant(
        of: find.byKey(const Key('dji_live_advanced_panel')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.byKey(const Key('dji_live_to_dji_fly')), findsOneWidget);
  });

  testWidgets('the offer to open on the plug comes once, after a session that showed a picture', (tester) async {
    memory.values[StoreKey.djiLivePictureSeen] = true;
    final api = phone();
    await openLive(tester, api);
    expect(find.byKey(const Key('dji_live_offer')), findsOneWidget);
    expect(find.text('Open this screen when you plug in the remote?'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('dji_live_offer_yes')));
    await tester.tap(find.byKey(const Key('dji_live_offer_yes')));
    await tester.pumpAndSettle();
    expect(api.openOnPlugSets, [true]);
    expect(find.byKey(const Key('dji_live_offer')), findsNothing);
    expect(memory.values[StoreKey.djiLiveOfferAnswered], isTrue);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open_live')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_live_offer')), findsNothing);
  });

  testWidgets('"Not now" answers the offer for good, and the switch stays in Advanced', (tester) async {
    memory.values[StoreKey.djiLivePictureSeen] = true;
    final api = phone();
    await openLive(tester, api, size: _large);
    await tester.ensureVisible(find.byKey(const Key('dji_live_offer_no')));
    await tester.tap(find.byKey(const Key('dji_live_offer_no')));
    await tester.pumpAndSettle();
    expect(api.openOnPlugSets, isEmpty);
    expect(find.byKey(const Key('dji_live_offer')), findsNothing);
    expect(memory.values[StoreKey.djiLiveOfferAnswered], isTrue);
    await tester.tap(find.byKey(const Key('dji_live_advanced')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_live_open_on_plug')), findsOneWidget);
  });

  testWidgets('a capture being played shows its name and Stop playing', (tester) async {
    final api = phone();
    final listener = await openLive(tester, api);
    await push(
      tester,
      listener,
      fakeSnapshot(
        state: DjiLinkState.absent,
        decode: fakeDecode(),
        source: DjiLinkSource(replay: true, playing: true, name: 'dji-link-20261023-102731'),
      ),
    );
    expect(find.byKey(const Key('dji_live_placeholder')), findsOneWidget);
    expect(find.text('Capture: dji-link-20261023-102731'), findsOneWidget);
    // A capture is not live: no picture chip over its name
    expect(find.byKey(const Key('dji_live_picture_live')), findsNothing);
    expect(find.text('Live'), findsNothing);
    await tester.tap(find.byKey(const Key('dji_live_capture_stop')));
    await tester.pumpAndSettle();
    expect(api.playbackStops, 1);
  });

  testWidgets('a capture for a bug report: nothing written before a remote opened, one file for three taps', (
    tester,
  ) async {
    final api = phone();
    final listener = await openLive(tester, api, size: _large);
    await tester.tap(find.byKey(const Key('dji_live_advanced')));
    await tester.pumpAndSettle();

    // No remote in this session and none kept: nothing is written, and the toast says why
    await tester.tap(find.byKey(const Key('dji_live_save_capture')));
    await tester.pumpAndSettle();
    expect(api.exports, isEmpty);
    expect(find.text('Nothing to save yet: plug in the remote first.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // A session under way: three taps while the first export runs make one native call and one toast
    await push(tester, listener, live());
    final gate = Completer<void>();
    api.exportGate = gate;
    final notifier = ProviderScope.containerOf(
      tester.element(find.byKey(const Key('dji_live'))),
    ).read(djiLinkProvider.notifier);
    final outcomes = [notifier.exportForBugReport(), notifier.exportForBugReport(), notifier.exportForBugReport()];
    gate.complete();
    expect(await Future.wait(outcomes), [
      DjiLinkExportOutcome.saved,
      DjiLinkExportOutcome.busy,
      DjiLinkExportOutcome.busy,
    ]);
    expect(api.exports, hasLength(1));

    // Nothing new since: the native side answers repeated, and the toast names the file already saved
    api.exportGate = null;
    api.exportResult = DjiLinkExport(
      ok: true,
      bytes: 4096,
      binPath: 'Download/Immuch360/dji-link/dji-link-20261022-120000.bin',
      headerPath: 'Download/Immuch360/dji-link/dji-link-20261022-120000.json',
      repeated: true,
    );
    await tester.tap(find.byKey(const Key('dji_live_save_capture')));
    await tester.pumpAndSettle();
    expect(find.text('Already saved: dji-link-20261022-120000'), findsOneWidget);
  });

  testWidgets('a saved capture says where it went in a toast', (tester) async {
    final api = phone();
    final listener = await openLive(tester, api, size: _large);
    await push(tester, listener, live());
    await tester.tap(find.byKey(const Key('dji_live_advanced')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('dji_live_save_capture')));
    await tester.pumpAndSettle();
    expect(find.text('Saved in Download/Immuch360/dji-link: dji-link-20261022-120000'), findsOneWidget);

    api.exportResult = DjiLinkExport(ok: false, bytes: 0, error: 'No space left');
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('dji_live_save_capture')));
    await tester.pumpAndSettle();
    expect(find.text('The capture could not be saved. Diagnostics says why.'), findsOneWidget);
  });

  testWidgets('the drone battery under 20 % is amber with its icon, and says low', (tester) async {
    final semantics = tester.ensureSemantics();
    addTearDown(semantics.dispose);
    final listener = await openLive(tester, phone());
    await push(tester, listener, live(frame: fakeFrame(percent: 20)));
    expect(find.byKey(const Key('dji_live_battery_low')), findsNothing);
    await push(tester, listener, live(frame: fakeFrame(atMs: 1100, percent: 19)));
    expect(find.byKey(const Key('dji_live_battery_low')), findsOneWidget);
    final number = tester.widget<Text>(find.text('19 %'));
    expect(number.style?.color, const Color(0xFFFFB300));
    expect(find.bySemanticsLabel('Drone battery 19 % low'), findsOneWidget);
  });

  testWidgets('ten frames a second change the numbers in place: nothing beside them moves', (tester) async {
    final listener = await openLive(tester, phone());
    await push(tester, listener, live());
    final battery = tester.getRect(find.byKey(const Key('dji_live_cell_droneBattery')));
    final motorTime = tester.getRect(find.byKey(const Key('dji_live_cell_motorTime')));
    final picture = tester.getRect(find.byKey(const Key('dji_live_picture_area')));
    for (var index = 0; index < 20; index++) {
      listener!.flightChanged(fakeFrame(atMs: 2000 + index * 100, motorTimeS: 41.6 + index * 7, percent: 34 - index));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(djiMinutes(41.6 + index * 7)), findsOneWidget);
      expect(tester.getRect(find.byKey(const Key('dji_live_cell_droneBattery'))), battery);
      expect(tester.getRect(find.byKey(const Key('dji_live_cell_motorTime'))), motorTime);
      expect(tester.getRect(find.byKey(const Key('dji_live_picture_area'))), picture);
    }
    // A group that stops coming leaves its place empty: the motor time does not move up
    listener!.flightChanged(fakeFrame(atMs: 5000, percent: null));
    await tester.pump();
    expect(find.text('14 %'), findsNothing);
    expect(tester.getRect(find.byKey(const Key('dji_live_cell_motorTime'))), motorTime);
    // An older frame (a snapshot built before) is never drawn over a newer one
    listener.flightChanged(fakeFrame(atMs: 4000, percent: 77));
    await tester.pump();
    expect(find.text('77 %'), findsNothing);
  });

  testWidgets('the obstacle alert is a test the pilot turns on in Advanced, and says it only informs', (tester) async {
    final api = phone();
    final listener = await openLive(tester, api, size: _large);
    await push(tester, listener, live());
    expect(api.obstacleAlerts.last, (false, true));
    await tester.tap(find.byKey(const Key('dji_live_advanced')));
    await tester.pumpAndSettle();
    final scrollable = find.descendant(
      of: find.byKey(const Key('dji_live_advanced_panel')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(find.byKey(const Key('dji_live_obstacle_limits')), 100, scrollable: scrollable);
    expect(find.text('Obstacle alert, not confirmed yet'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('dji_live_obstacle_test'))).value, isFalse);
    expect(find.byKey(const Key('dji_live_obstacle_sound')), findsNothing);
    expect(find.byKey(const Key('dji_live_obstacle_info_only')), findsOneWidget);
    expect(find.textContaining('No alert does not mean the way is clear.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('dji_live_obstacle_test')));
    await tester.pumpAndSettle();
    expect(api.obstacleAlerts.last, (true, true));
    expect(memory.values[StoreKey.djiObstacleAlertOn], isTrue);
    await tester.scrollUntilVisible(
      find.byKey(const Key('dji_live_obstacle_sound_test')),
      100,
      scrollable: scrollable,
    );
    await tester.tap(find.byKey(const Key('dji_live_obstacle_sound_test')));
    await tester.pumpAndSettle();
    expect(api.obstacleTests, 1);
    expect(find.byKey(const Key('dji_live_media_volume_off')), findsNothing);

    api.volumeOff = true;
    await tester.tap(find.byKey(const Key('dji_live_obstacle_sound_test')));
    await tester.pumpAndSettle();
    expect(find.text('The media volume is off: the obstacle sound cannot be heard.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('dji_live_obstacle_sound')));
    await tester.pumpAndSettle();
    expect(api.obstacleAlerts.last, (true, false));
    expect(memory.values[StoreKey.djiObstacleSoundOff], isTrue);
  });

  testWidgets('the obstacle banner over the picture: the distance, not confirmed yet, and a tap goes through it', (
    tester,
  ) async {
    final listener = await openLive(tester, phone());
    await push(tester, listener, live(frame: fakeFrame(alert: fakeDecision(listening: true))));
    expect(find.byKey(const Key('dji_live_obstacle_banner')), findsNothing);
    // Listening: the top view of the drone, never a "clear" sign
    expect(find.byKey(const Key('dji_live_obstacle_glyph')), findsOneWidget);

    listener!.flightChanged(fakeFrame(atMs: 2000, alert: fakeDecision(on: true, distanceM: 1.84)));
    await tester.pump();
    expect(find.text('Obstacle close: 1.8 m'), findsOneWidget);
    expect(find.text('Not confirmed yet'), findsOneWidget);
    expect(find.byKey(const Key('dji_live_obstacle_glyph_on')), findsOneWidget);
    // No side known yet: no glow on any edge
    expect(find.byKey(const Key('dji_live_obstacle_glow_left')), findsNothing);
    // The banner takes no touch: a tap on it reaches nothing
    await tester.tap(find.byKey(const Key('dji_live_obstacle_banner')), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_live_leave_dialog')), findsNothing);

    // A side, once a capture names one: the glow on that edge and the side under the distance
    listener.flightChanged(
      fakeFrame(atMs: 3000, alert: fakeDecision(on: true, distanceM: 0.9, side: DjiObstacleSide.left)),
    );
    await tester.pump();
    expect(find.byKey(const Key('dji_live_obstacle_glow_left')), findsOneWidget);
    expect(find.text('On the left  Not confirmed yet'), findsOneWidget);

    // The data stopped while it was on
    listener.flightChanged(fakeFrame(atMs: 4000, alert: fakeDecision(stopped: true)));
    await tester.pump();
    expect(find.text('Obstacle data stopped: look at the drone.'), findsOneWidget);
    expect(find.byKey(const Key('dji_live_obstacle_glow_left')), findsNothing);
  });

  testWidgets('the obstacle banner shows over "No picture" too', (tester) async {
    final listener = await openLive(tester, phone());
    await push(tester, listener, live());
    await push(
      tester,
      listener,
      live(
        decode: fakeDecode(lastOutputAgoMs: 2500),
        frame: fakeFrame(atMs: 2000, alert: fakeDecision(on: true, distanceM: 2.5)),
      ),
    );
    expect(cardTitle('No picture'), findsOneWidget);
    expect(find.text('Obstacle close: 2.5 m'), findsOneWidget);
  });
}

/// The motor time as the cells write it
String djiMinutes(double seconds) {
  final whole = seconds.floor();
  return '${whole ~/ 60}:${(whole % 60).toString().padLeft(2, '0')}';
}
