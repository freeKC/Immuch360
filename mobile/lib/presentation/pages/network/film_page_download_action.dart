// Download in the row after Play of the film page (lot B of the Plex films study, request 5): the button of
// film_download.widget.dart for the file of the film, nothing on a TV, for a share that is not Plex or while the file
// is not known yet.

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_film_versions.dart';
import 'package:immich_mobile/presentation/pages/network/film_page_actions.dart';
import 'package:immich_mobile/presentation/widgets/network/film_download.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/film_version_download.widget.dart';

/// A film with several versions asks which one to copy (release 47, FilmVersionDownloadButton)
Widget? filmPageDownloadAction(BuildContext context, WidgetRef ref, FilmPageContext film) {
  final entry = film.entry;
  final versions = plexFilmVersions(film.film);
  if (entry == null || versions.length < 2 || !canDownloadFilm(ref, entry.sourceId, entry)) {
    return filmDownloadPageAction(ref, entry, title: film.film.title);
  }
  return FilmVersionDownloadButton(
    film: film.film,
    entry: entry,
    paths: plexFilmVersionPaths(film.film, current: film.path, version: film.version),
    version: film.version,
  );
}
