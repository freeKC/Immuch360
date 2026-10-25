// "Send to a headset" (design 7.1), on a phone: the switch, the code in two groups and "New code", the addresses with
// the port, what is being sent, a row per headset, the screen kept on while sending, and that the stream is not
// encrypted on the network. The headset only watches: nothing it does reaches the remote or the drone.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_counters.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_texts.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_relay_tvs.widget.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';
import 'package:immich_mobile/providers/drone/dji_relay.provider.dart';

/// How long a headset has been connected, in minutes and seconds
String djiRelayDuration(int milliseconds) {
  final seconds = milliseconds ~/ 1000;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// What the phone measured of a receiver's way (its queue here, the drops, the slow writes, the round trip) and, from
/// the long pings of a receiver of this build, what its screen showed; null lines are left out
List<String> djiRelayHeadsetFlowLines(Translations t, DjiRelayHeadsetRow headset) => [
  if (headset.queueMaxAgeMs != null)
    t.dji_link_relay_headset_queue(
      queue: djiLinkNumber(headset.queueAgeMs ?? 0, 0),
      most: djiLinkNumber(headset.queueMaxAgeMs, 0),
      drops: '${headset.dropEvents ?? 0}',
      stalls: '${headset.writeStalls ?? 0}',
      trip: djiLinkNumber(headset.roundTripMs, 0),
    ),
  if (headset.receiverBufferMs != null)
    t.dji_link_relay_headset_screen(
      buffer: djiLinkNumber(headset.receiverBufferMs, 0),
      freezes: '${headset.receiverFreezes ?? 0}',
      longest: ((headset.receiverLongestFreezeMs ?? 0) / 1000).toStringAsFixed(1),
      skipped: '${headset.receiverSkips ?? 0}',
      lateCount: '${headset.receiverLate ?? 0}',
    ),
];

String djiRelaySendingText(Translations t, String? sending) => switch (sending) {
  'cable' => t.dji_link_relay_sending_cable,
  'replay' => t.dji_link_relay_sending_replay,
  _ => t.dji_link_relay_sending_none,
};

class DjiLinkSendSection extends ConsumerWidget {
  const DjiLinkSendSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final relay = ref.watch(djiRelayProvider);
    final notifier = ref.read(djiRelayProvider.notifier);
    final sending = ref.watch(djiLinkProvider.select((state) => state.snapshot?.relaySending));
    final small = context.textTheme.bodySmall;
    final code = relay.code;
    final port = relay.port ?? sending?.port ?? djiRelayDefaultPort;
    return Column(
      key: const Key('dji_link_send'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.dji_link_relay_intro, style: small),
        SwitchListTile(
          key: const Key('dji_link_relay_switch'),
          contentPadding: EdgeInsets.zero,
          title: Text(t.dji_link_relay),
          value: relay.sending || relay.starting,
          onChanged: relay.starting ? null : (on) => unawaited(on ? notifier.startSending() : notifier.stopSending()),
        ),
        if (relay.startFailed)
          Text(
            t.dji_link_relay_start_failed,
            key: const Key('dji_link_relay_start_failed'),
            style: small?.copyWith(color: context.colorScheme.error),
          ),
        if (relay.sending) ...[
          Text(t.dji_link_relay_code, style: context.textTheme.labelMedium),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  code == null ? '-' : formatPairingCode(code),
                  key: const Key('dji_link_relay_code'),
                  style: const TextStyle(fontFamily: 'GoogleSansCode', fontSize: 26, letterSpacing: 3),
                ),
              ),
              TextButton(
                key: const Key('dji_link_relay_new_code'),
                onPressed: () => unawaited(notifier.newCode()),
                child: Text(t.dji_link_relay_new_code),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(t.dji_link_relay_addresses, style: context.textTheme.labelMedium),
          if (relay.addresses.isEmpty)
            Text(t.dji_link_relay_no_address, key: const Key('dji_link_relay_no_address'), style: small)
          else
            for (final (index, address) in relay.addresses.indexed)
              SelectableText(
                address.hotspot
                    ? t.dji_link_relay_address_hotspot(address: '${address.address}:$port')
                    : '${address.address}:$port',
                key: Key('dji_link_relay_address_$index'),
                style: small?.copyWith(fontFamily: 'monospace', fontWeight: FontWeight.w700),
              ),
          if (!relay.announced)
            Text(t.dji_link_relay_not_announced, key: const Key('dji_link_relay_not_announced'), style: small),
          const SizedBox(height: 6),
          Text(
            djiRelaySendingText(t, sending?.sending),
            key: const Key('dji_link_relay_sending'),
            style: small?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(t.dji_link_relay_headsets, style: context.textTheme.labelMedium),
          if (sending == null || sending.headsets.isEmpty)
            Text(t.dji_link_relay_headsets_none, key: const Key('dji_link_relay_headsets_none'), style: small)
          else
            for (final (index, headset) in sending.headsets.indexed)
              Padding(
                key: Key('dji_link_relay_headset_$index'),
                padding: const EdgeInsets.only(top: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      // A TV says so in its hello, whether it proved its own code or the phone's
                      headset.kind == 'tv'
                          ? t.dji_link_relay_headset_tv(
                              name: headset.name ?? '-',
                              address: headset.address,
                              duration: djiRelayDuration(headset.connectedForMs),
                            )
                          : t.dji_link_relay_headset(
                              name: headset.name ?? '-',
                              address: headset.address,
                              duration: djiRelayDuration(headset.connectedForMs),
                            ),
                      style: small?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      t.dji_link_relay_headset_numbers(
                        pictures: djiLinkNumber(headset.picturesShownPerSecond, 0),
                        delay: djiLinkNumber(headset.relayDelayMs, 0),
                        dropped: '${headset.droppedUnits}',
                        megabits: djiLinkNumber(headset.megabitsPerSecond),
                      ),
                      style: small,
                    ),
                    for (final (line, text) in djiRelayHeadsetFlowLines(t, headset).indexed)
                      Text(text, key: Key('dji_link_relay_headset_${index}_flow_$line'), style: small),
                  ],
                ),
              ),
          if (sending != null) ...[
            DjiLinkFact(t.dji_link_relay_refused, '${sending.refusedProofs}'),
            DjiLinkFact(t.dji_link_relay_unexpected, '${sending.unexpectedRecords}'),
            DjiLinkFact(t.dji_link_relay_low_latency, sending.wifiLowLatencyHeld ? t.dji_link_yes : t.dji_link_no),
          ],
          SwitchListTile(
            key: const Key('dji_link_relay_keep_screen_on'),
            contentPadding: EdgeInsets.zero,
            title: Text(t.dji_link_relay_keep_screen_on, style: small),
            subtitle: Text(t.dji_link_relay_keep_screen_on_note, style: small),
            value: relay.keepScreenOn,
            onChanged: (on) => unawaited(notifier.setKeepScreenOn(on)),
          ),
        ],
        const DjiRelayTvsSection(),
        const SizedBox(height: 8),
        Text(t.dji_link_relay_not_encrypted, key: const Key('dji_link_relay_not_encrypted'), style: small),
      ],
    );
  }
}
