// "Receive from a phone" (design 8.2): the phones that send on this network (announced under the app's own pairing
// type with kind=drone), or the address the phone shows, and the code the phone shows, typed once per phone. Nothing
// typed here reaches the remote: the headset only watches.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';
import 'package:immich_mobile/providers/drone/dji_relay.provider.dart';

/// The state of the receiver in words
String djiRelayReceiveStateText(Translations t, DjiRelayReceiving receiving) {
  final phone = receiving.phoneName ?? receiving.host ?? '-';
  return switch (receiving.state) {
    DjiRelayReceiveState.idle => t.dji_link_receive_state_idle,
    DjiRelayReceiveState.connecting => t.dji_link_receive_state_connecting(phone: phone),
    DjiRelayReceiveState.checkingCode => t.dji_link_receive_state_checking,
    DjiRelayReceiveState.receiving => switch (receiving.phoneSource) {
      'cable' => t.dji_link_receive_state_live(phone: phone),
      'replay' => t.dji_link_receive_state_replay(
        phone: phone,
        name: receiving.replayName ?? '-',
        seconds: ((receiving.replayPositionMs ?? 0) / 1000).toStringAsFixed(1),
      ),
      _ => t.dji_link_receive_state_no_source(phone: phone),
    },
    DjiRelayReceiveState.lost => t.dji_link_receive_state_lost(
      seconds: ((receiving.reconnectInMs ?? 0) / 1000).toStringAsFixed(1),
    ),
    DjiRelayReceiveState.wrongCode => t.dji_link_receive_state_wrong_code,
    DjiRelayReceiveState.full => t.dji_link_receive_state_full,
    DjiRelayReceiveState.blocked => t.dji_link_receive_state_blocked,
    DjiRelayReceiveState.otherVersion => t.dji_link_receive_state_other_version,
    DjiRelayReceiveState.phoneUnproven => t.dji_link_receive_state_unproven,
    DjiRelayReceiveState.busy => t.dji_link_receive_state_busy,
  };
}

/// Why a connect was refused before it started
String djiRelayConnectErrorText(Translations t, String error) => switch (error) {
  'badCode' => t.dji_link_receive_code_invalid,
  'busy' => t.dji_link_receive_state_busy,
  'sending' => t.dji_link_receive_sending,
  _ => t.dji_link_receive_address_invalid,
};

class DjiLinkReceiveSection extends ConsumerStatefulWidget {
  const DjiLinkReceiveSection({super.key});

  @override
  ConsumerState<DjiLinkReceiveSection> createState() => _DjiLinkReceiveSectionState();
}

class _DjiLinkReceiveSectionState extends ConsumerState<DjiLinkReceiveSection> {
  final _address = TextEditingController();
  final _code = TextEditingController();
  late final DjiRelayNotifier _relay;

  /// The phone chosen in the list; null while the address is typed
  DjiRelayPhone? _chosen;
  String? _inputError;

  @override
  void initState() {
    super.initState();
    _relay = ref.read(djiRelayProvider.notifier);
    // Looked for as long as the section shows; after the first frame, which a change of the provider must not reach
    unawaited(Future.microtask(_relay.startBrowsing));
  }

  @override
  void dispose() {
    _relay.stopBrowsing();
    _address.dispose();
    _code.dispose();
    super.dispose();
  }

  void _choose(DjiRelayPhone phone) {
    setState(() {
      _chosen = phone;
      _inputError = null;
      _address.text = phone.address;
      final remembered = phone.id == null ? null : ref.read(djiRelayProvider).rememberedCodes[phone.id];
      if (remembered != null) {
        _code.text = formatPairingCode(remembered);
      }
    });
  }

