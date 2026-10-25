// The values the DJI live video may show, and the one table that decides which (p2/design-final-2026-10-24.md, 3.2).
// A value shows only once our own captures prove what it is: a proven value may sit over the picture with its label, a
// likely one only in Advanced, under "Not confirmed yet" with a question mark in its label, a guess nowhere, and a
// value with no source named in our reports has no decoder at all. A value whose group stopped coming is not drawn,
// never greyed, since a grey number can be read as current. Nothing here is a flight instrument: no value has been
// compared with DJI Fly yet. Opening a gate is a change of one row of [djiLiveGates], with the evidence that proves it
// named beside it; the value then takes its fixed place in its band, and nothing else moves.

import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';

/// How a value is known, from the black box reading of our own captures; none: no field of ours gives it
enum DjiLiveEvidence { proven, likely, guess, none }

/// Where a value may show: over the picture (the phone's bands, the Quest's columns and the window's cells), in
/// Advanced only, or nowhere
enum DjiLivePlace { overlay, advanced, nowhere }

/// The band of the phone (and the column of the Quest) a value takes once it is over the picture
enum DjiLiveBand { left, right, none }

/// Every value a pilot reads, in the order of its band, then the values of Advanced only
enum DjiLiveField {
  // The right band, top to bottom: the state of the drone
  droneBattery,
  timeLeft,
  motorTime,
  signalBars,
  remoteBattery,
  satellites,
  heading,
  landing,
  // The left band, bottom group, top to bottom: the flight, then what is under the drone
  height,
  verticalSpeed,
  distanceHome,
  speed,
  distanceBelow,
  // Over the picture as the obstacle ring, never as a cell
  obstacle,
  // Not a value: whether the obstacle ring may show the obstacle's side
  obstacleSide,
  // Advanced only
  motors,
  batteryVoltage,
  batteryTemperature,
  signal,
  linkRate,
}

class DjiLiveGate {
  const DjiLiveGate(this.evidence, this.place, {this.band = DjiLiveBand.none, this.drop = 0});

  final DjiLiveEvidence evidence;

  /// Where the row asks the value to show once it is proven; [djiLivePlace] keeps anything else out of the overlay
  final DjiLivePlace place;
  final DjiLiveBand band;

  /// When a band is too short, the value with the highest number leaves it first; 0 never leaves
  final int drop;
}

