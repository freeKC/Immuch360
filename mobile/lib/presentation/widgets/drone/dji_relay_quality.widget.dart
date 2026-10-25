// "Relay quality" and the lines of the steady stream (p2/relay-bandwidth-2026-10-25.md, 7.9 and 7.10). In Advanced on
// the phone's live screen: three choices, Automatic by default, each with one line, and under them, while sending, the
// steady stream's line and one line per receiver with what its Wi-Fi carries. The Send panel and Diagnostics show the
// same lines. The phone decides what each receiver gets; a receiver only says how it receives.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_texts.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';
import 'package:immich_mobile/providers/drone/dji_relay_quality.provider.dart';

String djiRelayQualityName(Translations t, DjiRelayQuality quality) => switch (quality) {
  DjiRelayQuality.automatic => t.dji_link_relay_quality_automatic,
  DjiRelayQuality.full => t.dji_link_relay_quality_full,
  DjiRelayQuality.steady => t.dji_link_relay_quality_steady,
};

String djiRelayQualityNote(Translations t, DjiRelayQuality quality) => switch (quality) {
  DjiRelayQuality.automatic => t.dji_link_relay_quality_automatic_note,
  DjiRelayQuality.full => t.dji_link_relay_quality_full_note,
  DjiRelayQuality.steady => t.dji_link_relay_quality_steady_note,
};

/// Why there is no steady stream, in words; the native side's word when it is one this build does not know
String djiRelaySteadyWhy(Translations t, String why) => switch (why) {
  'noEncoder' => t.dji_link_relay_steady_why_no_encoder,
  'refused' => t.dji_link_relay_steady_why_refused,
  'noSecondDecoder' => t.dji_link_relay_steady_why_no_decoder,
  'tooSlow' => t.dji_link_relay_steady_why_slow,
  'decoderTooSlow' => t.dji_link_relay_steady_why_decoder_slow,
  'pilotFirst' => t.dji_link_relay_steady_why_pilot,
  'failed' => t.dji_link_relay_steady_why_failed,
  _ => why,
};

/// The steady stream's line: running with its numbers, ready, or why there is none; null while the relay is off or the
/// phone has none to describe
String? djiRelaySteadyLine(Translations t, DjiRelaySending? sending) {
  final state = sending?.steadyState;
  if (sending == null || !sending.on || state == null) {
    return null;
  }
  final why = sending.steadyWhy;
  if (why == 'hot') {
    return t.dji_link_relay_steady_hot;
  }
  if (state == 'unavailable' && why != null) {
    return t.dji_link_relay_steady_unavailable(why: djiRelaySteadyWhy(t, why));
  }
  if (state == 'stopped' && why != null) {
    return t.dji_link_relay_steady_stopped(why: djiRelaySteadyWhy(t, why));
  }
  final encoder = sending.steadyEncoder ?? '-';
  if (state == 'off' && sending.quality == DjiRelayQuality.full) {
    // Full stream is the off switch: nothing is ready to send
    return t.dji_link_relay_steady_off;
  }
  if (state != 'running') {
    return t.dji_link_relay_steady_ready(encoder: encoder);
  }
  final width = sending.steadyWidth;
  final height = sending.steadyHeight;
  return t.dji_link_relay_steady_line(
    encoder: encoder,
    frame: width == null || height == null ? '-' : '${width}x$height',
    rate: '${sending.steadyPerSecond ?? 30}',
    megabits: djiLinkNumber(sending.steadyMegabits),
    median: djiLinkNumber(sending.steadyEncodeMedianMs, 0),
    p95: djiLinkNumber(sending.steadyEncodeP95Ms, 0),
  );
}

