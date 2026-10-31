// The TIFF photos of the headset and of the shares for the immersive viewer of a Meta Quest: its decoders, those of
// Android, refuse TIFF, so the app decodes the file in Dart and hands the viewer a JPEG of it from the cache, made once
// per photo. A TIFF of the server needs none: the viewer reads the JPEG the server made of it (see serverPhotoUrl).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/tiff_photos.dart';
import 'package:immich_mobile/presentation/widgets/network/network_tiff_image.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final _log = Logger('ImmersiveTiff');

/// The JPEGs of TIFF photos the immersive viewer reads, in a folder of the cache of the app (the system may empty it):
/// one per photo, made from its file the first time it opens, kept for the next ones
class TiffJpegCache {
  TiffJpegCache(this._folder);

  /// In the temporary folder of the app
  TiffJpegCache.temporary()
    : _folder = (() async => Directory(p.join((await getTemporaryDirectory()).path, 'tiff_jpeg')));

  final Future<Directory> Function() _folder;

  // The JPEGs being made, by their file: a photo opened twice at once is made once
  final _making = <String, Future<File>>{};

  /// The JPEG of the TIFF [key] names (its source, its path or id, and what tells a new version of it: size, date or
  /// checksum), made from [read], its file, when the cache does not hold it yet; [onDecoding] is told then, with what
  /// completes once it is made or failed. [read] runs in a turn of the decoder (see tiffAsJpeg). Throws
  /// [TiffDecodeException] when the TIFF does not decode.
  Future<File> jpegOf(
    String key,
    Future<Uint8List> Function() read, {
    void Function(Future<void> done)? onDecoding,
  }) async {
    final folder = await _folder();
    final file = File(p.join(folder.path, '${sha1.convert(utf8.encode(key))}.jpg'));
    if (file.existsSync() && file.lengthSync() > 0) {
      return file;
    }
    final making = _making[file.path];
    if (making != null) {
      return making;
    }
    final made = _make(folder, file, read);
    _making[file.path] = made;
    onDecoding?.call(made);
    try {
      return await made;
    } finally {
      // Awaited above
      unawaited(_making.remove(file.path));
    }
  }

  Future<File> _make(Directory folder, File file, Future<Uint8List> Function() read) async {
    final jpeg = await tiffAsJpeg(read);
    await folder.create(recursive: true);
    // Written aside and moved in place: a viewer never reads half a file
    final partial = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.part');
    await partial.writeAsBytes(jpeg, flush: true);
    await partial.rename(file.path);
    _log.info('JPEG of a TIFF for the immersive viewer: ${jpeg.length} bytes');
    _keepLatest(folder, file);
    return file;
  }

  /// Most JPEGs kept, the oldest deleted first
  static const maxFiles = 20;

  // Deletes the oldest JPEGs beyond [maxFiles], never [kept]
  static void _keepLatest(Directory folder, File kept) {
    try {
      final files = folder.listSync().whereType<File>().where((file) => file.path.endsWith('.jpg')).toList()
        ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      for (final old in files.skip(maxFiles)) {
        if (old.path != kept.path) {
          old.deleteSync();
        }
      }
    } on FileSystemException catch (error) {
      _log.fine('Could not tidy the JPEGs of TIFFs: $error');
    }
  }
}

final tiffJpegCacheProvider = Provider<TiffJpegCache>((_) => TiffJpegCache.temporary());

/// The URL of a JPEG in [jpegs] of the TIFF of the media bridge at [url] when this device decodes no TIFF (see
/// isDartTiffUrl), made from its whole file read with [client] the first time; null for any other photo. [entry] is
/// the listing of the file, when known: its size and date tell a new version, its type a TIFF without the name of one,
/// and a file larger than the device reads is refused before it is read. [onDecoding] is told while the JPEG is made
/// (see [TiffJpegCache.jpegOf]). A TIFF that did not decode in this session, here, in its page or in its tile, throws
/// at once, without reading its file again.
Future<String?> shareTiffJpegUrl(
  TiffJpegCache jpegs,
  http.Client client, {
  required Uri url,
  NetworkEntry? entry,
  void Function(Future<void> done)? onDecoding,
}) async {
  // The listing of another file (a version of the photo shown) tells nothing of this one
  final listed = entry != null && entry.name == url.pathSegments.lastOrNull ? entry : null;
  if (!isDartTiffUrl(url, mimeType: listed?.mimeType)) {
    return null;
  }
  final undecodable = undecodableShareKey(url);
  final failure = UndecodablePhotos.instance.failureOf(undecodable);
  if (failure != null) {
    throw failure;
  }
  try {
    final size = listed?.size;
    if (size != null) {
      checkTiffFileLength(size);
    }
    // The source and the path, not the token of the bridge, which changes with each start of the app
    final key = 'share:${url.pathSegments.skip(1).join('/')}:${listed?.size}:${listed?.modified}';
    final jpeg = await jpegs.jpegOf(key, () => readBridgeTiff(client, url), onDecoding: onDecoding);
    return jpeg.uri.toString();
  } on TiffDecodeException catch (error) {
    UndecodablePhotos.instance.remember(undecodable, error);
    rethrow;
  }
}

/// The whole file of the media bridge at [url], read with [client], at most as many bytes as the device reads for a
/// TIFF: a [TiffDecodeException] once more come, or when its Content-Length says so
Future<Uint8List> readBridgeTiff(http.Client client, Uri url) async {
  final response = await client.send(http.Request('GET', url));
  if (response.statusCode != HttpStatus.ok) {
    await response.stream.listen(null).cancel();
    throw http.ClientException('HTTP ${response.statusCode}', url);
  }
  final total = response.contentLength;
  if (total != null && total > TiffBudget.current.maxFileBytes) {
    await response.stream.listen(null).cancel();
    checkTiffFileLength(total);
  }
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in response.stream) {
    bytes.add(chunk);
    // Leaving the loop stops the download
    checkTiffFileLength(bytes.length);
  }
  return bytes.takeBytes();
}

/// Shows [text] ("Decoding the TIFF on this device") with [messenger] until [done] completes, however it ends
void showTiffDecodingLine(ScaffoldMessengerState? messenger, String text, Future<void> done) {
  if (messenger == null) {
    return;
  }
  final line = messenger.showSnackBar(SnackBar(content: Text(text), duration: const Duration(minutes: 10)));
  unawaited(
    done.catchError((Object _) {}).whenComplete(() {
      try {
        line.close();
      } catch (error) {
        // The messenger went with its page: the line went with it
        _log.fine('The decoding line was gone already: $error');
      }
    }),
  );
}
