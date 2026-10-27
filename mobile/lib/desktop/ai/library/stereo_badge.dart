// The badges of the thumbnails of the photos of two eyes side by side on a computer (design-final 2026-10-26, sections
// 4.2 and 4.5): "3D AI" on a photo whose relief was estimated by AI from a single photo, so that the honesty label
// goes wherever such a relief shows; "3D" on any other photo of two eyes side by side.
//
// A thumbnail never reads a file. What our XMP says of each file of the folder library is already in its index, read
// by the scan (library_index.dart, the origin column), and is read again here at the end of each local sync. A photo of
// another tool is told by the rule of its name and frame (stereo_photo_probe.dart), the one the viewer applies before
// it reads the head of a candidate: the stereo column of the index stays what our XMP declares.

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/library/folder_library_controller.dart';
import 'package:immich_mobile/desktop/library/library_index.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/asset_viewer/panorama.provider.dart';
import 'package:immich_mobile/providers/sync_status.provider.dart';

/// The badge a thumbnail shows
enum StereoBadge {
  /// "3D AI": a relief estimated by AI from a single photo
  estimatedRelief,

  /// "3D": two eyes side by side, made by another tool, or by Immuch360 from something else than one photo
  stereo,
}

/// The badge of a photo named [name], of [width] x [height] pixels, whose file the library knows as made by
/// Immuch360 with [origin] (null for any other file). A 360° photo keeps its own badge.
StereoBadge? stereoBadgeOf({
  required IndexedOrigin? origin,
  required String name,
  int? width,
  int? height,
  bool isPanorama = false,
}) {
  if (origin == IndexedOrigin.estimated) {
    return StereoBadge.estimatedRelief;
  }
  if (isPanorama) {
    return null;
  }
  if (origin == IndexedOrigin.other) {
    return StereoBadge.stereo;
  }
  return decideStereoPhoto(name: name, width: width, height: height) == null ? null : StereoBadge.stereo;
}

/// Where the content of each file Immuch360 made comes from, by asset id, read from the index of the library again
/// each time a local sync ends
final generatedOriginsProvider = FutureProvider<Map<String, IndexedOrigin>>((ref) async {
  ref.watch(syncStatusProvider.select((status) => status.localSyncStatus == SyncStatus.success));
  final library = await ref.watch(folderLibraryProvider.future);
  return library.index.generatedOrigins();
});

const _shadows = [Shadow(blurRadius: 5.0, color: Color.fromRGBO(0, 0, 0, 0.6))];

/// The badge of the thumbnail of [asset], beside the 360° one; nothing for any photo that is not two eyes side by side
class DesktopStereoBadge extends ConsumerWidget {
  const DesktopStereoBadge({super.key, required this.asset});

  final BaseAsset asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!asset.isImage) {
      return const SizedBox.shrink();
    }
    final localId = asset.localId;
    final origin = localId == null
        ? null
        : ref.watch(generatedOriginsProvider.select((origins) => origins.valueOrNull?[localId]));
    final ordinary =
        origin == null && decideStereoPhoto(name: asset.name, width: asset.width, height: asset.height) == null;
    if (ordinary) {
      // Nothing more is asked of an ordinary photo
      return const SizedBox.shrink();
    }
    final badge = stereoBadgeOf(
      origin: origin,
      name: asset.name,
      width: asset.width,
      height: asset.height,
      isPanorama: origin == IndexedOrigin.estimated ? false : ref.watch(isPanoramaProvider(asset)),
    );
    if (badge == null) {
      return const SizedBox.shrink();
    }
    final estimated = badge == StereoBadge.estimatedRelief;
    final label = Padding(
      padding: const EdgeInsets.only(right: 10.0, top: 6.0),
      child: Text(
        // "3D" is the same word in every language, as on the tiles of the shares
        estimated ? context.t.ai_immersive_badge : '3D',
        key: Key(estimated ? 'desktop_badge_3d_ai' : 'desktop_badge_3d'),
        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700, shadows: _shadows),
      ),
    );
    return estimated ? Tooltip(message: context.t.ai_immersive_relief_estimated, child: label) : label;
  }
}
