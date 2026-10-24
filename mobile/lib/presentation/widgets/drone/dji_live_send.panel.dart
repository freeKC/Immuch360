// "Send to a headset" on the live screen (p2/design-ux-phone-2026-10-24.md, section 5): one switch, one line saying
// where sending stands, the code in large letters while it is on, and two folded helps (no Wi-Fi, a headset that does
// not list the phone). The numbers of each headset, the refused codes and the screen switch stay on the Diagnostics
// page, on the same relay, so that both places always agree. The headset only watches: nothing it does reaches the
// remote or the drone.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';
import 'package:immich_mobile/providers/drone/dji_relay.provider.dart';
import 'package:immich_mobile/providers/network/phone_share.provider.dart';

/// The line under the switch; null while sending starts
String? djiLiveSendLine(Translations t, DjiRelayState relay, DjiRelaySending? sending) {
  if (relay.starting) {
    return null;
  }
  if (relay.startFailed) {
    return t.dji_link_relay_start_failed;
  }
  if (!relay.sending) {
    return relay.stoppedRemotely ? t.dji_live_send_stopped : t.dji_live_send_off;
  }
  final headsets = sending?.headsets ?? const <DjiRelayHeadsetRow>[];
  if (headsets.isNotEmpty) {
    return t.dji_live_send_watching(names: headsets.map((headset) => headset.name ?? headset.address).join(', '));
  }
  if (sending == null || sending.sending == 'none') {
    return t.dji_live_send_nothing;
  }
  // The name the headset lists, "Immuch360 on Galaxy S24+", not the bare device name
  final phoneName = relay.phoneName;
  return t.dji_live_send_waiting(phone: phoneName == null ? '-' : phoneShareServiceName(phoneName));
}

class DjiLiveSendPanel extends ConsumerWidget {
  const DjiLiveSendPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final relay = ref.watch(djiRelayProvider);
    final notifier = ref.read(djiRelayProvider.notifier);
    final sending = ref.watch(djiLinkProvider.select((state) => state.snapshot?.relaySending));
    final small = context.textTheme.bodySmall;
    final line = djiLiveSendLine(t, relay, sending);
    final code = relay.code;
    final port = relay.port ?? sending?.port ?? djiRelayDefaultPort;
    return ListView(
      key: const Key('dji_live_send_panel'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                t.dji_link_relay,
                style: context.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            Switch(
              key: const Key('dji_live_send_switch'),
              value: relay.sending || relay.starting,
              onChanged: relay.starting
                  ? null
                  : (on) => unawaited(on ? notifier.startSending() : notifier.stopSending()),
            ),
          ],
        ),
        if (line != null)
          Text(
            line,
            key: const Key('dji_live_send_line'),
            style: relay.startFailed ? small?.copyWith(color: context.colorScheme.error) : small,
          ),
        if (relay.sending) ...[
          const SizedBox(height: 16),
          Text(t.dji_live_send_code, style: context.textTheme.labelMedium),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  code == null ? '-' : formatPairingCode(code),
                  key: const Key('dji_live_send_code'),
                  style: const TextStyle(fontFamily: 'GoogleSansCode', fontSize: 32, letterSpacing: 3),
                ),
              ),
              TextButton(
                key: const Key('dji_live_send_new_code'),
                onPressed: () => unawaited(notifier.newCode()),
                child: Text(t.dji_link_relay_new_code),
              ),
            ],
          ),
          Text(t.dji_live_send_new_code_note, style: small),
          const SizedBox(height: 8),
          ExpansionTile(
            key: const Key('dji_live_send_no_wifi'),
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 8),
            expandedAlignment: Alignment.centerLeft,
            title: Text(t.dji_live_send_no_wifi_title, style: context.textTheme.bodyMedium),
            children: [Text(t.dji_live_send_no_wifi, style: small)],
          ),
          ExpansionTile(
            // A new tile when the announcement changes, so that it opens by itself only while there is none
            key: Key(relay.announced ? 'dji_live_send_not_listed' : 'dji_live_send_not_listed_open'),
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 8),
            expandedAlignment: Alignment.centerLeft,
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            // Open at once when the phone could not announce itself: the address is then the only way in
            initiallyExpanded: !relay.announced,
            title: Text(t.dji_live_send_not_listed_title, style: context.textTheme.bodyMedium),
            children: [
              Text(t.dji_live_send_not_listed, style: small),
              if (relay.addresses.isEmpty)
                Text(t.dji_link_relay_no_address, key: const Key('dji_live_send_no_address'), style: small)
              else
                for (final (index, address) in relay.addresses.indexed)
                  SelectableText(
                    address.hotspot
                        ? t.dji_link_relay_address_hotspot(address: '${address.address}:$port')
                        : '${address.address}:$port',
                    key: Key('dji_live_send_address_$index'),
                    style: small?.copyWith(fontFamily: 'monospace', fontWeight: FontWeight.w700),
                  ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        Text(
          t.dji_link_observer_note,
          key: const Key('dji_live_send_observer'),
          style: small?.copyWith(fontWeight: FontWeight.w700, color: context.colorScheme.error),
        ),
        const SizedBox(height: 6),
        Text(t.dji_link_relay_not_encrypted, style: small),
      ],
    );
  }
}
