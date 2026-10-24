// The values the DJI live video may show, and the one table that decides which (p2/design-ux-phone-2026-10-24.md,
// section 4). A value shows only once our own captures prove what it is (p2/telemetry-flight-2026-10-24.md, sections 0
// and 2): a proven value may sit over the picture with its label, a likely one only in Advanced with a question mark in
// its label, a guess nowhere. A value whose group stopped coming is not drawn at all, never greyed, since a grey number
// can be read as current. Nothing here is a flight instrument: no value has been compared with DJI Fly yet. Opening a
// gate is a change of one row of [djiLiveGates], with the evidence that proves the value named beside it.

import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';

/// How a value is known, from the black box reading of our own captures
enum DjiLiveEvidence { proven, likely, guess }

/// Where a value may show: over the picture (the phone's right band and the Quest's values line), in Advanced only, or
/// nowhere
enum DjiLivePlace { overlay, advanced, nowhere }

/// The values the link reads that a pilot could want, in the order they are drawn
enum DjiLiveField {
  droneBattery,
  motorTime,
  motors,
  batteryVoltage,
  batteryTemperature,
  heading,
  signal,
  linkRate,
  remoteBattery,
}

class DjiLiveGate {
  const DjiLiveGate(this.evidence, this.place);

  final DjiLiveEvidence evidence;

  /// Where the row asks the value to show; [djiLivePlace] keeps a likely value out of the overlay whatever it asks
  final DjiLivePlace place;
}

/// The gate: one row per value. The heights, the speeds, the satellites, the position and the camera angles have no
/// row: a guess, or a likely value a pilot would read first (the height), is worse than no number.
const djiLiveGates = <DjiLiveField, DjiLiveGate>{
  // 13/2 offset 20: equal to 3/85 offset 8 in 47 of 47 samples, and to remaining over full capacity (report 3.1)
  DjiLiveField.droneBattery: DjiLiveGate(DjiLiveEvidence.proven, DjiLivePlace.overlay),
  // 3/67 offset 42: one tenth per frame while the motors run, frozen after; 0 before and 41.6 s after the 24 October
  // flight (report 3.4)
  DjiLiveField.motorTime: DjiLiveGate(DjiLiveEvidence.proven, DjiLivePlace.overlay),
  // 3/67 offset 32, bits 0x04 and 0x08 together: set exactly while the motor time grows (report 3.4)
  DjiLiveField.motors: DjiLiveGate(DjiLiveEvidence.proven, DjiLivePlace.advanced),
  // 13/2 offset 1: equal to 3/85 offset 4 within 10 mV at rest, sags under load (report 3.1)
  DjiLiveField.batteryVoltage: DjiLiveGate(DjiLiveEvidence.proven, DjiLivePlace.advanced),
  // 13/2 offset 17: 21.0 before the 24 October flight, 28.3 after it (report 3.1)
  DjiLiveField.batteryTemperature: DjiLiveGate(DjiLiveEvidence.proven, DjiLivePlace.advanced),
  // 3/67 offset 28: within 1.5 degrees of the camera heading of two other pushes; its zero is not checked against
  // north yet, which the label says (report 3.2)
  DjiLiveField.heading: DjiLiveGate(DjiLiveEvidence.proven, DjiLivePlace.advanced),
  // 9/8 from the remote side: 0, then 70, 55, 70 while linking, 90 steady at short range; the top of its scale is not
  // known, which the label says (report 3.5)
  DjiLiveField.signal: DjiLiveGate(DjiLiveEvidence.proven, DjiLivePlace.advanced),
  // 9/54: 1.0 to 1.35 times the video rate measured from the envelopes (report 3.5)
  DjiLiveField.linkRate: DjiLiveGate(DjiLiveEvidence.proven, DjiLivePlace.advanced),
  // 6/30 offset 4: 50, 49, 48 over two days, never up; not compared with the remote's own lights yet (report 3.6)
  DjiLiveField.remoteBattery: DjiLiveGate(DjiLiveEvidence.likely, DjiLivePlace.advanced),
};

/// Where [field] shows: a guess nowhere, a likely value in Advanced at most, a proven one where its row says
DjiLivePlace djiLivePlace(DjiLiveField field) {
  final gate = djiLiveGates[field];
  if (gate == null) {
    return DjiLivePlace.nowhere;
  }
  return switch (gate.evidence) {
    DjiLiveEvidence.guess => DjiLivePlace.nowhere,
    DjiLiveEvidence.likely => gate.place == DjiLivePlace.nowhere ? DjiLivePlace.nowhere : DjiLivePlace.advanced,
    DjiLiveEvidence.proven => gate.place,
  };
}

