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

/// What a line of the reception says, in kind, for the warnings that come and go over the picture (FreeKC's rule of 25
/// October, dji_live_transient.dart): a new kind shows the line again, and the kinds that need an action, or that say
/// why no picture comes, keep it until they are resolved
enum DjiReceiveLine {
  idle,
  connecting,
  checking,
  live,
  replay,
  noSource(keeps: true),
  lost,
  wrongCode(keeps: true),
  full(keeps: true),
  blocked(keeps: true),
  otherVersion(keeps: true),
  unproven(keeps: true),
  busy(keeps: true),

  /// A TV's own lines ([djiWatchTvStateLine]): connected and no picture yet, then "Still no picture"
  waiting,
  stillNoPicture(keeps: true),
  stillTrying(keeps: true),
  decoderNone(keeps: true),
  decoderRefused(keeps: true),
  codeRefused(keeps: true);

  const DjiReceiveLine({this.keeps = false});

  /// The line stays: an error that needs an action until it is resolved
  final bool keeps;
}

/// The kind of [djiRelayReceiveStateText]
DjiReceiveLine djiRelayReceiveLine(DjiRelayReceiving receiving) => switch (receiving.state) {
  DjiRelayReceiveState.idle => DjiReceiveLine.idle,
  DjiRelayReceiveState.connecting => DjiReceiveLine.connecting,
  DjiRelayReceiveState.checkingCode => DjiReceiveLine.checking,
  DjiRelayReceiveState.receiving => switch (receiving.phoneSource) {
    'cable' => DjiReceiveLine.live,
    'replay' => DjiReceiveLine.replay,
    _ => DjiReceiveLine.noSource,
  },
  DjiRelayReceiveState.lost => DjiReceiveLine.lost,
  DjiRelayReceiveState.wrongCode => DjiReceiveLine.wrongCode,
  DjiRelayReceiveState.full => DjiReceiveLine.full,
  DjiRelayReceiveState.blocked => DjiReceiveLine.blocked,
  DjiRelayReceiveState.otherVersion => DjiReceiveLine.otherVersion,
  DjiRelayReceiveState.phoneUnproven => DjiReceiveLine.unproven,
  DjiRelayReceiveState.busy => DjiReceiveLine.busy,
};

/// Why a connect was refused before it started
String djiRelayConnectErrorText(Translations t, String error) => switch (error) {
  'badCode' => t.dji_link_receive_code_invalid,
  'busy' => t.dji_link_receive_state_busy,
  'sending' => t.dji_link_receive_sending,
  _ => t.dji_link_receive_address_invalid,
};
