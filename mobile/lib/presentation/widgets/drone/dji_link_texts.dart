// The words of the DJI link page for what the native side sends as codes: the state, the reason for it, the channel
// roles, the capabilities of a profile and the dead man signals. The native side never sends a sentence, so every
// line the pilot reads comes from the translations; a code this build does not know is shown as it is.

import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';

String djiLinkStateText(Translations t, DjiLinkState state) => switch (state) {
  DjiLinkState.absent => t.dji_link_state_absent,
  DjiLinkState.accessoryDetected => t.dji_link_state_accessory_detected,
  DjiLinkState.permissionPending => t.dji_link_state_permission_pending,
  DjiLinkState.permissionDenied => t.dji_link_state_permission_denied,
  DjiLinkState.accessoryOpen => t.dji_link_state_accessory_open,
  DjiLinkState.linkUsable => t.dji_link_state_link_usable,
  DjiLinkState.controllerIdentified => t.dji_link_state_controller_identified,
  DjiLinkState.aircraftLinked => t.dji_link_state_aircraft_linked,
  DjiLinkState.videoReady => t.dji_link_state_video_ready,
  DjiLinkState.telemetryReady => t.dji_link_state_telemetry_ready,
  DjiLinkState.linkLost => t.dji_link_state_link_lost,
  DjiLinkState.recovering => t.dji_link_state_recovering,
  DjiLinkState.unsupportedTransport => t.dji_link_state_unsupported_transport,
  DjiLinkState.unsupportedProtocol => t.dji_link_state_unsupported_protocol,
};

String djiLinkReasonText(Translations t, DjiLinkReason reason) => switch (reason) {
  DjiLinkReason.noAccessoryFeature => t.dji_link_reason_no_accessory_feature,
  DjiLinkReason.noUsbService => t.dji_link_reason_no_usb_service,
  DjiLinkReason.looking => t.dji_link_reason_looking,
  DjiLinkReason.nothingListed => t.dji_link_reason_nothing_listed,
  DjiLinkReason.listed => t.dji_link_reason_listed,
  DjiLinkReason.waitingForChooser => t.dji_link_reason_waiting_for_chooser,
  DjiLinkReason.permissionAsked => t.dji_link_reason_permission_asked,
  DjiLinkReason.permissionRequestFailed => t.dji_link_reason_permission_request_failed,
  DjiLinkReason.permissionRefused => t.dji_link_reason_permission_refused,
  DjiLinkReason.openFailed => t.dji_link_reason_open_failed,
  DjiLinkReason.opened => t.dji_link_reason_opened,
  DjiLinkReason.probeReturns => t.dji_link_reason_probe_returns,
  DjiLinkReason.probesFailed => t.dji_link_reason_probes_failed,
  DjiLinkReason.writeBlocked => t.dji_link_reason_write_blocked,
  DjiLinkReason.detached => t.dji_link_reason_detached,
  DjiLinkReason.streamEnded => t.dji_link_reason_stream_ended,
  DjiLinkReason.readsFailed => t.dji_link_reason_reads_failed,
  DjiLinkReason.writesFailed => t.dji_link_reason_writes_failed,
  DjiLinkReason.pageClosed => t.dji_link_reason_page_closed,
  DjiLinkReason.framesParse => t.dji_link_reason_frames_parse,
  DjiLinkReason.aircraftFrames => t.dji_link_reason_aircraft_frames,
  DjiLinkReason.videoDecoded => t.dji_link_reason_video_decoded,
};

String djiLinkRoleText(Translations t, String role) => switch (role) {
  'control' => t.dji_link_role_control,
  'video' => t.dji_link_role_video,
  'payload' => t.dji_link_role_payload,
  'reserved' => t.dji_link_role_reserved,
  'unknown' => t.dji_link_role_unknown,
  _ => role,
};

String djiLinkCapabilityText(Translations t, String name) => switch (name) {
  'ACCESSORY_OPEN' => t.dji_link_capability_accessory_open,
  'LINK_PROBE' => t.dji_link_capability_link_probe,
  'LINK_NEGOTIATION' => t.dji_link_capability_link_negotiation,
  'VIDEO_RECEIVE' => t.dji_link_capability_video_receive,
  'VIDEO_DECODE' => t.dji_link_capability_video_decode,
  'TELEMETRY_RECEIVE' => t.dji_link_capability_telemetry_receive,
  'CAMERA_SETTINGS' => t.dji_link_capability_camera_settings,
  'GIMBAL' => t.dji_link_capability_gimbal,
  'FLIGHT_ACTION' => t.dji_link_capability_flight_action,
  'CONTINUOUS_FLIGHT_CONTROL' => t.dji_link_capability_continuous_flight_control,
  'PHYSICAL_STICK_PRIORITY_KNOWN' => t.dji_link_capability_stick_priority_known,
  _ => name,
};

