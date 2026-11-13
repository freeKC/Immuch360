// The versions the video page offers for a slow link (filmVersionOffersProvider), wired at the integration of release
// 47 to the version choice of the film page: La Bataille de Gaulle of the test library, 2160p and 1080p.

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/film_player/film_slow_link.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_films.dart';
import 'package:immich_mobile/providers/network/film_version_offers.provider.dart';
import 'package:immich_mobile/providers/network/plex_film_version.provider.dart';
import 'package:immich_mobile/providers/network/plex_films.provider.dart';

import '../../infrastructure/network/plex/plex_film_versions_test.dart' show bataille;

class _Picks extends PlexFilmVersionPicks {
  final picked = <(String, String, int)>[];

  @override
  Map<String, int> build() => const {};

  @override
  Future<void> pick(String sourceId, String ratingKey, int mediaId) async => picked.add((sourceId, ratingKey, mediaId));
}

/// The fixture with the bit rates Plex gives each Media, in kbit/s
Map<String, Object?> _withBitrates() {
  final json = bataille();
  final media = (((json['MediaContainer']! as Map)['Metadata']! as List).first as Map)['Media']! as List;
  (media[0] as Map)['bitrate'] = 43000;
  (media[1] as Map)['bitrate'] = 2550;
  return json;
}

void main() {
  const tile = '/.films/3/14488/601/La.Bataille.2160p.mkv';

  ProviderContainer containerOf(PlexFilmDetails film, _Picks picks) {
    final container = ProviderContainer(
      overrides: [
        plexFilmDetailsProvider.overrideWith((ref, key) async => film),
        plexFilmVersionPicksProvider.overrideWith(() => picks),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test(
    'a film of two versions: both offered with their labels, paths and rates; the lighter one for a slow link',
    () async {
      final picks = _Picks();
      final container = containerOf(parsePlexFilmDetails(_withBitrates())!, picks);
      final offers = await container.read(filmVersionOffersProvider((sourceId: 'source', path: tile)).future);
      expect(offers.map((offer) => offer.label), ['2160p HEVC HDR, 52 GiB', '1080p HEVC, 3.0 GiB']);
      expect(offers.map((offer) => offer.path), [tile, '/.films/3/14488/602/La.Bataille.1080p.mkv']);
      expect(offers.map((offer) => offer.bitsPerSecond), [43000000, 2550000]);

      final lighter = lighterFilmVersion(
        offers,
        currentPath: tile,
        linkBitsPerSecond: 9100000,
        neededBitsPerSecond: 43000000,
      );
      expect(lighter?.path, '/.films/3/14488/602/La.Bataille.1080p.mkv');
      lighter!.onChosen!();
      expect(picks.picked, [('source', '14488', 502)], reason: 'the pick is remembered as on the film page');
    },
  );

  test('nothing offered for a path that is not a Plex film, nor for a film of one version', () async {
    final details = _withBitrates();
    final media = (((details['MediaContainer']! as Map)['Metadata']! as List).first as Map)['Media']! as List;
    media.removeAt(1);
    final container = containerOf(parsePlexFilmDetails(details)!, _Picks());
    expect(await container.read(filmVersionOffersProvider((sourceId: 'source', path: tile)).future), isEmpty);
    expect(
      await container.read(filmVersionOffersProvider((sourceId: 'source', path: '/Films/La.Bataille.mkv')).future),
      isEmpty,
    );
  });
}
