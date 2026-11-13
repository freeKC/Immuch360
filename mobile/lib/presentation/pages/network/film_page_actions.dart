// The hooks of the film page (plex_film.page.dart) for the lots that come after A2: the row of buttons after Play
// takes one action per builder of [filmPageActions], in order. Lot B adds Download, lot C "Play on..." (the request 9
// of 10 November 2026), each with one line in the list and a file of its own, so that the lots merge without
// touching the page.

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_films.dart';
import 'package:immich_mobile/presentation/pages/network/film_page_download_action.dart';
import 'package:immich_mobile/presentation/pages/network/film_page_play_on.dart';

/// What an action of the film page knows of the film
class FilmPageContext {
  const FilmPageContext({required this.sourceId, required this.film, this.path, this.entry});

  /// The Plex source the film is on
  final String sourceId;

  /// What the server holds of it: its ratingKey, its files and their streams
  final PlexFilmDetails film;

  /// The file Play opens, absolute in the share; null for an item without a file
  final String? path;

  /// That file as the share lists it (its size and date), null until known
  final NetworkEntry? entry;
}

/// Builds one button of the row after Play for [film], null to show none (no Download for a share that is not Plex,
/// for instance)
typedef FilmPageActionBuilder = Widget? Function(BuildContext context, WidgetRef ref, FilmPageContext film);

/// The actions of the row after Play, in order: Download (lot B), then "Play on..." (lot C)
const List<FilmPageActionBuilder> filmPageActions = [filmPageDownloadAction, playOnFilmAction];
