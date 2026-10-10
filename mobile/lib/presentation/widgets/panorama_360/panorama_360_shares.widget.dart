import 'dart:async';
import 'dart:math' as math;

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_panorama_file.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/pages/network/network_browser.page.dart';
import 'package:immich_mobile/presentation/widgets/network/network_media_tile.widget.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/network_panoramas.provider.dart';
import 'package:immich_mobile/routing/router.dart';

/// The 360° photos and videos of the network shares in the 360° list, under its filters, newest first: those the app
/// found 360° when it showed their folder or opened them (it does not walk the shares on its own). One row of tiles of
/// the size of the grid's, which a remote goes along with left and right; each opens in the photo or video page of its
/// share, previous and next going through the 360° files of the same share. Nothing when there is none.
class Panorama360SharesSection extends ConsumerWidget {
  const Panorama360SharesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final files = ref.watch(panorama360ShareFilesProvider);
    if (files.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    final args = ref.watch(timelineArgsProvider);
    // A remote arrives on the first file of the row, the first item of the list (see Panorama360Page)
    final tvMode = ref.watch(tvModeProvider);
    final columns = math.max(args.columnCount, 1);
    final extent = ((args.maxWidth - args.spacing * (columns - 1)) / columns).clamp(80.0, 240.0);

    return SliverToBoxAdapter(
      child: Padding(
        key: const Key('panorama_360_shares'),
        padding: const EdgeInsets.only(top: 8, bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(context.t.library_360_shares, style: context.textTheme.titleMedium),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
              child: Text(
                context.t.library_360_shares_hint,
                style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceSecondary),
              ),
            ),
            SizedBox(
              height: extent,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.zero,
                itemCount: files.length,
                separatorBuilder: (_, _) => SizedBox(width: args.spacing),
                itemBuilder: (context, index) => SizedBox.square(
                  dimension: extent,
                  child: _ShareFileTile(
                    key: ValueKey(files[index]),
                    file: files[index],
                    files: files,
                    autofocus: tvMode && index == 0,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShareFileTile extends ConsumerWidget {
  const _ShareFileTile({super.key, required this.file, required this.files, this.autofocus = false});

  final NetworkPanoramaFile file;
  final bool autofocus;

  /// Every file of the row, for previous and next in the page that opens
  final List<NetworkPanoramaFile> files;

  void _open(BuildContext context, WidgetRef ref) {
    final entries = [
      for (final other in files)
        if (other.sourceId == file.sourceId) other.entry,
    ];
    // The files whose share answered already; the page of another one reads its own
    final urls = <String, Uri>{
      for (final entry in entries)
        entry.path: ?ref.read(networkFileUrlProvider((sourceId: entry.sourceId, path: entry.path))).valueOrNull,
    };
    final folder = NetworkFolderMedia(
      entries: entries,
      urls: urls,
      index: entries.indexWhere((entry) => entry.path == file.path),
    );
    unawaited(
      context.pushRoute(
        file.isVideo
            ? NetworkVideoRoute(sourceId: file.sourceId, path: file.path, folder: folder)
            : NetworkPhotoRoute(sourceId: file.sourceId, path: file.path, folder: folder),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = ref.watch(networkFileUrlProvider((sourceId: file.sourceId, path: file.path))).valueOrNull;
    return NetworkMediaTile(entry: file.entry, url: url, autofocus: autofocus, onTap: () => _open(context, ref));
  }
}
