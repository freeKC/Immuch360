// The photos of a splat scene made ready for COLMAP (plan 2026-11-01, section 2.2, lot SP5): each turned upright by its
// EXIF orientation, reduced to 1 600 pixels on its longest side and written as a JPEG of quality 95 with a minimal
// EXIF that keeps its camera and focal length (exif_minimal.dart, splatPhotoExif), one folder per camera and size so
// that COLMAP gives each its own intrinsics (--ImageReader.single_camera_per_folder). Those that cannot be read, the
// 360° ones and the blurred ones (sharpness.dart) are left out with their reason; at most 200 photos are taken, spread
// evenly in time, and fewer than 20 usable ones make no scene.
//
// The members are read one after the other, in the order of time, and each is released as soon as its bytes are read:
// an original of the server is never more than one copy on the disk. The decoding, the reduction, the sharpness and
// the encoding run in isolates, a few photos at once (about 100 MB each for 12 Mpx) while the next one is read. On the
// PC (i9-13980HX, WSL, flutter test, the 55 photos of 11.9 Mpx of the skull of the measure, 1 November 2026): 14.2 s
// one at a time, 10.3 to 12.7 s two at once, 3.8 to 5.1 s eight at once; four took 15 s, their first photos waiting
// 10 s for the compiler of the test, which the app's compiled build does not have; with COLMAP of another job running
// alongside, 17 to 70 s. A photo the JPEG codec does not read (HEIC, PNG...) is decoded by the engine on the root
// isolate first, as for a 3D photo (engine_picture.dart). A photo twice as large as 1 600 pixels or more is halved by
// 2 x 2 averages first, before it is turned, then reduced by area average: the picture of one area average, at less
// cost. The frames of a video are taken by video_frames.dart into the same shape.

import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/codec/dart_sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/codec/engine_picture.dart';
import 'package:immich_mobile/desktop/ai/codec/exif_minimal.dart';
import 'package:immich_mobile/desktop/ai/codec/jpeg_segments.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/write_failure.dart';
import 'package:immich_mobile/desktop/ai/engine/dart_immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_chain.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/splat/sharpness.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/desktop/library/library_metadata.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/services/raw/raw_360_detection.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('SplatInputs');

/// Why a photo or a frame is not used for the scene
enum SplatLeftOutReason {
  /// It could not be read or decoded here (a HEIC on Linux, a damaged file, an original that could not be reached)
  unreadable,

  /// Blurred: much less sharp than the images taken just before and after it
  blurred,

  /// A 360° photo, not taken yet
  sphere,
}

/// A photo, or a moment of a video, left out of the scene, with its reason
class SplatLeftOut {
  const SplatLeftOut(this.name, this.reason, [this.detail]);

  /// The name of the original ("DSCF4667.JPG"), or the moment of the video ("1:02.4")
  final String name;
  final SplatLeftOutReason reason;

  /// What the system said, for the log; never shown as it is
  final String? detail;

  @override
  String toString() => 'SplatLeftOut($name, ${reason.name}${detail == null ? '' : ', $detail'})';
}

/// One image ready for COLMAP: images/[folder]/[name], [width] x [height], upright
class SplatImage {
  const SplatImage({
    required this.folder,
    required this.name,
    required this.width,
    required this.height,
    required this.sharpness,
    required this.source,
  });

  /// The folder of its camera ("cam1"), or "video"
  final String folder;

  /// "00001.jpg": the images are numbered in the order of time, which the sequential matching of a video follows
  final String name;
  final int width;
  final int height;

  /// The variance of the Laplacian of its grey copy (sharpness.dart)
  final double sharpness;

  /// The original it comes from ("DSCF4667.JPG"), or the moment of the video ("1:02.4")
  final String source;

  /// Its path under the images folder, as COLMAP names it
  String get relativePath => '$folder/$name';
}

/// What the preparation gives: the [images] ready for COLMAP in the order of time, those [leftOut] with their reason,
/// out of [total] photos or frames, and the camera of each folder ("cam1": "Canon EOS REBEL T3 55 mm")
class SplatInputs {
  const SplatInputs({
    required this.images,
    required this.leftOut,
    required this.total,
    this.cameras = const {},
    this.fromVideo = false,
  });

