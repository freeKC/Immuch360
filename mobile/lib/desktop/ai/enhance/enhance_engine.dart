// The engine of "Enhance (AI)" (release 51): one photo in, the same picture sharper out, in the .part of its job. The
// model of the level runs behind EnhanceBackend (sharpen_backend.dart, rebuild_backend.dart, natural_backend.dart;
// fakes in the tests); around it, this engine:
//  1. reads the photo (never opened for writing) and decodes it upright: a JPEG by the codecs of the app with its EXIF
//     orientation applied, another format by the decoder the caller gives (the app: the engine of Flutter on the root
//     isolate, engine_picture.dart, as the other kinds do); the ICC profile its pixels are in goes with them. This file
//     imports nothing of Flutter, so that a program compiled by `dart compile exe` (tools/enhance_probe.dart) runs it;
//  2. refuses a photo of more than 50 megapixels (tooLarge), and a run while the memory free is below the need of the
//     level (outOfMemory with enhanceMemoryMessage, which the panel says as "close other programs"): sd.cpp refused
//     SeedVR2 three times on the 16 GB laptop of the probe with 1 to 2 GB free;
//  3. runs the model of the level, its tiles told as "step 12 of 63";
//  4. takes the colour fix for Rebuild details (SeedVR2 shifts tones; VOSR takes its own inside Natural), then the
//     strength: the result blended with the photo;
//  5. writes a JPEG of the quality of the original (85 to 97, 92 without one): the EXIF of the version keeps the date
//     taken, its offset and the GPS position of the original, with the orientation 1 since the pixels are written
//     upright (the photo shows the same way); the profile of its pixels; and our XMP packet (EnhancedPhotoXmp): the
//     level, the strength, the model and its sum, Origin GeneratedContent, the IPTC digital source type of trained
//     algorithmic media, the software in CreatorTool and a description that starts with "AI enhanced".
// The heavy pixel work runs in isolates of its own, so that the window stays responsive. Never throws: a failure is an
// ImmersiveResult.failed, the work folder deleted either way.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/codec/dart_sbs_codec.dart' show orientDecoded;
import 'package:immich_mobile/desktop/ai/codec/exif_minimal.dart';
import 'package:immich_mobile/desktop/ai/codec/jpeg_segments.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_chain.dart' show SbsCodecChoice, mergedExif;
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_levels.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_pixels.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_plan.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/desktop/ai/scene/scene_textures.dart' show encodeScenePicture;
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:logging/logging.dart';

final _log = Logger('EnhanceEngine');

/// The message of a refusal for want of memory on the computer, which the panel says as "close other programs"
const enhanceMemoryMessage = 'enhance: not enough memory free on this computer';

/// The message of a card without the integer dot product SeedVR2 needs on it
const enhanceNoIntDotMessage = 'enhance: the graphics card lacks the integer dot product';

/// The model of one level, run on the whole picture
abstract interface class EnhanceBackend {
  /// The model as the XMP names it, "Real-ESRGAN x4plus"
  String get model;

  /// The SHA-256 of its weights
  String get modelSha256;

  /// Whether the last run said part of its work fell back to the processor
  bool get fellBack;

  /// The enhanced [picture] (upright RGBA), the same size, before the colour fix and the strength. [onStep] tells the
  /// tiles done of all. Throws [BackendException]: cancelled when [cancel] stopped it, outOfMemory with
  /// [enhanceMemoryMessage] when the engine refused for memory, gpuUnavailable, generatorFailed...
  Future<Uint8List> enhance(
    SbsDecoded picture, {
    required String workFolder,
    required int seed,
    required NativeCancelFlag cancel,
    required void Function(int done, int all) onStep,
  });
}

/// The photo decoded upright, the EXIF its version keeps and the JPEG quality of the original (null without one)
typedef EnhancePhoto = ({SbsDecoded picture, ImmersiveExif exif, int? quality});

/// [bytes] decoded upright when they are a JPEG the codecs of [choice] read; null for another format. Throws
/// [FormatException] for a JPEG no codec decodes. Pure: runs in an isolate.
EnhancePhoto? decodeEnhanceJpeg(Uint8List bytes, ImmersiveExif jobExif, {SbsCodecChoice choice = SbsCodecChoice.auto}) {
  if (bytes.length < 3 || bytes[0] != 0xFF || bytes[1] != 0xD8) {
    return null;
  }
  final JpegHeader header;
  try {
    header = JpegHeader.read(bytes);
  } on FormatException {
    return null;
  }
  final codecs = choice.codecs();
  SbsCodecException? last;
  for (final codec in codecs) {
    try {
      final decoded = codec.decodeJpeg(bytes);
      return (
        picture: orientDecoded(decoded, orientation: exifOrientation(header.exif)),
        exif: mergedExif(jobExif, keptExif(header.exif)),
        quality: header.estimatedQuality,
      );
    } on SbsCodecException catch (error) {
      last = error;
    }
  }
  throw FormatException(last?.message ?? 'No codec decodes this JPEG');
}

