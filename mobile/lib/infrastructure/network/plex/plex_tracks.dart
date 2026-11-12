// The audio and subtitle tracks of a Plex film for the players of the app (request 3 of 10 November 2026): the subtitle
// files Plex knows beside the film (a .srt next to it on the disk, or one Plex downloaded), which a player never sees
// in the file, served by the media bridge from memory in the format of their text; the names Plex gives every track
// ("Français (AC3 5.1)", "English (SRT External)") in the menus; the track Plex has for the account, chosen first; and
// the choice made in a menu written back to Plex (PUT /library/parts/{id}), so that the Plex apps start with it too.
//
// A player knows the tracks inside the file by its own indexes. They are matched to Plex's streams by their order
// among the tracks of their kind, and only when the counts and the languages agree: a track is never given the name
// of another one. The side files are told by their id (videoSidecarIdPrefix and the stream id).

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/video_track_naming.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_client.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_file_system.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_films.dart';
import 'package:logging/logging.dart';
import 'package:native_video_player/native_video_player.dart';

final _log = Logger('PlexFilmTracks');

/// What the server side of [PlexFilmTracks] does: the requests of a PlexFileSystem, replaced by the tests
abstract interface class PlexTrackServer {
  Future<Uint8List?> subtitleFile(PlexStream stream);
  Future<void> selectStreams(int partId, {int? audioStreamId, int? subtitleStreamId});
}

/// [PlexTrackServer] over a [PlexFileSystem]
class PlexFileSystemTracks implements PlexTrackServer {
  const PlexFileSystemTracks(this.fileSystem);

  final PlexFileSystem fileSystem;

  @override
  Future<Uint8List?> subtitleFile(PlexStream stream) => fileSystem.subtitleFile(stream);

  @override
  Future<void> selectStreams(int partId, {int? audioStreamId, int? subtitleStreamId}) =>
      fileSystem.selectStreams(partId, audioStreamId: audioStreamId, subtitleStreamId: subtitleStreamId);
}

/// The text formats of subtitle files the players read (Media3's parsers on Android, libmpv on the computers): its MIME
/// type and the extension of its name on the bridge
enum SubtitleTextFormat {
  subRip('application/x-subrip', 'srt'),
  webVtt('text/vtt', 'vtt'),
  ssa('text/x-ssa', 'ass');

  const SubtitleTextFormat(this.mimeType, this.extension);

  final String mimeType;
  final String extension;
}

final _subRipStart = RegExp(r'^\d+[ \t]*\r?\n[ \t]*\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}[ \t]*-->');

/// The format of the subtitle text [bytes] (UTF-8, a byte order mark allowed), read from its first lines: a Plex
/// Media Server names a side file's format from its extension, and a .vtt file of a real library held ASS text, another
/// one SubRip text. Text it does not recognise keeps the format of [codec], Plex's; null for none a player reads (SAMI,
/// for instance) and for an empty file.
SubtitleTextFormat? subtitleTextFormatOf(Uint8List bytes, {String? codec}) {
  if (bytes.isEmpty) {
    return null;
  }
  final head = utf8.decode(bytes.length > 1024 ? bytes.sublist(0, 1024) : bytes, allowMalformed: true);
  final text = (head.startsWith('\uFEFF') ? head.substring(1) : head).trimLeft();
  if (text.startsWith('WEBVTT')) {
    return SubtitleTextFormat.webVtt;
  }
  if (text.toLowerCase().startsWith('[script info]')) {
    return SubtitleTextFormat.ssa;
  }
  if (_subRipStart.hasMatch(text)) {
    return SubtitleTextFormat.subRip;
  }
  return switch (codec?.toLowerCase()) {
    'srt' || 'subrip' => SubtitleTextFormat.subRip,
    'vtt' || 'webvtt' => SubtitleTextFormat.webVtt,
    'ass' || 'ssa' => SubtitleTextFormat.ssa,
    _ => null,
  };
}

/// The tracks of one file of a Plex film while its page plays it; [dispose] takes its subtitle files off the bridge
class PlexFilmTracks implements VideoTrackNaming {
  PlexFilmTracks._(this._server, this.part, this._bridge, this._mediaId, this.subtitles);

