// The writer of the splat photos (plan of 3 November 2026, sections 2.2 and 6.3): a poster JPEG cleaned, given our
// EXIF and packet, then the SPZ byte for byte after its EOI. It only splices segments: the pixels of the poster are
// never decoded nor encoded again, so the output is the same on every device.
//
// The poster is cleaned first: APP0 JFIF, the ICC profile of an RGB poster, APP14 Adobe, the tables, the frame and
// the scans are kept; every other APP0 and APP1 (EXIF, XMP, Extended XMP), APP2 MPF, APP3 to APP13, APP15 and COM go,
// and so does whatever follows the first EOI (the video of a motion photo, the gain map of an Ultra HDR photo, a
// Samsung trailer). Then, in this order: SOI, APP0, our EXIF, our packet (ending before byte 65,536), the ICC chunks
// (after the packet, so that a large camera profile never pushes the packet out of the head the readers look at), the
// rest of the poster, its EOI, and the SPZ.
//
// Two passes over the SPZ: the first for its SHA-256 and its head (the packet holds both, and comes first in the file),
// the second to copy it after the head, the SHA-1 of the whole file computed on the way (the checksum Immich gives the
// asset, and the x-immich-checksum header of the upload). Reads of 1 MiB at most, never the SPZ nor the file whole in
// memory; the file goes to a .part renamed once complete. .github/desktop/ai/make_splat_photo_fixtures.py writes the
// same bytes from the same inputs.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:immich_mobile/domain/models/splat/splat_photo_xmp.dart';
import 'package:immich_mobile/domain/services/splat_photo/jpeg_walk.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_photo_exif.dart';

/// "http://ns.adobe.com/xap/1.0/\0", the start of the APP1 segment of an XMP packet
final xmpSignature = latin1.encode('http://ns.adobe.com/xap/1.0/\x00');

/// "ICC_PROFILE\0", the start of each APP2 chunk of an ICC profile
const _iccSignature = 'ICC_PROFILE\x00';

/// The most bytes of the payload of a marker segment (its length field counts itself)
const jpegMaxSegmentPayload = 65533;

/// The most bytes the writer reads or writes at a time
const splatPhotoChunk = 1 << 20;

/// Why a splat photo was not written
enum SplatPhotoWriteProblem {
  /// The poster is not a JPEG the writer can follow
  posterNotJpeg,

  /// The poster's frame is not 1.25 to 1.85 times as long as it is high (or high as long), or longer than 2,048 px
  posterShape,

  /// The poster takes more than 1 MiB
  posterTooLarge,

  /// The scene is not an SPZ of version 1 to 4
  notSpz,

  /// The scene is shorter than 32 bytes, or longer than the writer's 1 GiB
  spzSize,

  /// The packet would end past byte 65,536
  packetTooLate,

  /// The scene changed between the two passes
  changed,

  cancelled,
}

class SplatPhotoWriteException implements Exception {
  const SplatPhotoWriteException(this.problem, [this.detail = '']);

  final SplatPhotoWriteProblem problem;
  final String detail;

  @override
  String toString() => 'SplatPhotoWriteException(${problem.name}${detail.isEmpty ? '' : ': $detail'})';
}

/// The poster once cleaned (see the top of this file): its APP0 JFIF, the chunks of its ICC profile, the rest of its
/// segments up to its EOI included, and its frame
class SplatPoster {
  const SplatPoster({
    required this.app0,
    required this.icc,
    required this.rest,
    required this.width,
    required this.height,
  });

  /// The whole APP0 segment, marker included; null when the poster had none
  final Uint8List? app0;

  /// The whole APP2 segments of the ICC profile, in their order
  final List<Uint8List> icc;

  /// APP14 Adobe, the tables, the frame and the scans, then the EOI
  final Uint8List rest;
  final int width;
  final int height;

  /// The bytes the poster takes in the file, without our segments
  int get length => 2 + (app0?.length ?? 0) + icc.fold<int>(0, (sum, chunk) => sum + chunk.length) + rest.length;
}

/// Whether a frame of [width] x [height] has the shape of a poster: its long side 1.25 to 1.85 times its short side,
/// 2,048 px at most
bool isSplatPosterShape(int width, int height) {
  if (width <= 0 || height <= 0) {
    return false;
  }
  final long = math.max(width, height);
  final ratio = long / math.min(width, height);
  return long <= splatPhotoPosterMaxLongest && ratio >= splatPhotoRatioMin && ratio <= splatPhotoRatioMax;
}