/// Whether [field] may show at [place]: the overlay shows the overlay values, Advanced every value that shows at all
bool djiLiveShowsAt(DjiLiveField field, DjiLivePlace place) {
  final where = djiLivePlace(field);
  return switch (place) {
    DjiLivePlace.overlay => where == DjiLivePlace.overlay,
    DjiLivePlace.advanced => where != DjiLivePlace.nowhere,
    DjiLivePlace.nowhere => false,
  };
}

/// One value ready to draw: its small label and its number with the unit
class DjiLiveValue {
  const DjiLiveValue(this.field, this.label, this.value);

  final DjiLiveField field;
  final String label;
  final String value;

  /// The one line form, for screen readers and the values line of the Quest
  String get line => '$label $value';
}

/// The motor time as minutes and seconds, the whole seconds only: 41.6 s is 0:41
String djiLiveMinutesSeconds(double seconds) {
  final whole = seconds.isFinite && seconds > 0 ? seconds.floor() : 0;
  return '${whole ~/ 60}:${(whole % 60).toString().padLeft(2, '0')}';
}

/// The small label of [field]; a likely value's label ends with a question mark
String djiLiveFieldLabel(Translations t, DjiLiveField field) => switch (field) {
  DjiLiveField.droneBattery => t.dji_live_drone_battery_label,
  DjiLiveField.motorTime => t.dji_live_motor_time_label,
  DjiLiveField.motors => t.dji_link_motors,
  DjiLiveField.batteryVoltage => t.dji_live_value_voltage,
  DjiLiveField.batteryTemperature => t.dji_live_value_temperature,
  DjiLiveField.heading => t.dji_live_value_heading,
  DjiLiveField.signal => t.dji_live_value_signal,
  DjiLiveField.linkRate => t.dji_live_value_link_rate,
  DjiLiveField.remoteBattery => t.dji_live_value_remote_battery,
};

/// The unit written after the number of [field], the same on the phone and in the Quest's values line
String djiLiveFieldUnit(DjiLiveField field) => switch (field) {
  DjiLiveField.droneBattery || DjiLiveField.remoteBattery => ' %',
  DjiLiveField.batteryVoltage => ' V',
  DjiLiveField.batteryTemperature => ' °C',
  DjiLiveField.heading => '°',
  DjiLiveField.linkRate => ' Mbit/s',
  DjiLiveField.motorTime || DjiLiveField.motors || DjiLiveField.signal => '',
};

/// The number of [field] as [telemetry] gives it, null when its group never came or is stale
String? _number(Translations t, DjiLinkTelemetry telemetry, DjiLiveField field) {
  final flight = telemetry.flight;
  final battery = telemetry.battery;
  final link = telemetry.link;
  final freshFlight = flight != null && !flight.stale ? flight : null;
  final freshBattery = battery != null && !battery.stale ? battery : null;
  final freshLink = link != null && !link.stale ? link : null;
  return switch (field) {
    DjiLiveField.droneBattery => freshBattery == null ? null : '${freshBattery.percent}',
    DjiLiveField.motorTime => freshFlight == null ? null : djiLiveMinutesSeconds(freshFlight.motorTimeS),
    DjiLiveField.motors => switch (freshFlight?.motorsOn) {
      null => null,
      true => t.dji_link_bench_on,
      false => t.dji_link_bench_off,
    },
    DjiLiveField.batteryVoltage => freshBattery?.volts.toStringAsFixed(2),
    DjiLiveField.batteryTemperature => freshBattery?.temperatureC.toStringAsFixed(1),
    DjiLiveField.heading => freshFlight?.headingDeg.toStringAsFixed(1),
    DjiLiveField.signal => freshLink?.signalRemoteSide?.toString(),
    DjiLiveField.linkRate => freshLink?.liveRateMbps?.toStringAsFixed(1),
    DjiLiveField.remoteBattery => telemetry.remoteBatteryStale ? null : telemetry.remoteBatteryPercent?.toString(),
  };
}

/// The values of [telemetry] that may show at [place], in the order of [DjiLiveField], the stale ones left out
List<DjiLiveValue> djiLiveValues(Translations t, DjiLinkTelemetry? telemetry, DjiLivePlace place) {
  if (telemetry == null) {
    return const [];
  }
  return [
    for (final field in DjiLiveField.values)
      if (djiLiveShowsAt(field, place))
        if (_number(t, telemetry, field) case final String number)
          DjiLiveValue(field, djiLiveFieldLabel(t, field), '$number${djiLiveFieldUnit(field)}'),
  ];
}

/// The templates of the Quest flight view's values line, one per overlay value ("Drone {value} %"), under the names
/// the native side reads (FlightViewControls.VALUE_FIELDS): a value without a template is never shown there
Map<String, String> djiLiveFlightViewTemplates(Translations t) => {
  for (final field in DjiLiveField.values)
    if (djiLiveShowsAt(field, DjiLivePlace.overlay))
      field.name: '${djiLiveFieldLabel(t, field)} {value}${djiLiveFieldUnit(field)}',
};
