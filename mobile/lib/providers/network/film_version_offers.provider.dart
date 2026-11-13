// The other versions of a film the video page may offer when the link is slower than the file (film_slow_link.dart).
//
// The hook of release 47 for the version choice of the film page (branch fix-plex-audio-47, plex_film_version.provider
// .dart): none here until that integration fills it with the versions of the film (PlexFilmVersions), their labels,
// their play paths and the pick they remember.

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/film_player/film_slow_link.dart';

export 'package:immich_mobile/domain/services/film_player/film_slow_link.dart' show FilmVersionOffer;

/// The film of a share by its source and the path of the file that plays
typedef FilmVersionOffersKey = ({String sourceId, String path});

/// The versions of the film at the key's path, that one included or not; empty when the film has one version, or the
/// share no versions
final filmVersionOffersProvider = FutureProvider.autoDispose.family<List<FilmVersionOffer>, FilmVersionOffersKey>(
  (ref, film) async => const [],
);