  final List<SplatImage> images;
  final List<SplatLeftOut> leftOut;
  final int total;
  final Map<String, String?> cameras;
  final bool fromVideo;

  /// Those left out as blurred (SplatResultDetails.blurred)
  int get blurred => leftOut.where((image) => image.reason == SplatLeftOutReason.blurred).length;

  /// Whether there are enough images for a scene (SplatV1.minImages); otherwise the job fails as tooFewImages with
  /// [countsMessage]
  bool get isEnough => images.length >= SplatV1.minImages;

  /// "12/150", the message of a tooFewImages failure
  String get countsMessage => splatCountsMessage(images.length, total);
}

/// The photos a scene is made from, in the order of time: all of them up to [max], otherwise [max] spread evenly in
/// time (the first and the last always taken); [total] is how many were chosen
class SplatPhotoPlan {
  const SplatPhotoPlan(this.taken, this.total);

  final List<SplatMember> taken;
  final int total;

  /// "200 photos at most: 200 of these 512 are used, spread evenly in time"
  bool get isCapped => taken.length < total;
}

/// [members] in the order of time (those without a date after the others, by name), [max] of them at most, spread
/// evenly in time
SplatPhotoPlan planSplatPhotos(List<SplatMember> members, {int max = SplatV1.maxPhotos}) {
  final sorted = [...members]..sort(compareSplatMembers);
  if (sorted.length <= max) {
    return SplatPhotoPlan(sorted, sorted.length);
  }
  final last = sorted.length - 1;
  return SplatPhotoPlan([for (var i = 0; i < max; i++) sorted[(i * last / (max - 1)).round()]], sorted.length);
}

/// The order of the members of a scene: by the time they were taken, those without a date after, then by name
int compareSplatMembers(SplatMember a, SplatMember b) {
  final aTaken = a.taken;
  final bTaken = b.taken;
  if (aTaken != null && bTaken != null) {
    final byTime = aTaken.compareTo(bTaken);
    if (byTime != 0) {
      return byTime;
    }
  } else if (aTaken != null || bTaken != null) {
    return aTaken != null ? -1 : 1;
  }
  return a.name.compareTo(b.name);
}

/// How many photos are prepared at once: a third of the processors, from one to eight (see the top of this file)
int splatPhotosAtOnce() => math.max(1, math.min(8, Platform.numberOfProcessors ~/ 3));

/// The name of the image at [index] (from 0) in the order of time: "00001.jpg"
String splatImageName(int index) => '${(index + 1).toString().padLeft(5, '0')}.jpg';

/// The folder the images are written to before the blurred ones are known, under the images folder
const _staging = '.staging';