/// The gate: one row per value (p2/design-final-2026-10-24.md, 3.2, with the classes of
/// p2/telemetry-deep-dive-2026-10-24.md, sections 0 and 8, p2/telemetry-flight-2026-10-24.md, sections 0 and 2, and
/// p2/telemetry-proof-2026-10-25.md, sections 4 and 6: the 09:42 capture and the afternoon flight of 25 October, two
/// independent pieces of evidence per proven row, the same in both captures)
const djiLiveGates = <DjiLiveField, DjiLiveGate>{
  // 13/2 offset 20: equal to 3/85 offset 8 in 47 of 47 samples, and to remaining over full capacity (report 1, 3.1)
  DjiLiveField.droneBattery: DjiLiveGate(DjiLiveEvidence.proven, DjiLivePlace.overlay, band: DjiLiveBand.right),
  // No field of our captures gives the flight time left: the native side reads no byte for it
  DjiLiveField.timeLeft: DjiLiveGate(DjiLiveEvidence.none, DjiLivePlace.overlay, band: DjiLiveBand.right),
  // 3/67 offset 42: one tenth per frame while the motors run, frozen after (report 1, 3.4)
  DjiLiveField.motorTime: DjiLiveGate(
    DjiLiveEvidence.proven,
    DjiLivePlace.overlay,
    band: DjiLiveBand.right,
    drop: 1,
  ),
  // 9/117 from the remote side: 0, then 3, 4, 5 as the signal settles; never seen at range (report 1, 3.5)
  DjiLiveField.signalBars: DjiLiveGate(DjiLiveEvidence.likely, DjiLivePlace.overlay, band: DjiLiveBand.right, drop: 2),
  // 6/30 offset 4: 50, 49, 48 over two days, never up; not compared with the remote's own lights yet (report 1, 3.6)
  DjiLiveField.remoteBattery: DjiLiveGate(
    DjiLiveEvidence.likely,
    DjiLivePlace.overlay,
    band: DjiLiveBand.right,
    drop: 3,
  ),
  // 3/67 offset 36: 0 in every frame of three indoor captures (deep dive 6.1)
  DjiLiveField.satellites: DjiLiveGate(DjiLiveEvidence.guess, DjiLivePlace.overlay, band: DjiLiveBand.right, drop: 4),
  // 3/67 offset 28: within 1.5 degrees of the camera heading of two other pushes; its zero is not checked against
  // north, which the label of Advanced says (report 1, 3.2). Over the picture once north is proven.
  DjiLiveField.heading: DjiLiveGate(DjiLiveEvidence.proven, DjiLivePlace.advanced, band: DjiLiveBand.right, drop: 5),
  // 3/67 offset 30 = 12 in the frames of the only landing captured; one landing proves nothing (report 1, 3.3)
  DjiLiveField.landing: DjiLiveGate(DjiLiveEvidence.likely, DjiLivePlace.nowhere, band: DjiLiveBand.right),
  // 3/67 offset 16, 0.1 m, positive up, above the lift off point: trunc((r - z) / 100) of the 50 Hz push in 4126 of
  // 4134 frames, and its changes match the range below over the floor (4 clean events of the afternoon, ratios 0.87 to
  // 1.28, and a slow climb at 09:42, 0.72 to 1.15). In the air only (bit 0x04, likely "in the air"): with the motors
  // spinning before lift off it drifted to -1.2 m and +1.0 m. The native HeightHold also keeps it back after lift off
  // and, until the motors stop, after a jump of more than 10 m between two frames (a 16 bit wrap near 32.7 m is not
  // tested). Tested 0 to 1.8 m indoors, no climb to the limit, the scale from plausibility, not a tape (proof 4.1).
  // Keep the hold until a flight has climbed past 33 m (protocol step 2).
  DjiLiveField.height: DjiLiveGate(DjiLiveEvidence.proven, DjiLivePlace.overlay, band: DjiLiveBand.left),
  // 3/67 offset 22, 0.1 m/s, positive down on the wire, shown climb positive: slope 9.42 and correlation 0.983 against
  // the rate of the 50 Hz height in 2409 frames in the air (8.59 and 0.916 over 646 at 09:42), that height matching the
  // range below; 1.5 m/s in a 1.64 m/s climb. In the air only (proof 4.2)
  DjiLiveField.verticalSpeed: DjiLiveGate(DjiLiveEvidence.proven, DjiLivePlace.overlay, band: DjiLiveBand.left),
  // No field of our captures gives the distance from home: no fix indoors (deep dive 6.2)
  DjiLiveField.distanceHome: DjiLiveGate(DjiLiveEvidence.none, DjiLivePlace.overlay, band: DjiLiveBand.left, drop: 1),
  // 3/67 offsets 18 and 20, 0.1 m/s along the axes the heading counts from: the rates of the 50 Hz positions (slopes
  // 10.03 and 9.91, correlations 0.975 and 0.990; 0.988 and 0.995 at 09:42), their course is the heading in 332 of 373
  // frames (162 of 162), and the obstacle ring fits that displacement best at scale 1.0 in both captures (a shallow
  // fit, no tape). In the air only: stale on the ground. Tested to 1.5 m/s (proof 4.3)
  DjiLiveField.speed: DjiLiveGate(DjiLiveEvidence.proven, DjiLivePlace.overlay, band: DjiLiveBand.left, drop: 2),
  // 10/3 from the remote side, millimetres, while the motors run: the distance to whatever is under the drone (floor,
  // table, hand). It tracks the 50 Hz height over the floor (4 clean events, ratios 0.87 to 1.28, and a slow climb at
  // 09:42), reads 7 to 63 mm on a hand before lift off, and had a reading in every one of 4637 frames in the air (1244
  // at 09:42). Tested to 1.77 m, its reach not reached (proof 4.4). The bottom of the left band, the first to leave it.
  DjiLiveField.distanceBelow: DjiLiveGate(
    DjiLiveEvidence.proven,
    DjiLivePlace.overlay,
    band: DjiLiveBand.left,
    drop: 3,
  ),
  // 36/8 from 18.4: 360 distances in millimetres around the drone, only while the motors run. The scale is proven by
  // the 50 Hz displacement (the ring predicted from it fits best at scale 1.0, 127 and 67 ring pairs) and by the nose
  // sector shrinking on forward legs with 12 degrees of turn or less (6 of 6, 3 of 4 at 09:42); sensors against each
  // other, no tape. Over the picture as the obstacle ring and its number, not as a cell; the distances that make it
  // glow stay the pilot's choice. Not tested: a wall at a known distance, glass, thin branches, outdoors (proof 4.7).
  // Its row also offers the ring: djiObstacleOffer.
  DjiLiveField.obstacle: DjiLiveGate(DjiLiveEvidence.proven, DjiLivePlace.overlay),
  // 36/8 index 0 at the nose, growing clockwise (ObstacleRing.MAPPING, RingMapping(noseSector = 0, clockwise = true)),
  // the same in both captures: the camera picture shows the heading grows on a turn to the right; turns of 80 to 100
  // degrees in place move the ring by -heading change / 5 sectors in 12 of 13 and 4 of 4 (a right turn puts what was
  // ahead on the left); the ring predicted from the displacement fits best with the nose at 0 growing with the
  // heading; the nose sector shrinks flying forward (6 of 6 legs with 12 degrees of turn or less, 3 of 4 at 09:42;
  // proof 4.7). Not a value: it says the ring shows the side.
  DjiLiveField.obstacleSide: DjiLiveGate(DjiLiveEvidence.proven, DjiLivePlace.nowhere),
  // 3/67 offset 32, bit 0x08: set 0.1 s before the motor time starts and cleared the frame it stops, the spin up before
  // lift off included (report 1, 3.4; proof 4.9)
  DjiLiveField.motors: DjiLiveGate(DjiLiveEvidence.proven, DjiLivePlace.advanced),
  // 13/2 offset 1: equal to 3/85 offset 4 within 10 mV at rest, sags under load (report 1, 3.1)
  DjiLiveField.batteryVoltage: DjiLiveGate(DjiLiveEvidence.proven, DjiLivePlace.advanced),
  // 13/2 offset 17: 21.0 before the 24 October flight, 28.3 after it (report 1, 3.1)
  DjiLiveField.batteryTemperature: DjiLiveGate(DjiLiveEvidence.proven, DjiLivePlace.advanced),
  // 9/8 from the remote side: 0, then 70, 55, 70 while linking, 90 steady at short range; the top of its scale is not
  // known, which the label says (report 1, 3.5)
  DjiLiveField.signal: DjiLiveGate(DjiLiveEvidence.proven, DjiLivePlace.advanced),
  // 9/54: 1.0 to 1.35 times the video rate measured from the envelopes (report 1, 3.5)
  DjiLiveField.linkRate: DjiLiveGate(DjiLiveEvidence.proven, DjiLivePlace.advanced),
};

