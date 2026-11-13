// The versions of a Plex film (plex_film_versions.dart) and the file the film page opens for each
// (plexFilmPlayPath): La Bataille de Gaulle of the test library, 2160p HEVC Dolby Vision 8 52 GB with TrueHD, AC3
// and DTS, and 1080p HEVC 3 GB with E-AC-3, as the server answers /library/metadata/14488.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/film_player/film_audio_choice.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_film_versions.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_films.dart';
import 'package:immich_mobile/presentation/pages/network/plex_film.page.dart';

Map<String, Object?> bataille({int? doviProfile = 8}) => {
  'MediaContainer': {
    'librarySectionID': '3',
    'Metadata': [
      {
        'ratingKey': '14488',
        'title': "La Bataille de Gaulle : J'écris ton nom",
        'Media': [
          {
            'id': 501,
            'videoResolution': '4k',
            'videoCodec': 'hevc',
            'width': 3840,
            'height': 1608,
            'Part': [
              {
                'id': 601,
                'key': '/library/parts/601/1/file.mkv',
                'file': '/films/La.Bataille.2160p.mkv',
                'size': 55834574848,
                'container': 'mkv',
                'Stream': [
                  {
                    'id': 1,
                    'streamType': 1,
                    'codec': 'hevc',
                    'profile': 'main 10',
                    'colorTrc': 'smpte2084',
                    'DOVIPresent': true,
                    'DOVIProfile': ?doviProfile,
                  },
                  {
                    'id': 2,
                    'streamType': 2,
                    'index': 1,
                    'codec': 'truehd',
                    'languageTag': 'fr',
                    'default': true,
                    'displayTitle': 'French (TRUEHD 7.1)',
                  },
                  {
                    'id': 3,
                    'streamType': 2,
                    'index': 2,
                    'codec': 'ac3',
                    'languageTag': 'fr',
                    'displayTitle': 'French (AC3 5.1)',
                  },
                  {'id': 4, 'streamType': 2, 'index': 3, 'codec': 'dca', 'languageTag': 'fr'},
                ],
              },
            ],
          },
          {
            'id': 502,
            'videoResolution': '1080',
            'videoCodec': 'hevc',
            'Part': [
              {
                'id': 602,
                'key': '/library/parts/602/1/file.mkv',
                'file': '/films/La.Bataille.1080p.mkv',
                'size': 3221225472,
                'container': 'mkv',
                'Stream': [
                  {'id': 11, 'streamType': 1, 'codec': 'hevc', 'colorTrc': 'bt709'},
                  {'id': 12, 'streamType': 2, 'index': 1, 'codec': 'eac3', 'languageTag': 'fr', 'default': true},
                ],
              },
            ],
          },
          {'id': 503, 'videoResolution': 'sd'},
        ],
      },
    ],
  },
};

void main() {
  final film = parsePlexFilmDetails(bataille())!;

  test('the versions with a file, their lines, heights and sizes', () {
    final versions = plexFilmVersions(film);
    expect(versions.map((media) => media.id), [501, 502], reason: 'the Media without a file is left out');
    expect(versions.map(plexFilmVersionLabel), ['2160p HEVC HDR, 52 GiB', '1080p HEVC, 3.0 GiB']);
    expect(versions.map(plexMediaHeight), [2160, 1080]);
    expect(plexMediaSize(versions.first), 55834574848);
  });

  test('Dolby Vision is read from the stream; a profile 5 version says so', () {
    final video = plexMediaVideo(plexFilmVersions(film).first)!;
    expect(video.doviProfile, 8);
    expect(video.isHdr, isTrue);
    expect(plexPartIsDolbyVision5(film.partOf(601)!), isFalse);
    final five = parsePlexFilmDetails(bataille(doviProfile: 5))!;
    expect(plexPartIsDolbyVision5(five.partOf(601)!), isTrue);
    expect(plexFilmVersionLabel(plexFilmVersions(five).first), '2160p HEVC Dolby Vision, 52 GiB');
    expect(plexMediaVideo(plexFilmVersions(film).last)!.isHdr, isFalse);
  });

  test('the streams of a version for the decoders, with every audio track', () {
    final streams = plexVersionStreams(plexFilmVersions(film).first);
    expect(streams.videoCodec, 'hevc');
    expect(streams.audioCodec, 'truehd');
    expect(streams.otherAudioCodecs, ['ac3', 'dca']);
  });

  test('the audio tracks of a file in its order, and the labels in a sentence', () {
    final part = film.partOf(601)!;
    expect(plexFilmAudioTracks(part).map((track) => track.codec), ['truehd', 'ac3', 'dca']);
    final pick = pickFilmAudio(plexFilmAudioTracks(part), decodes: (codec) => codec != 'truehd');
    expect(plexEmbeddedAudio(part)[pick.index!].displayTitle, 'French (AC3 5.1)');
    expect(plexTrackLabelInSentence('French (AC3 5.1)'), 'French AC3 5.1');
  });

  group('the file the film page opens', () {
    const tile = '/.films/3/14488/601/La.Bataille.2160p.mkv';

    test('the tile of the films page for its version, the version\'s own path for the other', () {
      expect(plexFilmPlayPath(film, given: tile, version: 0), tile);
      expect(plexFilmPlayPath(film, given: tile, version: 1), '/.films/3/14488/602/La.Bataille.1080p.mkv');
      expect(plexFilmPlayPath(film, version: 1), '/.films/3/14488/602/La.Bataille.1080p.mkv');
    });

    test('a file of the folder view: kept for its own version', () {
      const folder = '/Films/La.Bataille.1080p.mkv';
      expect(plexFilmPlayPath(film, given: folder, givenPartId: 602, version: 1), folder);
      expect(
        plexFilmPlayPath(film, given: folder, givenPartId: 602, version: 0),
        '/.films/3/14488/601/La.Bataille.2160p.mkv',
      );
      expect(plexFilmPlayPath(film, given: folder, version: 0), folder, reason: 'its part not known yet');
    });
  });
}
