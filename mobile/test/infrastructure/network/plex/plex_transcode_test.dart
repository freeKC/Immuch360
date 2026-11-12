import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_transcode.dart';

/// The answer of the test server (Plex Media Server 1.42.1) to the decision call for a film in H.264 and DTS, with
/// directPlay=0, directStream=1, protocol=hls and X-Plex-Platform Android, 11 November 2026: the shape, the film's
/// fields left out
const _dtsDecision = {
  'MediaContainer': {
    'size': 1,
    'directPlayDecisionCode': 3000,
    'directPlayDecisionText': 'App cannot direct play this item. Direct play is disabled.',
    'generalDecisionCode': 1001,
    'generalDecisionText': 'Direct play not available; Conversion OK.',
    'transcodeDecisionCode': 1001,
    'transcodeDecisionText': 'Direct play not available; Conversion OK.',
    'Metadata': [
      {
        'ratingKey': '6017',
        'Media': [
          {
            'container': 'mpegts',
            'protocol': 'hls',
            'selected': true,
            'Part': [
              {
                'Stream': [
                  {'streamType': 1, 'codec': 'h264', 'decision': 'copy', 'location': 'segments-av'},
                  {'streamType': 2, 'codec': 'eac3', 'decision': 'transcode', 'channels': 6},
                ],
              },
            ],
          },
        ],
      },
    ],
  },
};

/// The answer for the platform "Generic": no profile for HLS
const _genericDecision = {
  'MediaContainer': {
    'generalDecisionCode': 2000,
    'generalDecisionText': 'Neither direct play nor conversion is available.',
    'transcodeDecisionCode': 4005,
    'transcodeDecisionText': 'Cannot convert this item. No conversion profile found for protocol hls.',
  },
};

final _base = Uri.parse('https://10-0-0-2.0123456789abcdef.plex.direct:32400');