  Future<void> _connect() async {
    final t = context.t;
    if (normalizePairingCode(_code.text) == null) {
      setState(() => _inputError = t.dji_link_receive_code_invalid);
      return;
    }
    final chosen = _chosen;
    DjiRelayPhone phone;
    if (chosen != null && _address.text.trim() == chosen.address) {
      phone = chosen;
    } else {
      final typed = parseDjiRelayAddress(_address.text);
      if (typed == null) {
        setState(() => _inputError = t.dji_link_receive_address_invalid);
        return;
      }
      // A typed address whose phone is listed keeps that phone's id, for its remembered code
      final listed = ref
          .read(djiRelayProvider)
          .phones
          .where((phone) => phone.host == typed.host && phone.port == typed.port)
          .firstOrNull;
      phone = listed ?? DjiRelayPhone(name: typed.host, host: typed.host, port: typed.port);
    }
    setState(() => _inputError = null);
    await _relay.connect(phone, _code.text);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final relay = ref.watch(djiRelayProvider);
    final receiving = ref.watch(djiLinkProvider.select((state) => state.snapshot?.relayReceiving));
    final small = context.textTheme.bodySmall;
    // A remembered code fills the empty field when it is read after the phone was chosen
    ref.listen(djiRelayProvider.select((state) => state.rememberedCodes), (_, codes) {
      final remembered = _chosen?.id == null ? null : codes[_chosen!.id];
      if (remembered != null && _code.text.isEmpty) {
        _code.text = formatPairingCode(remembered);
      }
    });
    final active = receiving != null && receiving.state != DjiRelayReceiveState.idle;
    final error = _inputError ?? (relay.connectError == null ? null : djiRelayConnectErrorText(t, relay.connectError!));
    return Column(
      key: const Key('dji_link_receive'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.dji_link_receive_intro, style: small),
        const SizedBox(height: 8),
        Text(t.dji_link_receive_phones, style: context.textTheme.labelMedium),
        if (relay.phones.isEmpty)
          Text(t.dji_link_receive_none_found, key: const Key('dji_link_receive_none_found'), style: small)
        else
          RadioGroup<String>(
            groupValue: _chosen?.address,
            onChanged: (value) {
              final phone = relay.phones.where((phone) => phone.address == value).firstOrNull;
              if (phone != null) {
                _choose(phone);
              }
            },
            child: Column(
              children: [
                for (final phone in relay.phones)
                  RadioListTile<String>(
                    key: ValueKey('dji_link_receive_phone_${phone.address}'),
                    value: phone.address,
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(phone.name),
                    subtitle: Text(phone.address),
                    secondary: const Icon(Icons.smartphone_rounded),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        TextField(
          key: const Key('dji_link_receive_address'),
          controller: _address,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: t.dji_link_receive_address,
            hintText: '192.168.1.23:$djiRelayDefaultPort',
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          key: const Key('dji_link_receive_code'),
          controller: _code,
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.characters,
          inputFormatters: [LengthLimitingTextInputFormatter(14)],
          style: const TextStyle(fontFamily: 'GoogleSansCode', fontSize: 20, letterSpacing: 2),
          decoration: InputDecoration(
            labelText: t.dji_link_receive_code,
            hintText: 'K7M2Q 9XRTH',
            isDense: true,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (_) => unawaited(_connect()),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              error,
              key: const Key('dji_link_receive_error'),
              style: small?.copyWith(color: context.colorScheme.error),
            ),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              key: const Key('dji_link_receive_connect'),
              onPressed: () => unawaited(_connect()),
              child: Text(t.dji_link_receive_connect),
            ),
            OutlinedButton(
              key: const Key('dji_link_receive_disconnect'),
              onPressed: active || relay.target != null ? () => unawaited(_relay.disconnect()) : null,
              child: Text(t.dji_link_receive_disconnect),
            ),
          ],
        ),
        if (receiving != null) ...[
          const SizedBox(height: 6),
          Text(
            djiRelayReceiveStateText(t, receiving),
            key: const Key('dji_link_receive_state'),
            style: small?.copyWith(
              fontWeight: FontWeight.w700,
              color: switch (receiving.state) {
                DjiRelayReceiveState.wrongCode ||
                DjiRelayReceiveState.phoneUnproven ||
                DjiRelayReceiveState.otherVersion ||
                DjiRelayReceiveState.blocked ||
                DjiRelayReceiveState.busy => context.colorScheme.error,
                _ => null,
              },
            ),
          ),
        ],
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(t.dji_link_receive_not_encrypted, key: const Key('dji_link_receive_not_encrypted'), style: small),
        ),
      ],
    );
  }
}
