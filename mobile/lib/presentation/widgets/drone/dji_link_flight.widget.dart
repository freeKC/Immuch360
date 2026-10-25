// The flight and battery section of Diagnostics: the fields our captures of 23 to 25 October 2026 explain
// (p2/telemetry-flight-2026-10-24.md, p2/telemetry-proof-2026-10-25.md), each group with how it is known, greyed with
// its age when it stopped coming. Each label says the class the telemetry reports give its value: a proven value plain,
// with what it means where that matters (the height in the air only, the speeds along the heading's axes, offset 41 a
// smoothed distance below), a likely one "(likely)", a guess "(guess)", the heading with its zero not checked. The
// values are raw here, on the ground too, so the height's label says it means something in the air only; the live
// screens show the height and the speeds in the air only, the height after the native HeightHold. Bit 0x04 is only
// likely "in the air", so that row is not drawn. Not a flight instrument: nothing here has been compared with DJI Fly
// yet, and the note says so in every state.

import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_counters.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_texts.dart';

class DjiLinkFlightSection extends StatelessWidget {
  const DjiLinkFlightSection({super.key, required this.telemetry});

  final DjiLinkTelemetry? telemetry;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final telemetry = this.telemetry;
    final note = Text(
      t.dji_link_flight_note,
      key: const Key('dji_link_flight_note'),
      style: context.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700, color: context.colorScheme.error),
    );
    if (telemetry == null) {
      return Column(
        key: const Key('dji_link_flight'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          note,
          Text(t.dji_link_flight_none, style: context.textTheme.bodySmall),
        ],
      );
    }
    final flight = telemetry.flight;
    final battery = telemetry.battery;
    final gimbal = telemetry.gimbal;
    final link = telemetry.link;
    return Column(
      key: const Key('dji_link_flight'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        note,
        const SizedBox(height: 6),
        DjiLinkFact(
          t.dji_link_aircraft_present,
          telemetry.aircraftPresent ? t.dji_link_yes : t.dji_link_no,
          highlight: true,
        ),
        DjiLinkFact(
          t.dji_link_remote_present,
          telemetry.remotePresent ? t.dji_link_yes : t.dji_link_no,
          highlight: true,
        ),
        if (flight == null && battery == null && link?.aircraftClockMs == null)
          Text(t.dji_link_flight_none, style: context.textTheme.bodySmall),
        if (flight != null)
          _Group(
            key: const Key('dji_link_flight_group'),
            title: t.dji_link_flight_group,
            evidence: djiLinkEvidenceText(t, flight.evidence),
            stale: flight.stale,
            ageMs: flight.ageMs,
            facts: [
              (t.dji_link_height, '${flight.heightM.toStringAsFixed(1)} m'),
              (t.dji_link_heading, '${flight.headingDeg.toStringAsFixed(1)} °'),
              (t.dji_link_attitude, '${flight.pitchDeg.toStringAsFixed(1)} °, ${flight.rollDeg.toStringAsFixed(1)} °'),
              (t.dji_link_speeds, '${flight.speedsMps.map((speed) => speed.toStringAsFixed(1)).join(', ')} m/s'),
              (
                t.dji_link_flight_mode,
                flight.mode == 12 ? t.dji_link_flight_mode_landing(mode: '${flight.mode}') : '${flight.mode}',
              ),
              (t.dji_link_motors, flight.motorsOn ? t.dji_link_bench_on : t.dji_link_bench_off),
              (t.dji_link_motor_time, '${flight.motorTimeS.toStringAsFixed(1)} s'),
              (t.dji_link_satellites, '${flight.satellites}'),
              (t.dji_link_ground_height, '${flight.groundHeightM.toStringAsFixed(1)} m'),
            ],
          ),
        if (battery != null)
          _Group(
            key: const Key('dji_link_battery_group'),
            title: t.dji_link_battery,
            evidence: djiLinkEvidenceText(t, battery.evidence),
            stale: battery.stale,
            ageMs: battery.ageMs,
            facts: [
              (t.dji_link_battery_charge, '${battery.percent} %'),
              (t.dji_link_battery_voltage, '${battery.volts.toStringAsFixed(3)} V'),
              (t.dji_link_battery_current, '${battery.amps.toStringAsFixed(3)} A'),
              (
                t.dji_link_battery_capacity,
                t.dji_link_battery_remaining(remaining: '${battery.remainingMah}', full: '${battery.fullMah}'),
              ),
              (t.dji_link_battery_temperature, '${battery.temperatureC.toStringAsFixed(1)} °C'),
              (t.dji_link_battery_cells, '${battery.cells}'),
            ],
          ),
        if (link != null &&
            (link.aircraftClockMs != null ||
                link.signalAircraftSide != null ||
                link.signalRemoteSide != null ||
                link.liveRateMbps != null))
          _Group(
            key: const Key('dji_link_link_group'),
            title: t.dji_link_link_group,
            // The signal follows each link up of our captures, the top of its scale not known; the rate is a rate of
            // the video link, 1.0 to 1.35 times the video measured (p2/telemetry-flight-2026-10-24.md, 3.5)
            evidence: t.dji_link_evidence_link,
            stale: link.stale,
            ageMs: link.ageMs,
            facts: [
              (
                t.dji_link_signal,
                t.dji_link_signal_value(
                  aircraft: link.signalAircraftSide == null ? '-' : '${link.signalAircraftSide}',
                  remote: link.signalRemoteSide == null ? '-' : '${link.signalRemoteSide}',
                ),
              ),
              (t.dji_link_live_rate, '${djiLinkNumber(link.liveRateMbps)} Mbit/s'),
              (t.dji_link_aircraft_clock, link.aircraftClockMs == null ? '-' : '${link.aircraftClockMs} ms'),
              (t.dji_link_clock_jitter, '${djiLinkNumber(link.clockJitterP95Ms, 0)} ms'),
              (t.dji_link_clock_drift, '${djiLinkNumber(link.clockDriftMs, 0)} ms'),
            ],
          ),
        if (telemetry.remoteBatteryPercent != null)
          _Group(
            key: const Key('dji_link_remote_group'),
            title: t.dji_link_remote_group,
            evidence: djiLinkEvidenceText(t, DjiLinkEvidence.candidate),
            stale: telemetry.remoteBatteryStale,
            ageMs: telemetry.remoteBatteryAgeMs,
            facts: [(t.dji_link_remote_battery, '${telemetry.remoteBatteryPercent} %')],
          ),
        if (gimbal != null)
          _Group(
            key: const Key('dji_link_gimbal_group'),
            title: t.dji_link_message_gimbal,
            evidence: djiLinkEvidenceText(t, gimbal.evidence),
            stale: gimbal.stale,
            ageMs: gimbal.ageMs,
            facts: [
              (t.dji_link_gimbal_heading, '${gimbal.headingFineDeg.toStringAsFixed(2)} °'),
              (t.dji_link_gimbal_orientation, gimbal.quaternion.map((value) => value.toStringAsFixed(4)).join(', ')),
            ],
          ),
        const SizedBox(height: 6),
        DjiLinkFact(t.dji_link_layout_mismatch, '${telemetry.layoutMismatches}'),
        if (telemetry.unanswered.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(t.dji_link_unanswered, style: context.textTheme.labelMedium),
          for (final row in telemetry.unanswered)
            DjiLinkFact(
              t.dji_link_unanswered_request(
                sender: '${row.senderType}.${row.senderIndex}',
                commandSet: '${row.commandSet}',
                commandId: '${row.commandId}',
                policy: '${row.ackPolicy}',
              ),
              t.dji_link_unanswered_value(requests: '${row.count}', repeats: '${row.repeats}'),
            ),
        ],
      ],
    );
  }
}

/// One group of values: its title, its values greyed with their age when stale, and how it is known
class _Group extends StatelessWidget {
  const _Group({
    super.key,
    required this.title,
    required this.evidence,
    required this.stale,
    required this.ageMs,
    required this.facts,
  });

  final String title;

  /// How the values are known, said under the title
  final String evidence;
  final bool stale;

  /// Null when the age is not known: a stale group then says so without a number of seconds
  final int? ageMs;
  final List<(String, String)> facts;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final (label, value) in facts) DjiLinkFact(label, value)],
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: context.textTheme.labelMedium),
          Text(
            [
              evidence,
              if (stale)
                switch (ageMs) {
                  final int age => t.dji_link_stale(seconds: (age / 1000).toStringAsFixed(1)),
                  null => t.dji_link_stale_no_age,
                },
            ].join(', '),
            style: context.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
          ),
          if (stale) Opacity(key: const Key('dji_link_stale'), opacity: 0.45, child: body) else body,
        ],
      ),
    );
  }
}
