// TIFF photos where the device has no TIFF decoder. Android has none: BitmapFactory and ImageDecoder refuse TIFF, and
// the engine's fallback decoder is ImageDecoder itself ("Failed to create image decoder with message 'invalid input'"
// in the logcat of a Meta Quest 3, 31 October 2026). So, on Android (phones, TVs, the Quest):
//
// - a TIFF of the server shows as the largest JPEG the server makes of it, as a browser shows a HEIF or a raw file
//   (AssetMediaSize.fullsize: the server's full size conversion, or its preview while that conversion is off, see
//   sharpPanoramaUrl), with a notice in the details; the original stays what downloads and exports send. A TIFF on the
//   device that is on the server too shows the same way;
// - a TIFF of the device or of a network share, of which no server made a JPEG, is decoded in Dart (tiff_decoder.dart),
//   in a background isolate, its file read only when the decoder takes it, within what the device allows
//   ([TiffBudget]), one or two at a time, the photo on screen before the tiles;
// - a TIFF that does not decode says so ("This device cannot decode this TIFF") instead of the engine's "Invalid image
//   data", once: the failure is remembered for the session ([UndecodablePhotos]), so that no widget that resolves the
//   photo again (a new density, the page shown again, the tiles of a folder opened again) reads and decodes it again.
//
// iOS, macOS and Windows keep their decoders, which read TIFF: Core Graphics (ImageIO) and WIC, through the engine and
// the native image pipelines alike. Linux has no TIFF decoder in its engine and keeps the path of its desktop library
// (a tile for the formats it does not read).

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
// Pure Dart, MIT, in the lock through maplibre_gl (as in lib/desktop/library/local_image_codec.dart)
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/domain/services/tiff_decoder.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';

export 'package:immich_mobile/domain/services/tiff_decoder.dart' show TiffDecodeException, TiffPixels;

final _tiffName = RegExp(r'\.tiff?$', caseSensitive: false);

// The camera raw files built on TIFF: never shown as a TIFF, whatever type a share gives them
final _rawName = RegExp(
  r'\.(dng|cr2|cr3|crw|nef|nrw|arw|srf|sr2|orf|rw2|raf|pef|srw|3fr|erf|kdc|dcr|mos|mrw|x3f|iiq|rwl)$',
  caseSensitive: false,
);

const _tiffMimeTypes = {'image/tiff', 'image/tif', 'image/x-tiff'};

/// Whether [name] is the name of a TIFF file (.tif, .tiff)
bool isTiffName(String name) => _tiffName.hasMatch(name);

/// Whether [mimeType] is the type of a TIFF file (image/tiff and its older spellings), its parameters left out
bool isTiffMimeType(String? mimeType) =>
    mimeType != null && _tiffMimeTypes.contains(mimeType.split(';').first.trim().toLowerCase());

/// Whether [head], the first bytes of a file, starts as a TIFF does ("II*\0" or "MM\0*"). The camera raw files built
/// on TIFF (DNG, CR2, NEF, ARW) start the same way: this confirms a name or a type, it tells nothing alone.
bool hasTiffSignature(Uint8List head) =>
    head.length >= 4 &&
    ((head[0] == 0x49 && head[1] == 0x49 && head[2] == 0x2A && head[3] == 0x00) ||
        (head[0] == 0x4D && head[1] == 0x4D && head[2] == 0x00 && head[3] == 0x2A));

/// Whether the photo named [name], of the type [mimeType] when its source tells one, is a TIFF. A camera raw file never
/// is, whatever its structure or the type given.
bool isTiffPhoto(String name, {String? mimeType}) =>
    !_rawName.hasMatch(name) && (isTiffName(name) || isTiffMimeType(mimeType));

/// Whether this platform keeps its own path for TIFF: iOS and macOS decode it through Core Graphics, Windows through
/// WIC; Linux, whose engine has no TIFF decoder, keeps the tile of its desktop library. False on Android, which has
/// no TIFF decoder.
bool get thisPlatformKeepsItsTiffPath => !CurrentPlatform.isAndroid;

/// How a photo is decoded for the viewers
enum PhotoDecodePath {
  /// By the platform, as any photo: the native pipeline or the engine
  platform,

  /// The largest JPEG the server makes of it instead of its original
  serverPreview,

