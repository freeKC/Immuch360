// The streams of a Jellyfin or Emby film in the names of the player choice, from the media sources the bench servers
// gave, and the choice they lead to with the decoders of the Meta Quest 3: libmpv for the DTS film, the device for
// H.264 and AAC.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/film_player/film_decoders.dart';
import 'package:immich_mobile/domain/services/film_player/film_player_choice.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_api.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_film_streams.dart';

import '../../../domain/services/film_player/film_player_choice_test.dart' show questMimeTypes;
import 'fake_jellyfin_server.dart';

JellyfinMediaSource _sourceOf(String folder, String name) => JellyfinItemsPage.parse(
  jellyfinFixture(folder, 'items_films'),
).items.firstWhere((item) => item.name == name).firstSource!;

FilmPlayerChoice _choose(FilmStreams streams) => chooseFilmPlayer(
  streams: streams,
  device: deviceFilmDecoders(questMimeTypes),
  mpv: mpvFilmDecoders,
  preference: FilmPlayerPreference.automatic,
  conversion: true,
);

void main() {
  test('the names of the choice: DTS is dca, profiles lower case, DTS-HD MA is ma', () {
    expect(jellyfinCodecToPlex('dts'), 'dca');
    expect(jellyfinCodecToPlex('HEVC'), 'hevc');
    expect(jellyfinCodecToPlex('truehd'), 'truehd');
    expect(jellyfinProfileToPlex('DTS-HD MA'), 'ma');
    expect(jellyfinProfileToPlex('DTS-HD HRA'), 'hra');
    expect(jellyfinProfileToPlex('Main 10'), 'main 10');
    expect(jellyfinProfileToPlex(null), isNull);
  });

  test('the container: as told, or from the file name when the server tells a family', () {
    const family = JellyfinMediaSource(id: 's', container: 'mov,mp4,m4a,3gp,3g2,mj2', path: '/m/Film.MOV');
    expect(jellyfinContainer(family), 'mov');
    expect(jellyfinContainer(family, fileName: 'Film.m4v'), 'mp4');
    expect(jellyfinContainer(const JellyfinMediaSource(id: 's', container: 'mkv')), 'mkv');
    expect(jellyfinContainer(const JellyfinMediaSource(id: 's', container: 'matroska')), 'mkv');
  });

  test('the DTS film of the bench: libmpv on the Quest; the H.264 AAC film: the device', () {
    for (final folder in ['jellyfin', 'jellyfin-10.10', 'emby']) {
      final tone = filmStreamsOfJellyfinSource(_sourceOf(folder, folder == 'emby' ? 'Tone' : 'Tone (2021)'));
      expect(
        tone,
        const FilmStreams(
          container: 'mkv',
          videoCodec: 'h264',
          videoProfile: 'high',
          audioCodec: 'dca',
          audioProfile: 'dts',
        ),
        reason: folder,
      );
      expect(_choose(tone).kind, FilmPlayerKind.mpv, reason: folder);
      final pattern = filmStreamsOfJellyfinSource(_sourceOf(folder, folder == 'emby' ? 'Pattern' : 'Pattern (2024)'));
      expect(pattern.container, 'mp4');
      expect((pattern.videoCodec, pattern.audioCodec, pattern.audioProfile), ('h264', 'aac', 'lc'));
      expect(_choose(pattern).kind, FilmPlayerKind.device, reason: folder);
    }
  });

  test('the default audio track plays, the others are the choice of a player that lacks it', () {
    const source = JellyfinMediaSource(
      id: 's',
      container: 'mkv',
      defaultAudioStreamIndex: 2,
      streams: [
        JellyfinMediaStream(type: 'Video', index: 0, codec: 'hevc', profile: 'Main 10'),
        JellyfinMediaStream(type: 'Audio', index: 1, codec: 'aac'),
        JellyfinMediaStream(type: 'Audio', index: 2, codec: 'dts', profile: 'DTS-HD MA'),
        JellyfinMediaStream(type: 'Audio', index: 3, codec: 'truehd', isDefault: true),
      ],
    );
    final streams = filmStreamsOfJellyfinSource(source);
    expect((streams.audioCodec, streams.audioProfile), ('dca', 'ma'));
    expect(streams.otherAudioCodecs, ['aac', 'truehd']);
    expect(streams.videoProfile, 'main 10');
  });
}
