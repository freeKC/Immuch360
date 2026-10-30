// The original of a server video that the in-app player downloads before it plays (lot fix-decoder-limit): the original
// the device decodes, chosen over a copy of the server it cannot decode (see chooseVideoSource), from a server that
// ignores Range when its MP4 index is at the end of the file. Streamed, Media3 would read the whole file before its first
// frame with nothing to show, and the stall check of the player would give up after 20 s; downloaded, the progress
// shows and the file plays. The immersive viewer of the Meta Quest does the same on its side (VideoStartRule.kt).

import 'dart:async';
import 'dart:io';

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

/// Downloads of server originals for the in-app player, one file kept at a time in [directory]
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

  Uri? _urlOf(String videoId) {
    final endpoint = _serverEndpoint();
    return endpoint == null ? null : Uri.parse('$endpoint/assets/$videoId/original');
  }

  /// Whether the server streams the original of [videoId]: it answers Range (the player then reaches the index
  /// wherever it lies), or the index is at the head of the file ([headRead]: the probe of its head found what it
  /// declares). True when the question fails: the player streams it as before.
  Future<bool> streams(String videoId, {required bool headRead}) async {
    final url = _urlOf(videoId);
    if (url == null) {
      return true;
    }
    try {
      final request = http.Request('GET', url)
        ..headers.addAll(_headers())
        ..headers['range'] = 'bytes=1-1';
      final response = await _client().send(request).timeout(const Duration(seconds: 5));
      await response.stream.listen(null).cancel();
      final ranges = response.statusCode == 206;
      _log.info('$videoId: the server ${ranges ? 'answers' : 'ignores'} Range, its index read at the head: $headRead');
      return ranges || headRead;
    } catch (error) {
      _log.info('Could not tell whether the original of $videoId streams: $error');
      return true;
    }
  }

  /// Downloads the original of [videoId], [onProgress] told each new percent, and gives the file; the one already
  /// there when it is whole. Null when there is no server, when the server tells no size, when the download fails or
  /// once [isWanted] says no (the video is no longer on screen): no partial file is left, and the player streams the
  /// original instead. The original of the video before goes: one file at a time.
  Future<File?> download(String videoId, {void Function(int percent)? onProgress, bool Function()? isWanted}) async {
    final url = _urlOf(videoId);
    if (url == null) {
      return null;
    }
    final dir = await _directory();
    await dir.create(recursive: true);
    final target = File(p.join(dir.path, 'original-$videoId.mp4'));
    final partial = File('${target.path}.part');
    for (final entry in dir.listSync()) {
      if (entry is File && entry.path != target.path) {
        entry.deleteSync();
      }
    }
    IOSink? sink;
    try {
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
      return target;
    } catch (error) {
      _log.warning('The original of $videoId could not be downloaded, it streams instead: $error');
      await sink?.close();
      _delete(partial);
      return null;
    }
  }

  /// Removes the original downloaded, if any: the player that needed it is gone
  Future<void> clear() async {
    try {
      final dir = await _directory();
      if (dir.existsSync()) {
        for (final entry in dir.listSync()) {
          if (entry is File) {
            entry.deleteSync();
          }
        }
      }
    } catch (error) {
      _log.info('Could not remove the downloaded original: $error');
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
