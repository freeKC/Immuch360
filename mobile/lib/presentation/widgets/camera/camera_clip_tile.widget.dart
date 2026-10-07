// A clip in the day page: the camera's picture of it (event recordings only), its start in the camera's time, its
// length, its kind, and whether it is kept on this device. A ListTile, so that a remote reaches it too.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/presentation/widgets/camera/camera_badges.widget.dart';

/// m:ss, or h:mm:ss for an hour and more
String cameraDurationText(Duration duration) {
  final seconds = duration.inSeconds % 60;
  final minutes = duration.inMinutes % 60;
  final hours = duration.inHours;
  String two(int value) => value.toString().padLeft(2, '0');
  return hours > 0 ? '$hours:${two(minutes)}:${two(seconds)}' : '$minutes:${two(seconds)}';
}

class CameraClipTile extends StatelessWidget {
  const CameraClipTile({
    super.key,
    required this.clip,
    required this.time,
    required this.thumbnail,
    required this.isFetched,
    required this.onTap,
    this.onLongPress,
    this.autofocus = false,
  });

  final TapoClip clip;

  /// The start of the clip in the camera's time, formatted
  final String time;

  /// The picture of the clip, loaded once by the tile; null for none
  final Future<Uint8List?> Function() thumbnail;
  final bool isFetched;
  final VoidCallback onTap;

  /// Deletes the copy on this device (touch only: TV users clear the whole cache from the camera page)
  final VoidCallback? onLongPress;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: Key('camera_clip_${clip.start.millisecondsSinceEpoch ~/ 1000}'),
      autofocus: autofocus,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: _ClipThumbnail(key: ValueKey(clip.path), load: thumbnail),
      title: Text(
        '$time  ·  ${cameraDurationText(clip.duration)}',
        style: context.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w500),
      ),
      subtitle: Wrap(
        spacing: 12,
        runSpacing: 4,
        children: [
          CameraEventBadge(kind: clip.kind),
          if (isFetched) const CameraOnDeviceBadge(),
        ],
      ),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}

class _ClipThumbnail extends StatefulWidget {
  const _ClipThumbnail({super.key, required this.load});

  final Future<Uint8List?> Function() load;

  @override
  State<_ClipThumbnail> createState() => _ClipThumbnailState();
}

class _ClipThumbnailState extends State<_ClipThumbnail> {
  late final Future<Uint8List?> _image = widget.load().catchError((Object _) => null);

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(6)),
      child: SizedBox(
        width: 96,
        height: 54,
        child: FutureBuilder<Uint8List?>(
          future: _image,
          builder: (context, snapshot) {
            final bytes = snapshot.data;
            if (bytes == null) {
              return ColoredBox(
                color: context.colorScheme.surfaceContainerHighest,
                child: Icon(Icons.videocam_outlined, color: context.colorScheme.onSurfaceVariant),
              );
            }
            return Image.memory(
              bytes,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (context, error, stackTrace) =>
                  ColoredBox(color: context.colorScheme.surfaceContainerHighest),
            );
          },
        ),
      ),
    );
  }
}
