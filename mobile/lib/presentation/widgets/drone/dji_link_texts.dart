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
