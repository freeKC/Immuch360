import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/watch_key.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/duration_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/watch_progress.action.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/sheet_tile.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/watch_progress.provider.dart';

/// How much of the film [asset] was watched, in words: "Watched 42 %" or "Watched", and "Stopped at 42:10 of 1:38:00"
/// while a position is remembered, with "Play from the start" and "Mark as not watched" when they apply (see
/// watchActionsFor). The entries take the focus of a remote: on a TV, where the ⋮ of the viewer is hidden, the details
/// are the only menu. Nothing for a video without a row, nor for one that is no film.
class WatchProgressDetails extends ConsumerWidget {
  const WatchProgressDetails({super.key, required this.asset});

  final BaseAsset asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!asset.isVideo) {
      return const SizedBox.shrink();
    }
    final key = WatchKey.ofAsset(asset);
    final row = ref.watch(watchProgressProvider.select((rows) => rows.find(key)));
    if (row == null || !ref.watch(watchRuleProvider).isFilm(row.duration)) {
      return const SizedBox.shrink();
    }
    final t = context.t;
    final actions = watchActionsFor(row, ref.watch(watchRuleProvider));
    final titleStyle = context.textTheme.labelLarge;
    final subtitleStyle = context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceSecondary);
    final percent = (row.fraction * 100).round();
    return Column(
      key: const Key('watch_progress_details'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        SheetTile(
          title: row.watched ? t.video_watched : t.video_watched_percent(percent: percent),
          titleStyle: titleStyle,
          leading: Icon(
            row.watched ? Icons.check_circle_outline_rounded : Icons.history_rounded,
            size: 24,
            color: titleStyle?.color,
          ),
          subtitle: row.position > Duration.zero
              ? t.video_stopped_at(position: row.position.format(), duration: row.duration.format())
              : null,
          subtitleStyle: subtitleStyle,
        ),
        if (actions.restart || actions.unwatch)
          Padding(
            padding: const EdgeInsets.only(left: 64, right: 16),
            child: Wrap(
              spacing: 8,
              children: [
                if (actions.restart)
                  TextButton(
                    key: const Key('watch_progress_restart'),
                    onPressed: () => playFromStart(
                      ref.read(watchProgressProvider.notifier),
                      key,
                      ref.read(videoPlayerProvider(asset.id).notifier),
                    ),
                    child: Text(t.video_play_from_start),
                  ),
                if (actions.unwatch)
                  TextButton(
                    key: const Key('watch_progress_unwatch'),
                    onPressed: () => ref.read(watchProgressProvider.notifier).markUnwatched(key),
                    child: Text(t.video_mark_unwatched),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
