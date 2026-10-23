// What a headset shows of the way from the phone (design 9.3): the phone to headset delay split into the phone's part
// and the network's, this device's own decoding, phone receive to decoder output here (the display after it is not
// measured), how far behind the phone's own screen the picture is, and the pictures per second. A picture that stopped
// is never shown as live: the red line says for how long no new picture came.

import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_texts.dart';

/// After this long without a new picture, the red line says so
const djiLinkStaleLineMs = 500;

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
      ],
    );
  }
}