/// The JPEG of an enhanced photo: [picture] at [quality] with the EXIF of [exif] (orientation 1, the pixels upright),
/// the packet [xmp] and the profile of the pixels. Pure: runs in an isolate.
Uint8List encodeEnhancedJpeg(
  SbsDecoded picture, {
  required int quality,
  required ImmersiveExif exif,
  required String xmp,
  SbsCodecChoice choice = SbsCodecChoice.auto,
}) => encodeScenePicture(choice.codecs(), picture, quality: quality, exif: minimalExif(exif), xmp: xmp).$1;

/// The colour fix (Rebuild details) and the strength of [level] on [result], against [original]. Pure.
Uint8List finishEnhanced(
  Uint8List result,
  Uint8List original,
  int width,
  int height,
  EnhanceLevel level,
  int strength,
) {
  if (level == EnhanceLevel.rebuild) {
    colourFix(result, original, width, height);
  }
  blendStrength(result, original, strength / 100);
  return result;
}

/// The words of a level in the description of the file
String enhanceLevelWords(EnhanceLevel level) => switch (level) {
  EnhanceLevel.sharpen => 'Sharpen',
  EnhanceLevel.rebuild => 'Rebuild details',
  EnhanceLevel.natural => 'Natural',
};

class _Stop implements Exception {
  const _Stop(this.code, [this.message]);

  final ImmersiveErrorCode code;
  final String? message;
}

/// See the top of this file
class EnhanceEngine implements ImmersiveEngine {
  EnhanceEngine({
    required this.backend,
    required this.workFolder,
    this.codecs = SbsCodecChoice.auto,
    this.memory = const SystemMemoryProbe(),
    Future<SbsDecoded> Function(Uint8List bytes)? decodeOther,
    this.dropWorkFolder,
  }) : _decodeOther = decodeOther ?? _noOtherDecoder;

  final EnhanceBackend backend;

  /// The empty work folder of a job
  final Directory Function(String jobId) workFolder;

  /// Deletes the work folder once the job ended; null: deleted here
  final void Function(Directory folder)? dropWorkFolder;
  final SbsCodecChoice codecs;
  final MemoryProbe memory;

  /// The decoder of a photo that is not a JPEG: the app gives decodeWithEngine (engine_picture.dart); without one, such
  /// a photo is unsupportedFormat
  final Future<SbsDecoded> Function(Uint8List bytes) _decodeOther;

  static Future<SbsDecoded> _noOtherDecoder(Uint8List bytes) async =>
      throw const SbsCodecException('No decoder for this format here, only JPEG');

