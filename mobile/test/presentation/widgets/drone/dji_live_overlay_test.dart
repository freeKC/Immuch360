// The bands of the live screen (p2/design-final-2026-10-24.md, 3.3 and 3.4): each value in its fixed place with a fixed
// height, a value that stops coming leaves its place empty, the values that do not fit leave in their order of
// priority, and a gate opened later puts the flight numbers at the bottom of the left band.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_fields.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_overlay.widget.dart';
import 'package:immich_mobile/providers/drone/dji_live_frame.provider.dart';

import '../../../unit/presentation/presentation_context.dart';
import '../../pages/drone/dji_link_fakes.dart';

/// Every row with a band proven and over the picture, as a later build once the proof flights are in
final _proven = {
  for (final entry in djiLiveGates.entries)
    entry.key: DjiLiveGate(
      entry.value.evidence == DjiLiveEvidence.none ? DjiLiveEvidence.none : DjiLiveEvidence.proven,
      entry.value.band == DjiLiveBand.none ? DjiLivePlace.advanced : DjiLivePlace.overlay,
      band: entry.value.band,
      drop: entry.value.drop,
    ),
};

class _Frame extends DjiLiveFrameNotifier {
  _Frame(this.first);

  final DjiLiveFrame first;

  @override
  DjiLiveFrame? build() => first;
}

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  test('the values that do not fit leave in their order of priority, the battery and the height never', () {
    final right = djiLiveBandFields(DjiLiveBand.right, gates: _proven);
    expect(djiLiveFieldsThatFit(right, 1000, DjiLiveBand.right, gates: _proven), right);
    // Heading first, then the satellites, the remote's battery and the signal; the battery and the landing chip stay
    expect(djiLiveFieldsThatFit(right, 200, DjiLiveBand.right, gates: _proven), [
      DjiLiveField.droneBattery,
      DjiLiveField.motorTime,
      DjiLiveField.landing,
    ]);
    expect(djiLiveFieldsThatFit(right, 10, DjiLiveBand.right, gates: _proven), [
      DjiLiveField.droneBattery,
      DjiLiveField.landing,
    ]);
    final left = djiLiveBandFields(DjiLiveBand.left, gates: _proven);
    // Speed first, then the distance from home (which has no source anyway)
    expect(djiLiveFieldsThatFit(left, 100, DjiLiveBand.left, gates: _proven), [
      DjiLiveField.height,
      DjiLiveField.verticalSpeed,
    ]);
    expect(djiLiveFieldsThatFit(left, 140, DjiLiveBand.left, gates: _proven), [
      DjiLiveField.height,
      DjiLiveField.verticalSpeed,
      DjiLiveField.speed,
    ]);
  });

  Future<ProviderContainer> pumpBand(
    WidgetTester tester,
    DjiLiveBand band,
    DjiLiveFrame frame, {
    double height = 400,
    Map<DjiLiveField, DjiLiveGate> gates = djiLiveGates,
  }) async {
    await tester.pumpTestWidget(
      context,
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 80,
          height: height,
          child: ColoredBox(
            color: Colors.black,
            child: DjiLiveBandCells(band: band, gates: gates, alignment: Alignment.topLeft),
          ),
        ),
      ),
      overrides: [djiLiveFrameProvider.overrideWith(() => _Frame(frame))],
    );
    return ProviderScope.containerOf(tester.element(find.byType(DjiLiveBandCells)));
  }

  testWidgets('with today\'s gate the right band holds the drone battery and the motor time only', (tester) async {
    await pumpBand(tester, DjiLiveBand.right, fakeFrame());
    expect(find.text('34 %'), findsOneWidget);
    expect(find.text('0:41'), findsOneWidget);
    expect(find.text('50 %'), findsNothing);
    expect(find.byKey(const Key('dji_live_cell_heading')), findsNothing);
  });

  testWidgets('a cell keeps its size whatever its number, and a stale one keeps its place', (tester) async {
    final container = await pumpBand(
      tester,
      DjiLiveBand.left,
      fakeFrame(heightM: 0, verticalSpeedMps: 0, motorsOn: true, speedMps: 0),
      gates: _proven,
    );
    final height = tester.getRect(find.byKey(const Key('dji_live_cell_height')));
    final vertical = tester.getRect(find.byKey(const Key('dji_live_cell_verticalSpeed')));
    final speed = tester.getRect(find.byKey(const Key('dji_live_cell_speed')));
    expect(find.text('0.0 m'), findsOneWidget);
    expect(find.text('0.0 m/s'), findsNWidgets(2));
    for (final metres in [0.4, 8.8, 88.8, -0.5, 123.4]) {
      container
          .read(djiLiveFrameProvider.notifier)
          .offer(fakeFrame(atMs: 5000, heightM: metres, verticalSpeedMps: 2.5, motorsOn: true, speedMps: 8.8));
      await tester.pump();
      expect(tester.getRect(find.byKey(const Key('dji_live_cell_height'))), height);
      expect(tester.getRect(find.byKey(const Key('dji_live_cell_verticalSpeed'))), vertical);
      expect(tester.getRect(find.byKey(const Key('dji_live_cell_speed'))), speed);
    }
    expect(find.text('123 m'), findsOneWidget);
    expect(find.text('↑ 2.5 m/s'), findsOneWidget);
    // The height stops coming: its place stays, the speed under it does not move up
    container
        .read(djiLiveFrameProvider.notifier)
        .offer(fakeFrame(atMs: 6000, heightM: null, motorsOn: true, speedMps: 8.8));
    await tester.pump();
    expect(find.text('123 m'), findsNothing);
    expect(find.text('8.8 m/s'), findsOneWidget);
    expect(tester.getRect(find.byKey(const Key('dji_live_cell_speed'))), speed);
  });

  testWidgets('each value says its label and number in one line to a screen reader', (tester) async {
    final semantics = tester.ensureSemantics();
    addTearDown(semantics.dispose);
    await pumpBand(
      tester,
      DjiLiveBand.left,
      fakeFrame(heightM: 12.3, verticalSpeedMps: 1.2, motorsOn: true, speedMps: 4.2),
      gates: _proven,
    );
    expect(find.bySemanticsLabel('Height 12.3 m'), findsOneWidget);
    expect(find.bySemanticsLabel('Vertical ↑ 1.2 m/s'), findsOneWidget);
    expect(find.bySemanticsLabel('Speed 4.2 m/s'), findsOneWidget);
  });
}
