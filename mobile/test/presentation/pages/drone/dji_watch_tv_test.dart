// The watch page of the DJI live video on Android TV (p2/design-tv-2026-10-24.md, sections 2 to 5 and 8.1): the
// phones view with the focus on a phone row, this TV's own code with its QR code and its tries every 10 s, the full
// screen view at the first picture with the values on plates, the strip that never hides and the obstacle ring, the
// keys of the remote, Options, Back, the app going to the background, the screen saver after 10 minutes without a
// picture, and the one platform view that moves between the two views. Since the review of 24 October
// (p2/review-tv-2026-10-24.md): a refusal in full screen, the notice and Options read by the arrows alone, a held OK,
// a new code while watching, Stop watching then Home, two phones that refuse, and a TV out of the TV layout. Nothing
// ran on a TV: these are widget tests.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/platform/tv_api.g.dart';
import 'package:immich_mobile/presentation/pages/drone/dji_link.page.dart';
import 'package:immich_mobile/presentation/pages/drone/dji_watch.page.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_receive.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_video.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_notice.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_transient.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_watch_tv.widget.dart';
import 'package:immich_mobile/presentation/widgets/pairing/qr_code.widget.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';
import 'package:immich_mobile/providers/drone/dji_relay.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';

import '../../../unit/presentation/presentation_context.dart';
import 'dji_link_fakes.dart';

/// A 1080p TV: 960 by 540 dp
const _tv = Size(960, 540);

const _phoneId = '3f9c0a1b2c3d4e5f';

/// The first code the fake device makes: this TV's own code
const _ownCode = 'K7M2Q9XRTH';

/// The native text dialog of the TV: each request kept, the answers given in order, then Cancel
class _FakeTvApi extends Fake implements TvApi {
  final requests = <TvTextRequest>[];
  final answers = <String?>[];

  @override
  Future<String?> editText(TvTextRequest request) async {
    requests.add(request);
    return answers.isEmpty ? null : answers.removeAt(0);
  }
}

/// The picture of the test: counts how many times it was made, which a new platform view would do
class _CountedPicture extends StatefulWidget {
  const _CountedPicture(this.made);

  final List<int> made;

  @override
  State<_CountedPicture> createState() => _CountedPictureState();
}