  /// In Dart, by the decoder of tiff_decoder.dart (see [decodeTiff])
  dartTiff,
}

/// How the photo named [name] (of the type [mimeType] when known) is decoded: from the server ([fromServer]) or from
/// the device or a share. [platformKeepsTiffPath] stands for [thisPlatformKeepsItsTiffPath] in the tests.
PhotoDecodePath photoDecodePath(
  String name, {
  String? mimeType,
  required bool fromServer,
  bool? platformKeepsTiffPath,
}) {
  if ((platformKeepsTiffPath ?? thisPlatformKeepsItsTiffPath) || !isTiffPhoto(name, mimeType: mimeType)) {
    return PhotoDecodePath.platform;
  }
  return fromServer ? PhotoDecodePath.serverPreview : PhotoDecodePath.dartTiff;
}

/// What the Dart decoder may take of this device: the file it reads whole, the samples of the image it decodes (the
/// image package's decoder, for the rarer kinds, holds them all), how many TIFFs at once, and the long side of the
/// picture of a viewer. The decoder runs in an isolate of the app's group, whose memory Android bounds to half of the
/// device's: a TV of 2 GB gets a quarter of what a Meta Quest 3 of 8 GB does.
class TiffBudget {
  const TiffBudget({
    required this.maxFileBytes,
    required this.maxDecodedBytes,
    required this.maxConcurrentDecodes,
    required this.maxViewerSide,
  });

  /// A device of 6 GB or more (a Meta Quest 3, most phones of these years): a 64 megapixel photo in 16 bit RGB
  static const large = TiffBudget(
    maxFileBytes: 512 << 20,
    maxDecodedBytes: 384 << 20,
    maxConcurrentDecodes: 2,
    maxViewerSide: 8192,
  );

  /// A device of 3 to 6 GB
  static const medium = TiffBudget(
    maxFileBytes: 256 << 20,
    maxDecodedBytes: 192 << 20,
    maxConcurrentDecodes: 1,
    maxViewerSide: 8192,
  );

  /// A TV, a device Android calls low on memory, or one of less than 3 GB
  static const small = TiffBudget(
    maxFileBytes: 128 << 20,
    maxDecodedBytes: 96 << 20,
    maxConcurrentDecodes: 1,
    maxViewerSide: 4096,
  );

  /// For a device of [totalMemoryBytes] (null when unknown), a TV ([isTelevision]) or not, low on memory
  /// ([isLowRamDevice], as Android says) or not
  factory TiffBudget.forDevice({required bool isTelevision, required bool isLowRamDevice, int? totalMemoryBytes}) {
    const gigabyte = 1 << 30;
    if (isTelevision || isLowRamDevice || (totalMemoryBytes != null && totalMemoryBytes < 3 * gigabyte)) {
      return small;
    }
    // A device of 6 GB tells a little less: what the kernel keeps for itself
    return totalMemoryBytes != null && totalMemoryBytes >= 5.5 * gigabyte ? large : medium;
  }

  final int maxFileBytes;
  final int maxDecodedBytes;
  final int maxConcurrentDecodes;
  final int maxViewerSide;

  /// The budget of this device, set before the first frame (see main.dart); the largest until then, and in the tests
  static TiffBudget current = large;

  @override
  String toString() =>
      'TiffBudget(file ${maxFileBytes >> 20} MB, samples ${maxDecodedBytes >> 20} MB, $maxConcurrentDecodes at once, '
      'side $maxViewerSide)';
}

/// The memory of this device as Linux tells it (/proc/meminfo, which Android apps read), null where there is none
Future<int?> readTotalMemoryBytes({String path = '/proc/meminfo'}) async {
  try {
    final file = File(path);
    if (!file.existsSync()) {
      return null;
    }
    final line = (await file.readAsLines()).firstWhere((line) => line.startsWith('MemTotal:'), orElse: () => '');
    final kilobytes = int.tryParse(RegExp(r'(\d+)').firstMatch(line)?.group(1) ?? '');
    return kilobytes == null ? null : kilobytes * 1024;
  } on FileSystemException {
    return null;
  }
}

