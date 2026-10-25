// What a headset shows of the way from the phone (design 9.3): the phone to headset delay split into the phone's part
// and the network's, this device's own decoding, phone receive to picture shown here (the jitter buffer included), how
// far behind the phone's own screen the picture is, and the pictures per second. A paced reception adds its jitter
// buffer, what came late or was not shown, the freezes over 0.3 s and this device's network and display
// (relay-smoothness 6.2). A picture that stopped is never shown as live: the red line says for how long no new picture
// was shown, and no delay is given meanwhile; before the clocks are aligned the delay is an estimate, said apart
// (review-relay-2026-10-25 M1). A device that reached the safety net of its queue says it cannot keep up.

import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_texts.dart';

/// After this long without a new picture, the red line says so
const djiLinkStaleLineMs = 500;

/// The line of a device that could not keep up with the drone's stream stays this long after it happened
const djiLinkCannotKeepUpMs = 10000;

/// The delay from the phone the strips show: the most of the last 2 s when measured, else the 10 s median
double? djiLinkDelayNowMs(DjiRelayReceiving? receiving) =>
    receiving?.receiveToPictureNowMs ?? receiving?.receiveToPictureMs;

/// The line of a device whose queue reached its safety net in the last 10 s; null otherwise
String? djiLinkCannotKeepUpLine(Translations t, DjiRelayReceiving? receiving) {
  final ago = receiving?.safetyNetAgoMs;
  return ago != null && ago <= djiLinkCannotKeepUpMs ? t.dji_link_latency_cannot_keep_up : null;
}

/// The red line of a picture that stopped coming while the phone still sends; null while pictures come
String? djiLinkStaleLine(Translations t, DjiRelayReceiving receiving) {
  final ago = receiving.lastPictureAgoMs;
  final pictures = receiving.state == DjiRelayReceiveState.receiving && receiving.units > 0;
  if (!pictures || (ago != null && ago <= djiLinkStaleLineMs)) {
    return null;
  }
  return ago == null
      ? t.dji_link_latency_no_picture
      : t.dji_link_latency_stale(seconds: (ago / 1000).toStringAsFixed(1));
}

/// The lines of a paced reception: the jitter buffer, what came late or was not shown, the freezes, this device's
/// network and display. Empty for a reception that is not paced (no relayed unit yet).
List<String> djiLinkSmoothnessLines(Translations t, DjiRelayReceiving receiving) {
  if (receiving.paced != true) {
    return const [];
  }
  final freezes = receiving.freezes ?? 0;
  final rate = djiLinkNumber(receiving.refreshHz, 0);
  return [
    // The picture of the phone's steady stream (p2/relay-bandwidth-2026-10-25.md, 7.9 item 3)
    if (receiving.steady == true) t.dji_link_receive_steady(rate: djiLinkNumber(receiving.receivedPerSecond, 0)),
    t.dji_link_latency_buffer(
      target: djiLinkNumber(receiving.bufferTargetMs, 0),
      now: djiLinkNumber(receiving.bufferNowMs, 0),
      high: djiLinkNumber(receiving.bufferP95Ms, 0),
    ),
    t.dji_link_latency_smoothness(
      lateCount: '${receiving.lateUnits ?? 0}',
      skipped: '${receiving.renderSkips ?? 0}',
      stalls: '${receiving.decoderStalls ?? 0}',
      flushes: '${receiving.safetyFlushes ?? 0}',
      breaks: '${receiving.breaks ?? 0}',
      primers: '${receiving.primersUsed ?? 0}',
    ),
    if (freezes == 0)
      t.dji_link_latency_freezes_none
    else
      t.dji_link_latency_freezes(
        count: freezes,
        longest: ((receiving.longestFreezeMs ?? 0) / 1000).toStringAsFixed(1),
        source: '${receiving.freezesInSource ?? 0}',
      ),
    if (receiving.network == 'ethernet')
      t.dji_link_latency_network_ethernet(rate: rate)
    else if (receiving.network == 'wifi')
      t.dji_link_latency_network_wifi(
        band: receiving.wifiBand ?? '-',
        speed: receiving.wifiLinkMbps?.toString() ?? '-',
        signal: receiving.wifiRssi?.toString() ?? '-',
        rate: rate,
      ),
  ];
}