class _CountedPictureState extends State<_CountedPicture> {
  @override
  void initState() {
    super.initState();
    widget.made.add(1);
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(key: Key('dji_watch_placeholder'), color: Colors.black);
}

void main() {
  late PresentationContext context;
  late Map<StoreKey<bool>, bool> memory;
  late _FakeTvApi tvApi;
  late List<int> pictureMade;

  setUp(() async {
    context = await PresentationContext.create();
    memory = {};
    tvApi = _FakeTvApi();
    pictureMade = [];
  });

  tearDown(() async {
    await context.dispose();
  });

  FakeDjiLinkApi television() => FakeDjiLinkApi(
    environment: fakeEnvironment(accessoryFeature: false, flavour: 'phone'),
    snapshot: fakeSnapshot(state: DjiLinkState.unsupportedTransport),
  );

  Future<DjiLinkEvents?> openOnTv(
    WidgetTester tester,
    FakeDjiLinkApi api, {
    FakeRelayEnvironment? relay,
    bool noticeRead = true,
    bool tvMode = true,
  }) async {
    DjiLinkEvents? listener;
    await tester.binding.setSurfaceSize(_tv);
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
        tvModeProvider.overrideWithValue(tvMode),
        tvDeviceProvider.overrideWithValue(TvDeviceInfo(isTelevision: true, isLowRamDevice: false)),
        tvApiProvider.overrideWithValue(tvApi),
        djiLinkApiProvider.overrideWithValue(api),
        djiLinkEventsSetUpProvider.overrideWithValue((events) => listener = events),
        djiRelayEnvironmentProvider.overrideWithValue((relay ?? FakeRelayEnvironment()).build()),
        djiLiveNoticeReadProvider.overrideWith((ref) => noticeRead),
        djiLiveMemoryProvider.overrideWithValue(
          DjiLiveMemory(read: (key) => memory[key] ?? false, write: (key, value) async => memory[key] = value),
        ),
        isHorizonOsProvider.overrideWith((ref) async => false),
        djiLinkVideoViewBuilderProvider.overrideWithValue(() => _CountedPicture(pictureMade)),
      ],
    );
    await tester.tap(find.byKey(const Key('open_watch')));
    await tester.pump();
    await tester.pumpAndSettle();
    return listener;
  }

  Future<void> announce(WidgetTester tester, FakeRelayEnvironment relay, String host) async {
    relay.browsed.add(fakeAnnounced(host, fakeDroneTxt));
    await tester.pumpAndSettle();
  }

  Finder phoneRow(String host) => find.byKey(ValueKey('dji_watch_phone_$host:8362'));

  Future<void> push(WidgetTester tester, DjiLinkEvents? listener, DjiLinkSnapshot snapshot) async {
    listener!.snapshotChanged(snapshot);
    await tester.pumpAndSettle();
  }

  DjiLinkSnapshot picture({DjiLiveFrame? frame, String source = 'cable'}) => fakeSnapshot(
    decode: fakeDecode(),
    relayReceiving: fakeReceiving(phoneSource: source),
    telemetryValues: fakeTelemetry(percent: 34, motorTimeS: 41.6),
    liveFrame: frame ?? fakeFrame(),
  );

  DjiLinkSnapshot refused() => fakeSnapshot(relayReceiving: fakeReceiving(state: DjiRelayReceiveState.wrongCode));

  /// Whether the focus of the remote is on [finder] or inside it
  bool focused(WidgetTester tester, Finder finder) {
    final node = FocusManager.instance.primaryFocus;
    final focus = node?.context;
    if (focus == null) {
      return false;
    }
    final target = tester.element(finder);
    if (identical(focus, target)) {
      return true;
    }
    var inside = false;
    focus.visitAncestorElements((ancestor) {
      inside = identical(ancestor, target);
      return !inside;
    });
    return inside;
  }

  /// Scrolls Options until the item of [key] shows: the panel builds its list as it scrolls
  Future<void> showInOptions(WidgetTester tester, Key key) async {
    await tester.scrollUntilVisible(
      find.byKey(key),
      100,
      scrollable: find
          .descendant(of: find.byKey(const Key('dji_watch_tv_options_panel')), matching: find.byType(Scrollable))
          .first,
    );
    await tester.pumpAndSettle();
  }

  /// Opens the page with a phone that knows this TV: announced, its code tried at once, the first picture
  Future<(FakeDjiLinkApi, FakeRelayEnvironment, DjiLinkEvents?)> watching(WidgetTester tester) async {
    final relay = FakeRelayEnvironment();
    final api = television();
    final listener = await openOnTv(tester, api, relay: relay);
    await announce(tester, relay, '192.168.1.21');
    await push(tester, listener, picture());
    return (api, relay, listener);
  }

  testWidgets('the phones view: a row per sending phone with the focus on it, and this TV\'s code with its QR code', (
    tester,
  ) async {
    final relay = FakeRelayEnvironment();
    final api = television();
    await openOnTv(tester, api, relay: relay);
    // No phone yet: what to do, in one sentence
    expect(find.byKey(const Key('dji_watch_none')), findsOneWidget);
    expect(find.textContaining('turn on Send. The phone and this TV must be on the same Wi-Fi.'), findsOneWidget);
    // The rules worded for a TV, on top
    expect(
      find.text(
        'Flying while you watch this TV: in the EU open category, an observer next to you must keep the drone in '
        'sight and warn you. Without one, watch the drone, not the TV.',
      ),
      findsOneWidget,
    );
    expect(find.text('Watching only: nothing on this TV reaches the drone.'), findsOneWidget);
    // Made once, kept on this TV only
    expect(relay.secrets[djiWatchOwnCodeKey], _ownCode);

    expect(focused(tester, find.byKey(const Key('dji_watch_address'))), isTrue);
    await announce(tester, relay, '192.168.1.21');
    expect(phoneRow('192.168.1.21'), findsOneWidget);
    // The first phone listed takes the focus from "Phone not listed?"
    expect(focused(tester, phoneRow('192.168.1.21')), isTrue);
    final card = find.byKey(const Key('dji_watch_tv_code_card'));
    expect(card, findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('K7M2Q 9XRTH')), findsOneWidget);
    expect(find.descendant(of: card, matching: find.text('Let this TV watch')), findsOneWidget);
    expect(
      find.descendant(
        of: card,
        matching: find.text('On the phone, in DJI live video, open Send, then Add a TV, and scan this code.'),
      ),
      findsOneWidget,
    );
    expect(tester.widget<QrCodeView>(find.byType(QrCodeView)).data, 'IMMUCH360-WATCH:1:$_ownCode');
    // The two groups on one line beside the QR code, whatever the font
    expect(
      tester.getRect(find.byKey(const Key('dji_watch_tv_own_code'))).right,
      lessThanOrEqualTo(tester.getRect(find.byKey(const Key('dji_watch_tv_qr'))).left),
    );
    // The TV tried its own code at once: the pilot may have added it already
    expect(api.connects.first, ('192.168.1.21', 8362, _ownCode, _phoneId, 'Galaxy S24+'));
    // Never a typed code first
    expect(tvApi.requests, isEmpty);
  });

  testWidgets('a phone that does not know this TV yet: the card says so, a try every 10 s, 30 at most, then it stops', (
    tester,
  ) async {
    final relay = FakeRelayEnvironment();
    final api = television();
    final listener = await openOnTv(tester, api, relay: relay);
    await announce(tester, relay, '192.168.1.21');
    expect(api.connects, hasLength(1));
    await push(tester, listener, refused());
    expect(find.text('Immuch360 on Galaxy S24+ does not know this TV yet.'), findsOneWidget);
    expect(find.byKey(const Key('dji_watch_tv_code_card')), findsOneWidget);
    // A refused own code is not a typed one: no dialog
    expect(tvApi.requests, isEmpty);
    // Nothing kept for a phone that refused it
    expect(relay.secrets.containsKey('dji_relay_code.$_phoneId'), isFalse);

    // Not before the next 10 s
    await tester.pump(const Duration(seconds: 5));
    expect(api.connects, hasLength(1));
    // One try every 10 s while the phone refuses it, never two between two refusals
    var rounds = 0;
    while (api.connects.length < djiWatchOwnCodeTries && rounds < djiWatchOwnCodeTries + 10) {
      final before = api.connects.length;
      await tester.pump(djiWatchTryEvery);
      await tester.pump();
      expect(api.connects.length - before, lessThanOrEqualTo(1));
      await push(tester, listener, refused());
      rounds++;
    }
    expect(api.connects, hasLength(djiWatchOwnCodeTries));
    expect(api.connects.every((connect) => connect.$3 == _ownCode), isTrue);
    expect(rounds, greaterThanOrEqualTo(djiWatchOwnCodeTries - 1));
    for (var round = 0; round < 3; round++) {
      await tester.pump(djiWatchTryEvery);
      await tester.pump();
      await push(tester, listener, refused());
    }
    expect(api.connects, hasLength(djiWatchOwnCodeTries));
    expect(find.text('Stopped trying. Select the phone to try again.'), findsOneWidget);

    // Choosing the phone tries again at once
    await tester.tap(phoneRow('192.168.1.21'));
    await tester.pumpAndSettle();
    expect(api.connects, hasLength(djiWatchOwnCodeTries + 1));
    expect(find.byKey(const Key('dji_watch_tv_tries_stopped')), findsNothing);
  });

  testWidgets('the phone welcomes the TV: the first picture opens the full screen view, and the code is remembered', (
    tester,
  ) async {
    final (api, relay, _) = await watching(tester);
    expect(find.byKey(const Key('dji_watch_tv_full')), findsOneWidget);
    expect(find.byKey(const Key('dji_watch_tv_code_card')), findsNothing);
    expect(relay.secrets['dji_relay_code.$_phoneId'], _ownCode);
    expect(relay.secrets[djiRelayLastPhoneKey], _phoneId);
    expect(relay.secrets[djiWatchOwnCodePhonesKey], '["$_phoneId"]');
    expect(find.byKey(const Key('dji_watch_placeholder')), findsOneWidget);
    // The strip: where the picture comes from with the delay, Watching only and the observer rule
    final strip = find.byKey(const Key('dji_watch_tv_strip'));
    expect(
      find.descendant(of: strip, matching: find.text('Receiving from Galaxy S24+: live from the remote')),
      findsOneWidget,
    );
    expect(find.descendant(of: strip, matching: find.text('Delay from the phone: about 24 ms')), findsOneWidget);
    expect(
      find.descendant(of: strip, matching: find.text('Watching only: nothing on this TV reaches the drone.')),
      findsOneWidget,
    );
    expect(find.descendant(of: strip, matching: find.textContaining('watch the drone, not the TV')), findsOneWidget);
    // The values of the gate, on the right: the drone's battery and the motor time; on the left nothing while the drone
    // is on the ground (the height and the speeds come in the air only)
    final right = find.byKey(const Key('dji_watch_tv_column_right'));
    expect(find.descendant(of: right, matching: find.text('Drone battery')), findsOneWidget);
    expect(find.descendant(of: right, matching: find.text('34 %')), findsOneWidget);
    expect(find.descendant(of: right, matching: find.text('Motor time')), findsOneWidget);
    expect(find.descendant(of: right, matching: find.text('0:41')), findsOneWidget);
    expect(find.text('Not compared with DJI Fly yet: do not fly by these numbers.'), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(const Key('dji_watch_tv_column_left')), matching: find.byType(Text)),
      findsNothing,
    );
    expect(find.textContaining('Height'), findsNothing);
    // The hint of the keys, for 5 s
    expect(
      find.text('OK: show or hide the numbers. Menu, or hold OK: options. Back: the phones. Any key: the notes again.'),
      findsOneWidget,
    );
    await tester.pump(djiWatchTvHintFor);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_watch_tv_hint')), findsNothing);
    expect(api.disconnects, 0);
  });

  testWidgets('OK hides and shows the numbers, the strip stays; arrows show the hint; play and colours do nothing', (
    tester,
  ) async {
    final (api, _, _) = await watching(tester);
    await tester.pump(djiWatchTvHintFor);
    await tester.pumpAndSettle();
    final right = find.byKey(const Key('dji_watch_tv_column_right'));
    final strip = find.byKey(const Key('dji_watch_tv_strip'));

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(right, findsNothing);
    expect(find.text('Not compared with DJI Fly yet: do not fly by these numbers.'), findsNothing);
    expect(strip, findsOneWidget);
    expect(find.descendant(of: strip, matching: find.textContaining('Watching only')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(right, findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(find.byKey(const Key('dji_watch_tv_hint')), findsOneWidget);
    await tester.pump(djiWatchTvHintFor);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_watch_tv_hint')), findsNothing);

    // No physical key in the simulator's maps for the colour keys of a remote: they come with one of their own, as the
    // Android embedder sends them with the scan code of the remote
    final physical = {
      LogicalKeyboardKey.colorF0Red: PhysicalKeyboardKey.f21,
      LogicalKeyboardKey.colorF1Green: PhysicalKeyboardKey.f22,
      LogicalKeyboardKey.colorF2Yellow: PhysicalKeyboardKey.f23,
      LogicalKeyboardKey.colorF3Blue: PhysicalKeyboardKey.f24,
    };
    final connects = api.connects.length;
    for (final key in [
      LogicalKeyboardKey.mediaPlayPause,
      LogicalKeyboardKey.mediaPause,
      LogicalKeyboardKey.mediaPlay,
      LogicalKeyboardKey.colorF0Red,
      LogicalKeyboardKey.colorF1Green,
      LogicalKeyboardKey.colorF2Yellow,
      LogicalKeyboardKey.colorF3Blue,
    ]) {
      await tester.sendKeyEvent(key, physicalKey: physical[key]);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dji_watch_tv_full')), findsOneWidget, reason: '$key');
      expect(right, findsOneWidget, reason: '$key');
      expect(find.byKey(const Key('dji_watch_tv_options_panel')), findsNothing, reason: '$key');
    }
    expect(api.connects, hasLength(connects));
    expect(api.disconnects, 0);
    expect(api.playbackStops, 0);
  });

  testWidgets('the warnings of the full screen come for five seconds and fade; a key brings them back', (tester) async {
    final (_, _, listener) = await watching(tester);
    final strip = find.byKey(const Key('dji_watch_tv_strip'));
    final state = find.byKey(const Key('dji_watch_tv_strip_state'));
    final watchingOnly = find.byKey(const Key('dji_watch_tv_strip_watching'));
    final observer = find.byKey(const Key('dji_watch_tv_strip_observer'));
    final delay = find.byKey(const Key('dji_watch_tv_strip_delay'));
    final flyNote = find.byKey(const Key('dji_watch_tv_fly_note'));
    for (final finder in [state, watchingOnly, observer, delay, flyNote]) {
      expect(finder, findsOneWidget);
    }
    FadeTransition fade(Finder finder) =>
        tester.widget<FadeTransition>(find.ancestor(of: finder, matching: find.byType(FadeTransition)).first);

    // Five seconds in all, then out over 0.8 s
    await tester.pump(djiTransientHold - const Duration(milliseconds: 600));
    expect(fade(watchingOnly).opacity.value, 1);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 400));
    expect(fade(watchingOnly).opacity.value, closeTo(0.5, 0.05));
    await tester.pumpAndSettle();
    // Gone, the plate shrunk to the delay, which stays with the values
    for (final finder in [state, watchingOnly, observer, flyNote]) {
      expect(finder, findsNothing);
    }
    expect(delay, findsOneWidget);
    expect(find.byKey(const Key('dji_watch_tv_column_right')), findsOneWidget);
    expect(tester.getSize(strip).height, lessThan(60));

    // Any key brings them back for five seconds: here an arrow, with the hint
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    for (final finder in [state, watchingOnly, observer, flyNote]) {
      expect(finder, findsOneWidget);
    }
    await tester.pump(djiTransientHold);
    await tester.pumpAndSettle();
    expect(watchingOnly, findsNothing);

    // A picture that stops: its red line comes by itself, and stays while the picture is black
    await push(
      tester,
      listener,
      fakeSnapshot(
        decode: fakeDecode(lastOutputAgoMs: 2500),
        relayReceiving: fakeReceiving(phoneSource: 'cable', lastPictureAgoMs: 2500),
        liveFrame: fakeFrame(),
      ),
    );
    final stale = find.byKey(const Key('dji_watch_tv_strip_stale'));
    expect(stale, findsOneWidget);
    await tester.pump(djiTransientHold * 2);
    await tester.pumpAndSettle();
    expect(stale, findsOneWidget);
    expect(watchingOnly, findsNothing);
  });

  testWidgets("the phone's steady picture is said for five seconds at each switch, then gone", (tester) async {
    final (_, _, listener) = await watching(tester);
    final steady = find.byKey(const Key('dji_watch_tv_strip_steady'));
    expect(steady, findsNothing);
    DjiLinkSnapshot from({required bool phone, required int switches}) => fakeSnapshot(
      decode: fakeDecode(),
      relayReceiving: fakeReceiving(phoneSource: 'cable', steady: phone, streamSwitches: switches),
      telemetryValues: fakeTelemetry(percent: 34, motorTimeS: 41.6),
      liveFrame: fakeFrame(),
    );
    await push(tester, listener, from(phone: true, switches: 1));
    expect(steady, findsOneWidget);
    expect(find.text('Steady picture from the phone: less detail, no lost pictures'), findsOneWidget);
    await tester.pump(djiTransientHold + djiTransientFadeOut);
    await tester.pumpAndSettle();
    expect(steady, findsNothing);
    // Back to the drone's picture: nothing to say; steady again: said again
    await push(tester, listener, from(phone: false, switches: 2));
    expect(steady, findsNothing);
    await push(tester, listener, from(phone: true, switches: 3));
    expect(steady, findsOneWidget);
  });

  testWidgets('the phones view: the rules on top come for five seconds, and any key brings them back', (tester) async {
    final relay = FakeRelayEnvironment();
    await openOnTv(tester, television(), relay: relay);
    await announce(tester, relay, '192.168.1.21');
    final rules = find.byKey(const Key('dji_link_observer'));
    expect(rules, findsOneWidget);
    await tester.pump(djiTransientHold);
    await tester.pumpAndSettle();
    expect(rules, findsNothing);
    expect(phoneRow('192.168.1.21'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(rules, findsOneWidget);
    expect(find.text('Watching only: nothing on this TV reaches the drone.'), findsOneWidget);
  });

  testWidgets('Menu, Info and OK held open Options; Back closes it and stays in full screen', (tester) async {
    await watching(tester);
    final panel = find.byKey(const Key('dji_watch_tv_options_panel'));
    for (final key in [LogicalKeyboardKey.contextMenu, LogicalKeyboardKey.info]) {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
      expect(panel, findsOneWidget, reason: '$key');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(panel, findsNothing, reason: '$key');
      expect(find.byKey(const Key('dji_watch_tv_full')), findsOneWidget, reason: '$key');
    }

    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();
    expect(panel, findsOneWidget);
    // What is left of the held OK changes nothing in Options
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(panel, findsOneWidget);
    expect(find.text('Hide the numbers'), findsOneWidget);
    expect(find.text('Picture and decoder'), findsOneWidget);
    expect(find.text('c2.android.hevc.decoder, software, Automatic'), findsOneWidget);
    expect(find.text('Values from the drone'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_watch_tv_column_right')), findsOneWidget);
  });

  testWidgets('Back goes to the phones view still receiving, the picture moved and not made again, then leaves', (
    tester,
  ) async {
    final (api, _, _) = await watching(tester);
    expect(pictureMade, hasLength(1));

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_watch_tv_full')), findsNothing);
    expect(phoneRow('192.168.1.21'), findsOneWidget);
    expect(find.text('Watching'), findsOneWidget);
    expect(find.byKey(const Key('dji_watch_placeholder')), findsOneWidget);
    expect(api.disconnects, 0);
    expect(api.stops, 0);
    expect(pictureMade, hasLength(1), reason: 'one platform view, moved');
    expect(focused(tester, phoneRow('192.168.1.21')), isTrue);

    // OK on the row watched: full screen again, with the same picture
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_watch_tv_full')), findsOneWidget);
    expect(pictureMade, hasLength(1));
    expect(api.connects, hasLength(1));

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_watch')), findsNothing);
    expect(api.stops, 1);
  });

  testWidgets('Stop watching in Options disconnects and stays on the phones view, with no try of its own', (
    tester,
  ) async {
    final (api, _, _) = await watching(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    await showInOptions(tester, const Key('dji_watch_stop'));
    await tester.tap(find.byKey(const Key('dji_watch_stop')));
    await tester.pumpAndSettle();
    expect(api.disconnects, 1);
    expect(find.byKey(const Key('dji_watch_tv_full')), findsNothing);
    expect(phoneRow('192.168.1.21'), findsOneWidget);
    expect(find.byKey(const Key('dji_watch')), findsOneWidget);
    await tester.pump(const Duration(seconds: 30));
    expect(api.connects, hasLength(1));
  });

  testWidgets('Home stops receiving and browsing; back in front it connects by itself', (tester) async {
    final relay = FakeRelayEnvironment()
      ..secrets['dji_relay_code.$_phoneId'] = _ownCode
      ..secrets[djiWatchOwnCodeKey] = _ownCode
      ..secrets[djiRelayLastPhoneKey] = _phoneId;
    final api = television();
    await openOnTv(tester, api, relay: relay);
    await announce(tester, relay, '192.168.1.21');
    expect(api.connects, hasLength(1));

    for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    expect(api.disconnects, 1);
    // Not browsing: a phone announced now is not listed, nor connected
    await announce(tester, relay, '192.168.1.21');
    expect(api.connects, hasLength(1));

    for (final state in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    await announce(tester, relay, '192.168.1.21');
    expect(api.connects, hasLength(2));
    expect(api.connects.last, ('192.168.1.21', 8362, _ownCode, _phoneId, 'Galaxy S24+'));
  });

  testWidgets('the screen stays on while pictures come, and is let go 10 minutes after the last one', (tester) async {
    final relay = FakeRelayEnvironment();
    final listener = await openOnTv(tester, television(), relay: relay);
    expect(relay.screen.last, isTrue);
    await tester.pump(const Duration(minutes: 9));
    expect(relay.screen.last, isTrue);
    await tester.pump(const Duration(minutes: 1));
    await tester.pump();
    expect(relay.screen.last, isFalse);

    await push(tester, listener, picture());
    expect(relay.screen.last, isTrue);
    await push(
      tester,
      listener,
      fakeSnapshot(decode: fakeDecode(lastOutputAgoMs: 5000), relayReceiving: fakeReceiving()),
    );
    await tester.pump(djiWatchTvScreenIdle);
    await tester.pump();
    expect(relay.screen.last, isFalse);
  });

  testWidgets('the phone\'s code typed in the TV\'s text dialog, and asked again when the phone refuses it', (
    tester,
  ) async {
    final relay = FakeRelayEnvironment();
    final api = television();
    final listener = await openOnTv(tester, api, relay: relay);
    await announce(tester, relay, '192.168.1.21');
    tvApi.answers.addAll(['mnpqr stuvw', null]);
    await tester.tap(find.byKey(const Key('dji_watch_tv_type_code')));
    await tester.pumpAndSettle();
    expect(tvApi.requests.single.title, 'Code shown on Immuch360 on Galaxy S24+');
    expect(tvApi.requests.single.kind, TvTextKind.text);
    expect(api.connects.last.$3, 'MNPQRSTUVW');
    expect(relay.secrets['dji_relay_code.$_phoneId'], 'MNPQRSTUVW');

    await push(tester, listener, refused());
    expect(tvApi.requests, hasLength(2));
    expect(tvApi.requests.last.title, 'The code does not match: type it again.');
    expect(relay.secrets.containsKey('dji_relay_code.$_phoneId'), isFalse);
  });

  testWidgets('a phone not listed: its address typed in the TV\'s text dialog, watched with this TV\'s code', (
    tester,
  ) async {
    final api = television();
    await openOnTv(tester, api);
    tvApi.answers.add('8.8.8.8');
    await tester.tap(find.byKey(const Key('dji_watch_address')));
    await tester.pumpAndSettle();
    expect(tvApi.requests.single.kind, TvTextKind.url);
    expect(find.byKey(const Key('dji_watch_error')), findsOneWidget);
    expect(api.connects, isEmpty);

    tvApi.answers.add('10.0.2.2');
    await tester.tap(find.byKey(const Key('dji_watch_address')));
    await tester.pumpAndSettle();
    expect(api.connects.single, ('10.0.2.2', 8362, _ownCode, null, 'Galaxy S24+'));
  });

  testWidgets('a new code for this TV forgets the phones that knew the old one', (tester) async {
    final relay = FakeRelayEnvironment()
      ..secrets[djiWatchOwnCodeKey] = 'WXYZ234567'
      ..secrets['dji_relay_code.$_phoneId'] = 'WXYZ234567'
      ..secrets[djiWatchOwnCodePhonesKey] = '["$_phoneId"]';
    final api = television();
    await openOnTv(tester, api, relay: relay);
    await announce(tester, relay, '192.168.1.21');
    expect(find.text('Press OK to watch'), findsOneWidget);
    // A phone with a code here is not tried
    expect(api.connects, isEmpty);

    await tester.tap(find.byKey(const Key('dji_watch_tv_options')));
    await tester.pumpAndSettle();
    await showInOptions(tester, const Key('dji_watch_tv_new_code'));
    expect(find.text('Remove this TV on the phone, then add it again.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('dji_watch_tv_new_code')));
    await tester.pumpAndSettle();
    expect(relay.secrets[djiWatchOwnCodeKey], _ownCode);
    expect(relay.secrets.containsKey('dji_relay_code.$_phoneId'), isFalse);
    expect(relay.secrets.containsKey(djiWatchOwnCodePhonesKey), isFalse);
    expect(find.text('Press OK to try'), findsOneWidget);
    expect(find.text('K7M2Q 9XRTH'), findsOneWidget);
  });

  testWidgets('the obstacle ring on a TV: on by default with its sound, number and circle, never hidden by OK', (
    tester,
  ) async {
    final (api, _, listener) = await watching(tester);
    // On by default on a TV too (FreeKC's rule of 25 October); a TV never vibrates
    expect(api.obstacleRings.last.offered, isTrue);
    expect(api.obstacleRings.last.sound, isTrue);
    expect(api.obstacleRings.last.numbers, isTrue);
    expect(api.obstacleRings.last.frame, isFalse);
    expect(api.obstacleRings.last.haptic, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    // The old test switch is gone; the ring on this TV's screen, on by default, can only turn it off here
    expect(find.byKey(const Key('dji_watch_obstacle')), findsNothing);
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('dji_watch_obstacle_here'))).value, isTrue);
    expect(find.text('On by default, when the phone shows it. The phone sets its distances and side.'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('dji_watch_obstacle_sound'))).value, isTrue);
    await tester.tap(find.byKey(const Key('dji_watch_obstacle_sound')));
    await tester.pumpAndSettle();
    expect(api.obstacleRings.last.sound, isFalse);
    expect(memory[StoreKey.djiObstacleSoundOff], isTrue);

    Future<void> choose(Key key) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();
      await showInOptions(tester, key);
      await tester.tap(find.byKey(key));
      await tester.pumpAndSettle();
    }

    await choose(const Key('dji_watch_tv_sound_test'));
    expect(api.obstacleTests, 1);
    await choose(const Key('dji_watch_obstacle_numbers'));
    expect(api.obstacleRings.last.numbers, isFalse);
    expect(memory[StoreKey.djiObstacleNumbersOff], isTrue);
    await choose(const Key('dji_watch_obstacle_numbers'));
    expect(api.obstacleRings.last.numbers, isTrue);
    await choose(const Key('dji_watch_obstacle_here'));
    expect(api.obstacleRings.last.offered, isFalse);
    expect(memory[StoreKey.djiObstacleRingOff], isTrue);
    await choose(const Key('dji_watch_obstacle_here'));
    expect(api.obstacleRings.last.offered, isTrue);
    await choose(const Key('dji_watch_obstacle_sample'));
    expect(api.obstacleSamples, 1);

    await push(tester, listener, picture(frame: fakeFrame(alert: fakeDecision(on: true, arcs: [fakeArc(1.84)]))));
    final ring = find.byKey(const Key('dji_live_obstacle_ring'));
    expect(ring, findsOneWidget);
    expect(find.byKey(const Key('dji_live_obstacle_circle')), findsOneWidget);
    // The frame at the edges, as this TV's choice in Options
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    await showInOptions(tester, const Key('dji_watch_obstacle_shape'));
    expect(
      find.descendant(
        of: find.byKey(const Key('dji_watch_obstacle_shape')),
        matching: find.text('Circle around the centre'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('dji_watch_obstacle_shape')));
    await tester.pumpAndSettle();
    expect(api.obstacleRings.last.frame, isTrue);
    expect(memory[StoreKey.djiObstacleShapeFrame], isTrue);
    expect(find.byKey(const Key('dji_live_obstacle_frame')), findsOneWidget);
    expect(find.byKey(const Key('dji_live_obstacle_circle')), findsNothing);
    expect(find.byKey(const Key('dji_watch_tv_obstacle')), findsNothing);
    expect(find.text('Obstacle close: 1.8 m'), findsNothing);
    expect(find.text('1.8 m'), findsOneWidget);
    // OK hides the numbers, the ring's with them, never the ring
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_watch_tv_column_right')), findsNothing);
    expect(ring, findsOneWidget);
    expect(find.text('1.8 m'), findsNothing);
  });

  testWidgets('a value that changes never moves its neighbour, and a column that lost every value says so', (
    tester,
  ) async {
    final (_, _, listener) = await watching(tester);
    final motor = find.byKey(const Key('dji_watch_tv_cell_motorTime'));
    final before = tester.getTopLeft(motor);
    listener!.flightChanged(fakeFrame(atMs: 2000, percent: 9));
    await tester.pumpAndSettle();
    expect(find.text('9 %'), findsOneWidget);
    expect(find.byKey(const Key('dji_watch_tv_battery_low')), findsOneWidget);
    expect(tester.getTopLeft(motor), before);

    listener.flightChanged(fakeFrame(atMs: 3000, percent: null, motorTimeS: null));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_watch_tv_values_stale_right')), findsOneWidget);
    expect(find.text('These values are no longer updated'), findsOneWidget);
  });

  testWidgets('the flight column in the air, empty and quiet once landed, stale only when the flight data stops', (
    tester,
  ) async {
    final (_, _, listener) = await watching(tester);
    // The proof flights of 25 October: height above the take off point, vertical speed climb positive, speed, below
    listener!.flightChanged(
      fakeFrame(atMs: 2000, motorsOn: true, heightM: 0.8, verticalSpeedMps: -0.2, speedMps: 0.0, distanceBelowM: 0.519),
    );
    await tester.pumpAndSettle();
    final left = find.byKey(const Key('dji_watch_tv_column_left'));
    for (final text in ['Height', '0.8 m', 'Vertical', '↓ 0.2 m/s', 'Speed', '0.0 m/s', 'Below', '0.52 m']) {
      expect(find.descendant(of: left, matching: find.text(text)), findsOneWidget, reason: text);
    }
    // Landed on a hand: the flight data still comes, nothing to show on the left and no stale line
    listener.flightChanged(fakeFrame(atMs: 3000));
    await tester.pumpAndSettle();
    expect(find.descendant(of: left, matching: find.byType(Text)), findsNothing);
    expect(find.byKey(const Key('dji_watch_tv_values_stale_left')), findsNothing);
    // The flight data stops: the column says so
    listener.flightChanged(fakeFrame(atMs: 4000, motorsOn: null, percent: null, motorTimeS: null));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_watch_tv_values_stale_left')), findsOneWidget);
  });

  testWidgets('the notice on a TV: its two rules first, then every line of the notice word for word', (tester) async {
    await openOnTv(tester, television(), noticeRead: false);
    expect(find.byKey(const Key('dji_live_notice')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('dji_live_notice_observer'))).data,
      startsWith('Flying while you watch this TV'),
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('dji_live_notice_watching'))).data,
      'Watching only: nothing on this TV reaches the drone.',
    );
    final observer = tester.getTopLeft(find.byKey(const Key('dji_live_notice_observer')));
    final pilot = tester.getTopLeft(find.textContaining('This tool reads the cable'));
    expect(observer.dy, lessThan(pilot.dy));
  });

  testWidgets('Diagnostics on a TV: the rules for a TV, what it received, and no Send', (tester) async {
    final api = television();
    await tester.binding.setSurfaceSize(const Size(1000, 6000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpTestWidget(
      context,
      const DjiLinkPage(),
      overrides: [
        tvDeviceProvider.overrideWithValue(TvDeviceInfo(isTelevision: true, isLowRamDevice: false)),
        djiLinkApiProvider.overrideWithValue(api),
        djiLinkEventsSetUpProvider.overrideWithValue((_) {}),
        djiRelayEnvironmentProvider.overrideWithValue(FakeRelayEnvironment().build()),
        isHorizonOsProvider.overrideWith((ref) async => false),
        djiLinkVideoViewBuilderProvider.overrideWithValue(
          () => const ColoredBox(key: Key('dji_link_video_placeholder'), color: Colors.black),
        ),
      ],
      expectSettle: false,
    );
    final container = ProviderScope.containerOf(tester.element(find.byType(DjiLinkPage)));
    await container.read(djiLinkProvider.notifier).pageShown();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('Watching only: nothing on this TV reaches the drone.'), findsOneWidget);
    expect(find.byKey(const Key('dji_link_reception_record')), findsOneWidget);
    expect(find.byKey(const Key('dji_link_send')), findsNothing);
    expect(find.byKey(const Key('dji_link_relay_switch')), findsNothing);
  });

  testWidgets('the phone removes this TV in full screen: back to the phones view with the card, nothing to type', (
    tester,
  ) async {
    final (api, relay, listener) = await watching(tester);
    expect(find.byKey(const Key('dji_watch_tv_full')), findsOneWidget);

    // Remove on the phone: BYE newCode, which the receiver reads as a refused code
    await push(tester, listener, refused());
    expect(find.byKey(const Key('dji_watch_tv_full')), findsNothing);
    expect(find.byKey(const Key('dji_watch_tv_code_card')), findsOneWidget);
    expect(find.text('Immuch360 on Galaxy S24+ does not know this TV yet.'), findsOneWidget);
    expect(find.text('The code does not match: type it again.'), findsNothing);
    expect(tvApi.requests, isEmpty);
    // The code the phone no longer knows is forgotten here
    expect(relay.secrets.containsKey('dji_relay_code.$_phoneId'), isFalse);

    // Added again on the phone: the next try is welcomed, and its first picture opens the full screen view again
    await tester.pump(djiWatchTryEvery);
    await tester.pump();
    expect(api.connects, hasLength(2));
    expect(api.connects.last.$3, _ownCode);
    await push(tester, listener, picture());
    expect(find.byKey(const Key('dji_watch_tv_full')), findsOneWidget);
    expect(find.byKey(const Key('dji_watch_tv_code_card')), findsNothing);
  });

  testWidgets('the notice on a TV: the arrows read it to its last line, and only then reach I understand', (
    tester,
  ) async {
    // The obstacle ring may show on a TV: the line "Information only" comes last
    await openOnTv(tester, television(), noticeRead: false);
    final text = find.byKey(const Key('dji_live_notice_text'));
    final last = find.byKey(const Key('dji_live_notice_last'));
    final understand = find.byKey(const Key('dji_live_notice_ok'));
    expect(find.descendant(of: last, matching: find.textContaining('Information only')), findsOneWidget);
    bool lastInView() => tester.getRect(last).bottom <= tester.getRect(text).bottom + 0.5;

    expect(focused(tester, text), isTrue);
    expect(lastInView(), isFalse, reason: 'the notice is longer than a 1080p TV, 960 by 540 dp');
    var presses = 0;
    var lastSeen = false;
    while (!focused(tester, understand) && presses < 20) {
      lastSeen = lastSeen || lastInView();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      presses++;
    }
    expect(focused(tester, understand), isTrue);
    expect(lastSeen, isTrue, reason: 'I understand comes once the last line was in view');
    expect(presses, greaterThan(1));

    // Up goes back to the text, which OK reads on to the end and leaves for I understand
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(focused(tester, text), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(focused(tester, understand), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_live_notice')), findsNothing);
    expect(find.byKey(const Key('dji_watch')), findsOneWidget);
  });

  testWidgets('Options by the arrows alone: from Hide the numbers down to Stop watching, every value flowing', (
    tester,
  ) async {
    final (api, _, listener) = await watching(tester);
    // Every value of Advanced, so that the read only lines are as long as in flight
    await push(
      tester,
      listener,
      picture(
        frame: fakeFrame(heightM: 1.2, verticalSpeedMps: 0.4, speedMps: 4.2, distanceBelowM: 3.1, obstacleM: 6.5),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    const items = [
      Key('dji_watch_tv_numbers'),
      Key('dji_watch_obstacle_here'),
      Key('dji_watch_obstacle_sound'),
      Key('dji_watch_tv_sound_test'),
      Key('dji_watch_obstacle_numbers'),
      Key('dji_watch_obstacle_shape'),
      Key('dji_watch_obstacle_sample'),
      Key('dji_watch_tv_safety'),
      Key('dji_watch_tv_diagnostics'),
      Key('dji_watch_save_record'),
      Key('dji_watch_tv_options_type_code'),
      Key('dji_watch_tv_new_code'),
      Key('dji_watch_stop'),
    ];
    for (final key in items) {
      expect(find.byKey(key), findsOneWidget, reason: '$key');
    }
    Key? focusedItem() => items.where((key) => focused(tester, find.byKey(key))).firstOrNull;
    expect(focusedItem(), items.first);

    final reached = [items.first];
    var lines = false;
    for (var press = 0; press < 30 && focusedItem() != items.last; press++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      final item = focusedItem();
      if (item == null) {
        // A block of read only lines, in view
        lines = true;
        expect(find.byKey(const Key('dji_watch_tv_options_panel')), findsOneWidget);
      } else if (item != reached.last) {
        reached.add(item);
      }
    }
    // Each item once, in order, never back to the top
    expect(reached, items);
    expect(lines, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(api.disconnects, 1);
    expect(find.byKey(const Key('dji_watch_tv_options_panel')), findsNothing);
  });

  testWidgets('a held OK on a phone row tries once, and a second press while it starts does nothing', (tester) async {
    final relay = FakeRelayEnvironment();
    final api = television();
    final listener = await openOnTv(tester, api, relay: relay);
    await announce(tester, relay, '192.168.1.21');
    await push(tester, listener, refused());
    expect(api.connects, hasLength(1));
    expect(focused(tester, phoneRow('192.168.1.21')), isTrue);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    for (var repeat = 0; repeat < 10; repeat++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(api.connects, hasLength(2));

    // The phone has not answered yet: OK again starts nothing
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(api.connects, hasLength(2));
  });

  testWidgets('a new code while watching with the old one ends that connection, and the next welcome keeps the new', (
    tester,
  ) async {
    final (api, relay, listener) = await watching(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    await showInOptions(tester, const Key('dji_watch_tv_new_code'));
    await tester.tap(find.byKey(const Key('dji_watch_tv_new_code')));
    await tester.pumpAndSettle();
    expect(api.disconnects, 1);
    expect(find.byKey(const Key('dji_watch_tv_full')), findsNothing);
    // The native side says the receiver stopped
    await push(tester, listener, fakeSnapshot(state: DjiLinkState.unsupportedTransport));
    expect(relay.secrets[djiWatchOwnCodeKey], 'ABCDEFGHJK');
    expect(relay.secrets.containsKey('dji_relay_code.$_phoneId'), isFalse);
    expect(find.text('ABCDE FGHJK'), findsOneWidget);

    // The pilot removes the TV on the phone and adds it again: the next try proves the new code, which is remembered
    await tester.pump(djiWatchTryEvery);
    await tester.pump();
    expect(api.connects.last.$3, 'ABCDEFGHJK');
    await push(tester, listener, picture());
    expect(relay.secrets['dji_relay_code.$_phoneId'], 'ABCDEFGHJK');
    expect(find.byKey(const Key('dji_watch_tv_full')), findsOneWidget);
  });

  testWidgets('two phones that do not know this TV: the red line names the one that refused, not the one tried', (
    tester,
  ) async {
    final relay = FakeRelayEnvironment();
    final api = television();
    final listener = await openOnTv(tester, api, relay: relay);
    await announce(tester, relay, '192.168.1.21');
    relay.browsed.add(
      fakeAnnounced('192.168.1.22', {...fakeDroneTxt, 'id': '0a1b2c3d4e5f6071'}, name: 'Immuch360 on Pixel 9'),
    );
    await tester.pumpAndSettle();
    expect(api.connects.single.$1, '192.168.1.21');
    await push(tester, listener, refused());
    expect(find.text('Immuch360 on Galaxy S24+ does not know this TV yet.'), findsOneWidget);

    await tester.pump(djiWatchTryEvery);
    await tester.pumpAndSettle();
    expect(api.connects.last.$1, '192.168.1.22');
    expect(find.text('Immuch360 on Galaxy S24+ does not know this TV yet.'), findsOneWidget);
    expect(find.text('Immuch360 on Pixel 9 does not know this TV yet.'), findsNothing);

    await push(tester, listener, refused());
    expect(find.text('Immuch360 on Pixel 9 does not know this TV yet.'), findsOneWidget);
    expect(find.text('Immuch360 on Galaxy S24+ does not know this TV yet.'), findsNothing);
  });

  testWidgets('Stop watching holds through Home: back in front, nothing connects until a phone is chosen', (
    tester,
  ) async {
    final relay = FakeRelayEnvironment()
      ..secrets['dji_relay_code.$_phoneId'] = _ownCode
      ..secrets[djiWatchOwnCodeKey] = _ownCode
      ..secrets[djiRelayLastPhoneKey] = _phoneId;
    final api = television();
    final listener = await openOnTv(tester, api, relay: relay);
    await announce(tester, relay, '192.168.1.21');
    expect(api.connects, hasLength(1));
    await push(tester, listener, picture());
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    await showInOptions(tester, const Key('dji_watch_stop'));
    await tester.tap(find.byKey(const Key('dji_watch_stop')));
    await tester.pumpAndSettle();
    expect(api.disconnects, 1);

    for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    for (final state in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    await announce(tester, relay, '192.168.1.21');
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(api.connects, hasLength(1));

    // Choosing the phone watches again
    await tester.tap(phoneRow('192.168.1.21'));
    await tester.pumpAndSettle();
    expect(api.connects, hasLength(2));
  });

  testWidgets('a television with the remote control layout turned off keeps the TV page', (tester) async {
    final relay = FakeRelayEnvironment();
    await openOnTv(tester, television(), relay: relay, tvMode: false);
    expect(find.byKey(const Key('dji_watch_tv_options')), findsOneWidget);
    expect(find.text('Watching only: nothing on this TV reaches the drone.'), findsOneWidget);
    await announce(tester, relay, '192.168.1.21');
    expect(find.byKey(const Key('dji_watch_tv_code_card')), findsOneWidget);
  });

  group('the words of a TV', () {
    testWidgets('every state of the reception, each decode failure', (tester) async {
      late Translations t;
      await tester.pumpTestWidget(
        context,
        Builder(
          builder: (context) {
            t = context.t;
            return const SizedBox();
          },
        ),
      );
      String line(
        DjiRelayReceiveState state, {
        bool flows = true,
        DjiLinkDecode? decode,
        bool long = false,
        int failures = 0,
      }) => djiWatchTvStateLine(
            t,
            fakeReceiving(state: state, phoneSource: 'cable', failures: failures, reconnectInMs: 1500),
            pictureFlows: flows,
            decode: decode,
            longWait: long,
          );
      expect(line(DjiRelayReceiveState.receiving), 'Receiving from Galaxy S24+: live from the remote');
      expect(line(DjiRelayReceiveState.receiving, flows: false), 'Connected to Galaxy S24+, no picture yet.');
      expect(
        line(DjiRelayReceiveState.receiving, flows: false, long: true),
        'Still no picture. Check that the phone shows the drone\'s picture.',
      );
      expect(line(DjiRelayReceiveState.connecting), 'Connecting to Galaxy S24+');
      expect(line(DjiRelayReceiveState.checkingCode), 'Checking the code');
      expect(line(DjiRelayReceiveState.blocked), 'Too many wrong codes from this TV: wait a minute.');
      expect(line(DjiRelayReceiveState.full), 'This phone already sends to four screens. Trying again every 10 s.');
      expect(line(DjiRelayReceiveState.lost), 'Connection lost, trying again in 1.5 s');
      expect(
        line(DjiRelayReceiveState.lost, failures: 3),
        'Still trying. Check that the phone and this TV are on the same Wi-Fi, and that the phone still sends.',
      );
      expect(line(DjiRelayReceiveState.otherVersion), 'The phone runs another version of Immuch360: update both.');
      expect(line(DjiRelayReceiveState.phoneUnproven), 'This phone did not prove the code: nothing it sends is shown.');
      expect(line(DjiRelayReceiveState.wrongCode), 'The code does not match: type it again.');
      // This TV's own code refused: the phone does not know this TV, there is nothing to type
      expect(
        djiWatchTvStateLine(
          t,
          fakeReceiving(state: DjiRelayReceiveState.wrongCode),
          pictureFlows: false,
          refusedBy: 'Immuch360 on Galaxy S24+',
        ),
        'Immuch360 on Galaxy S24+ does not know this TV yet.',
      );
      expect(
        line(DjiRelayReceiveState.receiving, decode: fakeDecode(failure: 'no-decoder')),
        'This TV has no decoder for the drone\'s video (H.265). The numbers still show.',
      );
      for (final decode in [
        fakeDecode(failure: 'configuration-refused'),
        fakeDecode(switchReason: 'noPictureNothingLeft'),
      ]) {
        expect(
          line(DjiRelayReceiveState.receiving, decode: decode),
          'This TV\'s decoders show no picture of this stream. Options, Diagnostics says which ones were tried.',
        );
      }
      expect(djiWatchTvPictureLines(t, fakeDecode(switchReason: 'noPictureWithKey'), fakeReceiving()), [
        'c2.android.hevc.decoder, software, Automatic',
        '30 pictures a second, 5.5 ms to decode',
        'Delay from the phone: about 24 ms',
        t.dji_link_video_switch_no_picture,
      ]);
      expect(djiWatchTvPictureLines(t, null, null), ['not started']);
      // The delay of the last 2 s when measured, so that a spike shows (review M1)
      expect(
        djiWatchTvPictureLines(t, fakeDecode(), fakeReceiving(receiveToPictureNowMs: 640)),
        contains('Delay from the phone: about 640 ms'),
      );
    });

    test('the state line comes and goes over the picture, but an error that needs an action stays', () {
      DjiReceiveLine kind(
        DjiRelayReceiveState state, {
        bool flows = true,
        DjiLinkDecode? decode,
        bool long = false,
        int failures = 0,
        String source = 'cable',
        String? refusedBy,
      }) => djiWatchTvLine(
        fakeReceiving(state: state, phoneSource: source, failures: failures),
        pictureFlows: flows,
        decode: decode,
        longWait: long,
        refusedBy: refusedBy,
      );
      // Where the picture comes from, a wait, a reconnection: they come and go
      for (final (line, expected) in [
        (kind(DjiRelayReceiveState.receiving), DjiReceiveLine.live),
        (kind(DjiRelayReceiveState.receiving, source: 'replay'), DjiReceiveLine.replay),
        (kind(DjiRelayReceiveState.receiving, flows: false), DjiReceiveLine.waiting),
        (kind(DjiRelayReceiveState.connecting), DjiReceiveLine.connecting),
        (kind(DjiRelayReceiveState.checkingCode), DjiReceiveLine.checking),
        (kind(DjiRelayReceiveState.lost), DjiReceiveLine.lost),
      ]) {
        expect(line, expected);
        expect(line.keeps, isFalse, reason: '$line');
      }
      // What needs an action, or says why no picture comes, stays
      for (final (line, expected) in [
        (kind(DjiRelayReceiveState.receiving, flows: false, long: true), DjiReceiveLine.stillNoPicture),
        (kind(DjiRelayReceiveState.receiving, source: 'none'), DjiReceiveLine.noSource),
        (kind(DjiRelayReceiveState.lost, failures: 3), DjiReceiveLine.stillTrying),
        (kind(DjiRelayReceiveState.blocked), DjiReceiveLine.blocked),
        (kind(DjiRelayReceiveState.full), DjiReceiveLine.full),
        (kind(DjiRelayReceiveState.otherVersion), DjiReceiveLine.otherVersion),
        (kind(DjiRelayReceiveState.phoneUnproven), DjiReceiveLine.unproven),
        (kind(DjiRelayReceiveState.wrongCode), DjiReceiveLine.wrongCode),
        (kind(DjiRelayReceiveState.wrongCode, refusedBy: 'Immuch360 on Galaxy S24+'), DjiReceiveLine.codeRefused),
        (kind(DjiRelayReceiveState.receiving, decode: fakeDecode(failure: 'no-decoder')), DjiReceiveLine.decoderNone),
        (
          kind(DjiRelayReceiveState.receiving, decode: fakeDecode(failure: 'configuration-refused')),
          DjiReceiveLine.decoderRefused,
        ),
      ]) {
        expect(line, expected);
        expect(line.keeps, isTrue, reason: '$line');
      }
      // The headset's strip reads the same kinds
      expect(djiRelayReceiveLine(fakeReceiving(phoneSource: 'cable')), DjiReceiveLine.live);
      expect(djiRelayReceiveLine(fakeReceiving(state: DjiRelayReceiveState.busy)).keeps, isTrue);
    });

    test('a value read from the sofa: 32 over 16, on black at 70 %', () {
      expect(djiWatchTvValueSize, 32);
      expect(djiWatchTvLabelSize, 16);
      expect(djiWatchTvPlate, const Color(0xB3000000));
      expect(djiWatchTvColumnWidth, 200);
      expect(djiWatchTvScreenIdle, const Duration(minutes: 10));
      expect(djiWatchTryEvery, const Duration(seconds: 10));
      expect(djiWatchOwnCodeTries, 30);
    });
  });
}
