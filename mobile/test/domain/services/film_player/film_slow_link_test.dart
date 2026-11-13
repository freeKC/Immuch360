// What the video page offers for a link slower than the film (release 47, the S24 test: a 2160p file of 43 Mbit/s over
// 9 to 12 Mbit/s)

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/film_player/film_slow_link.dart';

FilmVersionOffer _offer(String path, int? bitsPerSecond) =>
    (label: path, path: path, bitsPerSecond: bitsPerSecond, onChosen: null);

void main() {
  test('the conversion asks 70 % of the link, between 1.5 and 20 Mbit/s', () {
    expect(filmConversionKbpsFor(9100000), 6370);
    expect(filmConversionKbpsFor(1000000), 1500);
    expect(filmConversionKbpsFor(100000000), 20000);
  });

  test('the richest lighter version the link carries with its margin', () {
    final offers = [_offer('/uhd.mkv', 43000000), _offer('/hd.mkv', 2550000), _offer('/hd-high.mkv', 8000000)];
    final version = lighterFilmVersion(
      offers,
      currentPath: '/uhd.mkv',
      linkBitsPerSecond: 9100000,
      neededBitsPerSecond: 43000000,
    );
    expect(version?.path, '/hd.mkv', reason: '8 Mbit/s is above 70 % of 9.1');
    expect(
      lighterFilmVersion(
        offers,
        currentPath: '/uhd.mkv',
        linkBitsPerSecond: 12000000,
        neededBitsPerSecond: 43000000,
      )?.path,
      '/hd-high.mkv',
    );
  });

  test('the lightest one when none fits, none when none is known to be lighter', () {
    final offers = [_offer('/uhd.mkv', 43000000), _offer('/hd.mkv', 8000000), _offer('/other.mkv', null)];
    expect(
      lighterFilmVersion(
        offers,
        currentPath: '/uhd.mkv',
        linkBitsPerSecond: 2000000,
        neededBitsPerSecond: 43000000,
      )?.path,
      '/hd.mkv',
    );
    expect(
      lighterFilmVersion(offers, currentPath: '/hd.mkv', linkBitsPerSecond: 2000000, neededBitsPerSecond: 8000000),
      isNull,
    );
    expect(lighterFilmVersion(const [], currentPath: '/uhd.mkv', linkBitsPerSecond: 1, neededBitsPerSecond: 2), isNull);
  });
}
