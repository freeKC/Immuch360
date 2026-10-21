// A photo or a video of the DJI drone page: the tile of the share browser (thumbnail or frame, 360° badge, "Sent to
// Immich earlier", selection and upload progress), with what the drone adds: the "+N" chip of a sphere and its source
// shots, the note on a video whose sound was recorded apart, the chip of a file the Immich server refuses.

import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/drone_import_grouping.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/network/network_media_tile.widget.dart';

/// A tile of the page: a photo or a video with what was found beside it ([media]), or a source shot of a sphere
class DroneTileItem {
  const DroneTileItem({required this.entry, this.media, this.isSource = false});

  final NetworkEntry entry;
  final DroneMedia? media;

  /// A source shot of a sphere, shown under its sphere or in a group not stitched
  final bool isSource;
}

class DroneMediaTile extends StatelessWidget {
  const DroneMediaTile({
    super.key,
    required this.item,
    required this.url,
    required this.onTap,
    this.frameUrl,
    this.onLongPress,
    this.isSelected,
    this.sourcesShown = false,
    this.onToggleSources,
    this.onSoundNote,
  });

  final DroneTileItem item;

  /// The media bridge URL of the file, and of the proxy of a video
  final Uri? url;
  final Uri? frameUrl;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool? isSelected;

  /// Whether the source shots of the sphere are shown after it
  final bool sourcesShown;
  final VoidCallback? onToggleSources;
  final VoidCallback? onSoundNote;

  static const _shadows = [Shadow(blurRadius: 5.0, color: Color.fromRGBO(0, 0, 0, 0.6))];

  @override
  Widget build(BuildContext context) {
    final media = item.media;
    final sources = media?.sphereSources.length ?? 0;
    final t = context.t;
    return Stack(
      fit: StackFit.expand,
      children: [
        NetworkMediaTile(
          entry: item.entry,
          url: url,
          frameUrl: frameUrl,
          onTap: onTap,
          onLongPress: onLongPress,
          isSelected: isSelected,
        ),
        if (item.isSource)
          const Positioned(
            key: Key('drone_tile_source'),
            right: 6,
            bottom: 6,
            child: Icon(Icons.grid_view_rounded, color: Colors.white, size: 16, shadows: _shadows),
          ),
        if (sources > 0)
          Positioned(
            left: isSelected == null ? 6 : 32,
            top: 6,
            child: Tooltip(
              message: sourcesShown ? t.dji_import_sources_hide : t.dji_import_sources(count: sources),
              child: GestureDetector(
                key: const Key('drone_tile_sources'),
                onTap: onToggleSources,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    // Tinted while the sources are shown
                    color: sourcesShown ? context.primaryColor : Colors.black.withValues(alpha: 0.55),
                    borderRadius: const BorderRadius.all(Radius.circular(10)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Text(
                      '+$sources',
                      style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (media?.soundApart != null)
          Positioned(
            left: 30,
            bottom: 4,
            child: Tooltip(
              message: t.dji_import_sound_apart,
              child: GestureDetector(
                key: const Key('drone_tile_sound_apart'),
                onTap: onSoundNote,
                child: const Padding(
                  padding: EdgeInsets.all(2),
                  child: Icon(Icons.volume_off_rounded, color: Colors.white, size: 18, shadows: _shadows),
                ),
              ),
            ),
          ),
        if (media?.isRefused ?? false)
          Positioned(
            key: const Key('drone_tile_refused'),
            left: 4,
            right: 4,
            bottom: 28,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: context.colorScheme.errorContainer.withValues(alpha: 0.9),
                  borderRadius: const BorderRadius.all(Radius.circular(6)),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text(
                    t.dji_import_refused,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.colorScheme.onErrorContainer, fontSize: 10),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