/// Prepares [photos] (in the order of time, see [planSplatPhotos]) into [imagesFolder], emptied first: each read,
/// released, turned upright, reduced to [longSide], its sharpness measured, written as a JPEG of [quality]; then the
/// blurred ones left out and the others moved to one folder per camera and size, numbered in the order of time.
/// [onProgress] gets the photos done of all. [decodeOther] decodes what the JPEG codec does not read (the engine by
/// default, root isolate only). [atOnce] photos are prepared at once ([splatPhotosAtOnce] by default), while the next
/// one is read. Throws a ConversionException: cancelled once [cancel] is set, diskFull or readOnly when an image
/// cannot be written, the one of a member that is neither lost nor unreadable.
Future<SplatInputs> prepareSplatPhotos(
  List<SplatMember> photos, {
  required String imagesFolder,
  required NativeCancelFlag cancel,
  void Function(int done, int total)? onProgress,
  OtherPhotoDecoder? decodeOther,
  int? atOnce,
  SbsCodecChoice codec = SbsCodecChoice.auto,
  int longSide = SplatV1.photoLongSide,
  int quality = SplatV1.photoQuality,
}) async {
  final decode = decodeOther ?? decodeWithEngine;
  final total = photos.length;
  final images = Directory(imagesFolder);
  if (images.existsSync()) {
    await images.delete(recursive: true);
  }
  final staging = await Directory(p.join(imagesFolder, _staging)).create(recursive: true);

  final results = List<_PreparedPhoto?>.filled(total, null);
  final leftOutAt = <int, SplatLeftOut>{};
  final running = <Future<void>>{};
  var done = 0;
  Object? failure;
  StackTrace? failureStack;
  void finished() => onProgress?.call(++done, total);

  void checkCancel() {
    if (cancel.isCancelled) {
      throw const ConversionException(ImmersiveErrorCode.cancelled);
    }
  }

  try {
    for (var index = 0; index < total; index++) {
      checkCancel();
      if (failure != null) {
        break;
      }
      final member = photos[index];
      final read = await _readMember(member, cancel);
      if (read.leftOut != null) {
        leftOutAt[index] = read.leftOut!;
        finished();
        continue;
      }
      final bytes = read.bytes!;
      SbsDecoded? decoded;
      if (photoFormatOf(bytes) != PhotoFormat.jpeg) {
        try {
          decoded = await decode(bytes);
        } on SbsCodecException catch (error) {
          leftOutAt[index] = SplatLeftOut(member.name, SplatLeftOutReason.unreadable, error.message);
          finished();
          continue;
        }
      }
      // The next one is read while this one waits for its turn
      while (running.length >= (atOnce ?? splatPhotosAtOnce())) {
        await Future.any(running);
      }
      checkCancel();
      final request = _PhotoRequest(
        name: member.name,
        bytes: decoded == null ? TransferableTypedData.fromList([bytes]) : null,
        pixels: decoded == null ? null : TransferableTypedData.fromList([decoded.rgba]),
        width: decoded?.width ?? 0,
        height: decoded?.height ?? 0,
        out: p.join(staging.path, splatImageName(index)),
        codec: codec,
        longSide: longSide,
        quality: quality,
      );
      late final Future<void> task;
      task = _prepareInBackground(request)
          .then((prepared) {
            if (prepared.leftOut != null) {
              leftOutAt[index] = SplatLeftOut(member.name, prepared.leftOut!, prepared.detail);
            } else {
              results[index] = prepared;
            }
            finished();
          })
          .catchError((Object error, StackTrace stack) {
            if (failure == null) {
              failure = error;
              failureStack = stack;
            }
          })
          .whenComplete(() => running.remove(task));
      running.add(task);
    }
    await Future.wait(running);
    if (failure case final error?) {
      Error.throwWithStackTrace(error, failureStack ?? StackTrace.current);
    }
    checkCancel();
  } on FileSystemException catch (error) {
    throw ConversionException(writeFailureOf(error).errorCode, error.osError?.message ?? error.message);
  } finally {
    // A cancel or a failure lets the photos under way end (a second at most) before the job ends: none writes into a
    // folder the queue is deleting
    await Future.wait(running.toList());
  }

  // The blurred ones, against the photos kept just before and after them
  final order = [
    for (var index = 0; index < total; index++)
      if (results[index] != null) index,
  ];
  final blurred = blurredAmong([for (final index in order) results[index]!.sharpness]);
  final folders = <String, String>{};
  final cameras = <String, String?>{};
  final kept = <SplatImage>[];
  try {
    for (final (position, index) in order.indexed) {
      final prepared = results[index]!;
      final staged = File(p.join(staging.path, splatImageName(index)));
      if (blurred.contains(position)) {
        leftOutAt[index] = SplatLeftOut(photos[index].name, SplatLeftOutReason.blurred);
        await staged.delete();
        continue;
      }
      final folder = folders.putIfAbsent(prepared.cameraKey, () => 'cam${folders.length + 1}');
      cameras.putIfAbsent(folder, () => prepared.cameraLabel);
      final name = splatImageName(kept.length);
      await Directory(p.join(imagesFolder, folder)).create();
      await staged.rename(p.join(imagesFolder, folder, name));
      kept.add(
        SplatImage(
          folder: folder,
          name: name,
          width: prepared.width,
          height: prepared.height,
          sharpness: prepared.sharpness,
          source: photos[index].name,
        ),
      );
    }
    await staging.delete(recursive: true);
  } on FileSystemException catch (error) {
    throw ConversionException(writeFailureOf(error).errorCode, error.osError?.message ?? error.message);
  }
  final leftOut = [for (var index = 0; index < total; index++) ?leftOutAt[index]];
  final reasons = [
    for (final reason in SplatLeftOutReason.values)
      '${leftOut.where((out) => out.reason == reason).length} ${reason.name}',
  ];
  _log.info('${kept.length} of $total photos prepared in ${folders.length} folders; left out: ${reasons.join(', ')}');
  return SplatInputs(images: kept, leftOut: leftOut, total: total, cameras: cameras);
}

