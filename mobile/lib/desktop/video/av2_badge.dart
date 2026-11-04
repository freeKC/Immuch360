// The "AV2" badge of the thumbnails (store/m2/av2-2026-11-02/plan-2026-11-02.md, section 1.2), in the style of the
// "3D splat" badge of the shares: the word in the primary colour, bold, the same in every language. A thumbnail never
// reads the file: the scan of the folder library wrote "av2" in the index for each .ivf and .obu whose head starts an
// AV2 stream (library_index.dart, video_codec), and the badge reads the index again at the end of each local sync. The
// tiles of the shares read the head of the file in turn with the other tiles (network_media_tile.widget.dart).
//
// The image of such a tile is the neutral tile until the AV2 decoder is installed, then a frame the decoder gives
// (desktop_local_image_api.dart). Flutter's image cache keeps the neutral one under the key of the tile, so the key of
// an AV2 video of the library carries whether the decoder is installed (desktopAv2ThumbnailVariant): installed, the
// tile asks for its image again and gets its frame without a restart of the app, and the neutral tile it had is
// dropped from the cache (review of lot AD6, m1). The other views of the video ask its thumbnail without a variant of
// their own (the image of the viewer while a video opens, the overview of the timeline, the covers of the local
// albums): the window gives them the same one (av2ThumbnailVariantsProvider), so that they ask again too, at their
// next build, whether a tile of the video was built when the decoder came or not (review of lot AD11, m2).

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/library/folder_library_controller.dart';
import 'package:immich_mobile/desktop/video/av2_decoder.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';
import 'package:immich_mobile/providers/sync_status.provider.dart';

/// The AV2 streams of the folder library, by asset id, read from its index again each time a local sync ends
final av2LibraryVideosProvider = FutureProvider<Set<String>>((ref) async {
  ref.watch(syncStatusProvider.select((status) => status.localSyncStatus == SyncStatus.success));
  final library = await ref.watch(folderLibraryProvider.future);
  return library.index.av2VideoIds();
});

/// "AV2" in the style of the "3D splat" badge
class Av2BadgeLabel extends StatelessWidget {
  const Av2BadgeLabel({super.key});

  static const _shadows = [Shadow(blurRadius: 4, color: Colors.black54)];

  @override
  Widget build(BuildContext context) => Text(
    context.t.av2_badge,
    style: TextStyle(color: context.colorScheme.primary, fontSize: 12, fontWeight: FontWeight.w700, shadows: _shadows),
  );
}

/// The badge of the thumbnail of [asset] in the folder library: "AV2" on an AV2 stream the index knows, nothing else
class DesktopAv2Badge extends ConsumerWidget {
  const DesktopAv2Badge({super.key, required this.asset});

  final BaseAsset asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localId = asset.localId;
    if (!asset.isVideo || localId == null) {
      return const SizedBox.shrink();
    }
    final isAv2 = ref.watch(av2LibraryVideosProvider.select((ids) => ids.valueOrNull?.contains(localId) ?? false));
    if (!isAv2) {
      return const SizedBox.shrink();
    }
    return const Padding(
      key: Key('desktop_badge_av2'),
      padding: EdgeInsets.only(right: 10.0, top: 6.0),
      child: Av2BadgeLabel(),
    );
  }
}

/// The variant of the key of the thumbnail of an AV2 video once the AV2 decoder is installed
const av2DecoderThumbnailVariant = 'av2-decoder';

/// What keys the thumbnail of [asset] beside its file (LocalThumbProvider.variant), from the build of its tile
/// ([ref]): [av2DecoderThumbnailVariant] for an AV2 video of the index while the AV2 decoder is installed, else null.
/// When the decoder comes, the thumbnail the tile had (the neutral tile) leaves the image cache.
Object? desktopAv2ThumbnailVariant(WidgetRef ref, BaseAsset? asset) {
  final localId = asset?.localId;
  if (asset == null || !asset.isVideo || localId == null) {
    return null;
  }
  final isAv2 = ref.watch(av2LibraryVideosProvider.select((ids) => ids.valueOrNull?.contains(localId) ?? false));
  if (!isAv2) {
    return null;
  }
  ref.listen<bool>(av2DecoderInstalledProvider, (before, installed) {
    if (installed && before != true) {
      final neutral = getThumbnailImageProvider(asset);
      if (neutral != null) {
        PaintingBinding.instance.imageCache.evict(neutral);
      }
    }
  });
  return ref.watch(av2DecoderInstalledProvider) ? av2DecoderThumbnailVariant : null;
}

/// The variant of the thumbnails of the AV2 videos for the views that give none (getThumbnailImageProvider, through
/// localThumbnailVariantOf): [av2DecoderThumbnailVariant] for an AV2 video of the index while the AV2 decoder is
/// installed, as its tile has. Read by the window from its start (desktop_shell.dart), which keeps it for the life of
/// the app; the providers are read when a view asks, those of the tiles that watch them already
final av2ThumbnailVariantsProvider = Provider<void>((ref) {
  Object? variantOf(BaseAsset asset) {
    final localId = asset.localId;
    if (!asset.isVideo || localId == null) {
      return null;
    }
    final isAv2 = ref.read(av2LibraryVideosProvider).valueOrNull?.contains(localId) ?? false;
    return isAv2 && ref.read(av2DecoderInstalledProvider) ? av2DecoderThumbnailVariant : null;
  }

  localThumbnailVariantOf = variantOf;
  ref.onDispose(() {
    if (identical(localThumbnailVariantOf, variantOf)) {
      localThumbnailVariantOf = null;
    }
  });
});
