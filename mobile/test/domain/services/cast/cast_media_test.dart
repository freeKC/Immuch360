// Google Cast for a Plex film: the LOAD message (the relay's addresses and the film's texts, never a token), the
// content type, the static format table, the phone's address on the device's network, and the Cast devices of the
// sheet beside the linked screens

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/cast/cast_media.dart';

const _token = 'plex-token-0123456789';
const _plexHost = '192.168.1.10';

void main() {
  group('castLoadMessage', () {
    final film = CastFilm(
      contentUrl: Uri.parse('http://192.168.1.20:8364/cast/00112233445566778899aabbccddeeff/film'),
      contentType: 'video/mp4',
      title: 'Le Fabuleux Destin',
      year: 2001,
      posterUrl: Uri.parse('http://192.168.1.20:8364/cast/00112233445566778899aabbccddeeff/poster.jpg'),
      durationMs: 7320000,
      startMs: 61500,
    );

    test('loads the default receiver media with the relay addresses, the start, the title, year and poster', () {
      final message = castLoadMessage(film);
      expect(message['type'], 'LOAD');
      expect(message['autoplay'], true);
      expect(message['currentTime'], 61.5);
      final media = message['media']! as Map<String, Object?>;
      expect(media['contentId'], film.contentUrl.toString());
      expect(media['contentUrl'], film.contentUrl.toString());
      expect(media['streamType'], 'BUFFERED');
      expect(media['contentType'], 'video/mp4');
      expect(media['duration'], 7320);
      final metadata = media['metadata']! as Map<String, Object?>;
      expect(metadata['metadataType'], 1);
      expect(metadata['title'], 'Le Fabuleux Destin');
      expect(metadata['subtitle'], '2001');
      expect(metadata['releaseDate'], '2001');
      expect(metadata['images'], [
        {'url': film.posterUrl.toString()},
      ]);
    });

    test('carries no token, no Plex header and no address of the server', () {
      final text = jsonEncode(castLoadMessage(film));
      expect(text, isNot(contains(_token)));
      expect(text.toLowerCase(), isNot(contains('x-plex')));
      expect(text.toLowerCase(), isNot(contains('token')));
      expect(text, isNot(contains(_plexHost)));
      expect(text, isNot(contains('32400')));
      expect(text, isNot(contains('/library/')));
    });

    test('leaves out what is not known, and starts at 0 for a negative start', () {
      final message = castLoadMessage(
        CastFilm(
          contentUrl: Uri.parse('http://10.0.0.2:8364/cast/ab/film'),
          contentType: 'video/webm',
          title: 'X',
          startMs: -5,
        ),
      );
      expect(message['currentTime'], 0);
      final media = message['media']! as Map<String, Object?>;
      expect(media.containsKey('duration'), isFalse);
      final metadata = media['metadata']! as Map<String, Object?>;
      expect(metadata.keys, unorderedEquals(['metadataType', 'title']));
    });
  });

  test('castContentTypeOf: by container, else by extension; Matroska goes as MP4', () {
    expect(castContentTypeOf(container: 'mp4'), 'video/mp4');
    expect(castContentTypeOf(container: 'MKV'), 'video/mp4');
    expect(castContentTypeOf(container: 'webm'), 'video/webm');
    expect(castContentTypeOf(fileName: 'film.webm'), 'video/webm');
    expect(castContentTypeOf(fileName: 'film.mov'), 'video/mp4');
    expect(castContentTypeOf(), 'video/mp4');
  });

  group('checkCastFormat', () {
    const ultra = 'Chromecast Ultra';

    CastFormatCheck check(CastFilmFormat format, String? model) => checkCastFormat(format, castProfileOf(model));

    test('H.264 and AAC in MP4 play everywhere', () {
      final result = check(
        const CastFilmFormat(container: 'mp4', videoCodec: 'h264', audioCodec: 'aac', width: 1920, height: 1080),
        'Chromecast',
      );
      expect(result.support, CastSupport.yes);
      expect(result.issues, isEmpty);
    });

    test('an AVI with MPEG-4 Part 2 video and MP3 cannot play, with its container and its video named', () {
      final result = check(
        const CastFilmFormat(container: 'avi', videoCodec: 'mpeg4', audioCodec: 'mp3'),
        'Google TV Streamer',
      );
      expect(result.support, CastSupport.no);
      expect(result.reasons, const [
        CastIssue(CastIssueKind.container, CastSupport.no, 'AVI'),
        CastIssue(CastIssueKind.video, CastSupport.no, 'MPEG-4 Part 2'),
      ]);
    });

    test('DTS and TrueHD sound cannot play; Dolby Digital may, through the TV', () {
      expect(
        check(const CastFilmFormat(container: 'mp4', videoCodec: 'h264', audioCodec: 'dca'), ultra).reasons,
        const [CastIssue(CastIssueKind.audio, CastSupport.no, 'DTS')],
      );
      expect(
        check(const CastFilmFormat(container: 'mp4', videoCodec: 'h264', audioCodec: 'truehd'), ultra).support,
        CastSupport.no,
      );
      final dolby = check(const CastFilmFormat(container: 'mp4', videoCodec: 'h264', audioCodec: 'eac3'), ultra);
      expect(dolby.support, CastSupport.maybe);
      expect(dolby.reasons, const [CastIssue(CastIssueKind.audio, CastSupport.maybe, 'Dolby Digital Plus')]);
    });

    test('HEVC: plays on an Ultra, not on a Nest Hub, may on a plain Chromecast and an unknown TV', () {
      const hevc = CastFilmFormat(container: 'mp4', videoCodec: 'hevc', audioCodec: 'aac', width: 1920, height: 1080);
      expect(check(hevc, ultra).support, CastSupport.yes);
      expect(check(hevc, 'Google Nest Hub').support, CastSupport.no);
      expect(check(hevc, 'Chromecast').support, CastSupport.maybe);
      expect(check(hevc, 'BRAVIA 4K VH2').support, CastSupport.maybe);
      expect(check(hevc, null).support, CastSupport.maybe);
    });

    test('Matroska may play; 4K is no issue on an Ultra, cannot on a Chromecast HD', () {
      const uhd = CastFilmFormat(container: 'mkv', videoCodec: 'hevc', audioCodec: 'aac', width: 3840, height: 2160);
      final onUltra = check(uhd, ultra);
      expect(onUltra.support, CastSupport.maybe);
      expect(onUltra.reasons, const [CastIssue(CastIssueKind.container, CastSupport.maybe, 'Matroska')]);
      final onHd = check(uhd, 'Chromecast HD');
      expect(onHd.support, CastSupport.no);
      expect(onHd.reasons, const [CastIssue(CastIssueKind.size, CastSupport.no, '4K')]);
    });

    test('what the metadata does not tell adds nothing', () {
      expect(check(const CastFilmFormat(), 'Chromecast').support, CastSupport.yes);
    });
  });

  group('castRelayAddressFor', () {
    test('the private address on the device subnet', () {
      expect(castRelayAddressFor(['10.8.0.3', '192.168.1.20', '192.168.50.4'], '192.168.1.42'), '192.168.1.20');
    });

    test('none without a private address, or for a device that is no private IPv4 literal', () {
      expect(castRelayAddressFor(['100.64.1.2', '8.8.8.8'], '192.168.1.42'), isNull);
      expect(castRelayAddressFor(['192.168.1.20'], 'tv.local'), isNull);
      expect(castRelayAddressFor(['192.168.1.20'], '8.8.8.8'), isNull);
      expect(castRelayAddressFor(const [], '192.168.1.42'), isNull);
    });
  });

  group('the Cast devices of the sheet', () {
    test('a device of an mDNS answer: its name, model and id from the TXT record', () {
      final target = castTargetOf(
        serviceName: 'Chromecast-Ultra-abc',
        host: '192.168.1.42',
        port: 8009,
        attributes: {'id': 'abc', 'fn': 'Living room', 'md': 'Chromecast Ultra', 'ca': '201221'},
      );
      expect(
        target,
        const CastTarget(id: 'abc', name: 'Living room', host: '192.168.1.42', port: 8009, model: 'Chromecast Ultra'),
      );
    });

    test('a speaker (no display bit) and an address outside the private ranges are left out', () {
      expect(
        castTargetOf(serviceName: 's', host: '192.168.1.43', port: 8009, attributes: {'ca': '2052', 'fn': 'Kitchen'}),
        isNull,
      );
      expect(castTargetOf(serviceName: 's', host: '8.8.8.8', port: 8009, attributes: const {}), isNull);
    });

    test('merged: one row per device by name, the boxes that are linked screens announced nearby left to them', () {
      const living = CastTarget(id: 'a', name: 'Living room', host: '192.168.1.42', port: 8009);
      const livingAgain = CastTarget(
        id: 'a',
        name: 'Living room',
        host: '192.168.1.42',
        port: 8009,
        model: 'Chromecast',
      );
      const bedroom = CastTarget(id: 'b', name: 'bedroom', host: '192.168.1.44', port: 8009);
      const shield = CastTarget(id: 'c', name: 'Shield', host: '192.168.1.30', port: 8009);
      final rows = castRowsOf([shield, living, bedroom, livingAgain], {'192.168.1.30'});
      expect(rows.map((row) => row.id), ['b', 'a']);
      expect(rows.last.model, 'Chromecast');
    });
  });
}
