// The original of a server video that the in-app player downloads before it plays (lot fix-decoder-limit): an original
// the player chose (the one the device decodes over a copy of the server it cannot decode, see chooseVideoSource, or
// the one the settings or the details ask for) from a server that ignores Range when its MP4 index is at the end of the
// file. Streamed, Media3 would read the whole file before its first frame with nothing to show, and the stall check of
// the player would give up after 20 s; downloaded, the progress shows and the file plays. The immersive viewer of the
// Meta Quest does the same on its side (VideoStartRule.kt).

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _log = Logger('OriginalDownload');

/// Whether the MP4 whose first [length] bytes are [head] has its index (the moov box) before its media (the mdat box):
/// true when the moov comes first, false when the mdat does, null when neither shows in those bytes (a file of another
/// kind, a box larger than the head). The same walk of the top level boxes as ImmersiveMedia.mp4MoovBeforeMdat.
bool? mp4MoovBeforeMdat(Uint8List head, [int? length]) {
  final end = math.min(length ?? head.length, head.length);
  final data = ByteData.sublistView(head);
  var offset = 0;
  while (offset + 8 <= end) {
    var size = data.getUint32(offset);
    var header = 8;
    if (size == 1) {
      if (offset + 16 > end) {
        return null;
      }
      size = data.getUint32(offset + 8) * 0x100000000 + data.getUint32(offset + 12);
      header = 16;
    }
    switch (String.fromCharCodes(head, offset + 4, offset + 8)) {
      case 'moov':
        return true;
      case 'mdat':
        return false;
    }
    if (size < header) {
      return null;
    }
    offset += size;
  }
  return null;
}

/// Downloads of server originals for the in-app player, in [directory]: the file of the video on screen, and the ones
/// the pages around it still have loaded ([hold]), no other
class OriginalDownloads {
  OriginalDownloads({
    required this._client,
    required this._serverEndpoint,
    required this._headers,
    required this._directory,
  });

  final http.Client Function() _client;
  final String? Function() _serverEndpoint;
  final Map<String, String> Function() _headers;
  final Future<Directory> Function() _directory;

  /// The bytes of the head of an original read to tell where its index lies, as the immersive viewer reads them
  static const headBytes = 65536;

  // Whether the server streams the original of a video, by video id, once known
  final _streams = <String, bool>{};
  // The videos whose downloaded file a page has loaded (see hold), and the downloads under way
  final _held = <String>{};
  final _running = <String>{};

  Uri? _urlOf(String videoId) {
    final endpoint = _serverEndpoint();
    return endpoint == null ? null : Uri.parse('$endpoint/assets/$videoId/original');
  }

  File _fileOf(Directory dir, String videoId) => File(p.join(dir.path, 'original-$videoId.mp4'));

  /// Whether the server streams the original of [videoId]: it answers Range (the player then reaches the index
  /// wherever it lies), or the index (the moov box) comes before the media in the first [headBytes] of the file (see
  /// [mp4MoovBeforeMdat]), which a server that ignores Range still sends first. One request per video while the app
  /// runs. True when the question fails or the head tells nothing: the player streams it as before.
  Future<bool> streams(String videoId) async {
    final known = _streams[videoId];
    if (known != null) {
      return known;
    }
    final url = _urlOf(videoId);
    if (url == null) {
      return true;
    }
    try {
      final request = http.Request('GET', url)
        ..headers.addAll(_headers())
        ..headers['range'] = 'bytes=0-${headBytes - 1}';
      final response = await _client().send(request).timeout(const Duration(seconds: 5));
      final ranges = response.statusCode == 206;
      if (response.statusCode != 200 && !ranges) {
        await response.stream.listen(null).cancel();
        throw http.ClientException('HTTP ${response.statusCode}', url);
      }
      final head = BytesBuilder(copy: false);
      // Leaving the loop cancels the transfer: a server without Range sends the whole file
      await for (final bytes in response.stream.timeout(const Duration(seconds: 5))) {
        head.add(bytes);
        if (head.length >= headBytes) {
          break;
        }
      }
      final moovFirst = mp4MoovBeforeMdat(head.takeBytes(), headBytes);
      _log.info('$videoId: the server ${ranges ? 'answers' : 'ignores'} Range, its index first: $moovFirst');
      return _streams[videoId] = ranges || moovFirst != false;
    } catch (error) {
      _log.info('Could not tell whether the original of $videoId streams: $error');
      return true;
    }
  }