/// A duration of a connection or a stream, in minutes and seconds
String djiRelayStreamDuration(int milliseconds) {
  final seconds = milliseconds ~/ 1000;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// What a receiver gets: the full stream (of an earlier build: always), or the steady stream since when and why
String djiRelayReceiverStream(Translations t, DjiRelayHeadsetRow row, DjiRelayQuality quality) {
  if (row.steadyCapable == false) {
    return t.dji_link_relay_receiver_earlier;
  }
  if (row.stream != 'steady') {
    return t.dji_link_relay_receiver_full;
  }
  final time = djiRelayStreamDuration(row.streamForMs ?? 0);
  return quality == DjiRelayQuality.steady
      ? t.dji_link_relay_receiver_steady_setting(time: time)
      : t.dji_link_relay_receiver_steady(time: time);
}

/// What a receiver's Wi-Fi carries, its best second and what the drone sends; then its own Wi-Fi when it says it
List<String> djiRelayLinkLines(Translations t, DjiRelayHeadsetRow row, double? droneMegabits) => [
  t.dji_link_relay_link(
    name: row.name ?? row.address,
    carried: djiLinkNumber(row.megabitsPerSecond),
    best: djiLinkNumber(row.bestSecondMegabits),
    stream: djiLinkNumber(droneMegabits),
  ),
  if (row.wifiBand != null || row.wifiLinkMbps != null)
    t.dji_link_relay_receiver_wifi(
      band: row.wifiBand ?? '-',
      speed: row.wifiLinkMbps?.toString() ?? '-',
      signal: row.wifiRssi?.toString() ?? '-',
    ),
];

/// The steady stream's line and, per receiver, its stream and its link: in the Send panel, Diagnostics and Advanced
class DjiRelayStreamLines extends ConsumerWidget {
  const DjiRelayStreamLines({super.key, this.prefix = 'dji_relay'});

  /// The start of the keys of the lines, so that each place has its own
  final String prefix;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final small = context.textTheme.bodySmall;
    final sending = ref.watch(djiLinkProvider.select((state) => state.snapshot?.relaySending));
    if (sending == null || !sending.on) {
      return const SizedBox.shrink();
    }
    final steady = djiRelaySteadyLine(t, sending);
    final quality = sending.quality ?? DjiRelayQuality.automatic;
    return Column(
      key: Key('${prefix}_streams'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (steady != null) Text(steady, key: Key('${prefix}_steady_line'), style: small),
        for (final (index, row) in sending.headsets.indexed) ...[
          Text(
            '${row.name ?? row.address}: ${djiRelayReceiverStream(t, row, quality)}',
            key: Key('${prefix}_receiver_${index}_stream'),
            style: small?.copyWith(fontWeight: FontWeight.w600),
          ),
          for (final (line, text) in djiRelayLinkLines(t, row, sending.droneMegabits).indexed)
            Text(text, key: Key('${prefix}_receiver_${index}_link_$line'), style: small),
        ],
      ],
    );
  }
}

/// "Relay quality" in Advanced: three choices, each with its line, Automatic by default; under them while sending,
/// the steady stream's line and each receiver's link
class DjiRelayQualitySection extends ConsumerStatefulWidget {
  const DjiRelayQualitySection({super.key});

  @override
  ConsumerState<DjiRelayQualitySection> createState() => _DjiRelayQualitySectionState();
}

class _DjiRelayQualitySectionState extends ConsumerState<DjiRelayQualitySection> {
  @override
  void initState() {
    super.initState();
    unawaited(Future.microtask(() => ref.read(djiRelayQualityProvider.notifier).load()));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final small = context.textTheme.bodySmall;
    final quality = ref.watch(djiRelayQualityProvider);
    final notifier = ref.read(djiRelayQualityProvider.notifier);
    return Column(
      key: const Key('dji_relay_quality_section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.dji_link_relay_quality, style: context.textTheme.labelLarge),
        RadioGroup<DjiRelayQuality>(
          groupValue: quality,
          onChanged: (choice) {
            if (choice != null) {
              unawaited(notifier.set(choice));
            }
          },
          child: Column(
            children: [
              for (final choice in DjiRelayQuality.values)
                RadioListTile<DjiRelayQuality>(
                  key: Key('dji_relay_quality_${choice.name}'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(djiRelayQualityName(t, choice)),
                  subtitle: Text(djiRelayQualityNote(t, choice), style: small),
                  value: choice,
                ),
            ],
          ),
        ),
        const DjiRelayStreamLines(prefix: 'dji_relay_quality'),
      ],
    );
  }
}