class DjiLinkLatencyBlock extends StatelessWidget {
  const DjiLinkLatencyBlock({super.key, required this.receiving, this.decode});

  final DjiRelayReceiving receiving;
  final DjiLinkDecode? decode;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final receiving = this.receiving;
    final decode = this.decode;
    final small = context.textTheme.bodySmall;
    final relay = receiving.relayDelayMedianMs;
    final stale = djiLinkStaleLine(t, receiving);
    final cannotKeepUp = djiLinkCannotKeepUpLine(t, receiving);
    final decoderName = decode?.decoderName;
    return Column(
      key: const Key('dji_link_latency'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (stale != null)
          Text(
            stale,
            key: const Key('dji_link_latency_stale'),
            style: small?.copyWith(fontWeight: FontWeight.w700, color: context.colorScheme.error),
          ),
        if (cannotKeepUp != null)
          Text(
            cannotKeepUp,
            key: const Key('dji_link_latency_cannot_keep_up'),
            style: small?.copyWith(fontWeight: FontWeight.w700, color: context.colorScheme.error),
          ),
        Text(
          relay == null
              ? t.dji_link_latency_measuring
              : t.dji_link_latency_phone_to_headset(
                  median: djiLinkNumber(relay, 0),
                  phone: djiLinkNumber(receiving.phoneQueueMedianMs, 0),
                  network: djiLinkNumber(receiving.networkMedianMs, 0),
                  high: djiLinkNumber(receiving.relayDelayP95Ms, 0),
                  clocks: djiLinkNumber(receiving.clockUncertaintyMs, 0),
                ),
          key: const Key('dji_link_latency_relay'),
          style: small,
        ),
        if (decode != null && decoderName != null)
          Text(
            (decode.lowLatency ? t.dji_link_latency_decoding_low_latency : t.dji_link_latency_decoding)(
              median: djiLinkNumber(decode.decodeMedianMs, 0),
              high: djiLinkNumber(decode.decodeP95Ms, 0),
              decoder: decoderName,
            ),
            key: const Key('dji_link_latency_decoding'),
            style: small,
          ),
        if (receiving.receiveToPictureMs case final double total)
          Text(
            t.dji_link_latency_receive_to_picture(ms: djiLinkNumber(total, 0)),
            key: const Key('dji_link_latency_total'),
            style: small?.copyWith(fontWeight: FontWeight.w700),
          ),
        if (receiving.receiveToPictureNowMs case final double now)
          Text(
            t.dji_link_latency_receive_to_picture_now(ms: djiLinkNumber(now, 0)),
            key: const Key('dji_link_latency_now'),
            style: small,
          ),
        if (receiving.receiveToPictureEstimateMs case final double estimate)
          Text(
            t.dji_link_latency_receive_to_picture_estimate(ms: djiLinkNumber(estimate, 0)),
            key: const Key('dji_link_latency_estimate'),
            style: small,
          ),
        if (receiving.behindPhoneMs case final double behind)
          Text(
            t.dji_link_latency_behind_phone(ms: djiLinkNumber(behind, 0)),
            key: const Key('dji_link_latency_behind'),
            style: small,
          ),
        Text(
          t.dji_link_latency_rates(
            received: djiLinkNumber(receiving.receivedPerSecond, 0),
            decoded: djiLinkNumber(receiving.decodedPerSecond, 0),
            shown: djiLinkNumber(receiving.shownPerSecond, 0),
            wifi: '${receiving.lostOnWifi}',
            radio: '${receiving.lostOnRadio}',
          ),
          key: const Key('dji_link_latency_rates'),
          style: small,
        ),
        if (receiving.lostOnWifi > 0)
          Text(t.dji_link_latency_wifi_slow, key: const Key('dji_link_latency_wifi_slow'), style: small),
        for (final (index, line) in djiLinkSmoothnessLines(t, receiving).indexed)
          Text(line, key: Key('dji_link_latency_smoothness_$index'), style: small),
      ],
    );
  }
}