  /// Downloads the original of [videoId], [onProgress] told each new percent, and gives the file; the one already
  /// there when it is whole. Null when there is no server, when the server tells no size, when the download fails or
  /// once [isWanted] says no (the video is no longer on screen, or plays in another player): no partial file is left,
  /// and the player streams the original instead, or downloads it again when it is wanted again. Once it is whole, the
  /// files of the other videos go, but those a page still has loaded ([hold]).
  Future<File?> download(String videoId, {void Function(int percent)? onProgress, bool Function()? isWanted}) async {
    final url = _urlOf(videoId);
    if (url == null) {
      return null;
    }
    File? partial;
    IOSink? sink;
    _running.add(videoId);
    try {
      final dir = await _directory();
      await dir.create(recursive: true);
      final target = _fileOf(dir, videoId);
      partial = File('${target.path}.part');
      final request = http.Request('GET', url)..headers.addAll(_headers());
      final response = await _client().send(request);
      final total = response.contentLength ?? 0;
      if (response.statusCode != 200 || total <= 0) {
        await response.stream.listen(null).cancel();
        _log.info('The original of $videoId was not downloaded: HTTP ${response.statusCode}, $total bytes');
        return null;
      }
      if (target.existsSync() && target.lengthSync() == total) {
        await response.stream.listen(null).cancel();
        onProgress?.call(100);
        return target;
      }
      final out = partial.openWrite();
      sink = out;
      var done = 0;
      var shown = -1;
      await for (final chunk in response.stream) {
        if (isWanted != null && !isWanted()) {
          _log.info('The download of the original of $videoId stopped: no longer wanted');
          await out.close();
          sink = null;
          _delete(partial);
          return null;
        }
        out.add(chunk);
        done += chunk.length;
        final percent = done >= total ? 100 : (done * 100 ~/ total).clamp(0, 99);
        if (percent != shown) {
          shown = percent;
          onProgress?.call(percent);
        }
      }
      await out.close();
      sink = null;
      if (done != total) {
        throw HttpException('the download ended at $done of $total bytes', uri: url);
      }
      partial.renameSync(target.path);
      _log.info('The original of $videoId downloaded: $total bytes');
      _prune(dir, keep: videoId);
      return target;
    } catch (error) {
      _log.warning('The original of $videoId could not be downloaded, it streams instead: $error');
      await sink?.close();
      if (partial != null) {
        _delete(partial);
      }
      return null;
    } finally {
      _running.remove(videoId);
    }
  }

  /// A page loaded the downloaded original of [videoId] in its player: the file stays until it [release]s it
  void hold(String videoId) => _held.add(videoId);

  /// The page that loaded the original of [videoId] is gone: its file goes, the others stay
  Future<void> release(String videoId) async {
    _held.remove(videoId);
    try {
      _delete(_fileOf(await _directory(), videoId));
    } catch (error) {
      _log.info('Could not remove the downloaded original of $videoId: $error');
    }
  }

  // Removes the files of [dir] but the original of [keep], the ones held and the downloads under way: what an earlier
  // page or run of the app left
  void _prune(Directory dir, {required String keep}) {
    final kept = {
      for (final id in {keep, ..._held, ..._running}) ...[_fileOf(dir, id).path, '${_fileOf(dir, id).path}.part'],
    };
    for (final entry in dir.listSync()) {
      if (entry is File && !kept.contains(entry.path)) {
        _delete(entry);
      }
    }
  }

  static void _delete(File file) {
    try {
      if (file.existsSync()) {
        file.deleteSync();
      }
    } catch (_) {}
  }
}

/// The downloads of originals of the in-app player, in the cache of the app
final originalDownloadsProvider = Provider<OriginalDownloads>(
  (ref) => OriginalDownloads(
    client: () => NetworkRepository.client,
    serverEndpoint: () => Store.tryGet(StoreKey.serverEndpoint),
    headers: ApiService.getRequestHeaders,
    directory: () async => Directory(p.join((await getTemporaryDirectory()).path, 'video_original')),
  ),
);