void main() {
  group('PlexTranscodeRequest', () {
    const request = PlexTranscodeRequest(ratingKey: '6017', session: 'abc123', mediaIndex: 1, partIndex: 0);

    test('asks HLS, the video copied when it can be, no direct play, the session named', () {
      final query = request.query;
      expect(query['path'], '/library/metadata/6017');
      expect(query['mediaIndex'], '1');
      expect(query['partIndex'], '0');
      expect(query['protocol'], 'hls');
      expect(query['directPlay'], '0');
      expect(query['directStream'], '1');
      expect(query['session'], 'abc123');
      expect(query['X-Plex-Session-Identifier'], 'abc123');
      expect(query['offset'], '0.000');
    });

    test('no token or credential in any address', () {
      for (final uri in [request.decisionUri(_base), request.startUri(_base), request.stopUri(_base)]) {
        expect(uri.toString().toLowerCase(), isNot(contains('token')));
      }
      expect(request.headers.keys, ['x-plex-client-profile-extra']);
    });

    test('the addresses of the transcoder', () {
      expect(request.decisionUri(_base).path, '/video/:/transcode/universal/decision');
      expect(request.startUri(_base).path, '/video/:/transcode/universal/start.m3u8');
      expect(request.stopUri(_base).path, '/video/:/transcode/universal/stop');
      expect(request.stopUri(_base).queryParameters, {'session': 'abc123'});
      expect(request.startUri(_base).queryParameters, request.query);
    });

    test('the profile extra: the audio codecs of the device in 5.1, none when it has none', () {
      expect(
        request.profileExtra,
        'append-transcode-target-audio-codec(type=videoProfile&context=streaming&protocol=hls&audioCodec=eac3,ac3)+'
        'add-limitation(scope=videoAudioCodec&scopeName=eac3&type=upperBound&name=audio.channels&value=6)+'
        'add-limitation(scope=videoAudioCodec&scopeName=ac3&type=upperBound&name=audio.channels&value=6)',
      );
      expect(const PlexTranscodeRequest(ratingKey: '1', session: 's', audioCodecs: []).profileExtra, isEmpty);
    });

    test('a session id of 32 hexadecimal digits', () {
      expect(newPlexTranscodeSession(Random(1)), matches(RegExp(r'^[0-9a-f]{32}$')));
    });
  });

  group('parsePlexTranscodeDecision', () {
    test('the conversion the test server agreed to', () {
      final decision = parsePlexTranscodeDecision(_dtsDecision);
      expect(decision.canConvert, isTrue);
      expect(decision.transcodeCode, 1001);
      expect(decision.streams, [
        (type: 1, codec: 'h264', decision: 'copy'),
        (type: 2, codec: 'eac3', decision: 'transcode'),
      ]);
      expect(
        decision.logLine,
        'Plex conversion: 1001 Direct play not available; Conversion OK. (h264 copy, eac3 transcode)',
      );
    });

    test('no profile for HLS: no conversion', () {
      final decision = parsePlexTranscodeDecision(_genericDecision);
      expect(decision.canConvert, isFalse);
      expect(decision.transcodeCode, 4005);
    });

    test('an answer of another shape: no conversion', () {
      expect(parsePlexTranscodeDecision(null).canConvert, isFalse);
      expect(parsePlexTranscodeDecision({'MediaContainer': 'x'}).canConvert, isFalse);
      expect(
        parsePlexTranscodeDecision({
          'MediaContainer': {'mdeDecisionCode': '1000'},
        }).canConvert,
        isTrue,
      );
    });
  });

  group('playlists', () {
    final start = Uri.parse('https://server/video/:/transcode/universal/start.m3u8?session=abc');

    test('the variant named by start.m3u8', () {
      const master = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x800\nsession/abc/base/index.m3u8\n';
      expect(
        firstHlsEntry(master, start).toString(),
        'https://server/video/:/transcode/universal/session/abc/base/index.m3u8',
      );
      expect(firstHlsEntry('#EXTM3U\n', start), isNull);
    });

    test('the segments renamed by number, their addresses kept, the numbers stable across reads', () {
      final index = Uri.parse('https://server/video/:/transcode/universal/session/abc/base/index.m3u8');
      const text = '#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.0,\n00000.ts\n#EXTINF:4.0,\n00001.ts\n#EXT-X-ENDLIST\n';
      final first = renameHlsSegments(text, index);
      expect(
        first.playlist,
        '#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.0,\n0.ts\n#EXTINF:4.0,\n1.ts\n#EXT-X-ENDLIST\n',
      );
      expect(first.segments.map((uri) => uri.path), [
        '/video/:/transcode/universal/session/abc/base/00000.ts',
        '/video/:/transcode/universal/session/abc/base/00001.ts',
      ]);
      final again = renameHlsSegments(
        '#EXTM3U\n#EXTINF:4.0,\n00001.ts\n#EXTINF:4.0,\n00002.ts\n',
        index,
        known: first.segments,
      );
      expect(again.playlist, '#EXTM3U\n#EXTINF:4.0,\n1.ts\n#EXTINF:4.0,\n2.ts\n');
      expect(again.segments, hasLength(3));
    });
  });

  test('a tag that names another address is left out: the playlist names the bridge\'s files only', () {
    final index = Uri.parse('https://server/base/index.m3u8');
    const text =
        '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="https://elsewhere/key"\n#EXT-X-MAP:URI="init.mp4"\n'
        '#EXTINF:4.0,\nhttps://elsewhere/00000.ts\n';
    final renamed = renameHlsSegments(text, index);
    expect(renamed.playlist, '#EXTM3U\n#EXTINF:4.0,\n0.ts\n');
    expect(renamed.segments.single.toString(), 'https://elsewhere/00000.ts');
  });

  group('PlexConversion', () {
    late List<Uri> asked;
    late Map<String, String> sentHeaders;
    late Map<String, String> answers;

    PlexConversion conversion() => PlexConversion(
      request: const PlexTranscodeRequest(ratingKey: '6017', session: 'abc'),
      base: _base,
      fetch: (uri, headers) async {
        asked.add(uri);
        sentHeaders = headers;
        final body = answers[uri.path];
        if (body == null) {
          throw StateError('404');
        }
        return Uint8List.fromList(utf8.encode(body));
      },
    );

    setUp(() {
      asked = [];
      sentHeaders = {};
      answers = {
        '/video/:/transcode/universal/start.m3u8':
            '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nsession/abc/base/index.m3u8\n',
        '/video/:/transcode/universal/session/abc/base/index.m3u8': '#EXTM3U\n#EXTINF:4.0,\n00000.ts\n#EXT-X-ENDLIST\n',
        '/video/:/transcode/universal/session/abc/base/00000.ts': 'TS',
        '/video/:/transcode/universal/stop': '',
      };
    });

    test('the playlist of the stream, then its segments by number, with the profile extra', () async {
      final media = conversion();
      final playlist = await media.fetch(PlexConversion.playlistName);
      expect(playlist!.contentType, 'application/vnd.apple.mpegurl');
      expect(utf8.decode(playlist.bytes!), '#EXTM3U\n#EXTINF:4.0,\n0.ts\n#EXT-X-ENDLIST\n');
      expect(sentHeaders.keys, contains('x-plex-client-profile-extra'));
      final segment = await media.fetch('0.ts');
      expect(segment!.contentType, 'video/mp2t');
      expect(utf8.decode(segment.bytes!), 'TS');
      expect(await media.fetch('1.ts'), isNull);
      expect(await media.fetch('other'), isNull);
      // start.m3u8 once: the next reads of the playlist go to the stream's own
      await media.fetch(PlexConversion.playlistName);
      expect(asked.where((uri) => uri.path.endsWith('start.m3u8')), hasLength(1));
    });

    test('a server whose start.m3u8 is the media playlist itself', () async {
      answers['/video/:/transcode/universal/start.m3u8'] = '#EXTM3U\n#EXTINF:4.0,\nsession/abc/base/00000.ts\n';
      final media = conversion();
      expect(utf8.decode((await media.fetch(PlexConversion.playlistName))!.bytes!), '#EXTM3U\n#EXTINF:4.0,\n0.ts\n');
      expect(utf8.decode((await media.fetch('0.ts'))!.bytes!), 'TS');
    });

    test('a segment on another host is not fetched: the token goes to the Plex server only', () async {
      answers['/video/:/transcode/universal/session/abc/base/index.m3u8'] =
          '#EXTM3U\n#EXTINF:4.0,\nhttps://elsewhere.example/00000.ts\n';
      final media = conversion();
      expect(utf8.decode((await media.fetch(PlexConversion.playlistName))!.bytes!), '#EXTM3U\n#EXTINF:4.0,\n0.ts\n');
      expect(await media.fetch('0.ts'), isNull);
      expect(asked.map((uri) => uri.host), everyElement(_base.host));
    });

    test('stopped: the server told once, nothing served after', () async {
      final media = conversion();
      await media.stop();
      await media.stop();
      expect(asked.where((uri) => uri.path.endsWith('/stop')), hasLength(1));
      expect(asked.single.queryParameters, {'session': 'abc'});
      expect(await media.fetch(PlexConversion.playlistName), isNull);
    });
  });
}
