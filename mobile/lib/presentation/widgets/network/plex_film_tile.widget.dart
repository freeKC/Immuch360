import 'dart:math';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/watch_key.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_film_list.dart';
import 'package:immich_mobile/presentation/widgets/network/network_media_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/network_server_thumbnail_image.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_focusable.widget.dart';
import 'package:immich_mobile/presentation/widgets/watch_progress/watch_progress_overlay.widget.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';

/// The caption under a poster of the films page: the title on two lines, the year on one, at 13 sp on a TV so that two
/// rows and a header fit at 1080p
class PlexFilmCaption {
  const PlexFilmCaption._();

  static const _lineHeight = 1.25;
  static const _gap = 4.0;

  static double titleSize({required bool tvMode}) => tvMode ? 13 : 12.5;
  static double yearSize({required bool tvMode}) => tvMode ? 12 : 11;

  /// The height the caption takes under its poster with the text scale of [scaler]
  static double height(TextScaler scaler, {required bool tvMode}) =>
      _gap +
      2 * scaler.scale(titleSize(tvMode: tvMode)) * _lineHeight +
      scaler.scale(yearSize(tvMode: tvMode)) * _lineHeight +
      2;

  static TextStyle titleStyle(BuildContext context, {required bool tvMode}) => TextStyle(
    fontSize: titleSize(tvMode: tvMode),
    height: _lineHeight,
    fontWeight: FontWeight.w500,
    color: context.colorScheme.onSurface,
  );

  static TextStyle yearStyle(BuildContext context, {required bool tvMode}) => TextStyle(
    fontSize: yearSize(tvMode: tvMode),
    height: _lineHeight,
    color: context.colorScheme.onSurfaceVariant,
  );
}

/// The pixels a poster of [height] logical pixels is asked at: steps of 120, so that the tiles of one size share their
/// pictures in the cache
int plexPosterPixels(double height, double devicePixelRatio) =>
    (((height * devicePixelRatio) / 120).ceil() * 120).clamp(240, 960);

/// A film of the films page: its 2:3 poster from the server's photo transcoder, how much of it was watched along the
/// bottom edge, and its title and year under it. A screen reader says the title and the year; a computer shows the
/// whole title in a tooltip.
class PlexFilmTile extends ConsumerWidget {
  const PlexFilmTile({
    super.key,
    required this.film,
    required this.entry,
    required this.onTap,
    this.onLongPress,
    this.autofocus = false,
    this.tvMode = false,
  });

  final PlexFilm film;

  /// The file the film plays, at its path of plexFilmPartPath: its poster and its watch progress are read by it
  final NetworkEntry entry;
  final VoidCallback onTap;

  /// A long press, or a long OK on a remote: the menu of the film
  final VoidCallback? onLongPress;

  /// The first film of the page for a remote control
  final bool autofocus;
  final bool tvMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serverPictures = switch (ref.watch(networkConnectionsProvider).opened(entry.sourceId)) {
      final NetworkThumbnailSource source => source,
      _ => null,
    };
    final year = film.year;
    final caption = Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            film.title,
            key: const Key('plex_film_title'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: PlexFilmCaption.titleStyle(context, tvMode: tvMode),
          ),
          if (year != null)
            Text(
              '$year',
              key: const Key('plex_film_year'),
              maxLines: 1,
              style: PlexFilmCaption.yearStyle(context, tvMode: tvMode),
            ),
        ],
      ),
    );
    return Semantics(
      label: year == null ? film.title : '${film.title}, $year',
      button: true,
      onTap: onTap,
      onLongPress: onLongPress,
      excludeSemantics: true,
      child: RemoteFocusable(
        onTap: onTap,
        onLongPress: onLongPress,
        autofocus: autofocus,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.all(Radius.circular(6)),
                child: LayoutBuilder(
                  builder: (context, constraints) => Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(color: context.colorScheme.surfaceContainerHighest),
                      Center(
                        child: Icon(
                          Icons.movie_outlined,
                          size: min(48, constraints.maxWidth / 3),
                          color: context.colorScheme.onSurface.withAlpha(110),
                        ),
                      ),
                      if (serverPictures != null && film.thumb != null)
                        _Poster(
                          image: NetworkServerThumbnailImage(
                            serverPictures,
                            entry,
                            size: plexPosterPixels(constraints.maxHeight, MediaQuery.devicePixelRatioOf(context)),
                          ),
                        ),
                      WatchProgressOverlay(watchKey: WatchKey.ofEntry(entry)),
                    ],
                  ),
                ),
              ),
            ),
            if (CurrentPlatform.isDesktop) Tooltip(message: film.title, child: caption) else caption,
          ],
        ),
      ),
    );
  }
}

class _Poster extends ConsumerWidget {
  const _Poster({required this.image});

  final ImageProvider image;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Image(
      key: const Key('plex_film_poster'),
      image: image,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, _) {
        if (frame != null) {
          ref.read(networkThumbnailCacheProvider).retain(image);
        }
        return child;
      },
      // The icon under it stays
      errorBuilder: (context, _, _) => const SizedBox.shrink(),
    );
  }
}

/// Where a film stands whose page has not come yet
class PlexFilmPlaceholder extends StatelessWidget {
  const PlexFilmPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: context.colorScheme.surfaceContainerHighest.withAlpha(150),
              borderRadius: const BorderRadius.all(Radius.circular(6)),
            ),
          ),
        ),
        const SizedBox(height: 40),
      ],
    );
  }
}