/// Whether the ICC profile whose first chunk is [chunk] (a whole APP2 segment) is one of RGB
bool _isRgbIcc(Uint8List chunk) {
  // Marker and length (4), signature (12), sequence and count (2), then the profile: its colour space at 16
  const at = 4 + 12 + 2 + 16;
  return chunk.length >= at + 4 && latin1.decode(chunk.sublist(at, at + 4)) == 'RGB ';
}

/// The poster [jpeg] cleaned (see the top of this file); throws a [SplatPhotoWriteException] for a poster that is not
/// a JPEG, of another shape (unless [checkShape] is false), or larger than 1 MiB once cleaned
SplatPoster cleanSplatPoster(Uint8List jpeg, {bool checkShape = true}) {
  final JpegLayout layout;
  try {
    layout = walkJpeg(jpeg);
  } on JpegWalkException catch (error) {
    throw SplatPhotoWriteException(SplatPhotoWriteProblem.posterNotJpeg, error.detail);
  }
  if (!layout.segments.any((segment) => isJpegSof(segment.marker)) ||
      !layout.segments.any((segment) => segment.marker == jpegSos)) {
    throw const SplatPhotoWriteException(SplatPhotoWriteProblem.posterNotJpeg, 'no frame or no scan');
  }
  if (checkShape && !isSplatPosterShape(layout.width, layout.height)) {
    throw SplatPhotoWriteException(SplatPhotoWriteProblem.posterShape, '${layout.width} x ${layout.height}');
  }
  Uint8List? app0;
  final icc = <Uint8List>[];
  final rest = BytesBuilder(copy: false);
  for (final segment in layout.segments) {
    final bytes = Uint8List.sublistView(jpeg, segment.offset, segment.end);
    if (segment.marker == jpegApp0) {
      if (app0 == null && segment.startsWith(jpeg, 'JFIF\x00')) {
        app0 = bytes;
      }
    } else if (segment.marker == jpegApp2) {
      if (segment.startsWith(jpeg, _iccSignature)) {
        icc.add(bytes);
      }
    } else if (segment.marker == jpegApp14) {
      rest.add(bytes);
    } else if (segment.isApp || segment.marker == jpegCom) {
      // EXIF, XMP, MPF, APP3 to APP13, APP15, comments
    } else {
      rest.add(bytes);
    }
  }
  rest.add(const [0xFF, jpegEoi]);
  final poster = SplatPoster(
    app0: app0,
    icc: icc.isNotEmpty && _isRgbIcc(icc.first) ? icc : const [],
    rest: rest.takeBytes(),
    width: layout.width,
    height: layout.height,
  );
  if (poster.length > splatPhotoPosterMaxBytes) {
    throw SplatPhotoWriteException(SplatPhotoWriteProblem.posterTooLarge, '${poster.length} bytes');
  }
  return poster;
}

/// A marker segment of [marker] holding [signature] then [payload]
Uint8List _segment(int marker, List<int> signature, List<int> payload) {
  final length = signature.length + payload.length + 2;
  if (length - 2 > jpegMaxSegmentPayload) {
    throw SplatPhotoWriteException(SplatPhotoWriteProblem.packetTooLate, 'a segment of $length bytes');
  }
  return (BytesBuilder(copy: false)
        ..add([0xFF, marker, length >> 8, length & 0xFF])
        ..add(signature)
        ..add(payload))
      .takeBytes();
}

/// The head of a splat photo: [poster] with the EXIF [exif] (from "Exif\0\0" on) and the packet [xmp], up to the EOI
/// of the poster; throws [SplatPhotoWriteProblem.packetTooLate] when the packet would end past byte 65,536
Uint8List assembleSplatPhotoHead({required SplatPoster poster, required Uint8List exif, required String xmp}) {
  final out = BytesBuilder(copy: false)..add(const [0xFF, jpegSoi]);
  if (poster.app0 case final app0?) {
    out.add(app0);
  }
  out.add(_segment(jpegApp1, const [], exif));
  out.add(_segment(jpegApp1, xmpSignature, utf8.encode(xmp)));
  if (out.length > splatPhotoPacketWithin) {
    throw SplatPhotoWriteException(SplatPhotoWriteProblem.packetTooLate, 'the packet ends at ${out.length}');
  }
  for (final chunk in poster.icc) {
    out.add(chunk);
  }
  out.add(poster.rest);
  return out.takeBytes();
}

