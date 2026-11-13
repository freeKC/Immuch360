// The audio track of a film when the player cannot decode the one it would play (film_audio_choice.dart), with the
// tracks of the films of the desktop Plex validation of 13 November 2026.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/film_player/film_audio_choice.dart';
import 'package:immich_mobile/domain/services/film_player/film_decoders.dart';

bool _quest(String codec) => !libmpvMissingAudioCodecs.contains(codec);

void main() {
  // La Bataille de Gaulle 2160p: TrueHD 7.1 by default, then AC3 5.1 and DTS 2.0, all three French
  const bataille = [
    FilmAudioTrack(codec: 'truehd', language: 'fr', isDefault: true),
    FilmAudioTrack(codec: 'ac3', language: 'fr'),
    FilmAudioTrack(codec: 'dca', language: 'fr'),
  ];

  test('a track the player decodes is kept', () {
    expect(pickFilmAudio(bataille, wanted: 1, decodes: _quest), const FilmAudioPick(FilmAudioOutcome.kept, index: 1));
  });

  test('the default TrueHD track gives its place to the first track the computers decode: AC3 5.1', () {
    expect(pickFilmAudio(bataille, decodes: _quest), const FilmAudioPick(FilmAudioOutcome.switched, index: 1, from: 0));
  });

  test('the same language comes first, then the first track decoded', () {
    const tracks = [
      FilmAudioTrack(codec: 'truehd', language: 'fre', isDefault: true),
      FilmAudioTrack(codec: 'eac3', language: 'eng'),
      FilmAudioTrack(codec: 'ac3', language: 'fra'),
    ];
    expect(pickFilmAudio(tracks, decodes: _quest).index, 2, reason: 'fre and fra are both French');
    const others = [
      FilmAudioTrack(codec: 'truehd', language: 'fr', isDefault: true),
      FilmAudioTrack(codec: 'eac3', language: 'en'),
      FilmAudioTrack(codec: 'ac3', language: 'de'),
    ];
    expect(pickFilmAudio(others, decodes: _quest), const FilmAudioPick(FilmAudioOutcome.switched, index: 1, from: 0));
  });

  test('the account\'s pick is the track the player would play, before the default one', () {
    const tracks = [
      FilmAudioTrack(codec: 'ac3', language: 'fr', isDefault: true),
      FilmAudioTrack(codec: 'truehd', language: 'en'),
      FilmAudioTrack(codec: 'aac', language: 'en'),
    ];
    expect(pickFilmAudio(tracks, wanted: 1, decodes: _quest).index, 2, reason: 'English, as picked');
  });

  test('a film with only TrueHD (Astérix, L\'Empire du Milieu) has no sound on the computers', () {
    const tracks = [FilmAudioTrack(codec: 'truehd', language: 'fr', isDefault: true)];
    expect(pickFilmAudio(tracks, decodes: _quest), const FilmAudioPick(FilmAudioOutcome.none, from: 0));
  });

  test('without a default, the first track is the one the player would play; no track, nothing to pick', () {
    const tracks = [FilmAudioTrack(codec: 'mlp'), FilmAudioTrack(codec: 'opus')];
    expect(pickFilmAudio(tracks, decodes: _quest), const FilmAudioPick(FilmAudioOutcome.switched, index: 1, from: 0));
    expect(pickFilmAudio(const [], decodes: _quest).outcome, FilmAudioOutcome.kept);
  });

  test('an unknown codec counts as decoded; DTS is one codec under its two names', () {
    expect(pickFilmAudio(const [FilmAudioTrack()], decodes: (_) => false).outcome, FilmAudioOutcome.kept);
    final asked = <String>[];
    pickFilmAudio(
      const [FilmAudioTrack(codec: 'dts')],
      decodes: (codec) {
        asked.add(codec);
        return true;
      },
    );
    expect(asked, ['dca']);
  });

  test('a decoder that failed at run time counts as not decoded', () {
    final failed = {'eac3'};
    const tracks = [
      FilmAudioTrack(codec: 'eac3', language: 'fr', isDefault: true),
      FilmAudioTrack(codec: 'aac', language: 'fr'),
    ];
    expect(pickFilmAudio(tracks, decodes: (codec) => !failed.contains(codec)).index, 1);
  });

  test('names in a sentence and language keys', () {
    expect(audioCodecDisplayName('truehd'), 'TrueHD');
    expect(audioCodecDisplayName('dts'), 'DTS');
    expect(audioCodecDisplayName('eac3'), 'E-AC-3');
    expect(audioCodecDisplayName('pcm_s24le'), 'PCM_S24LE');
    expect(audioLanguageKey('fre'), 'fr');
    expect(audioLanguageKey('fr-FR'), 'fr');
    expect(audioLanguageKey('und'), isNull);
    expect(audioLanguageKey('tlh'), 'tlh');
  });

  test('libmpv lacks TrueHD on the Quest only; the computers decode it since the 20261113-2 releases', () {
    expect(libmpvMissingAudioOn(android: true), {'truehd', 'mlp'});
    expect(libmpvMissingAudioOn(android: false), isEmpty);
    expect(mpvFilmDecoders.audio.contains('truehd'), isFalse, reason: 'the Quest libmpv of media-kit v1.1.7');
    expect(iosAudioCodecs.containsAll(['truehd', 'dca']), isFalse);
  });
}
