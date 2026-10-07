// The small labels of the camera pages (the memory card, the kind of a clip, a clip kept on this device) and the
// sentence of each failure of a camera (strings camera_error_*).

import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/utils/bytes_units.dart';

/// What to tell the user of [error], a failure of the camera at [host]: the TapoCameraException kinds in words, with
/// the tries left or the minutes of a lockout when the camera told them
String cameraErrorText(BuildContext context, Object error, {required String host}) {
  if (error is NetworkFileSystemException) {
    return context.t.network_share_failed(error: error.message);
  }
  if (error is! TapoCameraException) {
    return context.t.camera_error_unsupported(detail: error.runtimeType.toString());
  }
  return switch (error.kind) {
    TapoErrorKind.wrongPassword => [
      context.t.camera_error_wrong_password,
      if (error.attemptsLeft case final left?) context.t.camera_error_attempts_left(count: left),
    ].join(' '),
    TapoErrorKind.locked =>
      error.lockedMinutes == null
          ? context.t.camera_error_locked_later
          : context.t.camera_error_locked(minutes: error.lockedMinutes!),
    TapoErrorKind.notOwner => context.t.camera_error_not_owner,
    TapoErrorKind.busy => context.t.camera_error_busy,
    TapoErrorKind.unreachable => context.t.camera_error_unreachable(host: host),
    TapoErrorKind.mediaLocked => context.t.camera_error_media_locked,
    TapoErrorKind.certificateChanged => context.t.camera_error_certificate_changed(host: host),
    TapoErrorKind.h265 => context.t.camera_error_h265,
    // Never shown: a cancel is the user's own doing
    TapoErrorKind.cancelled => '',
    TapoErrorKind.unsupported => context.t.camera_error_unsupported(
      detail: [?error.detail, if (error.code != null) '${error.code}'].join(' '),
    ),
  };
}

/// The word of the kind of a clip
String cameraClipKindText(BuildContext context, TapoClipKind kind) => switch (kind) {
  TapoClipKind.motion => context.t.camera_event_motion,
  TapoClipKind.person => context.t.camera_event_person,
  TapoClipKind.pet => context.t.camera_event_pet,
  TapoClipKind.vehicle => context.t.camera_event_vehicle,
  TapoClipKind.babyCry => context.t.camera_event_baby_cry,
  TapoClipKind.animal => context.t.camera_event_animal,
  TapoClipKind.continuous => context.t.camera_event_continuous,
  TapoClipKind.other => context.t.camera_event_other,
};

/// The state of the memory card: what is used of it, that there is none, or the camera's own word for its state
class CameraCardBadge extends StatelessWidget {
  const CameraCardBadge({super.key, required this.card});

  final TapoCardStatus card;

  @override
  Widget build(BuildContext context) {
    final used = card.usedBytes;
    final total = card.totalBytes;
    final text = switch (card.state) {
      TapoCardState.absent => context.t.camera_sd_absent,
      TapoCardState.normal when used != null && total != null => context.t.camera_sd_used(
        used: formatBytes(used),
        total: formatBytes(total),
      ),
      _ => context.t.camera_sd_status(status: card.status),
    };
    return _Badge(
      key: const Key('camera_card_badge'),
      icon: card.state == TapoCardState.absent ? Icons.sd_card_alert_outlined : Icons.sd_card_outlined,
      text: text,
      color: card.state == TapoCardState.other ? context.colorScheme.error : null,
    );
  }
}

/// The kind of a clip
class CameraEventBadge extends StatelessWidget {
  const CameraEventBadge({super.key, required this.kind});

  final TapoClipKind kind;

  @override
  Widget build(BuildContext context) => _Badge(
    icon: switch (kind) {
      TapoClipKind.person => Icons.person_outline,
      TapoClipKind.pet || TapoClipKind.animal => Icons.pets_outlined,
      TapoClipKind.vehicle => Icons.directions_car_outlined,
      TapoClipKind.babyCry => Icons.child_care_outlined,
      TapoClipKind.continuous => Icons.schedule_outlined,
      TapoClipKind.motion || TapoClipKind.other => Icons.directions_run_outlined,
    },
    text: cameraClipKindText(context, kind),
  );
}

/// A clip already fetched to this device
class CameraOnDeviceBadge extends StatelessWidget {
  const CameraOnDeviceBadge({super.key});

  @override
  Widget build(BuildContext context) =>
      _Badge(icon: Icons.download_done_outlined, text: context.t.camera_clip_on_device, color: context.primaryColor);
}

class _Badge extends StatelessWidget {
  const _Badge({super.key, required this.icon, required this.text, this.color});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final color = this.color ?? context.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.textTheme.labelMedium?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
