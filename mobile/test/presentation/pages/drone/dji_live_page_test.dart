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
import 'package:immich_mobile/presentation/widgets/drone/dji_live_transient.dart';
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
  final numbers = <StoreKey<int>, int>{};

  DjiLiveMemory build() => DjiLiveMemory(
    read: (key) => values[key] ?? false,
    write: (key, value) async => values[key] = value,
    readInt: (key) => numbers[key],
    writeInt: (key, value) async => numbers[key] = value,
  );
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

  List<Override> liveOverrides(
    FakeDjiLinkApi api,
    void Function(DjiLinkEvents?) onEvents, {
    FakeRelayEnvironment? relay,
    bool noticeRead = true,
  }) => [
    djiLinkApiProvider.overrideWithValue(api),
    djiLinkEventsSetUpProvider.overrideWithValue(onEvents),
    djiRelayEnvironmentProvider.overrideWithValue((relay ?? FakeRelayEnvironment()).build()),
    djiLiveNoticeReadProvider.overrideWith((ref) => noticeRead),
    djiLiveMemoryProvider.overrideWithValue(memory.build()),
    // No platform view under flutter test: a placeholder stands where the picture is
    djiLinkVideoViewBuilderProvider.overrideWithValue(
      () => const ColoredBox(key: Key('dji_live_placeholder'), color: Colors.black),
    ),
  ];

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
      overrides: liveOverrides(api, (events) => listener = events, relay: relay, noticeRead: noticeRead),
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

  testWidgets(
    'Back on the safety notice with another page over the live screen leaves the live screen, not that page',
    (tester) async {
      await tester.binding.setSurfaceSize(_large);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      late NavigatorState navigator;
      await tester.pumpTestWidget(
        context,
        Builder(
          builder: (context) {
            navigator = Navigator.of(context);
            return const Text('first page');
          },
        ),
        overrides: liveOverrides(phone(), (_) {}, noticeRead: false),
      );
      // The live screen, and in the same instant another page over it; the notice comes over both
      navigator.push(MaterialPageRoute<void>(builder: (_) => const DjiLivePage())).ignore();
      navigator
          .push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('page over the live screen'))))
          .ignore();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dji_live_notice')), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('dji_live_notice')), findsNothing);
      expect(find.byKey(const Key('dji_live'), skipOffstage: false), findsNothing, reason: 'the live screen left');
      expect(find.text('page over the live screen'), findsOneWidget, reason: 'a pop closed this one instead');
    },
  );

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
    // Behind the gate: the remote's battery, the signal and the heading are not over the picture; the drone is on the
    // ground, where the native side gives no height and no speed (in the air only), so the left band is empty
    expect(find.text('50 %'), findsNothing);
    expect(find.text('90'), findsNothing);
    expect(find.textContaining('127'), findsNothing);
    expect(find.textContaining('Height'), findsNothing);
    expect(find.textContaining('Below'), findsNothing);
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

  testWidgets('the warnings over the picture come for five seconds and fade; a tap brings them back', (tester) async {
    final listener = await openLive(tester, phone());
    await push(tester, listener, live());
    final chip = find.byKey(const Key('dji_live_picture_live'));
    expect(chip, findsOneWidget);
    await tester.pump(djiTransientHold);
    await tester.pumpAndSettle();
    // The state of the picture goes; the values stay
    expect(chip, findsNothing);
    expect(find.text('34 %'), findsOneWidget);
    expect(find.text('0:41'), findsOneWidget);
    // A tap on the picture brings it back, and reaches nothing else
    await tester.tapAt(tester.getCenter(find.byKey(const Key('dji_live_picture_area'))));
    await tester.pumpAndSettle();
    expect(chip, findsOneWidget);
    expect(find.byKey(const Key('dji_live_leave_dialog')), findsNothing);
    // A new state shows by itself
    await tester.pump(djiTransientHold);
    await tester.pumpAndSettle();
    await push(tester, listener, live(decode: fakeDecode(picturesPerSecond: 12)));
    expect(find.text('Weak picture'), findsOneWidget);

    // The picture lost in flight: "Look at the drone and fly with the remote" for five seconds; the title and what
    // to do stay until the picture comes back
    await push(tester, listener, fakeSnapshot(state: DjiLinkState.linkLost, reason: DjiLinkReason.readsFailed));
    final advice = find.text('Look at the drone and fly with the remote.');
    expect(advice, findsOneWidget);
    await tester.pump(djiTransientHold);
    await tester.pumpAndSettle();
    expect(advice, findsNothing);
    expect(cardTitle('This phone lost the cable link'), findsOneWidget);
    expect(
      find.text('This phone tries again. Once landed, if it lasts, unplug the remote and plug it in again.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('dji_live_retry')), findsOneWidget);
    await tester.tapAt(tester.getCenter(find.byKey(const Key('dji_live_card_title'))));
    await tester.pumpAndSettle();
    expect(advice, findsOneWidget);
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
    await tester.tap(find.text('The headset or the TV does not list this phone?'));
    await tester.pumpAndSettle();
    expect(find.text('192.168.1.23:8362'), findsOneWidget);
    expect(find.text("192.168.43.1:8362 (this phone's hotspot)"), findsOneWidget);

    await push(tester, listener, fakeSnapshot(relaySending: fakeSending(sending: 'cable')));
    // The name the headset lists
    expect(
      find.text('On. On the headset or the TV, open Immuch360, Library, Drone, and pick Immuch360 on Galaxy S24+.'),
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
    expect(find.text('1 screen watching'), findsOneWidget);

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
    // In the air, 1.2 m above the take off point, climbing at 0.4 m/s, 1.53 m above the floor
    final flying = fakeFrame(
      motorsOn: true,
      heightM: 1.2,
      verticalSpeedMps: 0.4,
      speedMps: 0.8,
      distanceBelowM: 1.53,
      obstacleM: 1.84,
    );
    await push(tester, listener, live(frame: flying));
    await tester.tap(find.byKey(const Key('dji_live_advanced')));
    await tester.pumpAndSettle();

    // On by default, as every experimental switch; turned off here, the plug step never asks again
    final openOnPlug = find.byKey(const Key('dji_live_open_on_plug'));
    expect(tester.widget<SwitchListTile>(openOnPlug).value, isTrue);
    expect(
      find.text('On by default. If DJI Fly is on this phone too, Android asks each time which app opens the remote.'),
      findsOneWidget,
    );
    await tester.tap(openOnPlug);
    await tester.pumpAndSettle();
    expect(api.openOnPlugSets, [false]);
    expect(tester.widget<SwitchListTile>(openOnPlug).value, isFalse);
    expect(memory.values[StoreKey.djiLiveOfferAnswered], isTrue);
    await tester.tap(openOnPlug);
    await tester.pumpAndSettle();
    expect(api.openOnPlugSets, [false, true]);

    await tester.tap(find.byKey(const Key('dji_live_save_capture')));
    await tester.pumpAndSettle();
    final notes = api.exports.single;
    expect([notes.cable, notes.port, notes.remoteState, notes.aircraftState, notes.note], everyElement(isNull));
    expect(find.text('Exported to Download/Immuch360/dji-link/dji-link-20261022-120000.bin'), findsOneWidget);
    expect(find.textContaining('Keep the files to yourself.'), findsOneWidget);

    expect(find.byKey(const Key('dji_live_no_dji_warnings')), findsOneWidget);
    expect(find.byKey(const Key('dji_live_diagnostics')), findsOneWidget);
    expect(find.text('Heading (zero not checked against north)'), findsOneWidget);
    expect(find.text('127°'), findsOneWidget);
    final panel = find.descendant(
      of: find.byKey(const Key('dji_live_advanced_panel')),
      matching: find.byType(Scrollable),
    );
    // Proven by the flights of 25 October: with the proven values, with their full labels and no question mark
    for (final (field, label, value) in [
      ('height', 'Height above the take off point', '1.2 m'),
      ('verticalSpeed', 'Vertical speed', '↑ 0.4 m/s'),
      ('speed', 'Speed over the ground', '0.8 m/s'),
      ('distanceBelow', 'Distance below', '1.53 m'),
      ('obstacle', 'Nearest obstacle', '1.8 m'),
    ]) {
      final row = find.byKey(Key('dji_live_advanced_value_$field'));
      await tester.scrollUntilVisible(row, 100, scrollable: panel);
      expect(find.descendant(of: row, matching: find.text(label)), findsOneWidget, reason: field);
      expect(find.descendant(of: row, matching: find.text(value)), findsOneWidget, reason: field);
    }
    await tester.scrollUntilVisible(find.text('Drone battery voltage'), 100, scrollable: panel);
    expect(find.text('6.18 V'), findsOneWidget);
    // The values our captures only make likely: under "Not confirmed yet", with a question mark
    await tester.scrollUntilVisible(find.byKey(const Key('dji_live_values_pending')), 100, scrollable: panel);
    expect(find.byKey(const Key('dji_live_values_unconfirmed')), findsOneWidget);
    expect(find.text('Remote battery?'), findsOneWidget);
    expect(find.text('50 %'), findsOneWidget);
    expect(find.text('Signal bars?'), findsOneWidget);
    expect(find.text('Height above the take off point?'), findsNothing);
    expect(find.text('Vertical speed?'), findsNothing);
    expect(find.text('Distance below?'), findsNothing);
    expect(find.text('Nearest obstacle?'), findsNothing);
    expect(find.text('The distance from home shows once an outdoor flight proves it.'), findsOneWidget);
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

  testWidgets('on by default, the plug step offers nothing', (tester) async {
    memory.values[StoreKey.djiLivePictureSeen] = true;
    await openLive(tester, phone());
    expect(find.byKey(const Key('dji_live_card_plug')), findsOneWidget);
    expect(find.byKey(const Key('dji_live_offer')), findsNothing);
  });

  testWidgets('before the native side answers, the plug step offers nothing: open on the plug is on by default', (
    tester,
  ) async {
    memory.values[StoreKey.djiLivePictureSeen] = true;
    final api = phone()..openOnPlugAnswer = Completer<bool>();
    await openLive(tester, api);
    expect(find.byKey(const Key('dji_live_card_plug')), findsOneWidget);
    expect(find.byKey(const Key('dji_live_offer')), findsNothing);
    // An earlier build's off, read late: only then the offer
    api.openOnPlugAnswer!.complete(false);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_live_offer')), findsOneWidget);
  });

  testWidgets('turned off by an earlier build, the offer to open on the plug comes once after a picture', (
    tester,
  ) async {
    memory.values[StoreKey.djiLivePictureSeen] = true;
    final api = phone()..openOnPlugValue = false;
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
    final api = phone()..openOnPlugValue = false;
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
    final listener = await openLive(tester, phone());
    await push(tester, listener, live(frame: fakeFrame(percent: 20)));
    expect(find.byKey(const Key('dji_live_battery_low')), findsNothing);
    await push(tester, listener, live(frame: fakeFrame(atMs: 1100, percent: 19)));
    expect(find.byKey(const Key('dji_live_battery_low')), findsOneWidget);
    final number = tester.widget<Text>(find.text('19 %'));
    expect(number.style?.color, const Color(0xFFFFB300));
    expect(find.bySemanticsLabel('Drone battery 19 % low'), findsOneWidget);
    semantics.dispose();
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

  testWidgets('the obstacle ring is on by default, turned off in Advanced, with its distances, side and sound', (
    tester,
  ) async {
    final api = phone();
    final listener = await openLive(tester, api, size: _large);
    await push(tester, listener, live());
    // Every experimental switch on by default (FreeKC's rule of 25 October), the side too since the flights of 25
    // October proved which side is the front
    expect(api.obstacleRings.last.offered, isTrue);
    expect(api.obstacleRings.last.sound, isTrue);
    expect(api.obstacleRings.last.haptic, isTrue);
    expect(api.obstacleRings.last.numbers, isTrue);
    expect(api.obstacleRings.last.frame, isFalse);
    expect(api.obstacleRings.last.directional, isTrue);
    await tester.tap(find.byKey(const Key('dji_live_advanced')));
    await tester.pumpAndSettle();
    final scrollable = find.descendant(
      of: find.byKey(const Key('dji_live_advanced_panel')),
      matching: find.byType(Scrollable),
    );
    Future<void> tap(String key) async {
      await tester.scrollUntilVisible(find.byKey(Key(key)), 100, scrollable: scrollable);
      // A lazy list builds a little past its end: in the tree is not yet on the screen
      await tester.ensureVisible(find.byKey(Key(key)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
    }

    String value(String name) => tester.widget<Text>(find.byKey(Key('dji_live_obstacle_${name}_value'))).data!;
    bool enabled(String key) => tester.widget<IconButton>(find.byKey(Key(key))).onPressed != null;

    await tester.scrollUntilVisible(find.byKey(const Key('dji_live_obstacle_on')), 100, scrollable: scrollable);
    expect(find.text('Obstacle ring'), findsOneWidget);
    // Proven: the plain switch, no "not confirmed yet"
    expect(find.text('Show the obstacle ring'), findsOneWidget);
    expect(find.byKey(const Key('dji_live_obstacle_test')), findsNothing);
    expect(find.text('Obstacle ring, not confirmed yet'), findsNothing);
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('dji_live_obstacle_on'))).value, isTrue);
    expect(
      find.text("On by default. A soft glow over the picture when the drone's sensors see something close."),
      findsOneWidget,
    );

    // Off: nothing of the ring but the switch, the sample and the two lines
    await tap('dji_live_obstacle_on');
    expect(api.obstacleRings.last.offered, isFalse);
    expect(memory.values[StoreKey.djiObstacleRingOff], isTrue);
    await tester.scrollUntilVisible(find.byKey(const Key('dji_live_obstacle_limits')), 100, scrollable: scrollable);
    expect(find.byKey(const Key('dji_live_obstacle_sound')), findsNothing);
    expect(find.byKey(const Key('dji_live_obstacle_far')), findsNothing);
    expect(find.byKey(const Key('dji_live_obstacle_sample')), findsOneWidget);
    expect(find.byKey(const Key('dji_live_obstacle_info_only')), findsOneWidget);
    expect(find.textContaining('No glow does not mean the way is clear.'), findsOneWidget);

    await tap('dji_live_obstacle_on');
    expect(api.obstacleRings.last.offered, isTrue);
    expect(memory.values[StoreKey.djiObstacleRingOff], isFalse);
    // FreeKC's distances: a glow from 3.0 m, strong from 1.0 m
    expect(value('far'), '3.0 m');
    expect(value('near'), '1.0 m');
    expect(api.obstacleRings.last.farM, 3.0);
    expect(api.obstacleRings.last.nearM, 1.0);
    expect(
      find.text('Indoors the walls are close, so it may glow the whole flight: try 1.0 m, or turn the ring off.'),
      findsOneWidget,
    );

    // "Glow from" down to 1.5 m: "Strong glow from" stays 0.5 m under it
    await tap('dji_live_obstacle_far_less');
    expect(value('far'), '2.5 m');
    expect(memory.numbers[StoreKey.djiObstacleFarCm], 250);
    await tap('dji_live_obstacle_far_less');
    await tap('dji_live_obstacle_far_less');
    expect(value('far'), '1.5 m');
    expect(value('near'), '1.0 m');
    expect(enabled('dji_live_obstacle_near_more'), isFalse);
    // Down to its end for a room, 1.0 m: "Strong glow from" follows it down to 0.5 m, then goes down to 0.25 m
    await tap('dji_live_obstacle_far_less');
    expect(value('far'), '1.0 m');
    expect(enabled('dji_live_obstacle_far_less'), isFalse);
    expect(value('near'), '0.5 m');
    expect(memory.numbers[StoreKey.djiObstacleNearCm], 50);
    await tap('dji_live_obstacle_near_less');
    expect(value('near'), '0.25 m');
    expect(enabled('dji_live_obstacle_near_less'), isFalse);
    expect(memory.numbers[StoreKey.djiObstacleNearCm], 25);
    expect(api.obstacleRings.last.farM, 1.0);
    expect(api.obstacleRings.last.nearM, 0.25);
    // "Glow from" up again: "Strong glow from" may rise up to 0.5 m under it
    await tap('dji_live_obstacle_far_more');
    expect(value('far'), '1.5 m');
    expect(enabled('dji_live_obstacle_near_more'), isTrue);

    // The side, proven: shown by default, its switch turns it off and on again
    expect(find.byKey(const Key('dji_live_obstacle_side_test')), findsNothing);
    expect(find.text('Show the side, not confirmed yet'), findsNothing);
    expect(find.text('Show the side'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('dji_live_obstacle_side'))).value, isTrue);
    expect(find.text('On by default. Off: the glow goes evenly all around.'), findsOneWidget);
    await tap('dji_live_obstacle_side');
    expect(api.obstacleRings.last.directional, isFalse);
    expect(memory.values[StoreKey.djiObstacleSideOff], isTrue);
    await tap('dji_live_obstacle_side');
    expect(api.obstacleRings.last.directional, isTrue);
    expect(memory.values[StoreKey.djiObstacleSideOff], isFalse);

    await tap('dji_live_obstacle_sound_test');
    expect(api.obstacleTests, 1);
    expect(find.byKey(const Key('dji_live_media_volume_off')), findsNothing);
    api.volumeOff = true;
    await tap('dji_live_obstacle_sound_test');
    expect(find.text('The media volume is off: the obstacle sound cannot be heard.'), findsOneWidget);
    expect(find.textContaining('On by default. A short tick when the drone gets close'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('dji_live_obstacle_sound'))).value, isTrue);
    await tap('dji_live_obstacle_sound');
    expect(api.obstacleRings.last.sound, isFalse);
    expect(memory.values[StoreKey.djiObstacleSoundOff], isTrue);

    // A phone with a vibrator offers the tap, on by default; the number by the glow, on by default
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('dji_live_obstacle_haptic'))).value, isTrue);
    await tap('dji_live_obstacle_haptic');
    expect(api.obstacleRings.last.haptic, isFalse);
    expect(memory.values[StoreKey.djiObstacleHapticOff], isTrue);
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('dji_live_obstacle_numbers'))).value, isTrue);
    await tap('dji_live_obstacle_numbers');
    expect(api.obstacleRings.last.numbers, isFalse);
    expect(memory.values[StoreKey.djiObstacleNumbersOff], isTrue);

    // The shape: a circle around the centre by default, the frame at the edges as a choice
    await tester.scrollUntilVisible(find.byKey(const Key('dji_live_obstacle_shape')), 100, scrollable: scrollable);
    expect(find.text('Obstacle indicator shape'), findsOneWidget);
    expect(find.text('A circle by default. The frame leaves the middle of the picture clear.'), findsOneWidget);
    SegmentedButton<bool> shape() => tester.widget<SegmentedButton<bool>>(
      find.descendant(
        of: find.byKey(const Key('dji_live_obstacle_shape')),
        matching: find.byType(SegmentedButton<bool>),
      ),
    );
    expect(shape().selected, {false});
    await tap('dji_live_obstacle_shape_frame');
    expect(shape().selected, {true});
    expect(api.obstacleRings.last.frame, isTrue);
    expect(memory.values[StoreKey.djiObstacleShapeFrame], isTrue);
    await tap('dji_live_obstacle_shape_circle');
    expect(api.obstacleRings.last.frame, isFalse);
    expect(memory.values[StoreKey.djiObstacleShapeFrame], isFalse);

    // The sample on the ground; refused while the motors run
    await tap('dji_live_obstacle_sample');
    expect(api.obstacleSamples, 1);
    expect(find.text('Eight seconds of a made up obstacle, on this screen only.'), findsOneWidget);
    api.sampleRefused = true;
    await tap('dji_live_obstacle_sample');
    expect(find.text('Not while the motors run.'), findsOneWidget);
  });

  testWidgets('the sample is off while the motors run, and a phone without a vibrator has no vibration item', (
    tester,
  ) async {
    final api = phone()..vibrator = false;
    final listener = await openLive(tester, api, size: _large);
    await push(tester, listener, live(frame: fakeFrame(motorsOn: true)));
    await tester.tap(find.byKey(const Key('dji_live_advanced')));
    await tester.pumpAndSettle();
    final scrollable = find.descendant(
      of: find.byKey(const Key('dji_live_advanced_panel')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(find.byKey(const Key('dji_live_obstacle_limits')), 100, scrollable: scrollable);
    expect(find.byKey(const Key('dji_live_obstacle_haptic')), findsNothing);
    expect(find.byKey(const Key('dji_live_obstacle_numbers')), findsOneWidget);
    expect(tester.widget<ButtonStyleButton>(find.byKey(const Key('dji_live_obstacle_sample'))).onPressed, isNull);
    expect(find.text('Not while the motors run.'), findsOneWidget);
  });

  testWidgets('nothing over the picture until something is close, then a glow at its edge that takes no touch', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final listener = await openLive(tester, phone());
    await push(tester, listener, live(frame: fakeFrame(alert: fakeDecision(listening: true))));
    // Listening is not an alert, and none of the old block is left: no banner, no glyph, no ring
    expect(find.byKey(const Key('dji_live_obstacle_ring')), findsNothing);
    expect(find.byKey(const Key('dji_live_obstacle_banner')), findsNothing);
    expect(find.byKey(const Key('dji_live_obstacle_glyph')), findsNothing);
    expect(find.textContaining('Obstacle'), findsNothing);

    listener!.flightChanged(fakeFrame(atMs: 2000, alert: fakeDecision(on: true, arcs: [fakeArc(1.84)])));
    await tester.pump();
    final ring = find.byKey(const Key('dji_live_obstacle_ring'));
    expect(ring, findsOneWidget);
    FadeTransition fade() =>
        tester.widget<FadeTransition>(find.descendant(of: ring, matching: find.byType(FadeTransition)));
    expect(fade().opacity.value, lessThan(1));
    await tester.pump(const Duration(milliseconds: 150));
    expect(fade().opacity.value, 1);
    // Over the picture's box, never over the side bands
    expect(tester.getRect(ring), tester.getRect(find.byKey(const Key('dji_live_picture_area'))));
    expect(find.bySemanticsLabel('Obstacle within 1.8 m'), findsOneWidget);
    // A circle around the centre by default, with its number
    expect(find.byKey(const Key('dji_live_obstacle_circle')), findsOneWidget);
    expect(find.byKey(const Key('dji_live_obstacle_frame')), findsNothing);
    expect(find.byKey(const Key('dji_live_obstacle_distance')), findsOneWidget);
    // The ring takes no touch: a tap on it reaches nothing
    await tester.tap(ring, warnIfMissed: false);
    await tester.pump();
    expect(find.byKey(const Key('dji_live_leave_dialog')), findsNothing);

    // The side, once shown: the screen reader names it
    listener.flightChanged(
      fakeFrame(atMs: 3000, alert: fakeDecision(on: true, arcs: [fakeArc(0.9, centreDeg: -90)])),
    );
    await tester.pump();
    expect(find.bySemanticsLabel('Obstacle within 0.9 m. On the left'), findsOneWidget);

    // The data stopped while it showed: the last arcs, white, and no words over the picture
    listener.flightChanged(
      fakeFrame(atMs: 4000, alert: fakeDecision(stopped: true, arcs: [fakeArc(0.9, centreDeg: -90)])),
    );
    await tester.pump();
    expect(ring, findsOneWidget);
    expect(find.bySemanticsLabel('Obstacle data stopped: look at the drone.'), findsOneWidget);
    expect(find.text('Obstacle data stopped: look at the drone.'), findsNothing);

    // Nothing close any more: it fades out over 400 ms, then nothing is left
    listener.flightChanged(fakeFrame(atMs: 5000, alert: fakeDecision(listening: true)));
    await tester.pump();
    expect(ring, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
    expect(ring, findsOneWidget);
    // An animation ends just past its duration
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(ring, findsNothing);
    semantics.dispose();
  });

  testWidgets('the distance by the glow, on by default, outside the circle where the arc is', (tester) async {
    final listener = await openLive(tester, phone());
    await push(
      tester,
      listener,
      live(frame: fakeFrame(alert: fakeDecision(on: true, arcs: [fakeArc(1.44, centreDeg: 30)]))),
    );
    expect(find.text('1.4 m'), findsOneWidget);
    // Inside the picture, up and to the right of the centre, past the circle, where the arc is
    final number = tester.getCenter(find.text('1.4 m'));
    final picture = tester.getRect(find.byKey(const Key('dji_live_picture_area')));
    expect(picture.contains(number), isTrue);
    expect(number.dx, greaterThan(picture.center.dx));
    expect(number.dy, lessThan(picture.center.dy));
    expect((number - picture.center).distance, greaterThan(picture.height / 4));
  });

  testWidgets('the distance by the glow, turned off in Advanced, leaves the circle alone', (tester) async {
    memory.values[StoreKey.djiObstacleNumbersOff] = true;
    final listener = await openLive(tester, phone());
    await push(
      tester,
      listener,
      live(frame: fakeFrame(alert: fakeDecision(on: true, arcs: [fakeArc(1.44, centreDeg: 30)]))),
    );
    expect(find.byKey(const Key('dji_live_obstacle_circle')), findsOneWidget);
    expect(find.text('1.4 m'), findsNothing);
  });

  testWidgets('the ring shows over "No picture" too', (tester) async {
    final listener = await openLive(tester, phone());
    await push(tester, listener, live());
    await push(
      tester,
      listener,
      live(
        decode: fakeDecode(lastOutputAgoMs: 2500),
        frame: fakeFrame(atMs: 2000, alert: fakeDecision(on: true, arcs: [fakeArc(2.5)])),
      ),
    );
    expect(cardTitle('No picture'), findsOneWidget);
    expect(find.byKey(const Key('dji_live_obstacle_ring')), findsOneWidget);
  });
}

/// The motor time as the cells write it
String djiMinutes(double seconds) {
  final whole = seconds.floor();
  return '${whole ~/ 60}:${(whole % 60).toString().padLeft(2, '0')}';
}
