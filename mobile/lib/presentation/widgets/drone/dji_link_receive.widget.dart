// The words of a headset's reception (design 8.2): where the reception of a phone's picture stands, and why a connect
// was refused before it started. The watch page and the Diagnostics page say them; nothing typed on a headset reaches
// the remote, the headset only watches.

import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';

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
