// The gate of the values the DJI live video may show (design section 4, p2/telemetry-flight-2026-10-24.md): proven
// values over the picture with their label, likely ones in Advanced only with a question mark, guesses nowhere, and a
// value whose group stopped coming not drawn at all.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_fields.dart';

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
          expect(place, DjiLivePlace.nowhere, reason: field.name);
        case DjiLiveEvidence.likely:
          expect(place, isNot(DjiLivePlace.overlay), reason: field.name);
        case DjiLiveEvidence.proven:
          expect(place, gate.place, reason: field.name);
      }
    }
    // The first build: the drone's battery and the motor time over the picture, nothing else
    expect(
      [for (final field in DjiLiveField.values) if (djiLiveShowsAt(field, DjiLivePlace.overlay)) field],
      [DjiLiveField.droneBattery, DjiLiveField.motorTime],
    );
    expect(djiLivePlace(DjiLiveField.remoteBattery), DjiLivePlace.advanced);
    // No row at all for what a pilot would read first and our captures cannot prove yet
    final names = DjiLiveField.values.map((field) => field.name.toLowerCase()).join(' ');
    for (final missing in ['height', 'speed', 'satellite', 'position', 'distance']) {
      expect(names.contains(missing), isFalse, reason: missing);
    }
  });

  test('the motor time is minutes and whole seconds', () {
    expect(djiLiveMinutesSeconds(0), '0:00');
    expect(djiLiveMinutesSeconds(41.6), '0:41');
    expect(djiLiveMinutesSeconds(65), '1:05');
    expect(djiLiveMinutesSeconds(-3), '0:00');
    expect(djiLiveMinutesSeconds(double.nan), '0:00');
  });

  testWidgets('over the picture: the drone battery and the motor time, with their labels', (tester) async {
    final t = await english(tester);
    expect(shown(djiLiveValues(t, fakeTelemetry(percent: 34, motorTimeS: 41.6), DjiLivePlace.overlay)), [
      ('Drone', '34 %'),
      ('Motor time', '0:41'),
    ]);
    expect(djiLiveValues(t, null, DjiLivePlace.overlay), isEmpty);
    expect(djiLiveValues(t, fakeTelemetry(), DjiLivePlace.nowhere), isEmpty);
  });

  testWidgets('a group that stopped coming is not drawn at all', (tester) async {
    final t = await english(tester);
    expect(shown(djiLiveValues(t, fakeTelemetry(batteryStale: true), DjiLivePlace.overlay)), [('Motor time', '0:38')]);
    expect(shown(djiLiveValues(t, fakeTelemetry(stale: true), DjiLivePlace.overlay)), [('Drone', '38 %')]);
    expect(djiLiveValues(t, fakeTelemetry(stale: true, batteryStale: true), DjiLivePlace.overlay), isEmpty);
    final advanced = djiLiveValues(t, fakeTelemetry(remoteBatteryStale: true), DjiLivePlace.advanced);
    expect(advanced.any((value) => value.field == DjiLiveField.remoteBattery), isFalse);
  });

  testWidgets('Advanced lists every value that shows, a likely one with a question mark in its label', (tester) async {
    final t = await english(tester);
    final values = djiLiveValues(t, fakeTelemetry(), DjiLivePlace.advanced);
    expect(shown(values), [
      ('Drone', '38 %'),
      ('Motor time', '0:38'),
      ('Motors', 'On'),
      ('Drone battery voltage', '6.18 V'),
      ('Drone battery temperature', '26.9 °C'),
      ('Heading (zero not checked against north)', '126.8°'),
      ('Signal (its scale is not known yet)', '90'),
      ('Link rate', '5.9 Mbit/s'),
      ('Remote battery?', '50 %'),
    ]);
    for (final value in values) {
      final likely = djiLiveGates[value.field]!.evidence == DjiLiveEvidence.likely;
      expect(value.label.endsWith('?'), likely, reason: value.field.name);
    }
    expect(values.first.line, 'Drone 38 %');
  });

  testWidgets('the flight view of the Quest gets one template per value over the picture', (tester) async {
    final t = await english(tester);
    expect(djiLiveFlightViewTemplates(t), {'droneBattery': 'Drone {value} %', 'motorTime': 'Motor time {value}'});
  });
}
