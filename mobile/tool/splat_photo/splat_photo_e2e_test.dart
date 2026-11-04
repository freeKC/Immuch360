// The splat photos end to end against a compat Immich of ai1 (plan of 3 November 2026, section 10.2, lots L2, L3 and
// L6), with the app's own classes: the save job (its drawn poster, the checks of "already there", bulk-upload-check,
// the upload with its checksum header and its metadata item, the album), then the head read and the scene taken out
// of the original, directly and through a proxy that drops Range. Never FreeKC's server: the URL must be one of ai1.
// The assets and the album made are deleted at the end.
//
//   SPLAT_E2E_URL=http://192.168.4.134:2283 SPLAT_E2E_KEY=... SPLAT_E2E_PROXY=http://192.168.4.134:2285 \
//   SPLAT_E2E_SCENE=room.spz SPLAT_E2E_OUT=result.json flutter test tool/splat_photo/splat_photo_e2e_test.dart
//
// SPLAT_E2E_CARRIER=path keeps a copy of the splat photo as the server holds it; SPLAT_E2E_KEEP=1 leaves the asset
// and its album on the server for the web check (their ids in the result), to delete afterwards.
//
// The key is read from the environment only, never printed nor written.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/splat/splat_photo_xmp.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_photo_probe.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_poster_draw.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_save_job.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_tail_fetch.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';

final _env = Platform.environment;

/// A compat server through its REST API and an API key, as the app's adapter reaches it through its API client
class _HttpServer implements SplatSaveServer {
  _HttpServer(this.base, this.key);

  final String base;
  final String key;
  final client = http.Client();
  int bodyBytesSent = 0;

  /// The upload requests made: a save that finds its scene there already makes none
  int uploadRequests = 0;

  @override
  String get url => '$base/api';

  Map<String, String> get _headers => {'x-api-key': key, 'Accept': 'application/json'};

  Future<Object?> _json(String method, String path, [Object? body]) async {
    final request = http.Request(method, Uri.parse('$url$path'))..headers.addAll(_headers);
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final response = await http.Response.fromStream(await client.send(request));
    if (response.statusCode == 404 || response.statusCode == 400 && method == 'GET') {
      return null;
    }
    if (response.statusCode >= 300) {
      throw http.ClientException('$method $path: ${response.statusCode} ${response.body}');
    }
    return response.body.isEmpty ? null : jsonDecode(response.body);
  }

  @override
  Future<(int, int, int)?> version() async {
    final json = await _json('GET', '/server/version') as Map?;
    return json == null ? null : (json['major'] as int, json['minor'] as int, json['patch'] as int);
  }

  SplatServerAsset _asset(Map json) => SplatServerAsset(
    id: json['id'] as String,
    originalFileName: json['originalFileName'] as String,
    isTrashed: json['isTrashed'] == true,
    createdAt: DateTime.tryParse('${json['createdAt']}'),
  );

  @override
  Future<SplatServerAsset?> asset(String id) async {
    final json = await _json('GET', '/assets/$id') as Map?;
    return json == null ? null : _asset(json);
  }

  @override
  Future<List<SplatServerAsset>> searchByName(String name, {int size = 50}) async {
    final json =
        (await _json('POST', '/search/metadata', {
              'originalFileName': name,
              'size': size,
              'withDeleted': true,
              'order': 'desc',
            }))!
            as Map;
    return [for (final item in ((json['assets'] as Map)['items'] as List)) _asset(item as Map)];
  }

