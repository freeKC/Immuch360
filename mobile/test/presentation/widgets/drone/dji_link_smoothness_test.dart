// The Diagnostics rows of the relay's smoothness (relay-smoothness 6.1 and 6.2): on a receiver, its jitter buffer,
// what came late or was not shown, the freezes and its network; on the phone, each receiver's queue and what its long
// pings say of its screen. Nothing is shown that the native side did not measure.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_latency.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_send.widget.dart';

import '../../../unit/presentation/presentation_context.dart';
import '../../pages/drone/dji_link_fakes.dart';

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

  DjiRelayReceiving paced({
    int freezes = 0,
    String? network = 'wifi',
    double? longestFreezeMs,
    int freezesInSource = 0,
  }) {
    final base = fakeReceiving();
    return DjiRelayReceiving(
      state: base.state,
      phoneSource: base.phoneSource,
      replay: base.replay,
      failures: base.failures,
      units: base.units,
      lostOnWifi: base.lostOnWifi,
      receivedPerSecond: base.receivedPerSecond,
      decodedPerSecond: base.decodedPerSecond,
      shownPerSecond: base.shownPerSecond,
      lostOnRadio: base.lostOnRadio,
      receiveToPictureMs: 212,
      paced: true,
      bufferTargetMs: 180,
      bufferNowMs: 176.4,
      bufferP95Ms: 205,
      lateUnits: 3,
      renderSkips: 7,
      decoderStalls: 1,
      safetyFlushes: 0,
      freezes: freezes,
      longestFreezeMs: longestFreezeMs,
      freezesInSource: freezesInSource,
      breaks: 2,
      primers: 3,
      primersUsed: 1,
      network: network,
      wifiBand: '5',
      wifiLinkMbps: 866,
      wifiRssi: -58,
      refreshHz: 60,
    );
  }

  testWidgets('a paced reception says its buffer, what was late or not shown, the freezes and its network', (
    tester,
  ) async {
    final t = await english(tester);
    expect(djiLinkSmoothnessLines(t, paced()), [
      'Smoothing buffer: 180 ms (now 176 ms, 95 %: 205 ms)',
      'Late 3, not shown 7, decoder stalls 1, safety flushes 0; breaks 2, kept key pictures used 1',
      'No freeze over 0.3 s',
      'This device: Wi-Fi 5 GHz, 866 Mbit/s, -58 dBm, display 60 Hz',
    ]);
    final frozen = djiLinkSmoothnessLines(
      t,
      paced(freezes: 4, longestFreezeMs: 1240, freezesInSource: 2, network: 'ethernet'),
    );
    expect(frozen[2], "Freezes over 0.3 s: 4, the longest 1.2 s, 2 with a gap in the drone's stream");
    expect(frozen[3], 'This device: Ethernet, display 60 Hz');
    // Another network says nothing of it
    expect(djiLinkSmoothnessLines(t, paced(network: 'other')), hasLength(3));
    // A reception that is not paced (a phone of an earlier build, no unit yet) has none of these lines
    expect(djiLinkSmoothnessLines(t, fakeReceiving()), isEmpty);
    // The delay shown includes the buffer, and says so
    expect(
      t.dji_link_latency_receive_to_picture(ms: '212'),
      'Phone receive to picture shown here: 212 ms (smoothing buffer included)',
    );
  });

  testWidgets('the latency block shows the lines of a paced reception under the rates', (tester) async {
    await tester.pumpTestWidget(
      context,
      Material(child: DjiLinkLatencyBlock(receiving: paced(freezes: 1, longestFreezeMs: 420))),
    );
    expect(find.byKey(const Key('dji_link_latency_smoothness_0')), findsOneWidget);
    expect(find.text('Smoothing buffer: 180 ms (now 176 ms, 95 %: 205 ms)'), findsOneWidget);
    expect(find.text("Freezes over 0.3 s: 1, the longest 0.4 s, 0 with a gap in the drone's stream"), findsOneWidget);
    expect(find.text('Phone receive to picture shown here: 212 ms (smoothing buffer included)'), findsOneWidget);
  });

  testWidgets("a receiver's row on the phone says its queue and, from its long pings, its screen", (tester) async {
    final t = await english(tester);
    final plain = DjiRelayHeadsetRow(
      address: '192.168.1.50',
      connectedForMs: 5000,
      droppedUnits: 0,
      megabitsPerSecond: 18,
    );
    expect(djiRelayHeadsetFlowLines(t, plain), isEmpty);
    final measured = DjiRelayHeadsetRow(
      address: '192.168.1.50',
      connectedForMs: 5000,
      droppedUnits: 64,
      megabitsPerSecond: 18,
      kind: 'tv',
      queueAgeMs: 12.6,
      queueMaxAgeMs: 1530,
      dropEvents: 2,
      writeStalls: 5,
      writeP95Ms: 3.1,
      roundTripMs: 9.4,
    );
    expect(djiRelayHeadsetFlowLines(t, measured), [
      'Waiting on this phone 13 ms (at most 1530 ms); dropped 2 times; slow writes 5; round trip 9 ms',
    ]);
    final withScreen = DjiRelayHeadsetRow(
      address: '192.168.1.50',
      connectedForMs: 5000,
      droppedUnits: 0,
      megabitsPerSecond: 18,
      queueMaxAgeMs: 40,
      receiverBufferMs: 180,
      receiverFreezes: 3,
      receiverLongestFreezeMs: 1100,
      receiverSkips: 12,
      receiverLate: 4,
    );
    expect(djiRelayHeadsetFlowLines(t, withScreen), [
      'Waiting on this phone 0 ms (at most 40 ms); dropped 0 times; slow writes 0; round trip - ms',
      'On its screen: buffer 180 ms, freezes over 0.3 s 3 (the longest 1.1 s), not shown 12, late 4',
    ]);
  });
}
