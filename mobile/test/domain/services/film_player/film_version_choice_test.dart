// The version of a film that plays when its server holds several (film_version_choice.dart): La Bataille de Gaulle,
// 2160p HEVC HDR 52 GB and 1080p HEVC 3 GB, on the screens of the app.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/film_player/film_version_choice.dart';

void main() {
  const uhd = FilmVersion(height: 2160, sizeBytes: 52000000000);
  const hd = FilmVersion(height: 1080, sizeBytes: 3000000000);

  test('the version picked on the page wins', () {
    expect(chooseFilmVersion(const [uhd, hd], remembered: 0, screenHeight: 1080, phone: true), 0);
    expect(chooseFilmVersion(const [uhd, hd], remembered: 5, screenHeight: 2160), 0, reason: 'a pick no longer there');
  });

  test('a 1080p screen opens the 1080p version, a 4K screen the 2160p one', () {
    expect(chooseFilmVersion(const [uhd, hd], screenHeight: 1080), 1);
    expect(chooseFilmVersion(const [uhd, hd], screenHeight: 1050), 1, reason: 'a laptop screen with scaling');
    expect(chooseFilmVersion(const [uhd, hd], screenHeight: 2160), 0);
    expect(chooseFilmVersion(const [hd, uhd], screenHeight: 2160), 1);
  });

  test('a version the device does not decode gives its place, unless none is decoded', () {
    const undecodable = FilmVersion(height: 2160, sizeBytes: 52000000000, decodable: false);
    expect(chooseFilmVersion(const [undecodable, hd], screenHeight: 2160), 1);
    const both = [undecodable, FilmVersion(height: 1080, decodable: false)];
    expect(chooseFilmVersion(both, screenHeight: 2160), 0);
  });

  test('a phone leaves a very large file when a smaller version is there', () {
    const phoneUhd = FilmVersion(height: 1440, sizeBytes: 52000000000);
    expect(chooseFilmVersion(const [phoneUhd, hd], screenHeight: 1440, phone: true), 1);
    expect(chooseFilmVersion(const [phoneUhd, hd], screenHeight: 1440), 0, reason: 'not a phone');
    expect(chooseFilmVersion(const [phoneUhd], screenHeight: 1440, phone: true), 0);
  });

  test('every version above the screen: the smallest; the screen not known: the first decoded', () {
    expect(chooseFilmVersion(const [uhd, hd], screenHeight: 720), 1);
    expect(chooseFilmVersion(const [FilmVersion(), hd], screenHeight: 720), 1, reason: 'an unknown height is large');
    expect(chooseFilmVersion(const [uhd, hd]), 0);
    expect(chooseFilmVersion(const []), 0);
  });
}