/// The bytes of [member], read then released at once; or why it is left out
Future<({Uint8List? bytes, SplatLeftOut? leftOut})> _readMember(SplatMember member, NativeCancelFlag cancel) async {
  try {
    final source = await member.load(cancel);
    return (bytes: source.bytes ?? await File(source.path!).readAsBytes(), leftOut: null);
  } on ConversionException catch (error) {
    if (error.code != ImmersiveErrorCode.sourceLost &&
        error.code != ImmersiveErrorCode.decodeFailed &&
        error.code != ImmersiveErrorCode.unsupportedFormat) {
      rethrow;
    }
    return (bytes: null, leftOut: SplatLeftOut(member.name, SplatLeftOutReason.unreadable, error.message));
  } on FileSystemException catch (error) {
    return (
      bytes: null,
      leftOut: SplatLeftOut(member.name, SplatLeftOutReason.unreadable, error.osError?.message ?? error.message),
    );
  } finally {
    await member.release();
  }
}

/// What the isolate of a photo is given: plain values only
class _PhotoRequest {
  const _PhotoRequest({
    required this.name,
    required this.bytes,
    required this.pixels,
    required this.width,
    required this.height,
    required this.out,
    required this.codec,
    required this.longSide,
    required this.quality,
  });

  final String name;

  /// The JPEG, or the RGBA [pixels] the engine decoded upright ([width] x [height])
  final TransferableTypedData? bytes;
  final TransferableTypedData? pixels;
  final int width;
  final int height;
  final String out;
  final SbsCodecChoice codec;
  final int longSide;
  final int quality;
}

/// What the isolate of a photo gives back
class _PreparedPhoto {
  const _PreparedPhoto({
    this.width = 0,
    this.height = 0,
    this.sharpness = 0,
    this.cameraKey = '',
    this.cameraLabel,
    this.leftOut,
    this.detail,
  });

  final int width;
  final int height;
  final double sharpness;

  /// What makes two photos one camera for COLMAP: make, model, focal lengths and size
  final String cameraKey;
  final String? cameraLabel;
  final SplatLeftOutReason? leftOut;
  final String? detail;
}

/// [_preparePhoto] in another isolate. Its own function, so that the closure sent there holds the request only, never
/// the state of the preparation (the cancel flag, the members)
Future<_PreparedPhoto> _prepareInBackground(_PhotoRequest request) => Isolate.run(() => _preparePhoto(request));

