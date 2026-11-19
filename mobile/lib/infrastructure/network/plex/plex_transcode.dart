// The server's conversion of a Plex film (the second fallback of release 46, after libmpv): the Plex transcoder makes
// an HLS stream of the film in codecs the device decodes, video copied when the device decodes it, audio converted
// (DTS, TrueHD, WMA to E-AC-3 5.1 or AAC), the video converted to H.264 only when it must be (DivX 3, WMV, VC-1).
//
// How it was found (the test server, Plex Media Server 1.42.1, read only, 11 November 2026, store/m2/release-46/lots/
// feat-plex-mpv-46.md): the decision call /video/:/transcode/universal/decision with directPlay=0, directStream=1 and
// protocol=hls, sent with the app's own headers (X-Plex-Platform "Android" on Android), answers transcodeDecisionCode
// 1001 "Direct play not available; Conversion OK." for a DTS, a TrueHD, a DivX 3 and a WMA film: video copied where it
// can be, audio to AAC stereo. With the client profile extra below the audio goes to E-AC-3 in 5.1. The platform
// "Generic", or the profile name "Generic", gets 4005 "No conversion profile found for protocol hls"; "linux" (the app
// on Linux) got 400 in the captures of 11 November. HEVC is converted to H.264 1080p whatever the profile extra says
// (an HLS stream in MPEG-TS): only the audio is copied for a HEVC film with TrueHD.
//
// The token never reaches a player: the app's media bridge serves the playlist and its segments under a random id
// (PlexConversion, generated media), and fetches each of them from the server in Dart with the token in its header,
// as it reads the films. The playlist of the server names its segments by paths under its session; the bridge's
// playlist names them by number, and the app keeps their paths.

import 'dart:math';

import 'package:immich_mobile/infrastructure/network/hls_conversion.dart';

export 'package:immich_mobile/infrastructure/network/hls_conversion.dart' show firstHlsEntry, renameHlsSegments;

/// Where the transcoder answers on the server
const plexTranscodePath = '/video/:/transcode/universal';

/// What the app asks the server to convert, and how
class PlexTranscodeRequest {
  const PlexTranscodeRequest({
    required this.ratingKey,
    required this.session,
    this.mediaIndex = 0,
    this.partIndex = 0,
    this.offset = Duration.zero,
    this.audioCodecs = const ['eac3', 'ac3'],
    this.maxVideoBitrateKbps = defaultMaxVideoBitrateKbps,
    this.videoResolution = '1920x1080',
  });

  /// The film (/library/metadata/{ratingKey})
  final String ratingKey;

  /// The id of this conversion on the server, random per play: the stop names it
  final String session;
  final int mediaIndex;
  final int partIndex;

  /// Where the conversion starts in the film
  final Duration offset;

  /// The audio codecs the converted stream may carry besides AAC, in the order the server should prefer them: those
  /// the device decodes (E-AC-3 and AC-3 on the Quest)
  final List<String> audioCodecs;

  /// The highest video bit rate of the conversion, in kbit/s: a film above it has its video converted down to it (a
  /// link slower than the file, release 47)
  final int maxVideoBitrateKbps;
  final String videoResolution;

  static const defaultMaxVideoBitrateKbps = 20000;

  /// The client profile extra: the device takes these audio codecs in 5.1
  String get profileExtra => [
    if (audioCodecs.isNotEmpty)
      'append-transcode-target-audio-codec(type=videoProfile&context=streaming&protocol=hls&audioCodec=${audioCodecs.join(',')})',
    for (final codec in audioCodecs)
      'add-limitation(scope=videoAudioCodec&scopeName=$codec&type=upperBound&name=audio.channels&value=6)',
  ].join('+');

  /// The query of the decision call and of start.m3u8: no token, no credential
  Map<String, String> get query => {
    'path': '/library/metadata/$ratingKey',
    'mediaIndex': '$mediaIndex',
    'partIndex': '$partIndex',
    'protocol': 'hls',
    'fastSeek': '1',
    'directPlay': '0',
    'directStream': '1',
    'directStreamAudio': '1',
    'subtitles': 'auto',
    'subtitleSize': '100',
    'audioBoost': '100',
    'location': 'lan',
    'hasMDE': '1',
    'copyts': '1',
    'mediaBufferSize': '102400',
    'maxVideoBitrate': '$maxVideoBitrateKbps',
    'videoResolution': videoResolution,
    'offset': (offset.inMilliseconds / 1000).toStringAsFixed(3),
    'session': session,
    'X-Plex-Session-Identifier': session,
  };