  /// Reads the subtitle files of [part] that a player can draw (text ones, [maxSidecars] at most, each within
  /// [timeout]: a file that does not come is left out, the film plays without it), and serves them on [bridge]
  static Future<PlexFilmTracks> load(
    PlexTrackServer server,
    PlexFilmPart part,
    MediaBridge bridge, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final sidecars = part.streams.where((stream) => stream.isSidecar && stream.isTextSubtitle).take(maxSidecars);
    final read = await Future.wait([
      for (final stream in sidecars)
        server
            .subtitleFile(stream)
            .timeout(timeout)
            .then<(PlexStream, Uint8List?)>((bytes) => (stream, bytes))
            .catchError((Object error) {
              _log.info('A subtitle file of the film could not be read: ${plexErrorKind(error)}');
              return (stream, null);
            }),
    ]);
    final files = <String, GeneratedFile>{};
    final subtitles = <(String, VideoSubtitle)>[];
    final mediaId = _randomId();
    for (final (stream, bytes) in read) {
      if (bytes == null || bytes.isEmpty) {
        continue;
      }
      final format = subtitleTextFormatOf(bytes, codec: stream.codec);
      if (format == null) {
        _log.info('A subtitle file of the film is in no format the players read (${stream.codec}): left out');
        continue;
      }
      final name = '${stream.id}.${format.extension}';
      files[name] = GeneratedFile(bytes, '${format.mimeType}; charset=utf-8');
      subtitles.add((
        name,
        VideoSubtitle(
          uri: '',
          mimeType: format.mimeType,
          language: stream.languageTag ?? stream.languageCode,
          label: stream.label,
          id: '$videoSidecarIdPrefix${stream.id}',
        ),
      ));
    }
    final List<VideoSubtitle> served;
    if (files.isEmpty) {
      served = const [];
    } else {
      bridge.registerGenerated(mediaId, _SubtitleFiles(files));
      served = [
        for (final (name, subtitle) in subtitles)
          VideoSubtitle(
            uri: bridge.urlFor(mediaId, name).toString(),
            mimeType: subtitle.mimeType,
            language: subtitle.language,
            label: subtitle.label,
            id: subtitle.id,
          ),
      ];
    }
    return PlexFilmTracks._(server, part, files.isEmpty ? null : bridge, mediaId, served);
  }

  /// Subtitle files given to a player at most: a film with dozens of downloaded languages keeps its first ones
  static const maxSidecars = 12;

  final PlexTrackServer _server;
  final PlexFilmPart part;
  final MediaBridge? _bridge;
  final String _mediaId;

  /// The subtitle files beside the film, as the players take them
  final List<VideoSubtitle> subtitles;

  bool _disposed = false;

  /// The streams of [kind] inside the file, in the order of the file (Plex's index)
  List<PlexStream> _embedded(VideoTrackKind kind) {
    final type = kind == VideoTrackKind.audio ? PlexStreamType.audio : PlexStreamType.subtitle;
    return part.streams.where((stream) => stream.type == type && !stream.isSidecar).toList()
      ..sort((a, b) => (a.index ?? 0).compareTo(b.index ?? 0));
  }

  /// The stream of Plex behind [track]: a side file by its id; a track inside the file by its place among those of its
  /// kind, when its language agrees with Plex's (a player that lists fewer tracks than Plex gets no name)
  PlexStream? streamOf(VideoTrackRef track) {
    final sidecar = track.sidecarId;
    if (sidecar != null) {
      final id = int.tryParse(sidecar.substring(videoSidecarIdPrefix.length));
      return part.streams.where((stream) => stream.id == id && stream.isSidecar).firstOrNull;
    }
    final ordinal = track.ordinal;
    final streams = _embedded(track.kind);
    if (ordinal == null || ordinal < 0 || ordinal >= streams.length) {
      return null;
    }
    final stream = streams[ordinal];
    return plexLanguagesAgree(track.language, stream) ? stream : null;
  }

  @override
  String? labelOf(VideoTrackRef track) => streamOf(track)?.label;

  @override
  void picked(VideoTrackKind kind, VideoTrackRef? track) {
    final int? id;
    if (track == null) {
      // Subtitles off; audio is never off
      id = kind == VideoTrackKind.subtitle ? 0 : null;
    } else {
      id = streamOf(track)?.id;
    }
    if (id == null || _disposed) {
      return;
    }
    unawaited(
      _server
          .selectStreams(
            part.id,
            audioStreamId: kind == VideoTrackKind.audio ? id : null,
            subtitleStreamId: kind == VideoTrackKind.subtitle ? id : null,
          )
          .catchError(
            (Object error) => _log.info('The track picked could not be written back to Plex: ${plexErrorKind(error)}'),
          ),
    );
  }

