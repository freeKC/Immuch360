// The other versions of a film the video page may offer when the link is slower than the file (film_slow_link.dart).
//
// Wired at the integration of release 47 to the version choice of the film page (plex_film_version.provider.dart):
// the versions of a Plex film (plexFilmVersions), their labels, their play paths and the pick they remember.

import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/film_player/film_slow_link.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_film_list.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_film_versions.dart';
import 'package:immich_mobile/presentation/pages/network/plex_film.page.dart';
import 'package:immich_mobile/providers/network/plex_film_version.provider.dart';
import 'package:immich_mobile/providers/network/plex_films.provider.dart';

export 'package:immich_mobile/domain/services/film_player/film_slow_link.dart' show FilmVersionOffer;

/// The film of a share by its source and the path of the file that plays
typedef FilmVersionOffersKey = ({String sourceId, String path});

/// The versions of the film at the key's path, that one included or not; empty when the film has one version, or the
/// share no versions
final filmVersionOffersProvider = FutureProvider.autoDispose.family<List<FilmVersionOffer>, FilmVersionOffersKey>((
  ref,
  film,
) async {
  final at = plexFilmPathParts(film.path);
  if (at == null) {
    return const [];
  }
  final details = await ref.watch(plexFilmDetailsProvider((sourceId: film.sourceId, ratingKey: at.ratingKey)).future);
  final versions = plexFilmVersions(details);
  if (versions.length < 2) {
    return const [];
  }
  return [
    for (final (i, media) in versions.indexed)
      if (plexFilmPlayPath(details, version: i) case final String path)
        (
          label: plexFilmVersionLabel(media),
          path: path,
          bitsPerSecond: media.bitrate == null ? null : media.bitrate! * 1000,
          onChosen: media.id == null
              ? null
              : () => unawaited(
                  ref.read(plexFilmVersionPicksProvider.notifier).pick(film.sourceId, at.ratingKey, media.id!),
                ),
        ),
  ];
});
