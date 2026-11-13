import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/film_player/film_decoders.dart';
import 'package:immich_mobile/domain/services/film_player/film_player_choice.dart';
import 'package:immich_mobile/presentation/pages/network/network_video.page.dart' show filmErrorHandsOver;

/// The decoders of the Meta Quest 3, as its media_codecs xml listed them on 11 November 2026: avc, hevc, av01,
/// dolby-vision, mp4v-es (software), mvhevc; E-AC-3 and AC-4 (Dolby), MP3, FLAC, Opus, Vorbis, AAC. No AC-3 MIME of its
/// own: the Dolby decoder answers audio/ac3 too
const questMimeTypes = {
  'video/avc',
  'video/hevc',
  'video/av01',
  'video/dolby-vision',
  'video/mp4v-es',
  'video/mv-hevc',
  'audio/eac3',
  'audio/eac3-joc',
  'audio/ac3',
  'audio/ac4',
  'audio/mpeg',
  'audio/flac',
  'audio/opus',
  'audio/vorbis',
  'audio/mp4a-latm',
  'audio/raw',
};

FilmPlayerChoice choose(
  FilmStreams? streams, {
  bool mpv = true,
  bool conversion = true,
  FilmPlayerPreference preference = FilmPlayerPreference.automatic,
}) => chooseFilmPlayer(
  streams: streams,
  device: deviceFilmDecoders(questMimeTypes),
  mpv: mpv ? mpvFilmDecoders : null,
  preference: preference,
  conversion: conversion,
);