/// Under this the drone's battery is drawn in amber with its icon: our threshold, one constant; the drone's own low
/// battery warnings are set in DJI Fly and are not read here
const djiLiveBatteryLow = 20;

/// Where [field] shows: a guess or an unnamed value nowhere, a likely value in Advanced at most, a proven one where its
/// row says
DjiLivePlace djiLivePlace(DjiLiveField field, {Map<DjiLiveField, DjiLiveGate> gates = djiLiveGates}) {
  final gate = gates[field];
  if (gate == null) {
    return DjiLivePlace.nowhere;
  }
  return switch (gate.evidence) {
    DjiLiveEvidence.guess || DjiLiveEvidence.none => DjiLivePlace.nowhere,
    DjiLiveEvidence.likely => gate.place == DjiLivePlace.nowhere ? DjiLivePlace.nowhere : DjiLivePlace.advanced,
    DjiLiveEvidence.proven => gate.place,
  };
}

/// Whether [field] may show at [place]: the overlay shows the overlay values, Advanced every value that shows at all
bool djiLiveShowsAt(DjiLiveField field, DjiLivePlace place, {Map<DjiLiveField, DjiLiveGate> gates = djiLiveGates}) {
  final where = djiLivePlace(field, gates: gates);
  return switch (place) {
    DjiLivePlace.overlay => where == DjiLivePlace.overlay,
    DjiLivePlace.advanced => where != DjiLivePlace.nowhere,
    DjiLivePlace.nowhere => false,
  };
}

/// Whether [field] is shown, and only as likely: in Advanced under "Not confirmed yet"
bool djiLiveIsLikely(DjiLiveField field, {Map<DjiLiveField, DjiLiveGate> gates = djiLiveGates}) =>
    gates[field]?.evidence == DjiLiveEvidence.likely && djiLivePlace(field, gates: gates) != DjiLivePlace.nowhere;

/// The fields over the picture in [band], in their fixed order
List<DjiLiveField> djiLiveBandFields(DjiLiveBand band, {Map<DjiLiveField, DjiLiveGate> gates = djiLiveGates}) => [
  for (final field in DjiLiveField.values)
    if (gates[field]?.band == band && djiLiveShowsAt(field, DjiLivePlace.overlay, gates: gates)) field,
];

