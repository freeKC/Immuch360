// The Diagnostics page of the DJI live video: what it shows of a device that cannot read a remote controller at all,
// of a link that is open, of the counters, of an exported capture, of the live picture and its counters, of the flight
// and battery values, of "Your hardware" and of a capture being played. The safety banner is there in every one of
// those states. Stage 2b: "Send to a headset" on a phone, and on a headset where its reception stands, with the
// observer note and the delay from the phone. The live screen or the watch page owns the session under this page: the
// harness opens it as they would.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/presentation/pages/drone/dji_link.page.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_video.widget.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';
import 'package:immich_mobile/providers/drone/dji_relay.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';

import '../../../unit/presentation/presentation_context.dart';
import 'dji_link_fakes.dart';

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  Future<DjiLinkEvents?> pumpPage(
    WidgetTester tester,
    FakeDjiLinkApi api, {
    FakeRelayEnvironment? relay,
    bool horizonOs = false,
  }) async {
    DjiLinkEvents? listener;
    final relayEnvironment = (relay ?? FakeRelayEnvironment()).build();
    // The page is a long list and the test viewport is 800 by 600: a tall surface builds every section, so that a
    // section that stopped showing fails here rather than hiding behind a scroll
    await tester.binding.setSurfaceSize(const Size(1000, 6000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpTestWidget(
      context,
      const DjiLinkPage(),
      overrides: [
        djiLinkApiProvider.overrideWithValue(api),
        djiLinkEventsSetUpProvider.overrideWithValue((events) => listener = events),
        djiRelayEnvironmentProvider.overrideWithValue(relayEnvironment),
        isHorizonOsProvider.overrideWith((ref) async => horizonOs),
        // No platform view under flutter test: a placeholder stands where the picture is
        djiLinkVideoViewBuilderProvider.overrideWithValue(
          () => const ColoredBox(key: Key('dji_link_video_placeholder'), color: Colors.black),
        ),
      ],
      // The first frame shows the indeterminate indicator of a page that is still asking the device: settling waits
      // for an animation that only ends once the answers are in
      expectSettle: false,
    );
    // The live screen or the watch page under Diagnostics owns the session, and the relay sees it in front
    final container = ProviderScope.containerOf(tester.element(find.byType(DjiLinkPage)));
    await container.read(djiLinkProvider.notifier).pageShown();
    await container.read(djiRelayProvider.notifier).loadCode();
    await container.read(djiRelayProvider.notifier).setPageVisible(true);
    await tester.pump();
    await tester.pumpAndSettle();
    return listener;
  }

  testWidgets('neither starts nor stops the link itself: the live screen or the watch page owns it', (tester) async {
    final api = FakeDjiLinkApi();
    await tester.pumpTestWidget(
      context,
      const DjiLinkPage(),
      overrides: [
        djiLinkApiProvider.overrideWithValue(api),
        djiLinkEventsSetUpProvider.overrideWithValue((_) {}),
        djiRelayEnvironmentProvider.overrideWithValue(FakeRelayEnvironment().build()),
        djiLinkVideoViewBuilderProvider.overrideWithValue(() => const ColoredBox(color: Colors.black)),
      ],
      expectSettle: false,
    );
    await tester.pumpAndSettle();
    expect(find.text('Diagnostics'), findsOneWidget);
    expect(api.starts, 0);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(api.stops, 0);
  });

  testWidgets('says plainly when this device cannot be a USB accessory, and offers nothing to start', (tester) async {
    final api = FakeDjiLinkApi(environment: fakeEnvironment(accessoryFeature: false));

    await pumpPage(tester, api);

    expect(find.byKey(const Key('dji_link_no_transport')), findsOneWidget);
    expect(find.byKey(const Key('dji_link_safety')), findsOneWidget);
    expect(find.byKey(const Key('dji_link_link')), findsNothing);
    expect(find.byKey(const Key('dji_link_retry')), findsNothing);
    expect(find.byKey(const Key('dji_link_capture_start')), findsNothing);
    expect(api.starts, 0);
    // A capture can still be played here, which measures the decoder of a headset with no remote at all
    expect(find.byKey(const Key('dji_link_video_panel')), findsOneWidget);
    expect(find.byKey(const Key('dji_link_flight_note')), findsOneWidget);
    expect(find.byKey(const Key('dji_link_play')), findsOneWidget);
  });

  testWidgets('shows what this device can do about a USB accessory', (tester) async {
    final api = FakeDjiLinkApi(environment: fakeEnvironment(djiInstalled: true));

    await pumpPage(tester, api);

    expect(find.byKey(const Key('dji_link_environment')), findsOneWidget);
    expect(find.text('USB accessory feature'), findsOneWidget);
    expect(find.text('Quest 3'), findsNothing, reason: 'the model is a label of its own row');
    expect(find.textContaining('oculus/hollywood'), findsOneWidget);
    expect(find.text('DJI application installed'), findsOneWidget);
    expect(api.starts, 1);
  });

  testWidgets('a link that never gave a byte says so', (tester) async {
    final api = FakeDjiLinkApi(
      snapshot: fakeSnapshot(
        state: DjiLinkState.linkUsable,
        reason: DjiLinkReason.probeReturns,
        accessory: DjiLinkAccessory(manufacturer: 'DJI', model: 'com.dji.logiclink', description: ' RC'),
      ),
    );

    await pumpPage(tester, api);

    expect(find.text('Link takes bytes'), findsOneWidget);
    expect(find.text('never'), findsOneWidget);
    expect(find.text('The liveness probe returns. Nothing has answered yet.'), findsOneWidget);
    expect(find.textContaining('com.dji.logiclink'), findsOneWidget);
    expect(find.textContaining('Nothing is written for the first 20 seconds'), findsOneWidget);
  });

  testWidgets('a refused permission is a state of its own, with the banner still there', (tester) async {
    final api = FakeDjiLinkApi(
      snapshot: fakeSnapshot(state: DjiLinkState.permissionDenied, reason: DjiLinkReason.permissionRefused),
    );

    await pumpPage(tester, api);

    expect(find.text('USB permission refused'), findsOneWidget);
    expect(find.textContaining('It is asked again only when you tap Try again'), findsOneWidget);
    expect(find.byKey(const Key('dji_link_safety')), findsOneWidget);

    await tester.tap(find.byKey(const Key('dji_link_retry')));
    await tester.pumpAndSettle();
    expect(api.retries, 1);
  });

  testWidgets('a technical word from the native side follows the sentence of the reason', (tester) async {
    final api = FakeDjiLinkApi(
      snapshot: fakeSnapshot(
        state: DjiLinkState.permissionDenied,
        reason: DjiLinkReason.permissionRequestFailed,
        detail: 'SecurityException',
      ),
    );

    await pumpPage(tester, api);

    expect(find.text('The USB permission could not be asked for. (SecurityException)'), findsOneWidget);
  });

  testWidgets('an accessory nobody has described is named by its strings, and a blocked probe is said', (tester) async {
    final api = FakeDjiLinkApi(
      snapshot: fakeSnapshot(
        state: DjiLinkState.accessoryOpen,
        reason: DjiLinkReason.writeBlocked,
        probesHalted: true,
        accessory: DjiLinkAccessory(manufacturer: 'Acme', model: 'Bridge'),
        profile: DjiLinkProfile(
          id: 'observed-acme-bridge-none',
          label: 'Accessory not described yet: Acme Bridge',
          capabilities: [DjiLinkCapability(name: 'VIDEO_DECODE', support: DjiLinkSupport.unknown)],
        ),
      ),
    );

    await pumpPage(tester, api);

    expect(find.text('Accessory not described yet: Acme Bridge'), findsOneWidget);
    expect(find.text('Decode the video'), findsOneWidget);
    expect(find.byKey(const Key('dji_link_probes_halted')), findsOneWidget);
    expect(find.textContaining('Probing stopped; reading goes on.'), findsOneWidget);
  });

  testWidgets('counters, channels and frames are shown as they are', (tester) async {
    final api = FakeDjiLinkApi(
      snapshot: fakeSnapshot(
        counters: fakeCounters(unknownChannelFrames: 2, unknownChannelRejections: 3, headerCrcFailures: 5),
        crc: fakeCrc(headerSeedCandidate: 0x21, headerSeedVotes: 5, headerFailuresVoting: 6),
        channels: [
          DjiLinkChannel(
            channel: 22345,
            role: 'control',
            envelopes: 9,
            bytes: 300,
            largestPayload: 64,
            lastArrivalMs: 1000,
            firstArrivalMs: 900,
          ),
        ],
        frames: [
          DjiLinkFrame(
            atMs: 1000,
            channel: 22345,
            commandSet: 3,
            commandId: 67,
            isAcknowledgement: false,
            ackPolicy: 0,
            senderType: 3,
            receiverType: 2,
            sequence: 12,
            length: 20,
            encryption: 0,
            preview: '01 02 03',
          ),
        ],
        telemetry: [
          DjiLinkTelemetryRow(
            commandSet: 3,
            commandId: 67,
            count: 9,
            lastLength: 20,
            ratePerSecond: 10,
            preview: '01 02 03',
          ),
        ],
      ),
    );

    await pumpPage(tester, api);

    expect(find.byKey(const Key('dji_link_channels')), findsOneWidget);
    expect(find.byKey(const Key('dji_link_counters')), findsOneWidget);
    expect(find.textContaining('22345 control'), findsOneWidget);
    expect(find.text('Header checksum failures'), findsOneWidget);
    expect(find.text('5'), findsWidgets);
    expect(find.text('False sync patterns refused on an undescribed channel'), findsOneWidget);
    expect(find.text('3'), findsWidgets);
    expect(find.text('set 3 id 67'), findsOneWidget, reason: 'a telemetry row is its numbers, with no name');
    expect(find.textContaining('channel 22345, set 3 id 67, request'), findsOneWidget);
    expect(find.textContaining('Fields are read in the Flight and battery section'), findsOneWidget);
    expect(find.byKey(const Key('dji_link_crc')), findsOneWidget);
    expect(find.text('crc8-r8c-77 crc16-r8408-3692'), findsOneWidget);
    expect(find.text('0x21, 5 of 6 failures'), findsOneWidget);
  });

  testWidgets('with nothing captured the export writes the header alone and says so', (tester) async {
    final api = FakeDjiLinkApi(snapshot: fakeSnapshot(captureBytes: 0))
      ..exportResult = DjiLinkExport(
        ok: true,
        bytes: 0,
        headerPath: '/storage/emulated/0/Android/data/app/files/dji-link/dji-link-20261022-120000.json',
        sha256: 'e3b0c4',
        headerOnly: true,
      );

    await pumpPage(tester, api);

    expect(find.byKey(const Key('dji_link_capture_privacy')), findsOneWidget);
    final exportButton = find.byKey(const Key('dji_link_capture_export'));
    expect(tester.widget<FilledButton>(exportButton).onPressed, isNotNull);
    await tester.tap(exportButton);
    await tester.pumpAndSettle();

    expect(api.exports, hasLength(1));
    expect(find.byKey(const Key('dji_link_capture_header_only')), findsOneWidget);
    expect(find.textContaining('dji-link-20261022-120000.json'), findsOneWidget);
    expect(find.byKey(const Key('dji_link_capture_exported')), findsNothing);
  });

  testWidgets('a capture is exported with the note and shows where it went', (tester) async {
    final api = FakeDjiLinkApi(snapshot: fakeSnapshot(captureBytes: 0));

    await pumpPage(tester, api);

    final exportButton = find.byKey(const Key('dji_link_capture_export'));
    api.snapshotValue = fakeSnapshot(captureBytes: 4096);
    await tester.tap(find.byKey(const Key('dji_link_capture_start')));
    await tester.pumpAndSettle();
    expect(api.captureStarts, 1);

    await tester.enterText(find.byKey(const Key('dji_link_capture_notes')), 'props off, indoors');
    await tester.pumpAndSettle();
    await tester.tap(exportButton);
    await tester.pumpAndSettle();

    expect(api.exports.single.note, 'props off, indoors');
    expect(find.byKey(const Key('dji_link_capture_exported')), findsOneWidget);
    expect(find.textContaining('dji-link-20261022-120000.bin'), findsOneWidget);
    expect(find.textContaining('a1b2c3'), findsOneWidget);
  });

  testWidgets('a snapshot pushed by the native side reaches the page', (tester) async {
    final api = FakeDjiLinkApi();

    final listener = await pumpPage(tester, api);
    expect(listener, isNotNull);
    expect(find.text('Accessory open'), findsOneWidget);

    listener!.snapshotChanged(fakeSnapshot(state: DjiLinkState.aircraftLinked, firstByteMs: 120));
    await tester.pumpAndSettle();

    expect(find.text('Aircraft frames arrive'), findsOneWidget);
    expect(find.text('120 ms'), findsOneWidget);
  });

  testWidgets('the sticks are drawn and say why they are held at neutral', (tester) async {
    final api = FakeDjiLinkApi(
      snapshot: fakeSnapshot(
        sticks: fakeSticks(sampleAgeMs: 10, reasons: const ['LINK_NOT_LINKED', 'TRIGGERS_RELEASED']),
      ),
    );

    await pumpPage(tester, api);

    expect(find.byKey(const Key('dji_link_sticks')), findsOneWidget);
    expect(find.textContaining('the send path is off in this build'), findsOneWidget);
    expect(find.text('Held at neutral: no aircraft link, triggers released'), findsOneWidget);
    expect(find.text('Yaw and throttle'), findsOneWidget);
  });

  testWidgets('no sticks section until a gamepad was read', (tester) async {
    final api = FakeDjiLinkApi(snapshot: fakeSnapshot(sticks: fakeSticks()));

    await pumpPage(tester, api);

    expect(find.byKey(const Key('dji_link_sticks')), findsNothing);
    expect(find.text('Controller sticks'), findsNothing);
    expect(find.text('Roll and pitch'), findsNothing);
  });

  testWidgets('the video panel shows each state, the counters, the decoder and where the description came from', (
    tester,
  ) async {
    final states = {
      DjiLinkVideoState.waitingForVideo: 'Waiting for video from the remote.',
      DjiLinkVideoState.waitingForDescription:
          'Video arrives. Waiting for the description of the stream before decoding.',
      DjiLinkVideoState.building: 'Joined a running stream: the picture builds up over a few seconds.',
      DjiLinkVideoState.decoding: 'Decoding',
      DjiLinkVideoState.hidden: 'Decoding goes on while the panel is hidden.',
      DjiLinkVideoState.failed: 'This device could not decode the video (no-decoder).',
      DjiLinkVideoState.h264NotDecoded: 'H.264 video: recognised, not decoded in this version.',
    };
    final api = FakeDjiLinkApi(snapshot: fakeSnapshot(decode: fakeDecode()));
    final listener = await pumpPage(tester, api);

    for (final entry in states.entries) {
      listener!.snapshotChanged(
        fakeSnapshot(
          decode: fakeDecode(state: entry.key, failure: entry.key == DjiLinkVideoState.failed ? 'no-decoder' : null),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(entry.value), findsOneWidget, reason: '${entry.key}');
      // The privacy line goes with the panel whatever its state
      expect(find.byKey(const Key('dji_link_video_private')), findsOneWidget);
    }

    listener!.snapshotChanged(
      fakeSnapshot(decode: fakeDecode(switchReason: 'noOutputAfterJoin', keyPictureAgoMs: 2500, unitsDropped: 17)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Pictures dropped before the decoder'), findsOneWidget);
    expect(find.text('17'), findsOneWidget, reason: 'the pictures dropped before the decoder are counted on the page');
    expect(find.byKey(const Key('dji_link_video_placeholder')), findsOneWidget);
    expect(find.text('H.265, 1920 x 1080, Main High tier level 5.0'), findsOneWidget);
    expect(find.text('from the capture of 23 October 2026 (RC-N3 with Neo 2)'), findsOneWidget);
    expect(find.text('c2.android.hevc.decoder, software'), findsOneWidget);
    expect(find.text('336 in, 320 decoded, 300 shown, 20 skipped'), findsOneWidget);
    expect(find.text('last 6.1 ms, median 5.5 ms, 95 % 9.3 ms'), findsOneWidget);
    expect(find.text('2.5 s ago'), findsOneWidget);
    expect(find.byKey(const Key('dji_link_video_switch_reason')), findsOneWidget);
    expect(find.text('30 pictures/s, 4.8 Mbit/s, 5.5 ms'), findsOneWidget);

    await tester.tap(find.byKey(const Key('dji_link_video_choice_software')));
    await tester.pumpAndSettle();
    expect(api.choices, [DjiLinkDecoderChoice.software]);
  });

  testWidgets('the picture is drawn only while pictures come out of the decoder, black otherwise', (tester) async {
    final api = FakeDjiLinkApi(snapshot: fakeSnapshot(decode: fakeDecode(lastOutputAgoMs: null)));
    final listener = await pumpPage(tester, api);

    expect(find.byKey(const Key('dji_link_video_placeholder')), findsNothing);
    listener!.snapshotChanged(fakeSnapshot(decode: fakeDecode(lastOutputAgoMs: 120)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_link_video_placeholder')), findsOneWidget);
    // The stream stopped: no stale picture, and no transparent surface showing what was drawn before
    listener.snapshotChanged(fakeSnapshot(decode: fakeDecode(lastOutputAgoMs: 5000)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_link_video_placeholder')), findsNothing);
  });

  testWidgets('the flight and battery values come with their units, how they are known and the note', (tester) async {
    final api = FakeDjiLinkApi(snapshot: fakeSnapshot(telemetryValues: fakeTelemetry()));
    final listener = await pumpPage(tester, api);

    expect(find.byKey(const Key('dji_link_flight_note')), findsOneWidget);
    expect(find.text('-0.5 m'), findsOneWidget);
    expect(find.text('126.8 °'), findsOneWidget);
    expect(find.text('12, landing'), findsOneWidget);
    expect(find.text('38.7 s'), findsOneWidget);
    // Each label says how sure its value is (p2/telemetry-flight-2026-10-24.md, section 2)
    expect(find.text('Height above the take off point (likely)'), findsOneWidget);
    expect(find.text('Heading (zero not checked against north)'), findsOneWidget);
    expect(find.text('Flight mode (likely)'), findsOneWidget);
    expect(find.text('Speeds (likely)'), findsOneWidget);
    expect(find.text('Satellites (guess)'), findsOneWidget);
    expect(find.text('Distance below the drone (likely)'), findsOneWidget);
    // Which motor bit means in the air is a guess no capture settles: no row
    expect(find.text('In the air'), findsNothing);
    expect(find.text('38 %'), findsOneWidget);
    expect(find.text('6.180 V'), findsOneWidget);
    expect(find.text('-7.256 A'), findsOneWidget);
    expect(find.text('582 of 1525 mAh (the full capacity is likely)'), findsOneWidget);
    expect(find.text('Remote battery (likely)'), findsOneWidget);
    expect(find.text('aircraft side 90, remote side 90'), findsOneWidget);
    // How each group is known: our own captures, nothing else
    expect(find.text('our captures of 23 and 24 October'), findsWidgets);
    expect(find.textContaining('public'), findsNothing);
    expect(find.text('Body tilt, two angles (likely)'), findsOneWidget);
    expect(find.text('Signal (its scale is not known yet)'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('dji_link_link_group')),
        matching: find.text('our captures of 23 and 24 October'),
      ),
      findsOneWidget,
    );
    expect(find.text('119, 49 repeated'), findsOneWidget);
    expect(find.byKey(const Key('dji_link_stale')), findsNothing);

    listener!.snapshotChanged(fakeSnapshot(telemetryValues: fakeTelemetry(stale: true)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_link_stale')), findsOneWidget);
    expect(find.textContaining('no update for 4.2 s'), findsOneWidget);

    listener.snapshotChanged(fakeSnapshot());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_link_flight_note')), findsOneWidget, reason: 'the note stays in every state');
    expect(find.text('No flight data has arrived.'), findsOneWidget);
  });

  testWidgets('a stale remote battery says how old it is, and never "no update for 0.0 s"', (tester) async {
    DjiLinkTelemetry remoteOnly({int? ageMs}) => DjiLinkTelemetry(
      aircraftPresent: false,
      remotePresent: false,
      layoutMismatches: 0,
      unanswered: const [],
      remoteBatteryPercent: 50,
      remoteBatteryStale: true,
      remoteBatteryAgeMs: ageMs,
    );
    final api = FakeDjiLinkApi(snapshot: fakeSnapshot(telemetryValues: remoteOnly(ageMs: 6300)));
    final listener = await pumpPage(tester, api);

    expect(find.byKey(const Key('dji_link_remote_group')), findsOneWidget);
    expect(find.textContaining('no update for 6.3 s'), findsOneWidget);
    expect(find.byKey(const Key('dji_link_stale')), findsOneWidget);

    // An age the native side does not know is not shown as zero
    listener!.snapshotChanged(fakeSnapshot(telemetryValues: remoteOnly()));
    await tester.pumpAndSettle();
    expect(find.textContaining('no recent update'), findsOneWidget);
    expect(find.textContaining('0.0 s'), findsNothing);
  });

  testWidgets('"Your hardware" lists the starting profiles and binds the strings to one', (tester) async {
    final api = FakeDjiLinkApi(
      snapshot: fakeSnapshot(
        lastAccessory: DjiLinkAccessory(manufacturer: 'DJI', model: 'RC-N3 model string', description: 'remote'),
      ),
    );
    await pumpPage(tester, api);

    expect(find.byKey(const Key('dji_link_hardware')), findsOneWidget);
    expect(find.textContaining('RC-N3 model string'), findsOneWidget);
    expect(find.byKey(const Key('dji_link_usb_mode_hint')), findsOneWidget);
    await tester.tap(find.byKey(const Key('dji_link_hardware_choice')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('DJI RC-N3 with a Neo 2 and the Digital Transceiver').last);
    await tester.pumpAndSettle();
    expect(api.bindings, ['rc-n3-neo2']);
  });

  testWidgets('a capability answer names the device and flavour it was verified on, and is unknown elsewhere', (
    tester,
  ) async {
    // What the native side sends on a headset: the phone's answers are unknown here, with the phone they hold on
    final api = FakeDjiLinkApi(
      snapshot: fakeSnapshot(
        accessory: DjiLinkAccessory(manufacturer: 'DJI', model: 'RC-N3 model string'),
        profile: DjiLinkProfile(
          id: 'rc-n3-neo2',
          label: 'DJI RC-N3 with a Neo 2 and the Digital Transceiver',
          capabilities: [
            DjiLinkCapability(
              name: 'ACCESSORY_OPEN',
              support: DjiLinkSupport.unknown,
              provenance: 'dji-link-20261023-102731 (2026-10-23)',
              observedOn: 'Samsung SM-S926B, phone',
              observedDate: '2026-10-23',
            ),
            DjiLinkCapability(
              name: 'LINK_PROBE',
              support: DjiLinkSupport.supported,
              provenance: 'dji-link-20261023-102731 (2026-10-23)',
              observedOn: 'Samsung SM-S926B, phone',
              observedDate: '2026-10-23',
            ),
            DjiLinkCapability(
              name: 'VIDEO_DECODE',
              support: DjiLinkSupport.unknown,
              provenance: 'dji-link-20261023-102731 (2026-10-23)',
              observedDate: '2026-10-23',
            ),
            DjiLinkCapability(name: 'GIMBAL', support: DjiLinkSupport.unknown),
          ],
        ),
      ),
    );
    await pumpPage(tester, api);

    expect(
      find.text('unknown, not verified on this device, only on Samsung SM-S926B, phone (2026-10-23)'),
      findsOneWidget,
    );
    expect(find.text('supported, verified on Samsung SM-S926B, phone, 2026-10-23'), findsOneWidget);
    expect(
      find.text('unknown, observed offline in dji-link-20261023-102731 (2026-10-23), on no device yet'),
      findsOneWidget,
    );
    expect(find.textContaining('observed on'), findsNothing);
  });

  testWidgets('without any accessory strings there is nothing to bind', (tester) async {
    await pumpPage(tester, FakeDjiLinkApi());

    expect(find.byKey(const Key('dji_link_hardware_choice')), findsNothing);
    expect(find.text('No accessory strings have been read yet: plug the remote in first.'), findsOneWidget);
  });

  testWidgets('the bench chips fill the header of the export', (tester) async {
    final api = FakeDjiLinkApi(snapshot: fakeSnapshot(captureBytes: 4096));
    await pumpPage(tester, api);

    expect(find.text('The first 4 MiB of a session are kept, and the last 16 MiB.'), findsOneWidget);
    expect(find.textContaining('the video of the drone'), findsOneWidget);
    for (final chip in ['cable_original', 'port_top', 'remote_on', 'aircraft_motorsOff']) {
      await tester.tap(find.byKey(Key('dji_link_bench_$chip')));
      await tester.pumpAndSettle();
    }
    // A second tap takes a chip off again
    await tester.tap(find.byKey(const Key('dji_link_bench_port_bottom')));
    await tester.tap(find.byKey(const Key('dji_link_bench_port_bottom')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('dji_link_capture_export')));
    await tester.pumpAndSettle();

    final notes = api.exports.single;
    expect(notes.cable, 'original');
    expect(notes.port, isNull);
    expect(notes.remoteState, 'on');
    expect(notes.aircraftState, 'motorsOff');
  });

  testWidgets('a capture of the list plays from the second asked, and stops', (tester) async {
    final api = FakeDjiLinkApi(snapshot: fakeSnapshot(state: DjiLinkState.absent))..captures = [fakeExport20261023];
    final listener = await pumpPage(tester, api);

    expect(find.text('dji-link-20261023-102731'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('dji_link_play_start_at')), '1.5');
    await tester.tap(find.byKey(const Key('dji_link_play_dji-link-20261023-102731')));
    await tester.pumpAndSettle();
    expect(api.played, [('content://media/external/downloads/101', 1500)]);

    listener!.snapshotChanged(
      fakeSnapshot(
        state: DjiLinkState.absent,
        source: DjiLinkSource(replay: true, playing: true, name: 'dji-link-20261023-102731', positionMs: 3200),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Playing dji-link-20261023-102731, 3.2 s'), findsOneWidget);
    await tester.tap(find.byKey(const Key('dji_link_play_stop')));
    await tester.pumpAndSettle();
    expect(api.playbackStops, 1);
  });

  testWidgets('files chosen in the picker play, and a pair that does not match is said', (tester) async {
    final api = FakeDjiLinkApi(snapshot: fakeSnapshot(state: DjiLinkState.absent));
    await pumpPage(tester, api);

    expect(find.byKey(const Key('dji_link_play_none')), findsOneWidget);
    await tester.tap(find.byKey(const Key('dji_link_play_choose')));
    await tester.pumpAndSettle();
    expect(api.pickerOpens, 1);
    expect(find.text('Choose a .bin file and the .idx.csv file of the same capture.'), findsOneWidget);

    api.chosen = fakeExport20261023;
    await tester.tap(find.byKey(const Key('dji_link_play_choose')));
    await tester.pumpAndSettle();
    expect(api.played.single.$1, 'content://media/external/downloads/101');
  });

  testWidgets('a damaged or oversize capture is refused with its reason, and a failed playback says where it stopped', (
    tester,
  ) async {
    final api = FakeDjiLinkApi(snapshot: fakeSnapshot(state: DjiLinkState.absent))
      ..captures = [fakeExport20261023]
      ..playOutcome = 'damaged';
    final listener = await pumpPage(tester, api);

    await tester.tap(find.byKey(const Key('dji_link_play_dji-link-20261023-102731')));
    await tester.pumpAndSettle();
    expect(find.textContaining('has lines that do not fit its file, so it was not played'), findsOneWidget);

    api.playOutcome = 'tooLarge';
    await tester.tap(find.byKey(const Key('dji_link_play_dji-link-20261023-102731')));
    await tester.pumpAndSettle();
    expect(find.textContaining('larger than 64 MB, so it was not played'), findsOneWidget);

    listener!.snapshotChanged(
      fakeSnapshot(
        state: DjiLinkState.absent,
        source: DjiLinkSource(
          replay: true,
          playing: false,
          name: 'dji-link-20261023-102731',
          positionMs: 4100,
          failure: 'IllegalArgumentException',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(
        'dji-link-20261023-102731 stopped at 4.1 s on an error (IllegalArgumentException). The capture may be damaged.',
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('dji_link_playing')),
      findsNothing,
      reason: 'a failed playback did not play to its end',
    );
  });

  testWidgets('a capture is not played while a remote holds the cable', (tester) async {
    final api = FakeDjiLinkApi(snapshot: fakeSnapshot(state: DjiLinkState.aircraftLinked))
      ..captures = [fakeExport20261023];
    await pumpPage(tester, api);

    expect(find.byKey(const Key('dji_link_play_busy')), findsOneWidget);
    final play = tester.widget<IconButton>(find.byKey(const Key('dji_link_play_dji-link-20261023-102731')));
    expect(play.onPressed, isNull);
    final choose = tester.widget<OutlinedButton>(find.byKey(const Key('dji_link_play_choose')));
    expect(choose.onPressed, isNull);
  });

  testWidgets('a catalogued message is named in the identifier table', (tester) async {
    final api = FakeDjiLinkApi(
      snapshot: fakeSnapshot(
        telemetry: [
          DjiLinkTelemetryRow(
            commandSet: 3,
            commandId: 67,
            count: 113,
            lastLength: 85,
            ratePerSecond: 10,
            preview: '00 00',
            name: 'flightData',
          ),
        ],
      ),
    );
    await pumpPage(tester, api);

    expect(find.text('set 3 id 67 flight data'), findsOneWidget);
  });

  group('the DJI live video row of the Drone page', () {
    /// The tile on an Android device with the setting [enabled], in the TV layout when [tv]
    List<Override> android({bool enabled = true, bool tv = false}) => [
      appConfigProvider.overrideWithValue(AppConfig(djiLinkEnabled: enabled)),
      tvModeProvider.overrideWithValue(tv),
    ];

    Future<bool> shownOnAndroid(WidgetTester tester, List<Override> overrides) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await tester.pumpTestWidget(
          context,
          const Scaffold(body: Column(children: [DjiLinkTile()])),
          overrides: overrides,
        );
        await tester.pumpAndSettle();
        return find.byKey(const Key('dji_link_tile')).evaluate().isNotEmpty;
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    testWidgets('shows on an Android device with the default settings, untouched', (tester) async {
      expect(
        await shownOnAndroid(tester, [
          appConfigProvider.overrideWithValue(const AppConfig()),
          tvModeProvider.overrideWithValue(false),
        ]),
        isTrue,
      );
      expect(find.text('DJI live video'), findsOneWidget);
      expect(find.text('Plug your DJI remote into this phone and see what the drone sees'), findsOneWidget);
    });

    testWidgets('is offered on a headset too, whose Drone card opens the watch page directly', (tester) async {
      expect(
        await shownOnAndroid(tester, [...android(), isHorizonOsProvider.overrideWith((ref) async => true)]),
        isTrue,
      );
      expect(find.text('DJI live video'), findsOneWidget);
      expect(find.text("Watch the drone's picture your phone sends"), findsNothing);
    });

    testWidgets('is hidden with the setting off', (tester) async {
      expect(await shownOnAndroid(tester, android(enabled: false)), isFalse);
    });

    testWidgets('is hidden in the TV layout whatever the setting', (tester) async {
      expect(await shownOnAndroid(tester, android(tv: true)), isFalse);
    });

    testWidgets('is hidden off Android whatever the setting', (tester) async {
      // Under flutter test the target platform is Android unless it is said otherwise, so a computer is said here
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        await tester.pumpTestWidget(
          context,
          const Scaffold(body: Column(children: [DjiLinkTile()])),
          overrides: [
            appConfigProvider.overrideWithValue(const AppConfig(djiLinkEnabled: true)),
            tvModeProvider.overrideWithValue(false),
          ],
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('dji_link_tile')), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('stage 2b, a headset receiving from a phone', () {
    FakeDjiLinkApi headsetApi() => FakeDjiLinkApi(environment: fakeEnvironment(accessoryFeature: false));

    testWidgets('always shows the observer note and watching only, and where the reception stands', (tester) async {
      final relay = FakeRelayEnvironment();
      await pumpPage(tester, headsetApi(), relay: relay, horizonOs: true);

      expect(find.byKey(const Key('dji_link_safety')), findsOneWidget);
      expect(find.byKey(const Key('dji_link_observer')), findsOneWidget);
      expect(
        find.text(
          'Flying with a headset on: in the EU open category, an observer standing next to you must keep the drone '
          'in sight and warn you. Without one, do not fly with the headset on.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Watching only: nothing on this headset reaches the drone; the remote in your hands flies it.'),
        findsOneWidget,
      );
      // The watch page is where a phone is chosen: here the state only, and no flight view button
      expect(find.byKey(const Key('dji_link_receive_state')), findsOneWidget);
      expect(find.text('Not receiving.'), findsOneWidget);
      expect(find.byKey(const Key('dji_link_flight_view_open')), findsNothing);
      // A headset does not send: no "Send to a headset" on the Quest flavour
      expect(find.byKey(const Key('dji_link_send')), findsNothing);
    });

    testWidgets('words every state of the receiver', (tester) async {
      final api = headsetApi();
      final listener = await pumpPage(tester, api);
      final expected = {
        DjiRelayReceiveState.connecting: 'Connecting to Galaxy S24+',
        DjiRelayReceiveState.checkingCode: 'Checking the code',
        DjiRelayReceiveState.receiving: 'Receiving from Galaxy S24+: a capture, dji-link-20261023-102731 at 4.1 s',
        DjiRelayReceiveState.lost: 'Connection lost, trying again in 1.5 s',
        DjiRelayReceiveState.wrongCode: 'The code does not match: type it again.',
        DjiRelayReceiveState.full: 'This phone already sends to four headsets. Trying again every 10 s.',
        DjiRelayReceiveState.blocked: 'Too many wrong codes from this headset: wait a minute.',
        DjiRelayReceiveState.otherVersion: 'The phone runs another version of Immuch360: update both.',
        DjiRelayReceiveState.phoneUnproven: 'This phone did not prove the code: nothing it sends is shown.',
        DjiRelayReceiveState.busy: "A remote is open on this device's cable: unplug it to receive from a phone.",
        DjiRelayReceiveState.idle: 'Not receiving.',
      };
      for (final MapEntry(key: state, value: text) in expected.entries) {
        listener!.snapshotChanged(fakeSnapshot(relayReceiving: fakeReceiving(state: state, reconnectInMs: 1500)));
        await tester.pumpAndSettle();
        expect(find.text(text), findsOneWidget, reason: state.name);
      }
      listener!.snapshotChanged(fakeSnapshot(relayReceiving: fakeReceiving(phoneSource: 'cable')));
      await tester.pumpAndSettle();
      expect(find.text('Receiving from Galaxy S24+: live from the remote'), findsOneWidget);
      listener.snapshotChanged(fakeSnapshot(relayReceiving: fakeReceiving(phoneSource: 'none')));
      await tester.pumpAndSettle();
      expect(find.text('Connected to Galaxy S24+: the phone lost the remote, or plays nothing.'), findsOneWidget);
    });

    testWidgets('shows the delay from the phone, and a red line once the picture stopped', (tester) async {
      final listener = await pumpPage(tester, headsetApi());
      listener!.snapshotChanged(fakeSnapshot(decode: fakeDecode(), relayReceiving: fakeReceiving()));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('dji_link_latency')), findsOneWidget);
      expect(
        find.text('Phone to headset: 14 ms (phone 1 ms, network 13 ms; 95 %: 22 ms; clocks within 2 ms)'),
        findsOneWidget,
      );
      expect(find.textContaining('c2.android.hevc.decoder, low latency'), findsOneWidget);
      expect(find.textContaining('Decoding here: '), findsOneWidget);
      expect(find.text('Phone receive to decoder output here: 24 ms (display not included)'), findsOneWidget);
      expect(find.text('Behind the phone screen by about 15 ms'), findsOneWidget);
      expect(
        find.text('Pictures per second: 30 received, 30 decoded, 29 shown; lost on the Wi-Fi 0, on the radio 0'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('dji_link_latency_stale')), findsNothing);

      listener.snapshotChanged(
        fakeSnapshot(
          decode: fakeDecode(lastOutputAgoMs: 900),
          relayReceiving: fakeReceiving(lastPictureAgoMs: 900, lostOnWifi: 12, relayDelayMedianMs: null),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('No new picture for 0.9 s'), findsOneWidget);
      expect(find.text('Phone to headset: measuring the clocks'), findsOneWidget);
      expect(find.byKey(const Key('dji_link_latency_wifi_slow')), findsOneWidget);

      // After 2 s the picture is hidden: never a frozen picture that looks live
      listener.snapshotChanged(
        fakeSnapshot(decode: fakeDecode(lastOutputAgoMs: 2100), relayReceiving: fakeReceiving(lastPictureAgoMs: 2100)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dji_link_video_placeholder')), findsNothing);
    });

    testWidgets('a picture of the relay that does not come any more is black, whatever the decoder last said', (
      tester,
    ) async {
      // A headset: its link never starts, so no remote holds a cable there
      final listener = await pumpPage(tester, headsetApi(), horizonOs: true);
      final receivingSource = DjiLinkSource(replay: false, playing: false, relay: true, phoneName: 'Galaxy S24+');
      listener!.snapshotChanged(
        fakeSnapshot(
          state: DjiLinkState.absent,
          decode: fakeDecode(),
          relayReceiving: fakeReceiving(),
          source: receivingSource,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dji_link_video_placeholder')), findsOneWidget);

      // "New code" on the phone: the reception ended on its own, with a picture out of the decoder 300 ms ago
      final ended = DjiLinkSource(replay: false, playing: false, relay: false);
      listener.snapshotChanged(
        fakeSnapshot(
          state: DjiLinkState.absent,
          decode: fakeDecode(lastOutputAgoMs: 300),
          relayReceiving: fakeReceiving(state: DjiRelayReceiveState.wrongCode),
          source: ended,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dji_link_video_placeholder')), findsNothing);
      expect(find.text('The code does not match: type it again.'), findsOneWidget);

      // A lost connection is not live either
      listener.snapshotChanged(
        fakeSnapshot(
          state: DjiLinkState.absent,
          decode: fakeDecode(lastOutputAgoMs: 300),
          relayReceiving: fakeReceiving(state: DjiRelayReceiveState.lost, reconnectInMs: 500),
          source: receivingSource,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dji_link_video_placeholder')), findsNothing);

      // A capture played here afterwards owns the picture again
      listener.snapshotChanged(
        fakeSnapshot(
          state: DjiLinkState.absent,
          decode: fakeDecode(),
          relayReceiving: fakeReceiving(state: DjiRelayReceiveState.wrongCode),
          source: DjiLinkSource(replay: true, playing: true, relay: false, name: 'dji-link-20261023-102731'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dji_link_video_placeholder')), findsOneWidget);
    });
  });

  group('stage 2b, a page that closes while a start or a connect waits', () {
    ProviderContainer containerOf(FakeDjiLinkApi api, FakeRelayEnvironment relay) {
      final container = ProviderContainer(
        overrides: [
          djiLinkApiProvider.overrideWithValue(api),
          djiRelayEnvironmentProvider.overrideWithValue(relay.build()),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('a start the page left before the relay was asked for starts nothing', () async {
      final api = FakeDjiLinkApi(environment: fakeEnvironment(flavour: 'phone'));
      final relay = FakeRelayEnvironment()..nameGate = Completer<String>();
      final container = containerOf(api, relay);
      final notifier = container.read(djiRelayProvider.notifier);
      await notifier.setPageVisible(true);

      final starting = notifier.startSending();
      await Future<void>.delayed(Duration.zero);
      expect(container.read(djiRelayProvider).starting, isTrue);
      await notifier.setPageVisible(false);
      relay.nameGate!.complete('Galaxy S24+');
      await starting;

      expect(api.relayStarts, isEmpty);
      expect(relay.announced, isEmpty);
      expect(container.read(djiRelayProvider).starting, isFalse);
      expect(container.read(djiRelayProvider).sending, isFalse);
    });

    test('a connect the page left while the name was read starts no receiver', () async {
      final api = FakeDjiLinkApi(environment: fakeEnvironment(accessoryFeature: false));
      final relay = FakeRelayEnvironment()..nameGate = Completer<String>();
      final container = containerOf(api, relay);
      final notifier = container.read(djiRelayProvider.notifier);
      await notifier.setPageVisible(true);

      final connecting = notifier.connect(
        const DjiRelayPhone(name: 'Galaxy S24+', host: '192.168.1.21', port: 8362, id: '3f9c0a1b2c3d4e5f'),
        'K7M2Q9XRTH',
      );
      await notifier.setPageVisible(false);
      relay.nameGate!.complete('Quest 3');
      await connecting;

      expect(api.connects, isEmpty);
      expect(container.read(djiRelayProvider).target, isNull);
    });

    test('a start that goes on while the page is shown asks the relay as before', () async {
      final api = FakeDjiLinkApi(environment: fakeEnvironment(flavour: 'phone'));
      final relay = FakeRelayEnvironment()..nameGate = Completer<String>();
      final container = containerOf(api, relay);
      final notifier = container.read(djiRelayProvider.notifier);
      await notifier.setPageVisible(true);

      final starting = notifier.startSending();
      relay.nameGate!.complete('Galaxy S24+');
      await starting;

      expect(api.relayStarts, hasLength(1));
      expect(container.read(djiRelayProvider).sending, isTrue);
    });
  });

  group('stage 2b, a phone sending to headsets', () {
    FakeDjiLinkApi phoneApi() => FakeDjiLinkApi(environment: fakeEnvironment(flavour: 'phone'));

    testWidgets('the switch starts the relay with a code in two groups, the addresses and the announcement', (
      tester,
    ) async {
      final relay = FakeRelayEnvironment();
      final api = phoneApi();
      final listener = await pumpPage(tester, api, relay: relay);

      expect(find.byKey(const Key('dji_link_send')), findsOneWidget);
      expect(find.byKey(const Key('dji_link_relay_not_encrypted')), findsOneWidget);
      await tester.tap(find.byKey(const Key('dji_link_relay_switch')));
      await tester.pumpAndSettle();

      final start = api.relayStarts.single;
      expect(start.code, 'K7M2Q9XRTH');
      expect(start.phoneName, 'Galaxy S24+');
      expect(start.phoneId, '3f9c0a1b2c3d4e5f');
      expect(start.notificationTitle, 'DJI live video: sending');
      expect(start.channelName, 'DJI live video, send to a headset');
      expect(relay.secrets['dji_relay_code'], 'K7M2Q9XRTH');
      expect(relay.notificationAsks, 1);
      expect(find.text('K7M2Q 9XRTH'), findsOneWidget);
      expect(find.text('192.168.1.23:8362'), findsOneWidget);
      expect(find.text("192.168.43.1:8362 (this phone's hotspot)"), findsOneWidget);
      // Announced under the app's own pairing type with kind=drone: no third service type
      final (name, port, attributes) = relay.announced.single;
      expect(name, 'Immuch360 on Galaxy S24+');
      expect(port, 8362);
      expect(attributes, fakeDroneTxt);
      // The screen is kept on while the page is in front and sending
      expect(relay.screen.last, isTrue);

      listener!.snapshotChanged(fakeSnapshot(relaySending: fakeSending()));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Sending nothing yet: plug the remote or play a capture. With nothing to send and no headset, sending stops '
          'by itself after 10 minutes.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('dji_link_relay_headsets_none')), findsOneWidget);

      listener.snapshotChanged(
        fakeSnapshot(
          relaySending: fakeSending(
            sending: 'replay',
            headsets: [
              DjiRelayHeadsetRow(
                address: '192.168.1.40',
                name: 'Quest 3',
                connectedForMs: 75000,
                picturesShownPerSecond: 30,
                relayDelayMs: 14.2,
                droppedUnits: 0,
                megabitsPerSecond: 5.6,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Sending the capture being played'), findsOneWidget);
      expect(find.text('Quest 3, 192.168.1.40, connected for 1:15'), findsOneWidget);
      expect(
        find.text(
          'Shows 30 pictures per second, received 14 ms after this phone received them; 0 pictures dropped for it; '
          '5.6 Mbit/s',
        ),
        findsOneWidget,
      );
      expect(
        api.notifications.last,
        'Sending the drone\'s picture to 1 screen. With nothing to send and no screen, it stops by itself after '
        '10 minutes.',
      );

      await tester.tap(find.byKey(const Key('dji_link_relay_new_code')));
      await tester.pumpAndSettle();
      expect(api.relayCodes, ['ABCDEFGHJK']);
      expect(find.text('ABCDE FGHJK'), findsOneWidget);

      await tester.tap(find.byKey(const Key('dji_link_relay_keep_screen_on')));
      await tester.pumpAndSettle();
      expect(relay.screen.last, isFalse);

      await tester.tap(find.byKey(const Key('dji_link_relay_switch')));
      await tester.pumpAndSettle();
      expect(api.relayStops, 1);
      expect(relay.announcementsStopped, 1);
      expect(find.byKey(const Key('dji_link_relay_code')), findsNothing);
    });

    testWidgets('Stop in the notification stops the announcement', (tester) async {
      final relay = FakeRelayEnvironment();
      final api = phoneApi();
      final listener = await pumpPage(tester, api, relay: relay);
      await tester.tap(find.byKey(const Key('dji_link_relay_switch')));
      await tester.pumpAndSettle();
      expect(relay.announced, hasLength(1));

      listener!.relayStopRequested();
      await tester.pumpAndSettle();
      expect(relay.announcementsStopped, 1);
      expect(relay.screen.last, isFalse);
      expect(find.byKey(const Key('dji_link_relay_code')), findsNothing);
      expect(api.relayStops, 0, reason: 'the native side stopped the relay itself');
    });

    testWidgets('says so when the relay could not start', (tester) async {
      final api = phoneApi()..relayPort = 0;
      await pumpPage(tester, api);
      await tester.tap(find.byKey(const Key('dji_link_relay_switch')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dji_link_relay_start_failed')), findsOneWidget);
      expect(find.byKey(const Key('dji_link_relay_code')), findsNothing);
    });

    testWidgets('a phone without the accessory feature sends a played capture, and hides it while it receives', (
      tester,
    ) async {
      final api = FakeDjiLinkApi(
        environment: fakeEnvironment(accessoryFeature: false, flavour: 'phone'),
        snapshot: fakeSnapshot(state: DjiLinkState.unsupportedTransport),
      )..captures = [fakeExport20261023];
      final listener = await pumpPage(tester, api);
      expect(find.byKey(const Key('dji_link_send')), findsOneWidget);
      expect(find.byKey(const Key('dji_link_receive_state')), findsOneWidget);

      // Play in a loop
      await tester.tap(find.byKey(const Key('dji_link_play_loop')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('dji_link_play_dji-link-20261023-102731')));
      await tester.pumpAndSettle();
      expect(api.loops.single, isTrue);

      listener!.snapshotChanged(
        fakeSnapshot(
          source: DjiLinkSource(replay: false, playing: false, relay: true, phoneName: 'Galaxy S24+'),
          relayReceiving: fakeReceiving(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dji_link_send')), findsNothing);
    });
  });

  group('a headset saves what it received', () {
    testWidgets('the capture section gives way to a sentence and "Save a reception record", with its toast', (
      tester,
    ) async {
      // The Quest lists the accessory feature: the remote is still on the phone
      final api = FakeDjiLinkApi(environment: fakeEnvironment());
      await pumpPage(tester, api, horizonOs: true);
      expect(find.byKey(const Key('dji_link_capture_start')), findsNothing);
      expect(find.byKey(const Key('dji_link_capture_export')), findsNothing);
      expect(
        find.text(
          'On a headset the remote is on the phone: save the capture there. Here, a reception record says what this '
          'headset received and how it decoded it.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Keep the files to yourself.'), findsWidgets);

      await tester.tap(find.byKey(const Key('dji_link_save_record')));
      await tester.pumpAndSettle();
      expect(api.receptionExports, 1);
      expect(find.text('Saved in Download/Immuch360/dji-link: dji-relay-20261024-171200'), findsWidgets);

      api.receptionResult = DjiLinkExport(
        ok: true,
        bytes: 2048,
        binPath: 'Download/Immuch360/dji-link/dji-relay-20261024-171200.bin',
        repeated: true,
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('dji_link_save_record')));
      await tester.pumpAndSettle();
      expect(find.text('Already saved: dji-relay-20261024-171200'), findsWidgets);
    });

    testWidgets('a phone keeps its capture section', (tester) async {
      await pumpPage(tester, FakeDjiLinkApi(environment: fakeEnvironment(flavour: 'phone')));
      expect(find.byKey(const Key('dji_link_capture_export')), findsOneWidget);
      expect(find.byKey(const Key('dji_link_save_record')), findsNothing);
    });

    testWidgets('a headset without the accessory feature can save it too', (tester) async {
      final api = FakeDjiLinkApi(environment: fakeEnvironment(accessoryFeature: false));
      await pumpPage(tester, api, horizonOs: true);
      api.receptionResult = DjiLinkExport(ok: true, bytes: 0, nothing: true);
      await tester.tap(find.byKey(const Key('dji_link_save_record')));
      await tester.pumpAndSettle();
      expect(find.text('Nothing received yet: nothing to save.'), findsWidgets);
    });
  });
}
