// The server's conversion of a film served by the media bridge (Plex since release 46, Jellyfin and Emby since 49): the
// server makes an HLS stream of the film in codecs the device decodes, and the bridge serves its media playlist and
// its segments under a random id, fetching each of them from the server in Dart with the credentials in a header, as
// the films are read. The token never reaches a player: the server's playlist names its segments by paths under its
// session, the bridge's playlist names them by number, and the app keeps their paths.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:logging/logging.dart';

final _log = Logger('HlsConversion');

/// The first playlist [playlist] names (a line that is no tag), resolved against [at]: the variant of start.m3u8
Uri? firstHlsEntry(String playlist, Uri at) {
  for (final line in const LineSplitter().convert(playlist)) {
    final entry = line.trim();
    if (entry.isNotEmpty && !entry.startsWith('#')) {
      return at.resolve(entry);
    }
  }
  return null;
}

/// [playlist], a media playlist read at [at], with each segment renamed to its number ("0.ts", "1.ts"...) for the
/// bridge, and the server addresses of those numbers, which [known] keeps from the reads before (a playlist read again
/// keeps its numbers). A tag that names another address (#EXT-X-KEY, #EXT-X-MAP, #EXT-X-MEDIA with a URI) is left
/// out, Plex sends none: the playlist the player gets names the bridge's files only, which lets libmpv open it with
/// access-references on (android_mpv.dart).
({String playlist, List<Uri> segments}) renameHlsSegments(String playlist, Uri at, {List<Uri> known = const []}) {
  final segments = [...known];
  final lines = <String>[];
  for (final line in const LineSplitter().convert(playlist)) {
    final entry = line.trim();
    if (entry.startsWith('#') && entry.toUpperCase().contains('URI=')) {
      continue;
    }
    if (entry.isEmpty || entry.startsWith('#')) {
      lines.add(line);
      continue;
    }
    final uri = at.resolve(entry);
    var index = segments.indexOf(uri);
    if (index < 0) {
      index = segments.length;
      segments.add(uri);
    }
    lines.add('$index${_extensionOf(uri.path)}');
  }
  return (playlist: '${lines.join('\n')}\n', segments: segments);
}

String _extensionOf(String path) {
  final name = path.split('/').last;
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(dot).toLowerCase() : '.ts';
}

/// GETs [uri] on the server with the app's headers and [headers], and gives its body; throws when the server does not
/// answer 200, and when [abort] completes first (the request and its body stopped)
typedef HlsFetch = Future<Uint8List> Function(Uri uri, Map<String, String> headers, {Future<void>? abort});

/// The conversion of one film, served by the media bridge under a random id: [playlistName] is the playlist of its
/// stream (the variant of the master playlist at [start], its segments renamed), each segment "N.ts" fetched from the
/// server at [base] when a player asks for it, nothing fetched anywhere else. [stop] ends the conversion on the server
/// through [stopOnServer].
class HlsConversion implements NetworkConversion {
  HlsConversion({
    required this._start,
    required this._base,
    required this._fetch,
    this.headers = const {},
    required this._stopOnServer,
  });

  static const playlistName = 'film.m3u8';

  final Uri _start;
  final Uri _base;
  final HlsFetch _fetch;
  final Future<void> Function() _stopOnServer;

  /// Sent with every request of the conversion, beside the app's own
  final Map<String, String> headers;

  /// The media playlist on the server, once the master playlist named it
  Uri? _variant;
  List<Uri> _segments = const [];
  bool _stopped = false;

  @override
  String get playlist => playlistName;

  /// What the server converts last: the segments a player asks for twice (a seek back) are fetched again. A segment
  /// whose player went away ([abort]: a seek elsewhere) stops at once, so that the server's connection and the link go
  /// to the segment of the new place.
  @override
  Future<GeneratedFile?> fetch(String name, {Future<void>? abort}) async {
    if (_stopped) {
      return null;
    }
    if (name == playlistName) {
      return GeneratedFile(utf8.encode(await _playlist()), 'application/vnd.apple.mpegurl');
    }
    final dot = name.indexOf('.');
    final index = int.tryParse(dot < 0 ? name : name.substring(0, dot));
    if (index == null || index < 0 || index >= _segments.length) {
      return null;
    }
    final segment = _segments[index];
    if (!_onServer(segment)) {
      // The credentials go to the server of the conversion only
      return null;
    }
    final bytes = await _fetch(segment, headers, abort: abort);
    return GeneratedFile(bytes, name.endsWith('.ts') ? 'video/mp2t' : 'application/octet-stream');
  }

  /// The media playlist with its segments renamed, read again at each request: a player reads it again while the
  /// conversion runs
  Future<String> _playlist() async {
    var variant = _variant;
    if (variant == null) {
      final master = utf8.decode(await _fetch(_start, headers), allowMalformed: true);
      if (!master.contains('#EXT-X-STREAM-INF')) {
        // Already the media playlist
        final renamed = renameHlsSegments(master, _start, known: _segments);
        _segments = renamed.segments;
        return renamed.playlist;
      }
      variant = _variant = firstHlsEntry(master, _start);
      if (variant == null || !_onServer(variant)) {
        throw const NetworkFileSystemException('The server sent no playlist of its own');
      }
    }
    final text = utf8.decode(await _fetch(variant, headers), allowMalformed: true);
    final renamed = renameHlsSegments(text, variant, known: _segments);
    _segments = renamed.segments;
    return renamed.playlist;
  }

  /// Whether [uri] is on the server of the conversion: nothing else is asked with its credentials
  bool _onServer(Uri uri) => uri.scheme == _base.scheme && uri.host == _base.host && uri.port == _base.port;

  /// Ends the conversion on the server; the bridge serves nothing more of it
  @override
  Future<void> stop() async {
    if (_stopped) {
      return;
    }
    _stopped = true;
    try {
      await _stopOnServer();
    } catch (error) {
      _log.fine('The conversion did not stop on the server: ${error.runtimeType}');
    }
  }

  @override
  GeneratedFile? file(String name) => null;
}