  /// The audio track Plex has for the account, null when it marks none
  PlexStream? get selectedAudio =>
      part.streams.where((stream) => stream.type == PlexStreamType.audio && stream.selected).firstOrNull;

  /// The subtitles Plex has for the account (picked in a Plex app, or forced by the server), to start with: a side
  /// file by its id, a track inside the file by its place; null when Plex has none selected
  VideoTrackRef? get selectedSubtitle {
    final stream = part.streams
        .where((stream) => stream.type == PlexStreamType.subtitle && stream.selected)
        .firstOrNull;
    if (stream == null) {
      return null;
    }
    if (stream.isSidecar) {
      final id = '$videoSidecarIdPrefix${stream.id}';
      return subtitles.any((subtitle) => subtitle.id == id)
          ? VideoTrackRef(kind: VideoTrackKind.subtitle, sidecarId: id)
          : null;
    }
    final ordinal = _embedded(VideoTrackKind.subtitle).indexOf(stream);
    return ordinal < 0 ? null : VideoTrackRef(kind: VideoTrackKind.subtitle, ordinal: ordinal);
  }

  /// Takes the subtitle files off the bridge
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _bridge?.unregisterGenerated(_mediaId);
  }

  static String _randomId() {
    final random = Random.secure();
    return 'plexsub${List.generate(12, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  }
}

/// The subtitle files of a film, from memory
class _SubtitleFiles implements GeneratedMedia {
  const _SubtitleFiles(this._files);

  final Map<String, GeneratedFile> _files;

  @override
  GeneratedFile? file(String name) => _files[name];
}

/// Whether [language], the code a player reports for a track ("fr", "fre", "fra", "und", null), may be the language
/// of [stream]: a track without a language, or a stream without one, agrees with any
bool plexLanguagesAgree(String? language, PlexStream stream) {
  final code = language?.toLowerCase().split(RegExp('[-_]')).first;
  if (code == null || code.isEmpty || code == 'und' || code == 'mul' || code == 'zxx') {
    return true;
  }
  final tag = stream.languageTag?.toLowerCase().split(RegExp('[-_]')).first;
  final three = stream.languageCode?.toLowerCase();
  if (tag == null && three == null) {
    return true;
  }
  final asTwo = code.length == 3 ? (_twoLetterOf[code] ?? (code == three ? tag : null)) : code;
  if (asTwo != null && tag != null) {
    return asTwo == tag;
  }
  return code == three || _twoLetterOf[code] == _twoLetterOf[three];
}

/// The two letter codes of the three letter ones whose two forms (bibliographic and terminology) differ, and of the
/// common ones a player may report as such
const _twoLetterOf = {
  'eng': 'en',
  'fre': 'fr',
  'fra': 'fr',
  'ger': 'de',
  'deu': 'de',
  'spa': 'es',
  'ita': 'it',
  'por': 'pt',
  'jpn': 'ja',
  'kor': 'ko',
  'chi': 'zh',
  'zho': 'zh',
  'dut': 'nl',
  'nld': 'nl',
  'rus': 'ru',
  'pol': 'pl',
  'swe': 'sv',
  'nor': 'no',
  'nob': 'nb',
  'dan': 'da',
  'fin': 'fi',
  'cze': 'cs',
  'ces': 'cs',
  'gre': 'el',
  'ell': 'el',
  'per': 'fa',
  'fas': 'fa',
  'rum': 'ro',
  'ron': 'ro',
  'slo': 'sk',
  'slk': 'sk',
  'alb': 'sq',
  'sqi': 'sq',
  'arm': 'hy',
  'hye': 'hy',
  'baq': 'eu',
  'eus': 'eu',
  'geo': 'ka',
  'kat': 'ka',
  'ice': 'is',
  'isl': 'is',
  'mac': 'mk',
  'mkd': 'mk',
  'may': 'ms',
  'msa': 'ms',
  'wel': 'cy',
  'cym': 'cy',
  'tur': 'tr',
  'ara': 'ar',
  'heb': 'he',
  'hin': 'hi',
  'hun': 'hu',
  'ukr': 'uk',
  'tha': 'th',
  'vie': 'vi',
  'cat': 'ca',
};