/// What a splat photo says of itself beyond its scene: the [name] of the SPZ, the scene's [date] and place, the
/// orientation chosen before saving, what made the poster, and the words of the packet
class SplatPhotoMeta {
  const SplatPhotoMeta({
    required this.name,
    required this.date,
    required this.software,
    required this.creatorTool,
    this.description,
    this.sourceSha256,
    this.up,
    this.poster,
    this.origin = splatPhotoOriginUnknown,
    this.latitude,
    this.longitude,
    this.quality,
  });

  /// SplatName: the name of the SPZ, "salon_splat.spz" for the PLY "salon.ply" converted
  final String name;

  /// The scene's date: DateTimeOriginal of the EXIF, Immuch360:Created, the dates of the upload
  final SplatPhotoDate date;

  /// Software of the EXIF, "Immuch360 3.3.0"
  final String software;

  /// xmp:CreatorTool, "Immuch360 3.3.0 (windows)"
  final String creatorTool;

  /// dc:description, the caption in the app's language
  final String? description;

  /// The SHA-256 of the file the user saved, when it is not the SPZ itself (a PLY converted)
  final String? sourceSha256;
  final String? up;
  final SplatPosterKind? poster;
  final String origin;
  final double? latitude;
  final double? longitude;

  /// SplatQuality: the quality of a scene of the splat maker ("headset", "detailed", "maximum"), when the save knows it
  final String? quality;
}

/// The packet of a splat photo of the SPZ whose head is [head], [length] bytes summing to [sha256], told by [meta]
SplatPhotoXmp splatPhotoXmpOf({
  required SplatHead head,
  required int length,
  required String sha256,
  required SplatPhotoMeta meta,
}) => SplatPhotoXmp(
  splatVersion: head.formatVersion,
  splatGaussians: head.gaussians,
  splatShDegree: head.shDegree,
  splatLength: length,
  splatSha256: sha256,
  splatName: meta.name,
  splatSourceSha256: meta.sourceSha256 ?? sha256,
  splatUp: splatPhotoUps.contains(meta.up) ? meta.up : null,
  splatPoster: meta.poster,
  origin: meta.origin,
  created: meta.date.iso,
  creatorTool: meta.creatorTool,
  description: meta.description,
  splatQuality: meta.quality,
);

/// The head of a splat photo (everything before its scene) for [poster], the scene told by [xmp]
Uint8List splatPhotoHeadOf({required SplatPoster poster, required SplatPhotoXmp xmp, required SplatPhotoMeta meta}) =>
    assembleSplatPhotoHead(
      poster: poster,
      exif: splatPhotoExif(
        width: poster.width,
        height: poster.height,
        software: meta.software,
        taken: meta.date,
        latitude: meta.latitude,
        longitude: meta.longitude,
      ),
      xmp: xmp.toXml(),
    );

/// What the first pass over an SPZ found: its head, its length, its SHA-256
class SplatPhotoScene {
  const SplatPhotoScene({required this.head, required this.length, required this.sha256});

  final SplatHead head;
  final int length;
  final String sha256;
}

/// Checks that [length] bytes read by [read] are an SPZ a splat photo carries, and sums them: the first pass. Reads
/// [chunk] bytes at a time, [onProgress] told the share done, [cancelled] asked between reads.
Future<SplatPhotoScene> inspectSplatPhotoScene(
  Future<List<int>> Function(int offset, int length) read,
  int length, {
  int chunk = splatPhotoChunk,
  void Function(double done)? onProgress,
  bool Function()? cancelled,
}) async {
  if (length < splatPhotoMinLength || length > splatPhotoMaxLength) {
    throw SplatPhotoWriteException(SplatPhotoWriteProblem.spzSize, '$length bytes');
  }
  final first = await read(0, math.min(splatHeadBytes, length));
  final probe = probeSplatHead(Uint8List.fromList(first), length);
  if (probe is! SplatHead || probe.format != SplatFormat.spz) {
    throw SplatPhotoWriteException(SplatPhotoWriteProblem.notSpz, '$probe');
  }
  final sum = _Sum(sha256);
  for (var offset = 0; offset < length; offset += chunk) {
    if (cancelled?.call() ?? false) {
      throw const SplatPhotoWriteException(SplatPhotoWriteProblem.cancelled);
    }
    final want = math.min(chunk, length - offset);
    final bytes = await read(offset, want);
    if (bytes.length != want) {
      throw SplatPhotoWriteException(SplatPhotoWriteProblem.changed, '${bytes.length} bytes of $want at $offset');
    }
    sum.add(bytes);
    onProgress?.call((offset + want) / length);
  }
  return SplatPhotoScene(head: probe, length: length, sha256: sum.hex());
}