/// Throws a [TiffDecodeException] when a file of [length] bytes is more than the decoder reads ([TiffBudget.current])
void checkTiffFileLength(int length) {
  if (length > TiffBudget.current.maxFileBytes) {
    throw TiffDecodeException('$length bytes is more than this device reads for a TIFF');
  }
}

/// What a decode is for: the photo on screen goes before the tiles
enum TiffWork { viewer, tile }

/// Cancels the reading and the decoding of a TIFF nobody wants any more (its page gone, its tile scrolled away)
class TiffCancel {
  var _cancelled = false;
  final _actions = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    final actions = _actions.toList();
    _actions.clear();
    for (final action in actions) {
      action();
    }
  }

  /// Runs [action] when this is cancelled, at once when it is already
  void onCancel(void Function() action) => _cancelled ? action() : _actions.add(action);
}

/// A TIFF whose decode was given up before it ran or while its file came: nobody wanted it any more
class TiffDecodeCancelled implements Exception {
  const TiffDecodeCancelled();

  @override
  String toString() => 'TiffDecodeCancelled';
}

class _Turn {
  _Turn(this.cancel);

  final TiffCancel? cancel;
  final completer = Completer<void>();
}

var _decoding = 0;
final _waitingViewers = Queue<_Turn>();
final _waitingTiles = Queue<_Turn>();

/// [job] in a turn of the decoder: [TiffBudget.maxConcurrentDecodes] at most at once, the viewers ([work]) before the
/// tiles, each in the order asked. A job cancelled ([cancel]) while it waits leaves the queue at once and never runs,
/// with a [TiffDecodeCancelled]. Read the file in [job], when the turn came: a waiting job holds nothing.
Future<T> inTiffTurn<T>(Future<T> Function() job, {TiffWork work = TiffWork.viewer, TiffCancel? cancel}) async {
  if (cancel?.isCancelled ?? false) {
    throw const TiffDecodeCancelled();
  }
  if (_decoding >= TiffBudget.current.maxConcurrentDecodes) {
    final turn = _Turn(cancel);
    final queue = work == TiffWork.viewer ? _waitingViewers : _waitingTiles;
    queue.add(turn);
    cancel?.onCancel(() {
      if (queue.remove(turn)) {
        turn.completer.completeError(const TiffDecodeCancelled());
      }
    });
    // Handed over by the job that ends, the count staying the same
    await turn.completer.future;
  } else {
    _decoding++;
  }
  try {
    if (cancel?.isCancelled ?? false) {
      throw const TiffDecodeCancelled();
    }
    return await job();
  } finally {
    _handOver();
  }
}

void _handOver() {
  final next = _waitingViewers.isNotEmpty
      ? _waitingViewers.removeFirst()
      : _waitingTiles.isNotEmpty
      ? _waitingTiles.removeFirst()
      : null;
  if (next == null) {
    _decoding--;
  } else {
    next.completer.complete();
  }
}

/// How many jobs run and wait for the decoder (the tests)
@visibleForTesting
({int running, int waiting}) get tiffTurns =>
    (running: _decoding, waiting: _waitingViewers.length + _waitingTiles.length);

/// [bytes], a TIFF, decoded in a background isolate (see decodeTiffPixels), at most [maxSide] pixels on its long side,
/// upright. Called in a turn of the decoder (see [inTiffTurn]); [bytes] are copied for the isolate before this returns,
/// the caller may free them then. Throws [TiffDecodeException] when it does not decode.
Future<TiffPixels> decodeTiffNow(Uint8List bytes, {required int maxSide}) {
  try {
    checkTiffFileLength(bytes.length);
  } on TiffDecodeException catch (error) {
    return Future.error(error);
  }
  final job = (
    bytes: TransferableTypedData.fromList([bytes]),
    maxSide: maxSide,
    maxDecodedBytes: TiffBudget.current.maxDecodedBytes,
  );
  return _runDecode(job);
}

Future<TiffPixels> _runDecode(({TransferableTypedData bytes, int maxSide, int maxDecodedBytes}) job) =>
    Isolate.run(() => _decodeJob(job), debugName: 'TIFF decoder');

TiffPixels _decodeJob(({TransferableTypedData bytes, int maxSide, int maxDecodedBytes}) job) =>
    decodeTiffPixels(job.bytes.materialize().asUint8List(), maxSide: job.maxSide, maxDecodedBytes: job.maxDecodedBytes);