/// One value ready to draw: its small label and its number with the unit
class DjiLiveValue {
  const DjiLiveValue(this.field, this.label, this.value, {this.low = false});

  final DjiLiveField field;
  final String label;
  final String value;

  /// The drone's battery under [djiLiveBatteryLow]
  final bool low;

  /// The one line form, for screen readers and the values line of the window
  String get line => label.isEmpty ? value : '$label $value';
}

/// The motor time as minutes and seconds, the whole seconds only: 41.6 s is 0:41
String djiLiveMinutesSeconds(double seconds) {
  final whole = seconds.isFinite && seconds > 0 ? seconds.floor() : 0;
  return '${whole ~/ 60}:${(whole % 60).toString().padLeft(2, '0')}';
}

/// One decimal under 100 m, whole metres from 100 m, the sign kept: -0.5 m is below the take off point
String djiLiveHeight(double metres) => metres.abs() >= 100 ? metres.toStringAsFixed(0) : metres.toStringAsFixed(1);

/// An arrow up while climbing and down while descending, as the number reads: none at 0.0
String djiLiveVerticalSpeed(double metresPerSecond) {
  final number = metresPerSecond.abs().toStringAsFixed(1);
  if (number == '0.0') {
    return number;
  }
  return metresPerSecond > 0 ? '↑ $number' : '↓ $number';
}

/// The small label of [field] where it shows: over the picture its short form, in Advanced its full one, and a likely
/// value's label ends with a question mark
String djiLiveFieldLabel(
  Translations t,
  DjiLiveField field, {
  DjiLivePlace place = DjiLivePlace.advanced,
  Map<DjiLiveField, DjiLiveGate> gates = djiLiveGates,
}) {
  if (place == DjiLivePlace.overlay) {
    return switch (field) {
      DjiLiveField.droneBattery => t.dji_live_drone_battery_label,
      DjiLiveField.motorTime => t.dji_live_motor_time_label,
      DjiLiveField.signalBars => t.dji_live_value_signal_bars,
      DjiLiveField.remoteBattery => t.dji_live_value_remote_battery_short,
      DjiLiveField.satellites => t.dji_live_value_satellites,
      DjiLiveField.height => t.dji_live_value_height,
      DjiLiveField.verticalSpeed => t.dji_live_value_vertical_speed,
      DjiLiveField.distanceHome => t.dji_live_value_distance_home,
      DjiLiveField.speed => t.dji_live_value_speed,
      DjiLiveField.distanceBelow => t.dji_live_value_distance_below_short,
      // A chip, a number alone and a line under the battery: no label over them
      DjiLiveField.heading || DjiLiveField.landing || DjiLiveField.timeLeft => '',
      DjiLiveField.obstacle ||
      DjiLiveField.obstacleSide ||
      DjiLiveField.motors ||
      DjiLiveField.batteryVoltage ||
      DjiLiveField.batteryTemperature ||
      DjiLiveField.signal ||
      DjiLiveField.linkRate => djiLiveFieldLabel(t, field, gates: gates),
    };
  }
  if (djiLiveIsLikely(field, gates: gates)) {
    return switch (field) {
      DjiLiveField.remoteBattery => t.dji_live_value_remote_battery,
      DjiLiveField.signalBars => t.dji_live_value_signal_bars_likely,
      DjiLiveField.height => t.dji_live_value_height_likely,
      DjiLiveField.verticalSpeed => t.dji_live_value_vertical_speed_likely,
      DjiLiveField.speed => t.dji_live_value_speed_likely,
      DjiLiveField.distanceBelow => t.dji_live_value_distance_below_likely,
      DjiLiveField.obstacle => t.dji_live_value_obstacle_likely,
      _ => '${djiLiveFieldLabel(t, field, place: DjiLivePlace.overlay, gates: djiLiveProvenGates)}?',
    };
  }
  return switch (field) {
    DjiLiveField.droneBattery => t.dji_live_drone_battery_label,
    DjiLiveField.motorTime => t.dji_live_motor_time_label,
    DjiLiveField.motors => t.dji_link_motors,
    DjiLiveField.batteryVoltage => t.dji_live_value_voltage,
    DjiLiveField.batteryTemperature => t.dji_live_value_temperature,
    DjiLiveField.heading => t.dji_live_value_heading,
    DjiLiveField.signal => t.dji_live_value_signal,
    DjiLiveField.linkRate => t.dji_live_value_link_rate,
    DjiLiveField.remoteBattery => t.dji_live_value_remote_battery_short,
    DjiLiveField.signalBars => t.dji_live_value_signal_bars,
    DjiLiveField.satellites => t.dji_live_value_satellites,
    DjiLiveField.landing => t.dji_live_landing,
    // In Advanced the full words: above the take off point, climb positive, over the ground (proof 4.1 to 4.3)
    DjiLiveField.height => t.dji_live_value_height_full,
    DjiLiveField.verticalSpeed => t.dji_live_value_vertical_speed_full,
    DjiLiveField.distanceHome => t.dji_live_value_distance_home,
    DjiLiveField.speed => t.dji_live_value_speed_full,
    DjiLiveField.timeLeft || DjiLiveField.obstacleSide => '',
    DjiLiveField.distanceBelow => t.dji_live_value_distance_below,
    DjiLiveField.obstacle => t.dji_live_value_obstacle,
  };
}