/// A splat photo written: its [file], its [length] and the SHA-1 of the whole file in hexadecimal, its packet, its
/// head's length
class SplatPhotoWritten {
  const SplatPhotoWritten({
    required this.file,
    required this.length,
    required this.sha1,
    required this.xmp,
    required this.headLength,
  });

  final File file;
  final int length;
  final String sha1;
  final SplatPhotoXmp xmp;
  final int headLength;

  int get posterBytes => headLength;
}

/// Writes the splat photo of the SPZ read by [read] ([length] bytes) with the poster [posterJpeg] into [sink] (see
/// the top of this file): both passes, [onProgress] told the share done of the whole job. Gives the packet, the head's
/// length and the SHA-1 of what went to [sink].
Future<(SplatPhotoXmp, int, String)> writeSplatPhoto({
  required Future<List<int>> Function(int offset, int length) read,
  required int length,
  required Uint8List posterJpeg,
  required SplatPhotoMeta meta,
  required FutureOr<void> Function(List<int> bytes) sink,
  int chunk = splatPhotoChunk,
  void Function(double done)? onProgress,
  bool Function()? cancelled,
}) async {
  final poster = cleanSplatPoster(posterJpeg);
  final scene = await inspectSplatPhotoScene(
    read,
    length,
    chunk: chunk,
    onProgress: onProgress == null ? null : (done) => onProgress(done / 2),
    cancelled: cancelled,
  );
  final xmp = splatPhotoXmpOf(head: scene.head, length: length, sha256: scene.sha256, meta: meta);
  final head = splatPhotoHeadOf(poster: poster, xmp: xmp, meta: meta);
  final whole = _Sum(sha1);
  final again = _Sum(sha256);
  whole.add(head);
  await sink(head);
  for (var offset = 0; offset < length; offset += chunk) {
    if (cancelled?.call() ?? false) {
      throw const SplatPhotoWriteException(SplatPhotoWriteProblem.cancelled);
    }
    final want = math.min(chunk, length - offset);
    final bytes = await read(offset, want);
    if (bytes.length != want) {
      throw SplatPhotoWriteException(SplatPhotoWriteProblem.changed, '${bytes.length} bytes of $want at $offset');
    }
    again.add(bytes);
    whole.add(bytes);
    await sink(bytes);
    onProgress?.call(0.5 + (offset + want) / length / 2);
  }
  if (again.hex() != scene.sha256) {
    throw const SplatPhotoWriteException(SplatPhotoWriteProblem.changed, 'another SHA-256 at the second pass');
  }
  return (xmp, head.length, whole.hex());
}

/// Writes the splat photo of the SPZ [spz] with the poster [posterJpeg] into [out] (see [writeSplatPhoto]): into
/// `<out>.part` first, renamed once complete, deleted on a failure or a cancel
Future<SplatPhotoWritten> writeSplatPhotoFile({
  required File spz,
  required Uint8List posterJpeg,
  required SplatPhotoMeta meta,
  required File out,
  int chunk = splatPhotoChunk,
  void Function(double done)? onProgress,
  bool Function()? cancelled,
}) async {
  final part = File('${out.path}.part');
  final input = await spz.open();
  RandomAccessFile? output;
  try {
    output = await part.open(mode: FileMode.write);
    final target = output;
    final (xmp, headLength, hex) = await writeSplatPhoto(
      read: (offset, length) async {
        await input.setPosition(offset);
        return input.read(length);
      },
      length: await input.length(),
      posterJpeg: posterJpeg,
      meta: meta,
      sink: target.writeFrom,
      chunk: chunk,
      onProgress: onProgress,
      cancelled: cancelled,
    );
    await target.flush();
    await target.close();
    output = null;
    final length = await part.length();
    final written = await part.rename(out.path);
    return SplatPhotoWritten(file: written, length: length, sha1: hex, xmp: xmp, headLength: headLength);
  } catch (_) {
    await output?.close();
    try {
      await part.delete();
    } on FileSystemException {
      // Never written
    }
    rethrow;
  } finally {
    await input.close();
  }
}