/// The TIFF [read] gives, read when the turn of the decoder comes (see [inTiffTurn], [work], [cancel]), decoded as
/// [decodeTiffNow] does
Future<TiffPixels> decodeTiff(
  Future<Uint8List> Function() read, {
  required int maxSide,
  TiffWork work = TiffWork.viewer,
  TiffCancel? cancel,
}) => inTiffTurn(
  () async {
    final bytes = await read();
    if (cancel?.isCancelled ?? false) {
      throw const TiffDecodeCancelled();
    }
    return decodeTiffNow(bytes, maxSide: maxSide);
  },
  work: work,
  cancel: cancel,
);

/// The long side of the JPEG the immersive viewer reads of a TIFF (see [tiffAsJpeg]): the texture width of a 360
/// photo on the headset, or less on a device of little memory
int get tiffJpegMaxSide => TiffBudget.current.maxViewerSide;

/// The TIFF [read] gives as a JPEG of [quality], at most [maxSide] pixels on its long side, upright, made in a
/// background isolate in a turn of the decoder (see [inTiffTurn]): what the immersive viewer of the Meta Quest reads of
/// a TIFF of the headset or of a share, its decoders refusing TIFF. Throws [TiffDecodeException] when the TIFF does not
/// decode.
Future<Uint8List> tiffAsJpeg(Future<Uint8List> Function() read, {int? maxSide, int quality = 90, TiffCancel? cancel}) =>
    inTiffTurn(() async {
      final bytes = await read();
      checkTiffFileLength(bytes.length);
      if (cancel?.isCancelled ?? false) {
        throw const TiffDecodeCancelled();
      }
      final job = (
        bytes: TransferableTypedData.fromList([bytes]),
        maxSide: maxSide ?? tiffJpegMaxSide,
        maxDecodedBytes: TiffBudget.current.maxDecodedBytes,
        quality: quality,
      );
      return _runJpeg(job);
    }, cancel: cancel);

Future<Uint8List> _runJpeg(({TransferableTypedData bytes, int maxSide, int maxDecodedBytes, int quality}) job) =>
    Isolate.run(() => _jpegJob(job), debugName: 'TIFF to JPEG');

Uint8List _jpegJob(({TransferableTypedData bytes, int maxSide, int maxDecodedBytes, int quality}) job) {
  final pixels = decodeTiffPixels(
    job.bytes.materialize().asUint8List(),
    maxSide: job.maxSide,
    maxDecodedBytes: job.maxDecodedBytes,
  );
  try {
    final image = img.Image.fromBytes(
      width: pixels.width,
      height: pixels.height,
      bytes: pixels.rgba.buffer,
      bytesOffset: pixels.rgba.offsetInBytes,
      numChannels: 4,
    );
    return img.encodeJpg(image, quality: job.quality);
  } catch (error) {
    // A lack of memory included: the photo does not open, and is not read again
    throw TiffDecodeException('$error');
  }
}

/// [decodeTiffPixels] on the calling isolate, within the budget of this device (the tests)
@visibleForTesting
TiffPixels decodeTiffSync(Uint8List bytes, {required int maxSide}) =>
    decodeTiffPixels(bytes, maxSide: maxSide, maxDecodedBytes: TiffBudget.current.maxDecodedBytes);

/// The photos that did not decode in this session, by a key of their own (their URL, their asset), with the error
/// they gave: a photo is decoded once per session, a failure is told again at once, without reading the file again.
/// Only failures of the decoder are kept: a network error is tried again the next time the photo shows.
class UndecodablePhotos {
  UndecodablePhotos._();

  static final instance = UndecodablePhotos._();

  /// Most failures kept, the oldest dropped first
  static const maxEntries = 1000;

  final _failures = <String, Exception>{};

  /// The error the photo [key] gave in this session, null when it was not tried or decoded
  Exception? failureOf(String key) => _failures[key];

  /// Remembers that the photo [key] did not decode, with [error]
  void remember(String key, Exception error) {
    _failures.remove(key);
    _failures[key] = error;
    while (_failures.length > maxEntries) {
      _failures.remove(_failures.keys.first);
    }
  }

  /// Forgets every failure (the tests, between cases)
  @visibleForTesting
  void clear() => _failures.clear();
}
