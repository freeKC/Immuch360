import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/film_player/film_player_choice.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_film_streams.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_films.dart';

PlexFilmPart _part(List<PlexStream> streams, {String? container = 'MKV', int id = 7}) =>
    PlexFilmPart(id: id, key: '/library/parts/$id/1/file.mkv', container: container, streams: streams);

void main() {
  test('the video, the audio the account picked, the subtitles picked, in lower case', () {
    final part = _part(const [
      PlexStream(id: 1, type: PlexStreamType.video, codec: 'HEVC', profile: 'Main 10'),
      PlexStream(id: 2, type: PlexStreamType.audio, codec: 'truehd', isDefault: true),
      PlexStream(id: 3, type: PlexStreamType.audio, codec: 'ac3', selected: true),
      PlexStream(id: 4, type: PlexStreamType.subtitle, codec: 'pgs'),
      PlexStream(id: 5, type: PlexStreamType.subtitle, codec: 'srt', selected: true),
    ]);
    expect(
      filmStreamsOfPlexPart(part),
      const FilmStreams(
        container: 'mkv',
        videoCodec: 'hevc',
        videoProfile: 'main 10',
        audioCodec: 'ac3',
        otherAudioCodecs: ['truehd'],
        subtitleCodec: 'srt',
      ),
    );
  });

  test('no pick: the default audio track, else the first; no subtitles', () {
    final withDefault = _part(const [
      PlexStream(id: 2, type: PlexStreamType.audio, codec: 'aac'),
      PlexStream(id: 3, type: PlexStreamType.audio, codec: 'dca', profile: 'ma', isDefault: true),
    ]);
    expect(filmStreamsOfPlexPart(withDefault).audioCodec, 'dca');
    expect(filmStreamsOfPlexPart(withDefault).audioProfile, 'ma');
    expect(filmStreamsOfPlexPart(withDefault).subtitleCodec, isNull);
    final first = _part(const [
      PlexStream(id: 2, type: PlexStreamType.audio, codec: 'mp3'),
      PlexStream(id: 3, type: PlexStreamType.audio, codec: 'aac'),
    ]);
    expect(filmStreamsOfPlexPart(first).audioCodec, 'mp3');
  });

  test("the media's container when the part does not tell it", () {
    expect(filmStreamsOfPlexPart(_part(const [], container: null), container: 'avi').container, 'avi');
  });

  test('the profile of a stream is read from the answer of the server', () {
    final details = parsePlexFilmDetails({
      'MediaContainer': {
        'Metadata': [
          {
            'ratingKey': '6017',
            'title': 'A film',
            'Media': [
              {
                'id': 1,
                'Part': [
                  {
                    'id': 7,
                    'key': '/library/parts/7/1/file.mkv',
                    'container': 'mkv',
                    'Stream': [
                      {'id': 1, 'streamType': 1, 'codec': 'h264', 'profile': 'high 10'},
                      {'id': 2, 'streamType': 2, 'codec': 'dca', 'profile': 'ma'},
                    ],
                  },
                ],
              },
              {
                'id': 2,
                'Part': [
                  {'id': 9, 'key': '/library/parts/9/1/file.mkv'},
                ],
              },
            ],
          },
        ],
      },
    });
    final streams = filmStreamsOfPlexPart(details!.partOf(7)!);
    expect(streams.videoProfile, 'high 10');
    expect(streams.audioProfile, 'ma');
    expect(plexPartPlace(details, 9), (mediaIndex: 1, partIndex: 0));
    expect(plexPartPlace(details, 7), (mediaIndex: 0, partIndex: 0));
    expect(plexPartPlace(details, 42), (mediaIndex: 0, partIndex: 0));
  });
}