void main() {
  group('the device decodes it', () {
    test('H.264 and AC-3 in MKV, HEVC Dolby Vision and E-AC-3: the device', () {
      for (final streams in const [
        FilmStreams(container: 'mkv', videoCodec: 'h264', videoProfile: 'high', audioCodec: 'ac3'),
        FilmStreams(container: 'mkv', videoCodec: 'hevc', videoProfile: 'main 10', audioCodec: 'eac3'),
        FilmStreams(container: 'mp4', videoCodec: 'av1', audioCodec: 'aac', subtitleCodec: 'mov_text'),
        FilmStreams(container: 'mkv', videoCodec: 'h264', audioCodec: 'pcm', subtitleCodec: 'pgs'),
      ]) {
        final choice = choose(streams);
        expect(choice.kind, FilmPlayerKind.device, reason: '$streams');
        expect(choice.reason, FilmPlayerReason.deviceDecodesAll);
        expect(choice.deviceMissing, isEmpty);
      }
    });

    test('subtitles never move a film away from the device', () {
      final choice = choose(
        const FilmStreams(container: 'mkv', videoCodec: 'hevc', audioCodec: 'eac3', subtitleCodec: 'pgs'),
      );
      expect(choice.kind, FilmPlayerKind.device);
    });
  });

  group('the device lacks a decoder', () {
    test('DTS, DivX 3, WMA, an Xvid with B frames, 10 bit H.264: mpv', () {
      for (final (streams, missing) in const [
        (FilmStreams(container: 'mkv', videoCodec: 'h264', audioCodec: 'dca'), 'audio dca'),
        (FilmStreams(container: 'mkv', videoCodec: 'hevc', audioCodec: 'dca', audioProfile: 'ma'), 'audio dca'),
        (FilmStreams(container: 'avi', videoCodec: 'msmpeg4v3', audioCodec: 'mp3'), 'video msmpeg4v3'),
        (FilmStreams(container: 'avi', videoCodec: 'mpeg4', audioCodec: 'wmav2'), 'audio wmav2'),
        (
          FilmStreams(container: 'avi', videoCodec: 'mpeg4', videoProfile: 'advanced simple', audioCodec: 'mp3'),
          'video mpeg4 (advanced simple)',
        ),
        (
          FilmStreams(container: 'mkv', videoCodec: 'h264', videoProfile: 'high 10', audioCodec: 'aac'),
          'video h264 (high 10)',
        ),
        (FilmStreams(container: 'asf', videoCodec: 'wmv3', audioCodec: 'wmav2'), 'container asf'),
      ]) {
        final choice = choose(streams);
        expect(choice.kind, FilmPlayerKind.mpv, reason: '$streams');
        expect(choice.reason, FilmPlayerReason.deviceLacks);
        expect(choice.deviceMissing, contains(missing));
        expect(choice.mpvMissing, isEmpty);
      }
    });

    test('a plain MPEG-4 part 2 film (simple profile) stays on the device', () {
      final choice = choose(
        const FilmStreams(container: 'avi', videoCodec: 'mpeg4', videoProfile: 'simple', audioCodec: 'mp3'),
      );
      expect(choice.kind, FilmPlayerKind.device);
    });

    test('TrueHD, which the libmpv of the Quest lacks too: the server converts', () {
      final choice = choose(const FilmStreams(container: 'mkv', videoCodec: 'hevc', audioCodec: 'truehd'));
      expect(choice.kind, FilmPlayerKind.serverConversion);
      expect(choice.reason, FilmPlayerReason.noLocalDecoder);
      expect(choice.deviceMissing, ['audio truehd']);
      expect(choice.mpvMissing, ['audio truehd']);
    });

    test('TrueHD with an AC3 or E-AC-3 track beside it (release 47): the device plays that track, no conversion', () {
      final choice = choose(
        const FilmStreams(container: 'mkv', videoCodec: 'hevc', audioCodec: 'truehd', otherAudioCodecs: ['ac3', 'dca']),
      );
      expect(choice.kind, FilmPlayerKind.device);
      expect(choice.reason, FilmPlayerReason.deviceDecodesAll);
      final dtsOnly = choose(
        const FilmStreams(container: 'mkv', videoCodec: 'hevc', audioCodec: 'truehd', otherAudioCodecs: ['dca']),
      );
      expect(dtsOnly.kind, FilmPlayerKind.mpv, reason: 'the DTS track is decoded by mpv only');
      expect(dtsOnly.deviceMissing, ['audio truehd']);
    });

    test('TrueHD without the conversion: mpv anyway, the best of what is left', () {
      final choice = choose(
        const FilmStreams(container: 'mkv', videoCodec: 'hevc', audioCodec: 'truehd'),
        conversion: false,
      );
      expect(choice.kind, FilmPlayerKind.mpv);
      expect(choice.reason, FilmPlayerReason.bestEffort);
    });

    test('a build without libmpv (the phones in 46): the conversion, else the device that says why', () {
      const dts = FilmStreams(container: 'mkv', videoCodec: 'h264', audioCodec: 'dca');
      expect(choose(dts, mpv: false).kind, FilmPlayerKind.serverConversion);
      final none = choose(dts, mpv: false, conversion: false);
      expect(none.kind, FilmPlayerKind.device);
      expect(none.reason, FilmPlayerReason.bestEffort);
      expect(none.mpvMissing, isEmpty);
    });
  });

  group('what the user asks', () {
    const dts = FilmStreams(container: 'mkv', videoCodec: 'h264', audioCodec: 'dca');
    const plain = FilmStreams(container: 'mkv', videoCodec: 'h264', audioCodec: 'aac');

    test('Device and mpv win over the streams', () {
      expect(choose(dts, preference: FilmPlayerPreference.device).kind, FilmPlayerKind.device);
      expect(choose(dts, preference: FilmPlayerPreference.device).reason, FilmPlayerReason.asked);
      expect(choose(plain, preference: FilmPlayerPreference.mpv).kind, FilmPlayerKind.mpv);
      expect(choose(plain, preference: FilmPlayerPreference.mpv).reason, FilmPlayerReason.asked);
    });

    test('mpv asked on a build without it: the device, and why', () {
      final choice = choose(plain, preference: FilmPlayerPreference.mpv, mpv: false);
      expect(choice.kind, FilmPlayerKind.device);
      expect(choice.reason, FilmPlayerReason.mpvMissing);
    });

    test('streams unknown (Plex did not tell): the device', () {
      final choice = choose(null);
      expect(choice.kind, FilmPlayerKind.device);
      expect(choice.reason, FilmPlayerReason.streamsUnknown);
    });
  });

  test('the line of the log names the codecs only', () {
    final line = choose(const FilmStreams(container: 'mkv', videoCodec: 'hevc', audioCodec: 'truehd')).logLine;
    expect(
      line,
      'Film player: serverConversion (noLocalDecoder; the device lacks audio truehd; libmpv lacks audio truehd)',
    );
  });

  group('nextFilmPlayer', () {
    test('device, then mpv, then the conversion, then nothing', () {
      expect(
        nextFilmPlayer(FilmPlayerKind.device, tried: {}, mpvAvailable: true, conversion: true),
        FilmPlayerKind.mpv,
      );
      expect(
        nextFilmPlayer(FilmPlayerKind.mpv, tried: {FilmPlayerKind.device}, mpvAvailable: true, conversion: true),
        FilmPlayerKind.serverConversion,
      );
      expect(
        nextFilmPlayer(
          FilmPlayerKind.serverConversion,
          tried: {FilmPlayerKind.device, FilmPlayerKind.mpv},
          mpvAvailable: true,
          conversion: true,
        ),
        isNull,
      );
    });

    test('without libmpv the device hands over to the conversion; without either, nothing', () {
      expect(
        nextFilmPlayer(FilmPlayerKind.device, tried: {}, mpvAvailable: false, conversion: true),
        FilmPlayerKind.serverConversion,
      );
      expect(nextFilmPlayer(FilmPlayerKind.device, tried: {}, mpvAvailable: false, conversion: false), isNull);
    });

    test('the conversion chosen first that failed goes to nothing: mpv was found lacking already', () {
      expect(nextFilmPlayer(FilmPlayerKind.serverConversion, tried: {}, mpvAvailable: true, conversion: true), isNull);
    });

    test('mpv chosen first that failed goes to the conversion', () {
      expect(
        nextFilmPlayer(FilmPlayerKind.mpv, tried: {}, mpvAvailable: true, conversion: true),
        FilmPlayerKind.serverConversion,
      );
    });
  });

  group('filmErrorHandsOver', () {
    test('a decoder that refused or gave no picture, a format not recognized', () {
      expect(filmErrorHandsOver('immuch360-playback-error:decoder:video/mp4v-es:640:480', played: true), isTrue);
      expect(filmErrorHandsOver('immuch360-playback-error:noFrame:video/avc:3840:2160', played: true), isTrue);
      expect(
        filmErrorHandsOver(
          'None of the available extractors (MatroskaExtractor, ...) could read the stream.',
          played: false,
        ),
        isTrue,
      );
    });

    test('any other failure before the film played, but not the link or the server', () {
      expect(filmErrorHandsOver('java.lang.NullPointerException', played: false), isTrue);
      expect(filmErrorHandsOver('java.lang.NullPointerException', played: true), isFalse);
      expect(filmErrorHandsOver('Response code: 500', played: false), isFalse);
      expect(filmErrorHandsOver('Unable to connect to http://127.0.0.1:1234/x', played: false), isFalse);
      expect(filmErrorHandsOver('immuch360-playback-error:stalled::0:0', played: false), isFalse);
    });
  });

  group('deviceFilmDecoders', () {
    test('the Quest: the codecs of its decoders, PCM by Media3 itself, no DTS, TrueHD, DivX 3 or WMA', () {
      final quest = deviceFilmDecoders(questMimeTypes);
      expect(quest.video, containsAll(['h264', 'hevc', 'av1', 'mpeg4']));
      expect(quest.audio, containsAll(['aac', 'ac3', 'eac3', 'mp3', 'flac', 'opus', 'vorbis', 'pcm']));
      expect(quest.audio, isNot(anyOf(contains('dca'), contains('truehd'), contains('wmav2'))));
      expect(quest.video, isNot(anyOf(contains('msmpeg4v3'), contains('vc1'), contains('wmv3'))));
    });

    test('a device with a DTS decoder (some TV boxes) decodes DTS', () {
      expect(deviceFilmDecoders({...questMimeTypes, 'audio/vnd.dts'}).audio, contains('dca'));
    });
  });
}
