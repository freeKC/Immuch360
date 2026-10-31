import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/watch_key.dart';
import 'package:immich_mobile/domain/models/watch_progress.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/actions/action.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/watch_progress.provider.dart';

/// What the watch progress of a video offers, its [row] under [rule]: "Play from the start" while a position is
/// remembered, "Mark as not watched" once it was watched. Nothing for a video that is no film.
({bool restart, bool unwatch}) watchActionsFor(WatchProgress? row, WatchRule rule) {
  if (row == null || !rule.isFilm(row.duration)) {
    return (restart: false, unwatch: false);
  }
  return (restart: row.position > Duration.zero, unwatch: row.watched);
}

/// "Play from the start": the film of [key] forgets where it was (its check stays), and [player], the page's own player
/// of it, plays it from 0
void playFromStart(WatchProgressStore store, WatchKey key, VideoPlayerNotifier? player) {
  store.restart(key);
  if (player != null && player.mounted) {
    unawaited(player.restart());
  }
}

/// "Play from the start" in the ⋮ of the asset viewer, for a film whose position is remembered: the swipes and the
/// viewer keep no button of their own for it (FreeKC's rule: no button, no popup)
class PlayFromStartAction extends AssetActionBuilder {
  const PlayFromStartAction({required super.source});

  @override
  ActionItem? create(BuildContext context, WidgetRef ref) {
    final asset = ref.watch(assetsActionProvider(source)).singleOrNull;
    if (asset == null || !asset.isVideo) {
      return null;
    }
    final key = WatchKey.ofAsset(asset);
    final row = ref.watch(watchProgressProvider.select((rows) => rows.find(key)));
    if (!watchActionsFor(row, ref.watch(watchRuleProvider)).restart) {
      return null;
    }
    return .new(
      icon: Icons.replay_rounded,
      label: context.t.video_play_from_start,
      onAction: () => playFromStart(
        ref.read(watchProgressProvider.notifier),
        key,
        ref.read(videoPlayerProvider(asset.id).notifier),
      ),
    );
  }
}

/// "Mark as not watched" in the ⋮ of the asset viewer, for a film watched: its check and its position go
class MarkUnwatchedAction extends AssetActionBuilder {
  const MarkUnwatchedAction({required super.source});

  @override
  ActionItem? create(BuildContext context, WidgetRef ref) {
    final asset = ref.watch(assetsActionProvider(source)).singleOrNull;
    if (asset == null || !asset.isVideo) {
      return null;
    }
    final key = WatchKey.ofAsset(asset);
    final row = ref.watch(watchProgressProvider.select((rows) => rows.find(key)));
    if (!watchActionsFor(row, ref.watch(watchRuleProvider)).unwatch) {
      return null;
    }
    return .new(
      icon: Icons.remove_done_rounded,
      label: context.t.video_mark_unwatched,
      onAction: () => ref.read(watchProgressProvider.notifier).markUnwatched(key),
    );
  }
}

/// The two entries of the watch progress in the ⋮ of the asset viewer, those that apply (see [watchActionsFor])
class WatchProgressMenuItems extends StatelessWidget {
  const WatchProgressMenuItems({super.key, required this.source});

  final ActionSource source;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ActionMenuItem(action: PlayFromStartAction(source: source)),
      ActionMenuItem(action: MarkUnwatchedAction(source: source)),
    ],
  );
}
