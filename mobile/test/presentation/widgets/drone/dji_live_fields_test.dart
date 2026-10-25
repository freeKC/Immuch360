// The gate of the values the DJI live video may show (p2/design-final-2026-10-24.md, 3.2, with the classes of
// p2/telemetry-deep-dive-2026-10-24.md and p2/telemetry-proof-2026-10-25.md): proven values over the picture with their
// label, likely ones in Advanced only under "Not confirmed yet" with a question mark, guesses and unnamed values
// nowhere, a value whose group stopped coming not drawn at all, and the formats a pilot reads.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_fields.dart';
import 'package:immich_mobile/providers/drone/dji_live_frame.provider.dart';

import '../../../unit/presentation/presentation_context.dart';
import '../../pages/drone/dji_link_fakes.dart';

/// Every row proven and over the picture: the gate of a later build, once the proof flights are in
final _proven = {
  for (final entry in djiLiveGates.entries)
    entry.key: DjiLiveGate(
      entry.value.evidence == DjiLiveEvidence.none ? DjiLiveEvidence.none : DjiLiveEvidence.proven,
      entry.value.band == DjiLiveBand.none ? DjiLivePlace.advanced : DjiLivePlace.overlay,
      band: entry.value.band,
      drop: entry.value.drop,
    ),
};

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  /// The English texts, from a widget under the app's localisation
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

  List<(String, String)> shown(List<DjiLiveValue> values) => [for (final value in values) (value.label, value.value)];

  test('only proven values may sit over the picture, likely ones in Advanced at most, guesses nowhere', () {
    for (final field in DjiLiveField.values) {
      final gate = djiLiveGates[field]!;
      final place = djiLivePlace(field);
      switch (gate.evidence) {
        case DjiLiveEvidence.guess:
        case DjiLiveEvidence.none:
          expect(place, DjiLivePlace.nowhere, reason: field.name);
        case DjiLiveEvidence.likely:
          expect(place, isNot(DjiLivePlace.overlay), reason: field.name);
        case DjiLiveEvidence.proven:
          expect(place, gate.place, reason: field.name);
      }
    }
    // With today's classes: the drone's battery and the motor time on the right, the flight on the left, the
    // obstacle as the ring
    expect(
      [for (final field in DjiLiveField.values) if (djiLiveShowsAt(field, DjiLivePlace.overlay)) field],
      [
        DjiLiveField.droneBattery,
        DjiLiveField.motorTime,
        DjiLiveField.height,
        DjiLiveField.verticalSpeed,
        DjiLiveField.speed,
        DjiLiveField.distanceBelow,
        DjiLiveField.obstacle,
      ],
    );
    expect(djiLiveBandFields(DjiLiveBand.right), [DjiLiveField.droneBattery, DjiLiveField.motorTime]);
    expect(djiLiveBandFields(DjiLiveBand.left), [
      DjiLiveField.height,
      DjiLiveField.verticalSpeed,
      DjiLiveField.speed,
      DjiLiveField.distanceBelow,
    ]);
    // Every value a pilot reads has a row
    expect(djiLiveGates.keys.toSet(), DjiLiveField.values.toSet());
    // Likely: in Advanced, under "Not confirmed yet"
    for (final field in [DjiLiveField.remoteBattery, DjiLiveField.signalBars]) {
      expect(djiLivePlace(field), DjiLivePlace.advanced, reason: field.name);
      expect(djiLiveIsLikely(field), isTrue, reason: field.name);
    }
    expect([for (final field in DjiLiveField.values) if (djiLiveIsLikely(field)) field], [
      DjiLiveField.signalBars,
      DjiLiveField.remoteBattery,
    ]);
    // No source in our captures: nowhere, and the native side reads no byte for them
    expect(djiLivePlace(DjiLiveField.distanceHome), DjiLivePlace.nowhere);
    expect(djiLivePlace(DjiLiveField.timeLeft), DjiLivePlace.nowhere);
    expect(djiLivePlace(DjiLiveField.satellites), DjiLivePlace.nowhere);
    expect(djiLivePlace(DjiLiveField.landing), DjiLivePlace.nowhere);
    expect(djiLiveFlightValuesPending(), isTrue);
  });

  test('the proof flights of 25 October open the flight values, the distance below and the ring with its side', () {
    // p2/telemetry-proof-2026-10-25.md, sections 4 and 6: two independent pieces of evidence each, both captures
    for (final field in [
      DjiLiveField.height,
      DjiLiveField.verticalSpeed,
      DjiLiveField.speed,
      DjiLiveField.distanceBelow,
      DjiLiveField.obstacle,
      DjiLiveField.obstacleSide,
    ]) {
      expect(djiLiveGates[field]!.evidence, DjiLiveEvidence.proven, reason: field.name);
      expect(djiLiveIsLikely(field), isFalse, reason: field.name);
    }
    // In the left band, in this order; the distance below leaves it first on a short screen, height and vertical speed
    // never
    expect(djiLiveGates[DjiLiveField.distanceBelow]!.band, DjiLiveBand.left);
    expect(djiLiveGates[DjiLiveField.distanceBelow]!.drop, greaterThan(djiLiveGates[DjiLiveField.speed]!.drop));
    expect(djiLiveGates[DjiLiveField.height]!.drop, 0);
    expect(djiLiveGates[DjiLiveField.verticalSpeed]!.drop, 0);
    // The obstacle shows as the ring, never as a cell of a band
    expect(djiLiveGates[DjiLiveField.obstacle]!.band, DjiLiveBand.none);
    // Still waiting for an outdoor flight: satellites, the distance from home, the heading's north
    expect(djiLiveGates[DjiLiveField.satellites]!.evidence, DjiLiveEvidence.guess);
    expect(djiLiveGates[DjiLiveField.distanceHome]!.evidence, DjiLiveEvidence.none);
    expect(djiLivePlace(DjiLiveField.heading), DjiLivePlace.advanced);
  });

  test('the obstacle ring is offered as proven, a test while its data is likely, not at all without a field', () {
    expect(djiObstacleOffer(), DjiObstacleOffer.proven);
    final likely = {
      ...djiLiveGates,
      DjiLiveField.obstacle: const DjiLiveGate(DjiLiveEvidence.likely, DjiLivePlace.overlay),
    };
    expect(djiObstacleOffer(gates: likely), DjiObstacleOffer.test);
    final none = {
      ...djiLiveGates,
      DjiLiveField.obstacle: const DjiLiveGate(DjiLiveEvidence.none, DjiLivePlace.overlay),
    };
    expect(djiObstacleOffer(gates: none), DjiObstacleOffer.none);
    // Proven or not, its switch turns it off
    expect(const DjiObstacleSettings().offered(DjiObstacleOffer.proven), isTrue);
    expect(const DjiObstacleSettings(alertOn: false).offered(DjiObstacleOffer.proven), isFalse);
  });

  test('the side of the ring is shown by default once proven, a test while likely, never a value', () {
    // The flights of 25 October: proven, so shown unless "Show the side" is turned off
    expect(djiLiveGates[DjiLiveField.obstacleSide]!.evidence, DjiLiveEvidence.proven);
    expect(djiObstacleSideOffer(), DjiObstacleSideOffer.proven);
    final likely = {
      ...djiLiveGates,
      DjiLiveField.obstacleSide: const DjiLiveGate(DjiLiveEvidence.likely, DjiLivePlace.nowhere),
    };
    expect(djiObstacleSideOffer(gates: likely), DjiObstacleSideOffer.test);
    final guess = {
      ...djiLiveGates,
      DjiLiveField.obstacleSide: const DjiLiveGate(DjiLiveEvidence.guess, DjiLivePlace.nowhere),
    };
    expect(djiObstacleSideOffer(gates: guess), DjiObstacleSideOffer.none);
    // Not a value: never over the picture, never in Advanced, no template for the flight view
    expect(djiLivePlace(DjiLiveField.obstacleSide), DjiLivePlace.nowhere);
    expect(djiLiveIsLikely(DjiLiveField.obstacleSide), isFalse);
    // The settings turn the two rows into one boolean for the native side
    const settings = DjiObstacleSettings(alertOn: true, sideTest: true);
    expect(settings.directional(DjiObstacleSideOffer.test), isTrue);
    expect(const DjiObstacleSettings(alertOn: true).directional(DjiObstacleSideOffer.test), isFalse);
    expect(const DjiObstacleSettings().directional(DjiObstacleSideOffer.proven), isTrue);
    expect(const DjiObstacleSettings(sideOff: true).directional(DjiObstacleSideOffer.proven), isFalse);
    expect(settings.directional(DjiObstacleSideOffer.none), isFalse);
  });

  test('every switch of the ring is on by default, the side too now that it is proven (FreeKC, 25 October)', () {
    const settings = DjiObstacleSettings();
    // The ring is offered on by default
    expect(settings.alertOn, isTrue);
    expect(settings.offered(DjiObstacleOffer.test), isTrue);
    expect(settings.offered(DjiObstacleOffer.proven), isTrue);
    expect(settings.offered(DjiObstacleOffer.none), isFalse);
    expect(const DjiObstacleSettings(alertOn: false).offered(DjiObstacleOffer.test), isFalse);
    // The sound (a TV's too), the tap, the number: on; the circle around the centre, not the frame
    expect(settings.soundOn, isTrue);
    expect(settings.hapticOn, isTrue);
    expect(settings.numbersOn, isTrue);
    expect(settings.frame, isFalse);
    // The side: on by default since its row is proven, the arc toward the obstacle
    expect(djiObstacleSideOffer(), DjiObstacleSideOffer.proven);
    expect(settings.sideOff, isFalse);
    expect(settings.directional(djiObstacleSideOffer()), isTrue);
    // While likely it waited behind its test switch, off by default
    expect(settings.sideTest, isFalse);
    expect(settings.directional(DjiObstacleSideOffer.test), isFalse);
  });

  test('the distances stay in their steppers, "Strong glow from" at least 0.5 m under "Glow from"', () {
    expect(djiObstacleDistancesCm(300, 100), (300, 100));
    expect(djiObstacleDistancesCm(900, 400), (600, 250));
    // Down to 1.0 m and 0.25 m for a room
    expect(djiObstacleDistancesCm(50, 140), (100, 50));
    expect(djiObstacleDistancesCm(100, 25), (100, 25));
    expect(djiObstacleDistancesCm(150, 140), (150, 100));
    expect(djiObstacleDistancesCm(200, 175), (200, 150));
    expect(djiObstacleDistancesCm(300, 10), (300, 25));
    expect(const DjiObstacleSettings().farM, 3.0);
    expect(const DjiObstacleSettings().nearM, 1.0);
  });

  test('the formats: minutes and seconds, the height, the vertical speed with its arrow', () {
    expect(djiLiveMinutesSeconds(0), '0:00');
    expect(djiLiveMinutesSeconds(41.6), '0:41');
    expect(djiLiveMinutesSeconds(65), '1:05');
    expect(djiLiveMinutesSeconds(-3), '0:00');
    expect(djiLiveMinutesSeconds(double.nan), '0:00');
    expect(djiLiveHeight(12.34), '12.3');
    expect(djiLiveHeight(-0.5), '-0.5');
    expect(djiLiveHeight(0), '0.0');
    expect(djiLiveHeight(99.94), '99.9');
    expect(djiLiveHeight(123.4), '123');
    expect(djiLiveVerticalSpeed(1.2), '↑ 1.2');
    expect(djiLiveVerticalSpeed(-0.2), '↓ 0.2');
    expect(djiLiveVerticalSpeed(0.1), '↑ 0.1');
    expect(djiLiveVerticalSpeed(0.04), '0.0');
    expect(djiLiveVerticalSpeed(-0.04), '0.0');
  });

  testWidgets('on the ground over the picture: the drone battery and the motor time, with labels', (tester) async {
    final t = await english(tester);
    expect(shown(djiLiveValues(t, fakeFrame(), DjiLivePlace.overlay)), [
      ('Drone battery', '34 %'),
      ('Motor time', '0:41'),
    ]);
    expect(djiLiveValues(t, null, DjiLivePlace.overlay), isEmpty);
    expect(djiLiveValues(t, fakeFrame(), DjiLivePlace.nowhere), isEmpty);
  });

  testWidgets('over the picture in the air: the height, the vertical speed climbing up, the speed and what is below', (
    tester,
  ) async {
    final t = await english(tester);
    final climbing = fakeFrame(
      motorsOn: true,
      heightM: 1.0,
      verticalSpeedMps: 1.5,
      speedMps: 0.0,
      distanceBelowM: 1.53,
    );
    expect(shown(djiLiveValues(t, climbing, DjiLivePlace.overlay)), [
      ('Drone battery', '34 %'),
      ('Motor time', '0:41'),
      ('Height', '1.0 m'),
      ('Vertical', '↑ 1.5 m/s'),
      ('Speed', '0.0 m/s'),
      ('Below', '1.53 m'),
    ]);
    // Descending onto a hand: 0.2 m/s down, 0.5 m above the take off point, the hand 0.03 m under the drone
    final landing = fakeFrame(
      motorsOn: true,
      heightM: 0.5,
      verticalSpeedMps: -0.2,
      speedMps: 0.0,
      distanceBelowM: 0.028,
    );
    expect(shown(djiLiveValues(t, landing, DjiLivePlace.overlay)).skip(2).toList(), [
      ('Height', '0.5 m'),
      ('Vertical', '↓ 0.2 m/s'),
      ('Speed', '0.0 m/s'),
      ('Below', '0.03 m'),
    ]);
    // The motors spin before lift off: the native side gives no height or speed, the distance below only
    final spinning = fakeFrame(motorsOn: true, distanceBelowM: 0.008);
    expect(shown(djiLiveValues(t, spinning, DjiLivePlace.overlay)).skip(2).toList(), [('Below', '0.01 m')]);
  });

  testWidgets('a stale group is not drawn at all', (tester) async {
    final t = await english(tester);
    expect(shown(djiLiveValues(t, fakeFrame(percent: null), DjiLivePlace.overlay)), [('Motor time', '0:41')]);
    expect(shown(djiLiveValues(t, fakeFrame(motorTimeS: null), DjiLivePlace.overlay)), [('Drone battery', '34 %')]);
    expect(djiLiveValues(t, fakeFrame(percent: null, motorTimeS: null), DjiLivePlace.overlay), isEmpty);
    final advanced = djiLiveValues(t, fakeFrame(remoteBatteryPercent: null), DjiLivePlace.advanced);
    expect(advanced.where((value) => value.field == DjiLiveField.remoteBattery), isEmpty);
  });

  testWidgets('Advanced: the proven values, then the likely ones with their question marks', (tester) async {
    final t = await english(tester);
    final values = djiLiveValues(
      t,
      fakeFrame(
        motorsOn: true,
        heightM: 1.2,
        verticalSpeedMps: 0.4,
        speedMps: 4.24,
        distanceBelowM: 0.136,
        obstacleM: 1.84,
      ),
      DjiLivePlace.advanced,
    );
    expect(shown(values), [
      ('Drone battery', '34 %'),
      ('Motor time', '0:41'),
      ('Signal bars?', '5/5'),
      ('Remote battery?', '50 %'),
      ('Heading (zero not checked against north)', '127°'),
      ('Height above the take off point', '1.2 m'),
      ('Vertical speed', '↑ 0.4 m/s'),
      ('Speed over the ground', '4.2 m/s'),
      ('Distance below', '0.14 m'),
      ('Nearest obstacle', '1.8 m'),
      ('Motors', 'On'),
      ('Drone battery voltage', '6.18 V'),
      ('Drone battery temperature', '26.9 °C'),
      ('Signal (its scale is not known yet)', '90'),
      ('Link rate', '5.9 Mbit/s'),
    ]);
    // The satellites (a guess) and the landing chip are not there
    expect(values.where((value) => value.field == DjiLiveField.satellites), isEmpty);
    expect(values.first.line, 'Drone battery 34 %');
    // Under "Not confirmed yet": the signal bars and the remote's battery only
    expect([for (final value in values) if (djiLiveIsLikely(value.field)) value.field], [
      DjiLiveField.signalBars,
      DjiLiveField.remoteBattery,
    ]);
    // The labels a likely row takes, should a row go back
    final likely = {
      for (final entry in djiLiveGates.entries)
        entry.key: entry.value.evidence == DjiLiveEvidence.proven && entry.value.place == DjiLivePlace.overlay
            ? DjiLiveGate(DjiLiveEvidence.likely, entry.value.place, band: entry.value.band, drop: entry.value.drop)
            : entry.value,
    };
    expect(djiLiveFieldLabel(t, DjiLiveField.height, gates: likely), 'Height above the take off point?');
    expect(djiLiveFieldLabel(t, DjiLiveField.distanceBelow, gates: likely), 'Distance below?');
  });

  testWidgets('a gate opened later puts each value in its band, with its short label', (tester) async {
    final t = await english(tester);
    expect(djiLiveBandFields(DjiLiveBand.left, gates: _proven), [
      DjiLiveField.height,
      DjiLiveField.verticalSpeed,
      DjiLiveField.speed,
      DjiLiveField.distanceBelow,
    ]);
    expect(djiLiveBandFields(DjiLiveBand.right, gates: _proven), [
      DjiLiveField.droneBattery,
      DjiLiveField.motorTime,
      DjiLiveField.signalBars,
      DjiLiveField.remoteBattery,
      DjiLiveField.satellites,
      DjiLiveField.heading,
      DjiLiveField.landing,
    ]);
    final frame = fakeFrame(motorsOn: true, speedMps: 4.2, heightM: 12.3, verticalSpeedMps: 1.2, landing: true);
    expect(shown(djiLiveValues(t, frame, DjiLivePlace.overlay, gates: _proven)), [
      ('Drone battery', '34 %'),
      ('Motor time', '0:41'),
      ('Signal', '5/5'),
      ('Remote', '50 %'),
      ('Satellites', '0'),
      ('', '127°'),
      ('', 'Landing'),
      ('Height', '12.3 m'),
      ('Vertical', '↑ 1.2 m/s'),
      ('Speed', '4.2 m/s'),
    ]);
    expect(djiLiveFlightValuesPending(gates: _proven), isTrue, reason: 'no field gives the distance from home');
  });

  testWidgets('the drone battery under 20 % is low', (tester) async {
    final t = await english(tester);
    expect(djiLiveBatteryIsLow(fakeFrame(percent: 20)), isFalse);
    expect(djiLiveBatteryIsLow(fakeFrame(percent: 19)), isTrue);
    expect(djiLiveBatteryIsLow(fakeFrame(percent: null)), isFalse);
    expect(djiLiveValues(t, fakeFrame(percent: 19), DjiLivePlace.overlay).first.low, isTrue);
  });

  testWidgets('the Quest flight view gets a label and a value template for the values over the picture only', (
    tester,
  ) async {
    final t = await english(tester);
    expect(djiLiveFlightViewTemplates(t), {
      'cell.droneBattery.label': 'Drone battery',
      'cell.droneBattery.value': '{value} %',
      'cell.motorTime.label': 'Motor time',
      'cell.motorTime.value': '{value}',
      'cell.height.label': 'Height',
      'cell.height.value': '{value} m',
      'cell.verticalSpeed.label': 'Vertical',
      'cell.verticalSpeed.value': '{value} m/s',
      'cell.speed.label': 'Speed',
      'cell.speed.value': '{value} m/s',
      'cell.distanceBelow.label': 'Below',
      'cell.distanceBelow.value': '{value} m',
    });
    final later = djiLiveFlightViewTemplates(t, gates: _proven);
    // The obstacle is the ring, never a cell of a column
    expect(later.containsKey('cell.obstacle.value'), isFalse);
    expect(later['cell.height.value'], '{value} m');
    expect(later['cell.verticalSpeed.value'], '{value} m/s');
    expect(later['cell.landing.value'], 'Landing');
    expect(later.containsKey('cell.distanceHome.value'), isFalse);
  });
}
