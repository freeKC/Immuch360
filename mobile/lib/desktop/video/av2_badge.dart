// The "AV2" badge of the thumbnails (store/m2/av2-2026-11-02/plan-2026-11-02.md, section 1.2), in the style of the
// "3D splat" badge of the shares: the word in the primary colour, bold, the same in every language. A thumbnail never
// reads the file: the scan of the folder library wrote "av2" in the index for each .ivf and .obu whose head starts an
// AV2 stream (library_index.dart, video_codec), and the badge reads the index again at the end of each local sync. The
// tiles of the shares read the head of the file in turn with the other tiles (network_media_tile.widget.dart).

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/library/folder_library_controller.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
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