String djiLinkSignalText(Translations t, String signal) => switch (signal) {
  'CONTROLLER_INACTIVE' => t.dji_link_signal_controller_inactive,
  'POSE_NOT_TRACKED' => t.dji_link_signal_pose_not_tracked,
  'SESSION_NOT_FOCUSED' => t.dji_link_signal_session_not_focused,
  'HEADSET_REMOVED' => t.dji_link_signal_headset_removed,
  'SAMPLE_TOO_OLD' => t.dji_link_signal_sample_too_old,
  'LINK_NOT_LINKED' => t.dji_link_signal_link_not_linked,
  'WRITE_BLOCKED' => t.dji_link_signal_write_blocked,
  'FOREGROUND_LOST' => t.dji_link_signal_foreground_lost,
  'TRIGGERS_RELEASED' => t.dji_link_signal_triggers_released,
  _ => signal,
};

/// The profile line. A profile made from the strings read on the port, and one of the three identity strings, are
/// worded here; a named product keeps the label the native side gives it, which is a product name.
String djiLinkProfileText(Translations t, DjiLinkProfile profile, DjiLinkAccessory? accessory) {
  if (profile.id.startsWith('observed-')) {
    final strings = [accessory?.manufacturer, accessory?.model].whereType<String>().where((s) => s.trim().isNotEmpty);
    return t.dji_link_profile_undescribed(strings: strings.isEmpty ? t.dji_link_profile_no_strings : strings.join(' '));
  }
  if (profile.id.startsWith('model-') && accessory?.model != null) {
    return t.dji_link_profile_model_string(model: accessory!.model!);
  }
  return profile.label;
}

/// The name of a catalogued message, from the code the native side sends; a code this build does not know is shown as
/// it is
String djiLinkMessageName(Translations t, String code) => switch (code) {
  'flightData' => t.dji_link_message_flight_data,
  'gimbal' => t.dji_link_message_gimbal,
  'battery' => t.dji_link_message_battery,
  'remoteBattery' => t.dji_link_message_remote_battery,
  'signal' => t.dji_link_message_signal,
  'liveRate' => t.dji_link_message_live_rate,
  'aircraftClock' => t.dji_link_message_aircraft_clock,
  'moduleStatus' => t.dji_link_message_module_status,
  _ => code,
};

/// The sentence of the video panel for the state of the picture
String djiLinkVideoStateText(Translations t, DjiLinkDecode decode) => switch (decode.state) {
  DjiLinkVideoState.waitingForVideo => t.dji_link_video_waiting,
  DjiLinkVideoState.waitingForDescription => t.dji_link_video_waiting_description,
  DjiLinkVideoState.building => t.dji_link_video_building,
  DjiLinkVideoState.decoding => t.dji_link_video_decoding,
  DjiLinkVideoState.hidden => t.dji_link_video_hidden,
  DjiLinkVideoState.failed => t.dji_link_video_failed(reason: decode.failure ?? '-'),
  DjiLinkVideoState.h264NotDecoded => t.dji_link_video_h264,
};

String djiLinkDescriptionSourceText(Translations t, DjiLinkDescriptionSource source) => switch (source) {
  DjiLinkDescriptionSource.session => t.dji_link_video_description_session,
  DjiLinkDescriptionSource.cache => t.dji_link_video_description_cache,
  DjiLinkDescriptionSource.profile => t.dji_link_video_description_profile,
  DjiLinkDescriptionSource.none => t.dji_link_video_description_none,
};

String djiLinkEvidenceText(Translations t, DjiLinkEvidence evidence) => switch (evidence) {
  DjiLinkEvidence.publicAndCapture => t.dji_link_evidence_public,
  DjiLinkEvidence.capture => t.dji_link_evidence_capture,
  DjiLinkEvidence.candidate => t.dji_link_evidence_candidate,
};

/// Why the decoder moved to software, said under the decoder line
String? djiLinkSwitchReasonText(Translations t, String? reason) => switch (reason) {
  'noOutputAfterJoin' => t.dji_link_video_switch_join,
  'hardwareRetryFailed' => t.dji_link_video_switch_retry,
  'fatalErrors' => t.dji_link_video_switch_errors,
  _ => null,
};

/// The label of a chip of the bench
String djiLinkBenchText(Translations t, String value) => switch (value) {
  'original' => t.dji_link_bench_original,
  'other' => t.dji_link_bench_other,
  'top' => t.dji_link_bench_top,
  'bottom' => t.dji_link_bench_bottom,
  'phone' => t.dji_link_bench_phone,
  'on' => t.dji_link_bench_on,
  'off' => t.dji_link_bench_off,
  'motorsOff' => t.dji_link_bench_motors_off,
  'propellersOff' => t.dji_link_bench_propellers_off,
  'flying' => t.dji_link_bench_flying,
  _ => value,
};

/// Why a capture did not play
String djiLinkPlayErrorText(Translations t, String code) => switch (code) {
  'busy' => t.dji_link_play_busy,
  'empty' => t.dji_link_play_empty,
  'notPaired' => t.dji_link_play_not_paired,
  'damaged' => t.dji_link_play_damaged,
  'tooLarge' => t.dji_link_play_too_large,
  _ => t.dji_link_play_unreadable,
};

/// A number with [digits] decimals, or a dash when there is none
String djiLinkNumber(double? value, [int digits = 1]) => value == null ? '-' : value.toStringAsFixed(digits);