  /// The headers of the decision call and of every request of the conversion, beside the app's own (PlexClient)
  Map<String, String> get headers => {'x-plex-client-profile-extra': profileExtra};

  Uri decisionUri(Uri base) => base.resolve('$plexTranscodePath/decision').replace(queryParameters: query);

  Uri startUri(Uri base) => base.resolve('$plexTranscodePath/start.m3u8').replace(queryParameters: query);

  Uri stopUri(Uri base) => base.resolve('$plexTranscodePath/stop').replace(queryParameters: {'session': session});
}

/// A random session id for [PlexTranscodeRequest.session]
String newPlexTranscodeSession([Random? random]) {
  final source = random ?? Random.secure();
  return List.generate(16, (_) => source.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// One stream of the decision: what the server does with it
typedef PlexTranscodeStream = ({int? type, String? codec, String? decision});

/// What the server answers to the decision call
class PlexTranscodeDecision {
  const PlexTranscodeDecision({
    this.generalCode,
    this.generalText,
    this.transcodeCode,
    this.transcodeText,
    this.streams = const [],
  });

  final int? generalCode;
  final String? generalText;
  final int? transcodeCode;
  final String? transcodeText;
  final List<PlexTranscodeStream> streams;

  /// Whether the server will convert: 1000 to 1999 ("Direct play OK", "Conversion OK"), as Plex's own apps read it
  bool get canConvert {
    final code = transcodeCode ?? generalCode;
    return code != null && code >= 1000 && code < 2000;
  }

  /// The line of the log: the codes and what happens to each stream, never a title
  String get logLine =>
      'Plex conversion: ${transcodeCode ?? generalCode} ${transcodeText ?? generalText ?? ''}'
      '${streams.isEmpty ? '' : ' (${streams.map((s) => '${s.codec} ${s.decision}').join(', ')})'}';
}

/// The decision from the JSON of the server
PlexTranscodeDecision parsePlexTranscodeDecision(Object? json) {
  final container = json is Map ? json['MediaContainer'] : null;
  if (container is! Map) {
    return const PlexTranscodeDecision();
  }
  int? number(Object? value) => value is int ? value : int.tryParse('${value ?? ''}');
  String? text(Object? value) => value is String && value.isNotEmpty ? value : null;
  final streams = <PlexTranscodeStream>[];
  final metadata = container['Metadata'];
  if (metadata is List) {
    for (final item in metadata.whereType<Map>()) {
      final medias = item['Media'];
      if (medias is! List) {
        continue;
      }
      for (final media in medias.whereType<Map>()) {
        final parts = media['Part'];
        if (parts is! List) {
          continue;
        }
        for (final part in parts.whereType<Map>()) {
          final list = part['Stream'];
          if (list is! List) {
            continue;
          }
          for (final stream in list.whereType<Map>()) {
            streams.add((
              type: number(stream['streamType']),
              codec: text(stream['codec']),
              decision: text(stream['decision']),
            ));
          }
        }
      }
    }
  }
  return PlexTranscodeDecision(
    generalCode: number(container['generalDecisionCode']) ?? number(container['mdeDecisionCode']),
    generalText: text(container['generalDecisionText']) ?? text(container['mdeDecisionText']),
    transcodeCode: number(container['transcodeDecisionCode']),
    transcodeText: text(container['transcodeDecisionText']),
    streams: streams,
  );
}

/// GETs [uri] on the server with the app's headers and [headers], and gives its body; throws when the server does not
/// answer 200, and when [abort] completes first (the request and its body stopped)
typedef PlexConversionFetch = HlsFetch;

/// The conversion of one Plex film (see HlsConversion): start.m3u8 of [request] with its headers, stopped through the
/// transcoder's stop with its session
class PlexConversion extends HlsConversion {
  // The start and the stop are made of the base and the fetch: no super parameters
  // ignore: use_super_parameters
  PlexConversion({required this.request, required Uri base, required PlexConversionFetch fetch})
    : super(
        start: request.startUri(base),
        base: base,
        headers: request.headers,
        fetch: fetch,
        stopOnServer: () => fetch(request.stopUri(base), const {}),
      );

  static const playlistName = HlsConversion.playlistName;

  final PlexTranscodeRequest request;
}