  @override
  Future<Uint8List?> head(String assetId, int length, {bool Function()? cancelled}) async {
    final request = http.Request('GET', splatPhotoOriginalUri(url, assetId))
      ..headers.addAll(_headers)
      ..headers['range'] = 'bytes=0-${length - 1}';
    final response = await client.send(request);
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      builder.add(chunk);
      if (builder.length >= length) {
        break;
      }
    }
    final bytes = builder.takeBytes();
    return bytes.length > length ? Uint8List.sublistView(bytes, 0, length) : bytes;
  }

  @override
  Future<SplatBulkAnswer> bulkCheck(String id, String sha1) async {
    final json =
        (await _json('POST', '/assets/bulk-upload-check', {
              'assets': [
                {'id': id, 'checksum': sha1},
              ],
            }))!
            as Map;
    final result = (json['results'] as List).cast<Map>().firstWhere((result) => result['id'] == id);
    return SplatBulkAnswer(
      accept: result['action'] == 'accept',
      assetId: result['assetId'] as String?,
      isTrashed: result['isTrashed'] == true,
    );
  }

  @override
  Future<UploadResult> upload(
    UploadSource source, {
    Completer<void>? cancel,
    void Function(int, int)? onProgress,
  }) async {
    uploadRequests++;
    final request = http.MultipartRequest('POST', Uri.parse('$url/assets'))
      ..headers.addAll(_headers)
      ..headers.addAll(source.headers)
      ..fields.addAll({
        'deviceAssetId': source.deviceAssetId,
        'deviceId': 'splat-photo-e2e',
        'fileCreatedAt': source.createdAt.toUtc().toIso8601String(),
        'fileModifiedAt': source.modifiedAt.toUtc().toIso8601String(),
        'isFavorite': 'false',
        'duration': '0',
        if (source.metadataJson != null) 'metadata': source.metadataJson!,
      })
      ..files.add(
        http.MultipartFile(
          'assetData',
          source.openRead().map((chunk) {
            bodyBytesSent += chunk.length;
            return chunk;
          }),
          source.length,
          filename: source.filename,
        ),
      );
    final response = await http.Response.fromStream(await client.send(request));
    final json = response.body.isEmpty ? null : jsonDecode(response.body);
    if (response.statusCode == 200 || response.statusCode == 201) {
      return UploadResult.success(
        remoteAssetId: (json as Map)['id'] as String,
        isDuplicate: json['status'] == 'duplicate',
        statusCode: response.statusCode,
      );
    }
    return UploadResult.error(
      statusCode: response.statusCode,
      errorMessage: json is Map ? '${json['message']}' : response.body,
    );
  }

  @override
  Future<bool> albumExists(String id) async => await _json('GET', '/albums/$id') != null;

  @override
  Future<String> createAlbum(String name) async =>
      ((await _json('POST', '/albums', {'albumName': name}))! as Map)['id'] as String;

  @override
  Future<void> addToAlbum(String albumId, String assetId) async {
    await _json('PUT', '/albums/$albumId/assets', {
      'ids': [assetId],
    });
  }

  Future<void> delete({required List<String> assets, List<String> albums = const []}) async {
    if (assets.isNotEmpty) {
      await _json('DELETE', '/assets', {'ids': assets, 'force': true});
    }
    for (final album in albums) {
      await _json('DELETE', '/albums/$album');
    }
  }
}

