// The TIFF photos of the headset and of the shares for the immersive viewer of a Meta Quest: its decoders, those of
// Android, refuse TIFF, so the app decodes the file in Dart and hands the viewer a JPEG of it from the cache, made once
// per photo. A TIFF of the server needs none: the viewer reads the JPEG the server made of it (see serverPhotoUrl).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/tiff_photos.dart';
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

  /// The JPEG of the TIFF [key] names (its source, its path or id, and what tells a new version of it: size, date or
  /// checksum), made from [read], its file, when the cache does not hold it yet. Throws [TiffDecodeException] when
  /// the TIFF does not decode.
  Future<File> jpegOf(String key, Future<Uint8List> Function() read) async {
    final folder = await _folder();
    final file = File(p.join(folder.path, '${sha1.convert(utf8.encode(key))}.jpg'));
    if (file.existsSync() && file.lengthSync() > 0) {
      return file;
    }
    final jpeg = await tiffAsJpeg(await read());
    await folder.create(recursive: true);
    // Written aside and moved in place: a viewer never reads half a file
    final partial = File('${file.path}.part');
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
