// "Relay quality" and the lines of the steady stream (p2/relay-bandwidth-2026-10-25.md, 7.9 and 7.10): the three
// choices in Advanced with the one the native side keeps, the host call when one is picked, the steady stream's line or
// why there is none, and each receiver's stream and link. Nothing is shown that the native side did not say.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_latency.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_relay_quality.widget.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';
import 'package:immich_mobile/providers/drone/dji_relay.provider.dart';

import '../../../unit/presentation/presentation_context.dart';
import '../../pages/drone/dji_link_fakes.dart';

DjiRelaySending steadySending({
  String? state = 'running',
  String? why,
  DjiRelayQuality quality = DjiRelayQuality.automatic,
  List<DjiRelayHeadsetRow> headsets = const [],
  bool on = true,
}) => DjiRelaySending(
  on: on,
  port: 8362,
  sending: 'cable',
  headsets: headsets,
  refusedProofs: 0,
  unexpectedRecords: 0,
  wifiLowLatencyHeld: true,
  unitsDropped: 0,
  quality: quality,
  steadyState: state,
  steadyWhy: why,
  steadyEncoder: 'c2.exynos.hevc.encoder',
  steadyWidth: 1920,
  steadyHeight: 1080,
  steadyPerSecond: 30,
  steadyMegabits: 4.2,
  steadyEncodeMedianMs: 14.4,
  steadyEncodeP95Ms: 22.6,
  droneMegabits: 17.9,
);