/// [writeSplatPhotoFile] in an isolate of its own: [onProgress] told the share done, [cancel] completed to stop it
/// (the isolate ends at once, the .part is deleted, a [SplatPhotoWriteException] of cancelled thrown)
Future<SplatPhotoWritten> writeSplatPhotoFileInIsolate({
  required File spz,
  required Uint8List posterJpeg,
  required SplatPhotoMeta meta,
  required File out,
  void Function(double done)? onProgress,
  Future<void>? cancel,
}) async {
  final port = ReceivePort();
  final exit = ReceivePort();
  final errors = ReceivePort();
  final done = Completer<SplatPhotoWritten>();
  port.listen((message) {
    if (message is double) {
      onProgress?.call(message);
    } else if (message is (int, String, int) && !done.isCompleted) {
      final (length, hex, headLength) = message;
      done.complete(
        SplatPhotoWritten(
          file: out,
          length: length,
          sha1: hex,
          xmp: SplatPhotoXmp.findIn(_headOf(out)) ?? const SplatPhotoXmp(),
          headLength: headLength,
        ),
      );
    } else if (message is (String, String) && !done.isCompleted) {
      final (problem, detail) = message;
      done.completeError(
        SplatPhotoWriteException(
          SplatPhotoWriteProblem.values.firstWhere(
            (value) => value.name == problem,
            orElse: () => SplatPhotoWriteProblem.changed,
          ),
          detail,
        ),
      );
    }
  });
  var cancelled = false;
  errors.listen((message) {
    if (!done.isCompleted && !cancelled) {
      done.completeError(SplatPhotoWriteException(SplatPhotoWriteProblem.changed, '$message'));
    }
  });
  exit.listen((_) async {
    if (cancelled) {
      // Once the isolate is gone, so that no write of it comes after the delete (Windows refuses to delete a file
      // that is open)
      try {
        await File('${out.path}.part').delete();
      } on FileSystemException {
        // Never written
      }
      if (!done.isCompleted) {
        done.completeError(const SplatPhotoWriteException(SplatPhotoWriteProblem.cancelled));
      }
    } else if (!done.isCompleted) {
      done.completeError(const SplatPhotoWriteException(SplatPhotoWriteProblem.changed, 'the writer stopped'));
    }
  });
  final isolate = await Isolate.spawn(
    _writeMain,
    (port.sendPort, spz.path, posterJpeg, meta, out.path),
    onExit: exit.sendPort,
    onError: errors.sendPort,
  );
  unawaited(
    cancel?.then((_) {
      if (!done.isCompleted && !cancelled) {
        cancelled = true;
        isolate.kill(priority: Isolate.immediate);
      }
    }),
  );
  try {
    return await done.future;
  } finally {
    port.close();
    exit.close();
    errors.close();
  }
}

Uint8List _headOf(File file) {
  final handle = file.openSync();
  try {
    return handle.readSync(splatPhotoHeadBytes);
  } finally {
    handle.closeSync();
  }
}

Future<void> _writeMain((SendPort, String, Uint8List, SplatPhotoMeta, String) job) async {
  final (port, spz, poster, meta, out) = job;
  var last = -1.0;
  try {
    final written = await writeSplatPhotoFile(
      spz: File(spz),
      posterJpeg: poster,
      meta: meta,
      out: File(out),
      onProgress: (done) {
        if (done - last >= 0.01 || done >= 1) {
          last = done;
          port.send(done);
        }
      },
    );
    port.send((written.length, written.sha1, written.headLength));
  } on SplatPhotoWriteException catch (error) {
    port.send((error.problem.name, error.detail));
  } catch (error) {
    port.send((SplatPhotoWriteProblem.changed.name, '$error'));
  }
}

/// A SHA-1 or a SHA-256 fed in pieces
class _Sum {
  _Sum(Hash hash) {
    _input = hash.startChunkedConversion(_sink);
  }

  // Only told the digest, once hex closes the input
  // ignore: close_sinks
  final _sink = _DigestSink();
  late final ByteConversionSink _input;

  void add(List<int> bytes) => _input.add(bytes);

  String hex() {
    _input.close();
    return _sink.value.toString();
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// A SHA-256 fed in pieces, for the readers of the scene (splat_photo_tail.dart)
class SplatSha256 {
  final _sum = _Sum(sha256);
  String? _hex;

  void add(List<int> bytes) => _sum.add(bytes);

  /// The sum in lowercase hexadecimal, once every byte was added
  String hex() => _hex ??= _sum.hex();
}