/// Every row proven, for the label of a value whose likely label has no key of its own
final djiLiveProvenGates = <DjiLiveField, DjiLiveGate>{
  for (final field in DjiLiveField.values) field: const DjiLiveGate(DjiLiveEvidence.proven, DjiLivePlace.overlay),
};

/// The unit written after the number of [field], the same on the phone and on the Quest
String djiLiveFieldUnit(DjiLiveField field) => switch (field) {
  DjiLiveField.droneBattery || DjiLiveField.remoteBattery => ' %',
  DjiLiveField.batteryVoltage => ' V',
  DjiLiveField.batteryTemperature => ' °C',
  DjiLiveField.heading => '°',
  DjiLiveField.linkRate => ' Mbit/s',
  DjiLiveField.height || DjiLiveField.distanceHome || DjiLiveField.distanceBelow || DjiLiveField.obstacle => ' m',
  DjiLiveField.verticalSpeed || DjiLiveField.speed => ' m/s',
  DjiLiveField.signalBars => '/5',
  DjiLiveField.motorTime ||
  DjiLiveField.motors ||
  DjiLiveField.signal ||
  DjiLiveField.satellites ||
  DjiLiveField.timeLeft ||
  DjiLiveField.landing ||
  DjiLiveField.obstacleSide => '',
};

/// The number of [field] in [frame], null when its group is stale, never came, or has no source; with its unit
String? djiLiveFieldValue(Translations t, DjiLiveFrame? frame, DjiLiveField field) {
  if (frame == null) {
    return null;
  }
  final number = _number(t, frame, field);
  return number == null ? null : '$number${djiLiveFieldUnit(field)}';
}

String? _number(Translations t, DjiLiveFrame frame, DjiLiveField field) {
  switch (field) {
    case DjiLiveField.droneBattery:
      return frame.droneBatteryPercent?.toString();
    case DjiLiveField.motorTime:
      final seconds = frame.motorTimeS;
      return seconds == null ? null : djiLiveMinutesSeconds(seconds);
    case DjiLiveField.motors:
      final on = frame.motorsOn;
      return on == null ? null : (on ? t.dji_link_bench_on : t.dji_link_bench_off);
    case DjiLiveField.batteryVoltage:
      return frame.batteryVolts?.toStringAsFixed(2);
    case DjiLiveField.batteryTemperature:
      return frame.batteryTemperatureC?.toStringAsFixed(1);
    case DjiLiveField.heading:
      return frame.headingDeg?.toStringAsFixed(0);
    case DjiLiveField.signal:
      return frame.signal?.toString();
    case DjiLiveField.linkRate:
      return frame.linkRateMbps?.toStringAsFixed(1);
    case DjiLiveField.remoteBattery:
      return frame.remoteBatteryPercent?.toString();
    case DjiLiveField.signalBars:
      return frame.signalBars?.toString();
    case DjiLiveField.satellites:
      return frame.satellites?.toString();
    case DjiLiveField.landing:
      return frame.landing ? t.dji_live_landing : null;
    case DjiLiveField.height:
      final metres = frame.heightM;
      return metres == null ? null : djiLiveHeight(metres);
    case DjiLiveField.verticalSpeed:
      final speed = frame.verticalSpeedMps;
      return speed == null ? null : djiLiveVerticalSpeed(speed);
    case DjiLiveField.speed:
      return frame.speedMps?.toStringAsFixed(1);
    case DjiLiveField.distanceBelow:
      return frame.distanceBelowM?.toStringAsFixed(2);
    case DjiLiveField.obstacle:
      return frame.obstacleM?.toStringAsFixed(1);
    // No field of our captures gives these: nothing reads any byte for them
    case DjiLiveField.distanceHome:
    case DjiLiveField.timeLeft:
      return null;
    // Not a value: the ring draws the side or not
    case DjiLiveField.obstacleSide:
      return null;
  }
}