DjiRelayHeadsetRow salon({String? stream = 'steady', bool? capable = true, int? streamForMs = 135000}) =>
    DjiRelayHeadsetRow(
      address: '192.168.0.142',
      name: 'Salon 2',
      connectedForMs: 300000,
      droppedUnits: 0,
      megabitsPerSecond: 4.4,
      kind: 'tv',
      stream: stream,
      steadyCapable: capable,
      streamForMs: streamForMs,
      bestSecondMegabits: 9.4,
      allowedMegabits: 4.0,
      wifiBand: '5',
      wifiLinkMbps: 433,
      wifiRssi: -63,
    );

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  Future<Translations> english(WidgetTester tester) async {
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
    return t;
  }

  testWidgets('the steady stream line: running with its numbers, ready, or why there is none', (tester) async {
    final t = await english(tester);
    expect(
      djiRelaySteadyLine(t, steadySending()),
      'Steady stream: c2.exynos.hevc.encoder, 1920x1080, 30 per second, 4.2 Mbit/s now, encoding 14 ms (95 %: 23 ms)',
    );
    expect(djiRelaySteadyLine(t, steadySending(state: 'standby')), 'Steady stream ready: c2.exynos.hevc.encoder');
    expect(
      djiRelaySteadyLine(t, steadySending(state: 'unavailable', why: 'noEncoder')),
      'No steady stream on this phone: no H.265 encoder',
    );
    expect(
      djiRelaySteadyLine(t, steadySending(state: 'unavailable', why: 'noSecondDecoder')),
      'No steady stream on this phone: no second decoder',
    );
    expect(
      djiRelaySteadyLine(t, steadySending(state: 'stopped', why: 'pilotFirst')),
      "Steady stream stopped: the pilot's picture first",
    );
    expect(
      djiRelaySteadyLine(t, steadySending(state: 'stopped', why: 'decoderTooSlow')),
      'Steady stream stopped: the second decoder was too slow',
    );
    expect(
      djiRelaySteadyLine(t, steadySending(state: 'stopped', why: 'hot')),
      'Steady stream paused: the phone is hot',
    );
    // Nothing while the relay is off, or from a phone that has nothing to describe
    expect(djiRelaySteadyLine(t, steadySending(on: false)), isNull);
    expect(djiRelaySteadyLine(t, steadySending(state: null)), isNull);
    expect(djiRelaySteadyLine(t, null), isNull);
  });

  testWidgets("each receiver's stream and its link", (tester) async {
    final t = await english(tester);
    expect(
      djiRelayReceiverStream(t, salon(), DjiRelayQuality.automatic),
      'Steady stream for 2:15: the Wi-Fi could not keep up',
    );
    expect(
      djiRelayReceiverStream(t, salon(), DjiRelayQuality.steady),
      'Steady stream for 2:15: chosen in Relay quality',
    );
    expect(djiRelayReceiverStream(t, salon(stream: 'full'), DjiRelayQuality.automatic), 'Full stream');
    expect(
      djiRelayReceiverStream(t, salon(stream: 'full', capable: false), DjiRelayQuality.steady),
      'Full stream (earlier build)',
    );
    expect(djiRelayLinkLines(t, salon(), 17.9), [
      'Salon 2: the Wi-Fi carries 4.4 Mbit/s (best second 9.4), the drone sends 17.9 Mbit/s',
      'Its Wi-Fi: 5 GHz, 433 Mbit/s, -63 dBm',
    ]);
    // A receiver of an earlier build says nothing of its Wi-Fi
    final earlier = DjiRelayHeadsetRow(
      address: '192.168.1.40',
      name: 'Quest 3',
      connectedForMs: 5000,
      droppedUnits: 0,
      megabitsPerSecond: 17.6,
    );
    expect(djiRelayLinkLines(t, earlier, null), [
      'Quest 3: the Wi-Fi carries 17.6 Mbit/s (best second -), the drone sends - Mbit/s',
    ]);
    expect(djiRelayQualityName(t, DjiRelayQuality.full), 'Full stream');
    expect(
      djiRelayQualityNote(t, DjiRelayQuality.automatic),
      "The drone's picture while the Wi-Fi keeps up, the phone's steady picture when it cannot. On by default.",
    );
  });

  testWidgets('a TV or a headset says when the picture is the phone\'s steady one', (tester) async {
    final t = await english(tester);
    final steady = fakeReceiving(steady: true, streamSwitches: 1);
    final paced = DjiRelayReceiving(
      state: steady.state,
      phoneSource: steady.phoneSource,
      replay: steady.replay,
      failures: steady.failures,
      units: steady.units,
      lostOnWifi: steady.lostOnWifi,
      receivedPerSecond: steady.receivedPerSecond,
      decodedPerSecond: steady.decodedPerSecond,
      shownPerSecond: steady.shownPerSecond,
      lostOnRadio: steady.lostOnRadio,
      paced: true,
      steady: true,
      streamSwitches: 1,
    );
    expect(djiLinkSmoothnessLines(t, paced).first, "From the phone's encoder, 30 per second");
    expect(t.dji_watch_steady_switch, 'Steady picture from the phone: the Wi-Fi could not carry the full one');
  });

  testWidgets('Relay quality: three choices, the one the native side keeps, and the host call when one is picked', (
    tester,
  ) async {
    final api = FakeDjiLinkApi(environment: fakeEnvironment(flavour: 'phone'))
      ..relayQualityValue = DjiRelayQuality.full;
    await tester.pumpTestWidget(
      context,
      const Material(child: SingleChildScrollView(child: DjiRelayQualitySection())),
      overrides: [
        djiLinkApiProvider.overrideWithValue(api),
        djiRelayEnvironmentProvider.overrideWithValue(FakeRelayEnvironment().build()),
      ],
    );
    await tester.pumpAndSettle();
    expect(find.text('Relay quality'), findsOneWidget);
    for (final choice in DjiRelayQuality.values) {
      expect(find.byKey(Key('dji_relay_quality_${choice.name}')), findsOneWidget);
    }
    expect(find.text('Automatic'), findsOneWidget);
    expect(find.text('Full stream'), findsOneWidget);
    expect(find.text('Steady stream'), findsOneWidget);
    expect(
      find.text('The phone encodes the picture again for the Wi-Fi: less detail, no lost pictures.'),
      findsOneWidget,
    );
    RadioGroup<DjiRelayQuality> group() => tester.widget(find.byType(RadioGroup<DjiRelayQuality>));
    // The choice the native side keeps
    expect(group().groupValue, DjiRelayQuality.full);
    await tester.tap(find.byKey(const Key('dji_relay_quality_steady')));
    await tester.pumpAndSettle();
    expect(api.relayQualities, [DjiRelayQuality.steady]);
    expect(group().groupValue, DjiRelayQuality.steady);
    await tester.tap(find.byKey(const Key('dji_relay_quality_automatic')));
    await tester.pumpAndSettle();
    expect(api.relayQualities, [DjiRelayQuality.steady, DjiRelayQuality.automatic]);

    // While sending: the steady stream's line and each receiver's stream and link
    expect(find.byKey(const Key('dji_relay_quality_streams')), findsNothing);
    final container = ProviderScope.containerOf(tester.element(find.byType(DjiRelayQualitySection)));
    container
        .read(djiLinkProvider.notifier)
        .snapshotChanged(fakeSnapshot(relaySending: steadySending(headsets: [salon()])));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dji_relay_quality_steady_line')), findsOneWidget);
    expect(find.text('Salon 2: Steady stream for 2:15: the Wi-Fi could not keep up'), findsOneWidget);
    expect(
      find.text('Salon 2: the Wi-Fi carries 4.4 Mbit/s (best second 9.4), the drone sends 17.9 Mbit/s'),
      findsOneWidget,
    );
    expect(find.text('Its Wi-Fi: 5 GHz, 433 Mbit/s, -63 dBm'), findsOneWidget);
  });
}
