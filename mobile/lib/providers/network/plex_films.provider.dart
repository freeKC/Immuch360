// What the film page, the filters of a movie library and the films page of lot A1 read of a Plex server, through the
// connection of its source (networkConnectionsProvider): the full item of a film, its pictures through the server's
// photo transcoder, the filters of a library and the films they keep, and the Wikipedia lead of a film. Every value
// lives while a page watches it and is read again at the next visit: nothing of the library is kept on the device
// (Plex's terms call its metadata Content), but the Wikipedia leads of the last films, which the switch deletes.

import 'dart:async';
import 'dart:typed_data';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_file_system.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_films.dart';
import 'package:immich_mobile/infrastructure/wikipedia/wikipedia_film_client.dart';
import 'package:immich_mobile/infrastructure/wikipedia/wikipedia_languages.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/wikipedia.provider.dart';

/// The Plex connection of [sourceId]; a [NetworkFileSystemException] when the source is no Plex server
Future<PlexFileSystem> plexFileSystemOf(Ref ref, String sourceId) async {
  final fileSystem = await ref.read(networkConnectionsProvider).fileSystem(sourceId);
  if (fileSystem is! PlexFileSystem) {
    throw const NetworkFileSystemException('This share is not a Plex server');
  }
  return fileSystem;
}

/// The connection of a Plex source once open, null when it cannot be opened: what the film page reads of it beyond
/// the providers below (the language of a library)
final plexFilmFileSystemProvider = FutureProvider.autoDispose.family<PlexFileSystem?, String>((ref, sourceId) async {
  try {
    return await plexFileSystemOf(ref, sourceId);
  } catch (_) {
    return null;
  }
});

/// A film of a Plex server: its source and its ratingKey
typedef PlexFilmKey = ({String sourceId, String ratingKey});

/// The full item of a film, read when its page opens (see PlexFileSystem.filmDetails)
final plexFilmDetailsProvider = FutureProvider.autoDispose.family<PlexFilmDetails, PlexFilmKey>((ref, key) async {
  final fileSystem = await plexFileSystemOf(ref, key.sourceId);
  return fileSystem.filmDetails(key.ratingKey);
});

/// A picture of a Plex server: its source, its path on the server, the box asked
typedef PlexPictureKey = ({String sourceId, String path, int width, int height});

/// A poster or a background of a film, through the photo transcoder of the server (see PlexFileSystem.picture); null
/// when the server has none
final plexPictureProvider = FutureProvider.autoDispose.family<Uint8List?, PlexPictureKey>((ref, key) async {
  final fileSystem = await plexFileSystemOf(ref, key.sourceId);
  return fileSystem.picture(key.path, width: key.width, height: key.height);
});

/// The entry of the file a film page plays, for its watch progress and its upload
final plexFilmEntryProvider = FutureProvider.autoDispose.family<NetworkEntry, ({String sourceId, String path})>((
  ref,
  key,
) async {
  final fileSystem = await plexFileSystemOf(ref, key.sourceId);
  return fileSystem.stat(key.path);
});

/// The library of films [sectionKey] of [sourceId]
typedef PlexSectionKey = ({String sourceId, String sectionKey});

/// What the filter sheet of a library of films offers: its years (newest first), its decades, the content ratings of
/// its films as Plex stores them, each with its count when the server tells
class PlexFilmFilterOptions {
  const PlexFilmFilterOptions({this.years = const [], this.decades = const [], this.contentRatings = const []});

  final List<PlexFilterChoice> years;
  final List<PlexFilterChoice> decades;
  final List<PlexFilterChoice> contentRatings;

  bool get isEmpty => years.isEmpty && decades.isEmpty && contentRatings.isEmpty;
}

/// The filters of a library of films: the year, decade and contentRating filters the server lists, and their values;
/// a filter the server does not list is not offered
final plexFilmFilterOptionsProvider = FutureProvider.autoDispose.family<PlexFilmFilterOptions, PlexSectionKey>((
  ref,
  key,
) async {
  final fileSystem = await plexFileSystemOf(ref, key.sourceId);
  final filters = await fileSystem.sectionFilters(key.sectionKey);
  Future<List<PlexFilterChoice>> choices(String name) async {
    final filter = filters.where((filter) => filter.filter == name).firstOrNull;
    return filter == null ? const [] : fileSystem.filterChoices(key.sectionKey, filter);
  }

  final (years, decades, ratings) = await (choices('year'), choices('decade'), choices('contentRating')).wait;
  int yearOf(PlexFilterChoice choice) => int.tryParse(choice.key) ?? 0;
  return PlexFilmFilterOptions(
    years: [...years.where((choice) => yearOf(choice) > 0)]..sort((a, b) => yearOf(b).compareTo(yearOf(a))),
    decades: [...decades.where((choice) => yearOf(choice) > 0)]..sort((a, b) => yearOf(b).compareTo(yearOf(a))),
    contentRatings: ratings,
  );
});

/// The films of a library that a query keeps
typedef PlexFilmsKey = ({String sourceId, String sectionKey, PlexFilmsQuery query});

/// Every film of a library that a query keeps, with its entry (the path of plexFilmPath), [PlexFileSystem.allFilms]:
/// the filtered list of the folder view now, and the films page of lot A1 for its filters later
final plexFilmsProvider = FutureProvider.autoDispose
    .family<List<({NetworkEntry entry, PlexFilmItem item})>, PlexFilmsKey>((ref, key) async {
      final fileSystem = await plexFileSystemOf(ref, key.sourceId);
      return fileSystem.allFilms(key.sectionKey, key.query);
    });

/// What the Wikipedia block of a film page asks for: the film's numbers, the language of the app (a tag such as
/// "pt_BR") and the language of the library
typedef PlexWikipediaKey = ({String? imdb, String? tmdb, String appLocale, String? libraryLanguage});

/// The lead of the film's Wikipedia article in the language of the app, or down its chain (see wikipediaChainFor);
/// null when the switch is off (no request then goes out), when the film has no number to look it up by, or when
/// Wikipedia has nothing or does not answer
final plexFilmWikipediaProvider = FutureProvider.autoDispose.family<WikipediaFilmSummary?, PlexWikipediaKey>((
  ref,
  key,
) async {
  if (!ref.watch(appConfigProvider.select((config) => config.viewer.filmWikipedia))) {
    return null;
  }
  final ids = FilmExternalIds(imdb: key.imdb, tmdb: key.tmdb);
  if (ids.isEmpty) {
    return null;
  }
  final client = await ref.watch(wikipediaFilmClientProvider.future);
  return client.summary(ids, wikipediaChainFor(key.appLocale, libraryLanguage: key.libraryLanguage));
});

/// Turns the Wikipedia block of the film pages on or off; off, the leads kept on the device are deleted
Future<void> setFilmWikipedia(WidgetRef ref, bool on) async {
  await ref.read(settingsProvider).write(.viewerFilmWikipedia, on);
  if (!on) {
    try {
      final client = await ref.read(wikipediaFilmClientProvider.future);
      await client.clearCache();
    } catch (_) {
      // Nothing kept, or a cache that cannot be read: nothing to delete
    }
  }
}

/// Whether [source] is a Plex server
bool isPlexSource(NetworkSource? source) => source?.type == NetworkSourceType.plex;
