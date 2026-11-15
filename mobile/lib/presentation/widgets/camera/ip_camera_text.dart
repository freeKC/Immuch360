// The failures of a camera of another brand in words: one sentence per cause, what to do next in it. The live view's
// reasons (Media3 error code names on Android, the TV and the Quest, FFmpeg's lines on a computer, the reasons of the
// Dart playlist on iPhone and iPad) are read into the same causes where they tell one.

import 'package:flutter/widgets.dart';
import 'package:immich_mobile/domain/services/ip_camera.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/camera/camera_live_hls.dart';

String ipCameraErrorText(BuildContext context, IpCameraException error, {required String host}) => switch (error.kind) {
  IpCameraErrorKind.badAddress => context.t.ip_camera_error_bad_address,
  IpCameraErrorKind.needsAccount => context.t.ip_camera_error_needs_account,
  IpCameraErrorKind.wrongPassword => context.t.ip_camera_error_wrong_password,
  IpCameraErrorKind.basicOnly => context.t.ip_camera_error_basic_only,
  IpCameraErrorKind.unreachable => context.t.ip_camera_error_unreachable(host: host),
  IpCameraErrorKind.notOnvif => context.t.ip_camera_error_not_onvif(host: host),
  IpCameraErrorKind.noProfile => context.t.ip_camera_error_no_profile,
  IpCameraErrorKind.codecNotPlayableHere => context.t.ip_camera_error_codec_here(codec: error.detail ?? '?'),
  IpCameraErrorKind.secureNotHere => context.t.ip_camera_error_secure_not_here,
  IpCameraErrorKind.other => context.t.ip_camera_error_other(
    detail: [?error.detail, if (error.status != null) '${error.status}'].join(' '),
  ),
};

/// The cause in a reason of a live view, null when it tells none (the raw reason is then shown)
@visibleForTesting
IpCameraException? ipCameraLiveCause(String? reason, {required bool hasAccount}) {
  if (reason == null) {
    return null;
  }
  if (reason == cameraLiveRefused || RegExp(r'\b401\b').hasMatch(reason)) {
    return IpCameraException(hasAccount ? IpCameraErrorKind.wrongPassword : IpCameraErrorKind.needsAccount);
  }
  if (reason == cameraLiveH265) {
    return const IpCameraException(IpCameraErrorKind.codecNotPlayableHere, detail: 'H.265');
  }
  const codecs = {
    'ERROR_CODE_DECODING_FORMAT_UNSUPPORTED',
    'ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES',
    'ERROR_CODE_DECODER_INIT_FAILED',
    'ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED',
  };
  if (codecs.contains(reason)) {
    return const IpCameraException(IpCameraErrorKind.codecNotPlayableHere, detail: '');
  }
  const network = {'ERROR_CODE_IO_NETWORK_CONNECTION_FAILED', 'ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT'};
  if (network.contains(reason) ||
      reason == cameraLiveUnreachable ||
      RegExp(r'Connection refused|timed out|No route to host', caseSensitive: false).hasMatch(reason)) {
    return const IpCameraException(IpCameraErrorKind.unreachable);
  }
  if (RegExp(r'\b404\b').hasMatch(reason) || reason == 'ERROR_CODE_IO_FILE_NOT_FOUND') {
    return const IpCameraException(IpCameraErrorKind.noProfile, status: 404);
  }
  if (RegExp(r'\b46[1]\b').hasMatch(reason)) {
    // Unsupported transport: the camera refused RTP over TCP
    return const IpCameraException(IpCameraErrorKind.other, detail: 'RTSP over TCP refused', status: 461);
  }
  return null;
}

/// The line of a live view of a camera of another brand that failed with [reason]
String ipCameraLiveFailureText(BuildContext context, String? reason, {required bool hasAccount, required String host}) {
  final cause = ipCameraLiveCause(reason, hasAccount: hasAccount);
  if (cause == null) {
    return context.t.camera_live_failed(error: reason ?? '');
  }
  if (cause.kind == IpCameraErrorKind.codecNotPlayableHere && (cause.detail?.isEmpty ?? true)) {
    return context.t.ip_camera_error_codec_unknown_here;
  }
  return ipCameraErrorText(context, cause, host: host);
}
