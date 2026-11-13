// The version of a Plex film picked on its page (StoreKey.plexFilmVersions), and the version the film page opens: the
// pick, else the one this device plays best (film_version_choice.dart).

import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/film_player/film_decoders.dart';
import 'package:immich_mobile/domain/services/film_player/film_player_choice.dart';
import 'package:immich_mobile/domain/services/film_player/film_version_choice.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_film_versions.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_films.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/film_player.provider.dart';

/// The picks, by `<source id>:<ratingKey>`: the id of the Plex Media
class PlexFilmVersionPicks extends Notifier<Map<String, int>> {
  /// Picks kept at most, the oldest dropped first
  static const maxPicks = 500;

  StoreService get _store => ref.read(storeServiceProvider);

  @override
  Map<String, int> build() {
    final stored = ref.watch(storeServiceProvider).tryGet(StoreKey.plexFilmVersions);
    if (stored == null || stored.isEmpty) {
      return const {};
    }
    try {
      final decoded = jsonDecode(stored);
      if (decoded is! Map) {
        return const {};
      }
      return {
        for (final MapEntry(:key, :value) in decoded.entries)
          if (value is int) '$key': value,
      };
    } on FormatException {
      return const {};
    }
  }

  static String keyOf(String sourceId, String ratingKey) => '$sourceId:$ratingKey';

  /// The Media id picked for the film [ratingKey] of [sourceId], null when none
  int? of(String sourceId, String ratingKey) => state[keyOf(sourceId, ratingKey)];

  Future<void> pick(String sourceId, String ratingKey, int mediaId) async {
    final key = keyOf(sourceId, ratingKey);
    final next = {...state}..remove(key);
    next[key] = mediaId;
    while (next.length > maxPicks) {
      next.remove(next.keys.first);
    }
    state = next;
    await _store.put(StoreKey.plexFilmVersions, jsonEncode(next));
  }
}

final plexFilmVersionPicksProvider = NotifierProvider<PlexFilmVersionPicks, Map<String, int>>(PlexFilmVersionPicks.new);

/// What the default version reads of this device: the shorter side of its screen in pixels, whether it is a phone,
/// and whether its players decode the streams of a file (null: they all count as decodable)
typedef FilmVersionDevice = ({int? screenHeight, bool phone, bool Function(FilmStreams streams)? decodes});

/// The screen and the decoders of this device, for the default version; the tests give their own
final filmVersionDeviceProvider = FutureProvider.autoDispose<FilmVersionDevice>((ref) async {
  final display = PlatformDispatcher.instance.displays.firstOrNull;
  final size = display?.size;
  final screenHeight = size == null || size.isEmpty ? null : size.shortestSide.round();
  final tv = ref.watch(tvModeProvider);
  final phone = !tv && !CurrentPlatform.isDesktop && (Platform.isAndroid || Platform.isIOS);
  bool Function(FilmStreams streams)? decodes;
  if (CurrentPlatform.isDesktop) {
    final missing = libmpvMissingAudioOn(android: false);
    decodes = (streams) =>
        [streams.audioCodec, ...streams.otherAudioCodecs].any((codec) => codec == null || !missing.contains(codec));
  } else if (Platform.isAndroid) {
    final players = ref.read(filmPlayersProvider);
    final device = await players.deviceDecoders();
    final mpv = await players.mpvAvailable() ? mpvFilmDecoders : null;
    if (device != null) {
      decodes = (streams) => device.missing(streams).isEmpty || (mpv != null && mpv.missing(streams).isEmpty);
    }
  }
  return (screenHeight: screenHeight, phone: phone, decodes: decodes);
}, dependencies: [tvModeProvider]);

/// The place among the versions of [film] (plexFilmVersions) of the one its page opens: the pick of [picks], else the
/// version of the file [tappedPartId] the user opened in the folder view, else the best one for [device]
int plexFilmVersionIndex(
  PlexFilmDetails film,
  String sourceId,
  Map<String, int> picks,
  FilmVersionDevice? device, {
  int? tappedPartId,
}) {
  final versions = plexFilmVersions(film);
  if (versions.length < 2) {
    return 0;
  }
  final picked = picks[PlexFilmVersionPicks.keyOf(sourceId, film.ratingKey)];
  var remembered = picked == null ? -1 : versions.indexWhere((media) => media.id == picked);
  if (remembered < 0 && tappedPartId != null) {
    remembered = versions.indexWhere((media) => media.parts.any((part) => part.id == tappedPartId));
  }
  return chooseFilmVersion(
    plexFilmVersionsForChoice(film, decodes: device?.decodes),
    remembered: remembered >= 0 ? remembered : null,
    screenHeight: device?.screenHeight,
    phone: device?.phone ?? false,
  );
}