  @override
  Future<ImmersiveResult> run(
    EnhanceJob job, {
    required NativeCancelFlag cancel,
    void Function(ImmersiveProgress progress)? onProgress,
  }) async {
    final times = <ImmersiveStage, Duration>{};
    var stage = ImmersiveStage.reading;
    final clock = Stopwatch()..start();
    void enter(ImmersiveStage next, int perMille, {int? step, int? steps}) {
      if (next != stage) {
        times[stage] = (times[stage] ?? Duration.zero) + clock.elapsed;
        clock.reset();
        stage = next;
      }
      // The time left of the tiles, at the pace of those done
      final left = step != null && steps != null && step > 0
          ? Duration(microseconds: clock.elapsed.inMicroseconds * (steps - step) ~/ step)
          : null;
      onProgress?.call(ImmersiveProgress(next, perMille, step: step, steps: steps, remaining: left));
    }

    void check() {
      if (cancel.isCancelled) {
        throw const _Stop(ImmersiveErrorCode.cancelled);
      }
    }

    Directory? folder;
    try {
      enter(ImmersiveStage.reading, 0);
      final source = job.source;
      final Uint8List bytes;
      try {
        bytes = source.bytes ?? await File(source.path!).readAsBytes();
      } on FileSystemException catch (error) {
        throw _Stop(ImmersiveErrorCode.sourceLost, error.osError?.message ?? error.message);
      }
      check();

      enter(ImmersiveStage.decoding, 20);
      final jobExif = job.exif;
      final codecs = this.codecs;
      EnhancePhoto? photo;
      try {
        photo = await Isolate.run(() => decodeEnhanceJpeg(bytes, jobExif, choice: codecs), debugName: 'enhance-decode');
      } on FormatException catch (error) {
        throw _Stop(ImmersiveErrorCode.decodeFailed, error.message);
      }
      if (photo == null) {
        try {
          photo = (picture: await _decodeOther(bytes), exif: jobExif, quality: null);
        } on SbsCodecException catch (error) {
          throw _Stop(ImmersiveErrorCode.unsupportedFormat, error.message);
        }
      }
      final picture = photo.picture;
      final width = picture.width;
      final height = picture.height;
      if (width * height > enhanceMaxPixels) {
        throw _Stop(ImmersiveErrorCode.tooLarge, '$width x $height is more than ${enhanceMaxPixels ~/ 1000000} MP');
      }
      final available = memory.read().available;
      final need = enhanceFreeMemoryOf(job.level, pixels: width * height);
      if (available != null && available < need) {
        throw _Stop(
          ImmersiveErrorCode.outOfMemory,
          '$enhanceMemoryMessage (${available >> 20} MiB free, ${need >> 20} MiB needed)',
        );
      }
      check();

      enter(ImmersiveStage.loadingModels, 60);
      folder = workFolder(job.id);
      final Uint8List result;
      try {
        result = await backend.enhance(
          picture,
          workFolder: folder.path,
          seed: job.seed,
          cancel: cancel,
          onStep: (done, all) =>
              enter(ImmersiveStage.generating, all == 0 ? 80 : 80 + 780 * done ~/ all, step: done, steps: all),
        );
      } on BackendException catch (error) {
        throw _Stop(error.code, error.message);
      }
      check();
      if (result.length != picture.rgba.length) {
        throw const _Stop(ImmersiveErrorCode.outputRejected, 'The model gave a picture of another size');
      }

      enter(ImmersiveStage.pasteBack, 870);
      final original = picture.rgba;
      final level = job.level;
      final strength = job.strength;
      final finished = await Isolate.run(
        () => finishEnhanced(result, original, width, height, level, strength),
        debugName: 'enhance-finish',
      );
      check();

      enter(ImmersiveStage.encoding, 920);
      final xmp = EnhancedPhotoXmp.enhanced(
        level: level.xmp,
        levelName: enhanceLevelWords(level),
        strength: strength,
        model: backend.model,
        modelSha256: backend.modelSha256,
        width: width,
        height: height,
        sourceName: job.original.name,
        sourceSize: job.original.size,
        sourceSha1: job.original.sha1,
        created: job.created,
        creatorTool: job.creatorTool,
        derivativeId: job.derivativeId,
      ).toXml();
      final exif = photo.exif;
      final quality = sbsQualityFor(photo.quality);
      final profile = picture.iccProfile;
      final Uint8List jpeg;
      try {
        jpeg = await Isolate.run(
          () => encodeEnhancedJpeg(
            SbsDecoded(width: width, height: height, rgba: finished, iccProfile: profile),
            quality: quality,
            exif: exif,
            xmp: xmp,
            choice: codecs,
          ),
          debugName: 'enhance-encode',
        );
      } on SbsCodecException catch (error) {
        throw _Stop(ImmersiveErrorCode.writeFailed, error.message);
      }
      check();

      enter(ImmersiveStage.writing, 980);
      try {
        await File(job.partPath).writeAsBytes(jpeg, flush: true);
      } on FileSystemException catch (error) {
        final code = isEnhanceDiskFull(error) ? ImmersiveErrorCode.diskFull : ImmersiveErrorCode.writeFailed;
        throw _Stop(code, error.osError?.message ?? error.message);
      }
      times[stage] = (times[stage] ?? Duration.zero) + clock.elapsed;
      return ImmersiveResult.made(
        details: EnhanceResultDetails(
          width: width,
          height: height,
          level: level,
          strength: strength,
          model: backend.model,
          fellBack: backend.fellBack,
        ),
        bytesWritten: jpeg.length,
        stageTimes: times,
      );
    } on _Stop catch (stop) {
      if (stop.code != ImmersiveErrorCode.cancelled) {
        _log.warning('Enhance ${job.id} (${job.level.name}) failed: ${stop.code.name} ${stop.message ?? ''}');
      }
      return ImmersiveResult.failed(stop.code, message: stop.message, stageTimes: times);
    } catch (error, stack) {
      _log.warning('Enhance ${job.id} failed', error, stack);
      return ImmersiveResult.failed(ImmersiveErrorCode.modelFailed, message: '$error', stageTimes: times);
    } finally {
      final made = folder;
      if (made != null) {
        final drop = dropWorkFolder;
        if (drop != null) {
          drop(made);
        } else {
          try {
            if (made.existsSync()) {
              made.deleteSync(recursive: true);
            }
          } on FileSystemException catch (error) {
            _log.warning('The work folder ${made.path} could not be deleted: $error');
          }
        }
      }
    }
  }

  @override
  Future<void> dispose() async {}
}

/// Whether [error] says the drive is full: ENOSPC (28) elsewhere, ERROR_DISK_FULL (112) or ERROR_HANDLE_DISK_FULL (39)
bool isEnhanceDiskFull(FileSystemException error) {
  final code = error.osError?.errorCode;
  return Platform.isWindows ? code == 112 || code == 39 : code == 28;
}