/// Whether the drone's battery of [frame] is low: amber, with its icon and "low" for screen readers
bool djiLiveBatteryIsLow(DjiLiveFrame? frame) {
  final percent = frame?.droneBatteryPercent;
  return percent != null && percent < djiLiveBatteryLow;
}

/// The values of [frame] that may show at [place], in the order of [DjiLiveField], the stale ones left out
List<DjiLiveValue> djiLiveValues(
  Translations t,
  DjiLiveFrame? frame,
  DjiLivePlace place, {
  Map<DjiLiveField, DjiLiveGate> gates = djiLiveGates,
}) {
  if (frame == null) {
    return const [];
  }
  return [
    for (final field in DjiLiveField.values)
      if (djiLiveShowsAt(field, place, gates: gates))
        if (djiLiveFieldValue(t, frame, field) case final String value)
          DjiLiveValue(
            field,
            djiLiveFieldLabel(t, field, place: place, gates: gates),
            value,
            low: field == DjiLiveField.droneBattery && djiLiveBatteryIsLow(frame),
          ),
  ];
}

/// Whether one of height, the speeds and the distance from home does not show over the picture yet; Advanced then says
/// which waits for what
bool djiLiveFlightValuesPending({Map<DjiLiveField, DjiLiveGate> gates = djiLiveGates}) => [
  DjiLiveField.height,
  DjiLiveField.verticalSpeed,
  DjiLiveField.distanceHome,
  DjiLiveField.speed,
].any((field) => !djiLiveShowsAt(field, DjiLivePlace.overlay, gates: gates));

/// How the obstacle ring is offered: not at all while no field is named, behind "Obstacle ring, not confirmed yet"
/// while the field is likely, behind "Show the obstacle ring" once proven; both switches are on by default
enum DjiObstacleOffer { none, test, proven }

DjiObstacleOffer djiObstacleOffer({Map<DjiLiveField, DjiLiveGate> gates = djiLiveGates}) =>
    switch (gates[DjiLiveField.obstacle]?.evidence) {
      DjiLiveEvidence.proven => DjiObstacleOffer.proven,
      DjiLiveEvidence.likely => DjiObstacleOffer.test,
      _ => DjiObstacleOffer.none,
    };

/// How the ring's side is offered (p2/design-obstacle-ring-2026-10-25.md, 2.6): never while its row is a guess, only
/// behind "Show the side, not confirmed yet" while likely (else an even glow all around), by default once proven, as
/// since the flights of 25 October (proof 4.7), with "Show the side" to turn it off
enum DjiObstacleSideOffer { none, test, proven }

DjiObstacleSideOffer djiObstacleSideOffer({Map<DjiLiveField, DjiLiveGate> gates = djiLiveGates}) =>
    switch (gates[DjiLiveField.obstacleSide]?.evidence) {
      DjiLiveEvidence.proven => DjiObstacleSideOffer.proven,
      DjiLiveEvidence.likely => DjiObstacleSideOffer.test,
      _ => DjiObstacleSideOffer.none,
    };

/// The templates of the Quest flight view's two columns, a label and a value per field of the phone's bands
/// ("cell.droneBattery.label" "Drone battery", "cell.droneBattery.value" "{value} %"), under the names the native side
/// reads (FlightViewControls.LEFT_FIELDS and RIGHT_FIELDS): a field without a template has no cell there
Map<String, String> djiLiveFlightViewTemplates(
  Translations t, {
  Map<DjiLiveField, DjiLiveGate> gates = djiLiveGates,
}) => {
  for (final field in DjiLiveField.values)
    if (gates[field]?.band != DjiLiveBand.none && djiLiveShowsAt(field, DjiLivePlace.overlay, gates: gates)) ...{
      'cell.${field.name}.label': djiLiveFieldLabel(t, field, place: DjiLivePlace.overlay, gates: gates),
      'cell.${field.name}.value': field == DjiLiveField.landing
          ? t.dji_live_landing
          : '{value}${djiLiveFieldUnit(field)}',
    },
};
