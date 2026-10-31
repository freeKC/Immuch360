import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/watch_key.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/watch_progress.provider.dart';

/// How much of the film of [watchKey] was watched, over the bottom of its tile: a thin bar along the whole bottom edge,
/// filled as far as it was left, and a check at the bottom centre once it was watched (both while it is watched again).
/// Nothing for a video without a row, with "Remember where I stopped" off, or under its threshold (see WatchRule). Larger
/// on a TV, read from the couch; the focus ring of a TV goes around the tile, never over the bar.
///
/// One widget that any tile composes in its Stack (the tiles of the timeline, the albums, the search and the folders,
/// those of the shares, the device folders and the 360° list): it watches its own row only, so that a save rebuilds
/// that tile alone. It takes no touch.
class WatchProgressOverlay extends ConsumerWidget {
  const WatchProgressOverlay({super.key, required this.watchKey});

  final WatchKey watchKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Its row first: a tile without one watches nothing else
    final row = ref.watch(watchProgressProvider.select((rows) => rows.find(watchKey)));
    if (row == null || !ref.watch(watchRuleProvider).isFilm(row.duration)) {
      return const SizedBox.shrink();
    }
    final tv = ref.watch(tvModeProvider);
    final barHeight = tv ? 6.0 : 3.0;
    final checkSize = tv ? 28.0 : 16.0;
    final primary = context.primaryColor;
    final inProgress = row.position > Duration.zero;
    return IgnorePointer(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (row.watched)
              Padding(
                padding: EdgeInsets.only(bottom: inProgress ? 4 : 6),
                child: Container(
                  key: const Key('watch_progress_check'),
                  width: checkSize,
                  height: checkSize,
                  decoration: BoxDecoration(
                    color: primary,
                    shape: BoxShape.circle,
                    boxShadow: const [BoxShadow(blurRadius: 4, color: Color.fromRGBO(0, 0, 0, 0.5))],
                  ),
                  child: Icon(Icons.check_rounded, color: Colors.white, size: checkSize * 0.75),
                ),
              ),
            if (inProgress)
              SizedBox(
                key: const Key('watch_progress_bar'),
                height: barHeight,
                width: double.infinity,
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.45),
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: row.fraction,
                    heightFactor: 1,
                    child: ColoredBox(key: const Key('watch_progress_fill'), color: primary),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
