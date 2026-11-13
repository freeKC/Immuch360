// The link of the notifications of the film downloads: the page, Retry and Resume of a film, nothing else.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/film_download/film_download_link.dart';

void main() {
  test('a tap opens Downloaded films', () {
    expect(parseFilmDownloadLink(Uri.parse(filmDownloadsLink)), (filmId: null, action: null));
  });

  test('Retry and Resume name the film and go round the parser', () {
    for (final action in FilmDownloadLinkAction.values) {
      final link = filmDownloadActionLink('0a1b2c3d4e5f6071', action);
      expect(link, startsWith('immuch360://downloads?'));
      expect(parseFilmDownloadLink(Uri.parse(link)), (filmId: '0a1b2c3d4e5f6071', action: action));
    }
  });

  test('a film or an action the app does not make only opens the page', () {
    expect(parseFilmDownloadLink(Uri.parse('immuch360://downloads?film=../x&do=retry')), (filmId: null, action: null));
    expect(parseFilmDownloadLink(Uri.parse('immuch360://downloads?film=0a1b&do=delete')), (filmId: null, action: null));
    expect(parseFilmDownloadLink(Uri.parse('immuch360://downloads?do=resume')), (filmId: null, action: null));
  });

  test('other links are not ones of the downloads', () {
    expect(parseFilmDownloadLink(Uri.parse('immuch360://pair?u=http://192.168.1.2:2283')), isNull);
    expect(parseFilmDownloadLink(Uri.parse('immich://asset?id=1')), isNull);
    expect(parseFilmDownloadLink(Uri.parse('https://downloads/x')), isNull);
  });
}