void main() {
  final base = _env['SPLAT_E2E_URL'] ?? '';
  final key = _env['SPLAT_E2E_KEY'] ?? '';
  final proxy = _env['SPLAT_E2E_PROXY'];
  final scenePath = _env['SPLAT_E2E_SCENE'] ?? '';
  final skip = !RegExp(r'^http://192\.168\.4\.134:228[34]$').hasMatch(base) || key.isEmpty || scenePath.isEmpty
      ? 'needs SPLAT_E2E_URL (a compat server of ai1), SPLAT_E2E_KEY and SPLAT_E2E_SCENE'
      : null;

  test(
    'a scene saved, read back, saved again, taken out directly and through a proxy without Range',
    () async {
      final out = <String, Object?>{'server': base, 'started': DateTime.now().toIso8601String()};
      final server = _HttpServer(base, key);
      final work = Directory.systemTemp.createTempSync('splat_photo_e2e');
      final made = <String>[];
      final albums = <String>{};
      try {
        out['version'] = '${await server.version()}';
        final scene = File(scenePath);
        // A PLY is converted by the job: its SPZ is the one in the packet
        final isPly = scenePath.toLowerCase().endsWith('.ply');
        final records = SplatSaveRecords(() async => File('${work.path}/splat_saves.json'));
        final suffix = DateTime.now().millisecondsSinceEpoch;
        // A copy of the scene under a name of its own, so that a run never meets the files of another
        final named = scene.copySync('${work.path}/e2e_$suffix.${isPly ? 'ply' : 'spz'}')
          ..setLastModifiedSync(DateTime.utc(2026, 11, 3, 15));
        SplatSaveJob jobOf({bool force = false}) => SplatSaveJob(
          request: SplatSaveRequest(
            scene: named,
            sceneName: named.uri.pathSegments.last,
            sceneDate: DateTime.utc(2026, 11, 3, 15),
            caption: (count) => 'Splat scene of $count gaussians. Open it with Immuch360 to explore it.',
            cardLine: (count) => '$count gaussians',
            albumName: 'Splat scenes e2e $suffix',
            force: force,
            software: 'Immuch360 e2e',
            creatorTool: 'Immuch360 e2e (linux)',
          ),
          server: server,
          records: records,
          workFolder: () async => Directory('${work.path}/cache'),
          drawPoster: (spz, head, up, mark) async =>
              (await drawSplatPosterInIsolate(path: spz.path, head: head, up: up, mark: mark)).jpeg,
          drawCard: (name, line, mark) async => throw UnsupportedError('no card here'),
        );

        // 1. The save, timed
        final clock = Stopwatch()..start();
        final saved = await jobOf().run();
        out['saveMs'] = clock.elapsedMilliseconds;
        out['save'] = {
          'state': saved.state.name,
          'bytes': saved.carrierBytes,
          'sceneBytes': saved.sceneBytes,
          'inputBytes': scene.lengthSync(),
          'detail': saved.detail,
        };
        expect(saved.state, SplatSaveState.done, reason: '$saved');
        final assetId = saved.assetId!;
        out['assetId'] = assetId;
        made.add(assetId);
        final asset = (await server._json('GET', '/assets/$assetId'))! as Map;
        out['asset'] = {
          'type': asset['type'],
          'originalMimeType': asset['originalMimeType'],
          'originalFileName': asset['originalFileName'],
          'livePhotoVideoId': asset['livePhotoVideoId'],
          'fileCreatedAt': asset['fileCreatedAt'],
        };
        expect(asset['type'], 'IMAGE');
        final albumList = (await server._json('GET', '/albums?assetId=$assetId'))! as List;
        albums.addAll(albumList.map((album) => (album as Map)['id'] as String));
        out['albums'] = albumList.map((album) => (album as Map)['albumName']).toList();
        try {
          out['metadata'] = await server._json('GET', '/assets/$assetId/metadata');
        } catch (error) {
          out['metadata'] = 'unread: $error';
        }

        // 2. The head of the original: the packet, as the probe reads it
        final head = (await server.head(assetId, splatPhotoHeadBytes))!;
        final xmp = SplatPhotoXmp.findIn(head)!;
        out['packet'] = {
          'name': xmp.splatName,
          'length': xmp.splatLength,
          'gaussians': xmp.splatGaussians,
          'poster': xmp.splatPoster?.name,
        };
        expect(xmp.splatLength, isPly ? saved.sceneBytes : scene.lengthSync());
        if (isPly) {
          out['packet'] = {...out['packet']! as Map, 'sourceSha256': xmp.splatSourceSha256};
          expect(xmp.splatSourceSha256, sha256.convert(scene.readAsBytesSync()).toString());
        }

        // 3. The scene taken out of the end of the original, directly and through the proxy: the SPZ of the packet
        final sum = isPly ? xmp.splatSha256 : sha256.convert(scene.readAsBytesSync()).toString();
        expect(xmp.splatSha256, sum);
        Future<Map<String, Object?>> takeOut(String through) async {
          final file = File('${work.path}/tail-${through.hashCode}.spz');
          final watch = Stopwatch()..start();
          final fetched = await fetchSplatTail(
            source: SplatTailFromServer(
              client: http.Client(),
              url: splatPhotoOriginalUri('$through/api', assetId),
              headers: {'x-api-key': key},
            ),
            xmp: xmp,
            out: file,
          );
          final same = sha256.convert(file.readAsBytesSync()).toString() == sum;
          return {
            'route': fetched.route.name,
            'received': fetched.received,
            'sameSum': same,
            'ms': watch.elapsedMilliseconds,
          };
        }

        out['tailDirect'] = await takeOut(base);
        expect((out['tailDirect']! as Map)['sameSum'], isTrue);
        if (proxy != null) {
          out['tailProxy'] = await takeOut(proxy);
          expect((out['tailProxy']! as Map)['sameSum'], isTrue);
          final through = _HttpServer(proxy, key);
          final proxied = await through.head(assetId, splatPhotoHeadBytes);
          out['headThroughProxy'] = proxied?.length;
        }

        // 4. Saved again: from the record of this device, then from the heads of the server's splat photos; no upload
        // request in steps 4 and 5
        out['uploadRequestsAfterSave'] = server.uploadRequests;
        final again = await jobOf().run();
        out['againFromRecord'] = again.state.name;
        expect(again.state, SplatSaveState.alreadyThere);
        File('${work.path}/splat_saves.json').deleteSync();
        final found = await jobOf().run();
        out['againFromSearch'] = found.state.name;
        expect(found.state, SplatSaveState.alreadyThere);

        // 5. Save another copy: the same poster drawn, the same file, which bulk-upload-check finds
        final copy = await jobOf(force: true).run();
        out['anotherCopy'] = copy.state.name;
        expect(copy.state, SplatSaveState.duplicate);
        out['uploadRequestsAfterAgain'] = server.uploadRequests;
        expect(server.uploadRequests, out['uploadRequestsAfterSave']);

        // 6. The checksum header alone: the server answers a duplicate before the body
        server.bodyBytesSent = 0;
        final carrier = File('${work.path}/carrier.jpg');
        final original = await server.client.send(
          http.Request('GET', splatPhotoOriginalUri(server.url, assetId))..headers.addAll(server._headers),
        );
        await original.stream.pipe(carrier.openWrite());
        final keepCarrier = _env['SPLAT_E2E_CARRIER'];
        if (keepCarrier != null) {
          carrier.copySync(keepCarrier);
        }
        final sha1sum = sha1.convert(carrier.readAsBytesSync()).toString();
        final early = await server.upload(
          UploadSource(
            id: 'e2e',
            filename: 'checksum_$suffix.jpg',
            length: carrier.lengthSync(),
            openRead: carrier.openRead,
            createdAt: DateTime.utc(2026, 11, 3, 15),
            modifiedAt: DateTime.utc(2026, 11, 3, 15),
            deviceAssetId: 'splat-$sha1sum',
            headers: {'x-immich-checksum': sha1sum},
          ),
        );
        out['checksumHeader'] = {
          'isDuplicate': early.isDuplicate,
          'assetId': early.remoteAssetId == assetId,
          'clientBodyBytes': server.bodyBytesSent,
          'carrierBytes': carrier.lengthSync(),
        };
        expect(early.isDuplicate, isTrue);
      } finally {
        out['finished'] = DateTime.now().toIso8601String();
        try {
          if (_env['SPLAT_E2E_KEEP'] == '1') {
            out['kept'] = {'assets': made, 'albums': albums.toList()};
          } else {
            await server.delete(assets: made, albums: albums.toList());
            out['deleted'] = made.length;
          }
        } catch (error) {
          out['deleteError'] = '$error';
        }
        final path = _env['SPLAT_E2E_OUT'];
        if (path != null) {
          File(path).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(out));
        }
        work.deleteSync(recursive: true);
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