/// One photo turned upright, reduced, measured and written (see [prepareSplatPhotos]); in an isolate of its own
_PreparedPhoto _preparePhoto(_PhotoRequest request) {
  final codecs = request.codec.codecs();
  SbsDecoded upright;
  var originalLongSide = 0;
  var camera = const CameraExif();
  var sphere = false;
  final pixels = request.pixels;
  if (pixels != null) {
    originalLongSide = math.max(request.width, request.height);
    upright = halvedTo(
      SbsDecoded(width: request.width, height: request.height, rgba: pixels.materialize().asUint8List()),
      request.longSide,
    );
  } else {
    final bytes = request.bytes!.materialize().asUint8List();
    final JpegHeader header;
    try {
      header = JpegHeader.read(bytes);
    } on FormatException catch (error) {
      return _PreparedPhoto(leftOut: SplatLeftOutReason.unreadable, detail: error.message);
    }
    camera = cameraExifOf(header.exif);
    SbsDecoded? decoded;
    String? refusal;
    for (final codec in codecs) {
      try {
        decoded = codec.decodeJpeg(bytes);
        break;
      } on SbsCodecException catch (error) {
        refusal = error.message;
      }
    }
    if (decoded == null) {
      return _PreparedPhoto(leftOut: SplatLeftOutReason.unreadable, detail: refusal);
    }
    originalLongSide = math.max(decoded.width, decoded.height);
    upright = orientDecoded(halvedTo(decoded, request.longSide), orientation: exifOrientation(header.exif));
    try {
      sphere = xmpPacketsOf(bytes).any((packet) => gpanoProjectionOf(packet)?.toLowerCase() == 'equirectangular');
    } on FormatException {
      sphere = false;
    }
    sphere =
        sphere ||
        isEquirectCameraPhoto(
          name: request.name,
          make: camera.make,
          model: camera.model,
          width: upright.width,
          height: upright.height,
          hasDroneXmp: hasDroneDjiXmp(Uint8List.sublistView(bytes, 0, math.min(bytes.length, droneXmpWindow))),
        );
  }
  if (sphere) {
    return const _PreparedPhoto(leftOut: SplatLeftOutReason.sphere);
  }

  final fitted = fitEye(upright, maxWidth: request.longSide, maxHeight: request.longSide);
  final sharpness = sharpnessOf(fitted.rgba, width: fitted.width, height: fitted.height);
  final scaled = camera.scaled(math.max(fitted.width, fitted.height) / originalLongSide);
  Uint8List? jpeg;
  String? refusal;
  for (final codec in codecs) {
    try {
      jpeg = codec.encodeSbs(
        SbsPicture.single(width: fitted.width, height: fitted.height, rgba: fitted.rgba),
        SbsEncodeOptions(quality: request.quality, subsampling: ChromaSubsampling.s420, exif: splatPhotoExif(scaled)),
      );
      break;
    } on SbsCodecException catch (error) {
      refusal = error.message;
    }
  }
  if (jpeg == null) {
    return _PreparedPhoto(leftOut: SplatLeftOutReason.unreadable, detail: refusal);
  }
  File(request.out).writeAsBytesSync(jpeg);
  final focal = camera.focalLength;
  return _PreparedPhoto(
    width: fitted.width,
    height: fitted.height,
    sharpness: sharpness,
    cameraKey:
        '${camera.make ?? ''}|${camera.model ?? ''}|${focal == null ? '' : '${focal.$1}/${focal.$2}'}|'
        '${camera.focalLength35mm ?? ''}|${fitted.width}x${fitted.height}',
    cameraLabel: camera.label,
  );
}

/// [picture] halved by averages of 2 x 2 pixels (each channel rounded half up; an odd last row or column left out) as
/// long as it stays at least [longSide] on its longest side once halved: what fitEye then reduces is less than twice
/// as large as what it makes, and costs half as much
SbsDecoded halvedTo(SbsDecoded picture, int longSide) {
  var current = picture;
  while (math.max(current.width, current.height) ~/ 2 >= longSide) {
    final width = current.width ~/ 2;
    final height = current.height ~/ 2;
    final source = current.rgba;
    final sourceRow = current.width * 4;
    final out = Uint8List(width * height * 4);
    var at = 0;
    for (var y = 0; y < height; y++) {
      var top = 2 * y * sourceRow;
      var bottom = top + sourceRow;
      for (var x = 0; x < width; x++) {
        for (var channel = 0; channel < 4; channel++) {
          out[at + channel] =
              (source[top + channel] +
                  source[top + 4 + channel] +
                  source[bottom + channel] +
                  source[bottom + 4 + channel] +
                  2) >>
              2;
        }
        top += 8;
        bottom += 8;
        at += 4;
      }
    }
    current = SbsDecoded(width: width, height: height, rgba: out, iccProfile: picture.iccProfile);
  }
  return current;
}
