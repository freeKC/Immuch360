// The diagnostics line of a live view that failed: what a user reads back to us, in plain ASCII and never translated
// (model, firmware, power, the route of the stream, the step that failed and the camera's own code). Nothing secret
// goes in: no password, no account, no session.

import 'package:immich_mobile/domain/services/tapo_camera.dart';

/// See the header. [rtspError]: what RTSP said before the media port was tried in its place; [failure]: what made the
/// last open fail (a TapoLiveException tells its step); [error]: the reason the player or the playlist gave.
String cameraLiveDiagnostics({
  String? model,
  String? firmware,
  String? power,
  required TapoLiveRoute route,
  required bool hd,
  required int rtspPort,
  required int mediaPort,
  String? rtspError,
  Object? failure,
  String? error,
}) {
  final parts = <String>[
    (model == null || model.isEmpty) ? 'model ?' : model,
    if (firmware != null && firmware.isNotEmpty) firmware,
    'power ${power == null || power.isEmpty ? '?' : power}',
    if (rtspError != null) 'RTSP $rtspPort: $rtspError',
    switch (route) {
      TapoLiveRoute.rtsp => 'RTSP $rtspPort ${hd ? 'HD' : 'SD'}',
      TapoLiveRoute.mediaPort => 'media port $mediaPort ${hd ? 'HD' : 'SD'}',
      _ => route.name,
    },
  ];
  switch (failure) {
    case TapoLiveException(:final step, :final kind, :final code, :final detail):
      parts.add('failed at ${step.name}: ${_cause(kind, code, detail)}');
    case TapoCameraException(:final kind, :final code, :final detail):
      parts.add('failed: ${_cause(kind, code, detail)}');
    case null:
      if (error != null && error.isNotEmpty) {
        parts.add('failed: $error');
      }
    default:
      parts.add('failed: ${failure.runtimeType}');
  }
  return parts.join(' | ');
}

String _cause(TapoErrorKind kind, int? code, String? detail) =>
    '${kind.name}${code == null ? '' : ' code $code'}${detail == null || detail.isEmpty ? '' : ' ($detail)'}';
