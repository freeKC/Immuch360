// The engine of the 360° panoramas generated around a photo, pano-v1, behind ImmersiveEngine (design-final 2026-10-27,
// sections 4.3, 4.5 and 8.1; lot P3; measure M3, phase23/m3-measures-2026-10-27.md, section 9). A PanoramaJob in,
// `<name>_360.jpg` written to its .part out: an equirectangular JPEG of 6144 x 3072 with GPano, our XMP
// (PanoramaXmp: Origin GeneratedContent, the region of the photo, the part of the sphere it covers, the generator, its
// LoRA, the seed and the steps) and the IPTC digital source type of a composite with generated media, the photo itself
// pasted back. Its 3D version (relief-360-v1, lot P1) is a job of its own the queue chains after it.
//
// The steps, in the order the screens show them (ImmersiveStage.panorama), their shares of the job from M3 (about
// 250 s on an RTX 4060 Laptop: 30 s before the first step, 8.7 s a step, 41 s of upscale, 3 s to finish):
//  1. reading, decoding (0 to 2 %): the sum of the original checked against the one it was queued with, the photo
//     decoded upright and turned as the user sees it (the quarter turns of the job); a photo that is not a JPEG (HEIC,
//     PNG, WebP) is decoded by the engine of the app in the isolate of this engine, for this step and again for the
//     last one;
//  2. fieldOfView (to 3.5 %): from the focal length of its EXIF, else MoGe-2, else 65° (photo_fov.dart). Only the EXIF
//     of a JPEG is read: a photo that is not one goes to MoGe-2 (fovGuessed) even when its file has the focal length;
//  3. projection (to 5 %): the control frame of 2048 x 1024, the photo at its centre and pure green elsewhere,
//     written as a PNG to the work folder of the job, and the part of the sphere the photo covers;
//  4. loadingModels, then generating (to 80 %): the generator (GeneratorBackend: sd-cli of lot P2, on the graphics
//     card) with the fixed prompt, the seed of the job and its steps, "step 12 of 20" and the time left as it goes. Its
//     image is checked on the processor (its size, not grey, no pure green left outside the photo): a refused image
//     is made once more with the next seed, then the job fails as outputRejected and nothing is written;
//  5. seam (to 85 %): the panorama rolled by half a turn, the band of its seam filled in by MI-GAN, rolled back
//     (seam.dart); the flag seam when it stays visible;
//  6. upscale (to 95 %): widened by 32 columns wrapped from the other side, Real-ESRGAN x4 (UpscaleBackend, sd-cli),
//     cut back: 6144 x 3072 with no seam of the upscale;
//  7. pasteBack, encoding, writing (to 100 %): the photo reprojected at that size replaces its region, blended over 2 %
//     of its edge (paste_back.dart); the JPEG at quality 90 with the minimal EXIF of the 3D photos, the XMP and the ICC
//     profile of the photo (its pixels keep their colour space, design 8.7); the file in one write to the .part.
//
// The generator and the upscaler are child processes started from the isolate that runs the engine, the root isolate
// of the app (managed_process.dart: PR_SET_PDEATHSIG follows the thread that started the child). The steps on the
// processor (1 to 3, the check and 5, 7) each run in an isolate of their own (Isolate.run), which opens what it needs
// of MoGe-2 and MI-GAN on ONNX Runtime and gives it back at its end: a panorama lasts minutes, opening the two models
// takes a second, and nothing of the worker of the 3D photos is held meanwhile. Their progress and their result come
// back through one port, in order. The engine builds into a program without Flutter (test/desktop/ai/tools/
// panorama_probe.dart), the measure of the lot on a PC with a graphics card.
//
// The cancel flag is read between two steps and by each step (every 64 rows of a projection, between two regions of
// the seam); the generator and the upscaler stop within a second of it. A cancelled or failed job leaves the .part as
// it found it, and the work folder (`<temp>/immuch360-ai/<job>/`) is deleted at the end of every job. The original is
// never opened for writing.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/codec/dart_sbs_codec.dart' show orientDecoded;
import 'package:immich_mobile/desktop/ai/codec/exif_minimal.dart';
import 'package:immich_mobile/desktop/ai/codec/jpeg_segments.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/creator/write_failure.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_chain.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/engine/thread_priority.dart';
import 'package:immich_mobile/desktop/ai/gen/image_checks.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';
import 'package:immich_mobile/desktop/ai/panorama/control_image.dart';
import 'package:immich_mobile/desktop/ai/panorama/erp_projection.dart';
import 'package:immich_mobile/desktop/ai/panorama/panorama_prompt.dart';
import 'package:immich_mobile/desktop/ai/panorama/paste_back.dart';
import 'package:immich_mobile/desktop/ai/panorama/photo_fov.dart';
import 'package:immich_mobile/desktop/ai/panorama/seam.dart';
import 'package:immich_mobile/desktop/ai/panorama/upscale.dart';
import 'package:immich_mobile/desktop/ai/process/managed_process.dart' show AiWorkFolders;
import 'package:immich_mobile/desktop/ai/scene/migan_inpaint.dart';
import 'package:immich_mobile/desktop/ai/scene/moge_geometry.dart';
import 'package:immich_mobile/desktop/ai/scene/scene_textures.dart' show encodeScenePicture;
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/desktop/library/native_sha1.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:logging/logging.dart';
// Pure Dart rather than Flutter's foundation, so that the engine also builds into a program without Flutter (the
// measure of the 360° panoramas, test/desktop/ai/tools/panorama_probe.dart)
// ignore: depend_on_referenced_packages
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

final _log = Logger('PanoramaEngine');

/// Where each step of a panorama starts, in thousandths of the job (see the top of this file)
abstract final class PanoramaProgress {
  static const reading = 0;
  static const sum = 5;
  static const decoding = 10;
  static const fieldOfView = 20;
  static const projection = 35;
  static const loadingModels = 50;
  static const generating = 100;
  static const seam = 800;
  static const upscale = 850;
  static const pasteBack = 950;
  static const encoding = 970;
  static const writing = 990;
  static const done = 1000;
}

/// The sizes of a panorama: the control frame, the generation, the upscale and the columns wrapped around it; those
/// of pano-v1, smaller ones in the tests
class PanoramaSizes {
  const PanoramaSizes({
    this.controlWidth = PanoV1.controlWidth,
    this.controlHeight = PanoV1.controlHeight,
    this.generationWidth = PanoV1.generationWidth,
    this.generationHeight = PanoV1.generationHeight,
    this.scale = PanoV1.upscale,
    this.padding = PanoV1.upscalePadding,
  });

  final int controlWidth;
  final int controlHeight;
  final int generationWidth;
  final int generationHeight;
  final int scale;
  final int padding;

  int get outputWidth => generationWidth * scale;
  int get outputHeight => generationHeight * scale;
}

/// The next seed after a refused image: another image of the same photo
int nextPanoramaSeed(int seed) => (seed + 1) & 0x7fffffff;

/// Runs a step on the processor: in an isolate of its own in the app and in the measure program; in the caller's in
/// the tests, whose fakes count their calls
typedef PanoramaCompute = Future<void> Function(void Function() step);

/// Each step in an isolate of its own
Future<void> panoramaInIsolate(void Function() step) => Isolate.run(step, debugName: 'ai-panorama');

/// Each step in the isolate of the engine (the tests)
Future<void> panoramaInline(void Function() step) async => step();

/// Decodes a photo that is not a JPEG (HEIC, PNG, WebP...), upright: the engine of Flutter in the app; none in the
/// measure program, which takes JPEG photos only
typedef PanoramaPhotoDecoder = Future<SbsDecoded> Function(Uint8List bytes, {int? maxWidth});

/// The models a panorama runs on the processor, made in the isolate of the step that needs them and given back by
/// their close() at its end
abstract interface class PanoramaModelsSpec {
  /// MoGe-2, asked only for a photo without a focal length; null when there is none (the 65° of M3)
  GeometryBackend? openGeometry();

  /// MI-GAN, for the seam
  InpaintBackend openInpaint();

  /// The SHA-256 of MI-GAN, for the logs
  String get inpaintSha256;
}

/// MoGe-2 ViT-S and MI-GAN on ONNX Runtime, from the files of the AI components
class OrtPanoramaModelsSpec implements PanoramaModelsSpec {
  const OrtPanoramaModelsSpec({
    required this.libraryPath,
    required this.miganPath,
    required this.inpaintSha256,
    this.mogePath,
    this.mogeSha256 = '',
    this.tokens = mogeTokens,
  });

  final String libraryPath;
  final String miganPath;
  final String? mogePath;
  final String mogeSha256;
  final int tokens;

  @override
  final String inpaintSha256;

  OrtSession _open(
    String path,
    OrtSessionSettings settings,
    String? Function(List<OrtTensorSpec>, List<OrtTensorSpec>) refusalOf,
  ) {
    final priority = ComputePriority(ThreadPriorityPlatform.system());
    try {
      // Loaded first, so that what loading starts is not taken for a thread of the session
      final runtime = OrtRuntime.load(libraryPath);
      final session = priority.lowerThreadsBornDuring(() => runtime.openSession(path, settings: settings)).value;
      final refusal = refusalOf(session.inputs, session.outputs);
      if (refusal != null) {
        session.close();
        throw BackendException(ImmersiveErrorCode.modelFailed, refusal);
      }
      return session;
    } on OrtException catch (error) {
      throw BackendException(ImmersiveErrorCode.modelFailed, error.message);
    }
  }

  @override
  GeometryBackend? openGeometry() {
    final path = mogePath;
    if (path == null) {
      return null;
    }
    // Without the arena of ONNX Runtime: 0.9 GB less at the peak of MoGe for the same time (M2)
    final session = _open(path, OrtSessionSettings.forThisComputer().withCpuMemArena(false), mogeRefusalOf);
    return _OwnedGeometry(OrtMogeGeometry(session: () => session, modelSha256: mogeSha256, tokens: tokens), session);
  }

  @override
  InpaintBackend openInpaint() {
    final session = _open(miganPath, OrtSessionSettings.forThisComputer(), miganRefusalOf);
    // The seam hides nothing but itself: the holes keep their pixels, no line of the mean colour along the band
    return _OwnedInpaint(
      OrtMiganInpaint(session: () => session, modelSha256: inpaintSha256, paintHoles: false),
      session,
    );
  }
}

/// A geometry that gives its session back when closed
class _OwnedGeometry implements GeometryBackend {
  _OwnedGeometry(this.inner, this.session);

  final GeometryBackend inner;
  final OrtSession session;

  @override
  int get inputLongSide => inner.inputLongSide;

  @override
  String get modelSha256 => inner.modelSha256;

  @override
  GeometryMaps estimate(Float32List nchw, {required int width, required int height}) =>
      inner.estimate(nchw, width: width, height: height);

  @override
  void close() {
    inner.close();
    session.close();
  }
}

/// What the filling [inpaint] that OrtPanoramaModelsSpec opened gives MI-GAN for [region], the image and the mask: the
/// tests see there that the holes of the seam keep their pixels (openInpaint)
@visibleForTesting
(Uint8List, Uint8List) panoramaMiganInputsOf(InpaintBackend inpaint, InpaintRegion region) =>
    ((inpaint as _OwnedInpaint).inner as OrtMiganInpaint).inputsOf(region);

/// A filling that gives its session back when closed
class _OwnedInpaint implements InpaintBackend {
  _OwnedInpaint(this.inner, this.session);

  final InpaintBackend inner;
  final OrtSession session;

  @override
  int get regionMax => inner.regionMax;

  @override
  String get modelSha256 => inner.modelSha256;

  @override
  Uint8List fill(InpaintRegion region) => inner.fill(region);

  @override
  void close() {
    inner.close();
    session.close();
  }
}

/// What the first step found of the photo
class _Prepared {
  const _Prepared({required this.fov, required this.coverage, required this.exif, required this.decoder});

  final PhotoFov fov;
  final double coverage;
  final ImmersiveExif exif;
  final String? decoder;
}

/// What the check of the generated image and the seam found: a refusal, or the seam measured
class _Joined {
  const _Joined({this.refusal, this.before = 0, this.after = 0, this.regions = 0});

  final String? refusal;
  final double before;
  final double after;
  final int regions;
}

/// What the last step wrote
class _Written {
  const _Written({required this.bytes, this.encoder});

  final int bytes;
  final String? encoder;
}

/// A step that ended with [code]
class _Stop implements Exception {
  const _Stop(this.code, [this.message]);

  final ImmersiveErrorCode code;
  final String? message;
}

/// The messages of a step to the engine: a step entered, its result or its failure, its times
class _Entered {
  const _Entered(this.stage, this.perMille);

  final ImmersiveStage stage;
  final int perMille;
}

class _Ended {
  const _Ended(this.value, this.times);

  final Object? value;
  final Map<ImmersiveStage, Duration> times;
}

class _Failed {
  const _Failed(this.code, this.message, this.times);

  final ImmersiveErrorCode code;
  final String? message;
  final Map<ImmersiveStage, Duration> times;
}

/// The clock of the steps of one step on the processor, which reports each one it enters
class _StepClock {
  _StepClock(this._send, this._isCancelled, this.first);

  final SendPort _send;
  final bool Function() _isCancelled;
  final _watch = Stopwatch()..start();
  ImmersiveStage first;
  late ImmersiveStage _stage = first;
  final times = <ImmersiveStage, Duration>{};

  ImmersiveStage get stage => _stage;

  void enter(ImmersiveStage stage, int perMille) {
    _close();
    _stage = stage;
    _send.send(_Entered(stage, perMille));
    check();
  }

  void check() {
    if (_isCancelled()) {
      throw const _Stop(ImmersiveErrorCode.cancelled);
    }
  }

  bool isCancelled() => _isCancelled();

  void _close() {
    times[_stage] = (times[_stage] ?? Duration.zero) + _watch.elapsed;
    _watch.reset();
  }

  Map<ImmersiveStage, Duration> closed() {
    _close();
    return times;
  }
}

/// A step on the processor: a plain object sent to the isolate that runs it, never a closure of the engine (whose
/// context would hold the queue's callbacks, which no isolate can take)
abstract interface class _Step<T> {
  /// The step the engine is in when this one starts
  ImmersiveStage get first;

  T run(_StepClock clock);
}

/// What runs in the isolate of [step]: its clock on [send] and the cancel flag at [cancelAddress], its result or its
/// failure sent back the same way. Built here, apart from the engine, so that it holds nothing else.
void Function() _entryOf<T>(SendPort send, int cancelAddress, _Step<T> step) => () {
  final clock = _StepClock(send, NativeCancelFlag.readerOf(cancelAddress), step.first);
  try {
    final value = step.run(clock);
    send.send(_Ended(value, clock.closed()));
  } on _Stop catch (stop) {
    send.send(_Failed(stop.code, stop.message, clock.closed()));
  } on BackendException catch (error) {
    send.send(_Failed(error.code, error.message, clock.closed()));
  } on ProjectionCancelled {
    send.send(_Failed(ImmersiveErrorCode.cancelled, null, clock.closed()));
  } on OutOfMemoryError {
    send.send(_Failed(ImmersiveErrorCode.outOfMemory, 'Out of memory at the step ${clock.stage.name}', clock.closed()));
  } catch (error) {
    final code = switch (clock.stage) {
      ImmersiveStage.reading => ImmersiveErrorCode.sourceLost,
      ImmersiveStage.decoding => ImmersiveErrorCode.decodeFailed,
      ImmersiveStage.encoding || ImmersiveStage.writing => ImmersiveErrorCode.writeFailed,
      _ => ImmersiveErrorCode.modelFailed,
    };
    send.send(_Failed(code, '$error', clock.closed()));
  }
};

/// Runs [step] on the processor through [compute]: what it reports and its result come back in order through one
/// port. A failure inside is thrown as a [_Stop] with its code.
Future<T> _onProcessor<T>(
  PanoramaCompute compute,
  int cancelAddress,
  _Step<T> step, {
  required void Function(_Entered entered) onEntered,
  required void Function(Map<ImmersiveStage, Duration> times) onTimes,
}) async {
  final port = ReceivePort();
  final result = Completer<T>();
  port.listen((message) {
    switch (message) {
      case _Entered():
        onEntered(message);
      case _Ended(:final value, :final times):
        onTimes(times);
        if (!result.isCompleted) {
          result.complete(value as T);
        }
      case _Failed(:final code, message: final text, :final times):
        onTimes(times);
        if (!result.isCompleted) {
          result.completeError(_Stop(code, text));
        }
    }
  });
  unawaited(
    compute(_entryOf(port.sendPort, cancelAddress, step)).then(
      (_) {},
      onError: (Object error) {
        if (!result.isCompleted) {
          result.completeError(_Stop(ImmersiveErrorCode.modelFailed, 'A step of the panorama ended: $error'));
        }
      },
    ),
  );
  try {
    return await result.future;
  } finally {
    port.close();
  }
}

/// The photo upright and turned as the user sees it, with the EXIF its panorama keeps and its focal length
class _Upright {
  const _Upright(this.photo, {required this.exif, this.focal35, this.decoder});

  final SbsDecoded photo;
  final ImmersiveExif exif;
  final int? focal35;
  final String? decoder;
}

_Upright _decodeUpright(PanoramaJob job, Uint8List bytes, SbsDecoded? decoded, List<SbsCodec> codecs) {
  if (decoded != null) {
    return _Upright(
      orientDecoded(decoded, quarterTurns: job.quarterTurns),
      exif: job.exif,
      decoder: 'engine',
    );
  }
  final JpegHeader header;
  try {
    header = JpegHeader.read(bytes);
  } on FormatException catch (error) {
    throw _Stop(ImmersiveErrorCode.decodeFailed, 'Not a JPEG this app reads: ${error.message}');
  }
  for (final (index, codec) in codecs.indexed) {
    try {
      final photo = codec.decodeJpeg(bytes);
      return _Upright(
        orientDecoded(photo, orientation: exifOrientation(header.exif), quarterTurns: job.quarterTurns),
        exif: mergedExif(job.exif, keptExif(header.exif)),
        focal35: exifFocalLength35mm(header.exif),
        decoder: codec.name,
      );
    } on SbsCodecException catch (error) {
      if (isMemoryRefusal(error)) {
        throw _Stop(ImmersiveErrorCode.outOfMemory, error.message);
      }
      if (index == codecs.length - 1) {
        throw _Stop(ImmersiveErrorCode.decodeFailed, error.message);
      }
    }
  }
  throw const _Stop(ImmersiveErrorCode.decodeFailed, 'No codec');
}

/// Steps 1 to 3 (see the top of this file)
_Prepared _prepare(
  _StepClock clock, {
  required PanoramaJob job,
  required Uint8List bytes,
  required SbsDecoded? decoded,
  required List<SbsCodec> codecs,
  required PanoramaModelsSpec models,
  required PanoramaSizes sizes,
  required String controlPath,
}) {
  final source = job.source;
  clock.enter(ImmersiveStage.reading, PanoramaProgress.sum);
  if (source.sha1.isNotEmpty) {
    final sum = sha1OfBytes(bytes);
    if (sum != source.sha1) {
      throw _Stop(ImmersiveErrorCode.sourceLost, 'The photo changed after it was chosen (its SHA-1 is now $sum)');
    }
  }

  clock.enter(ImmersiveStage.decoding, PanoramaProgress.decoding);
  final upright = _decodeUpright(job, bytes, decoded, codecs);
  final photo = upright.photo;

  clock.enter(ImmersiveStage.fieldOfView, PanoramaProgress.fieldOfView);
  var fov = photoFovOfExif(photo.width, photo.height, upright.focal35);
  if (fov == null) {
    final geometry = models.openGeometry();
    if (geometry == null) {
      fov = photoFovGuess(photo.width, photo.height);
    } else {
      try {
        fov = photoFovOfModel(photo.width, photo.height, modelFocalOf(photo, geometry));
      } finally {
        geometry.close();
      }
    }
  }

  clock.enter(ImmersiveStage.projection, PanoramaProgress.projection);
  final control = controlFrameOf(
    photo,
    hfov: fov.hfov,
    width: sizes.controlWidth,
    height: sizes.controlHeight,
    isCancelled: clock.isCancelled,
  );
  File(controlPath).writeAsBytesSync(
    encodePngPicture(SbsDecoded(width: control.width, height: control.height, rgba: control.rgba)),
    flush: true,
  );
  return _Prepared(fov: fov, coverage: control.coverage, exif: upright.exif, decoder: upright.decoder);
}

/// The check of the generated image, then step 5 (see the top of this file)
_Joined _join(
  _StepClock clock, {
  required String generatedPath,
  required String controlPath,
  required String wrappedPath,
  required PanoramaSizes sizes,
  required PanoramaModelsSpec models,
}) {
  final report = checkGeneratedFile(generatedPath, controlPath: controlPath);
  final problem = report.problemFor(sizes.generationWidth, sizes.generationHeight);
  if (problem != null) {
    File(generatedPath).deleteSync();
    return _Joined(refusal: problem);
  }
  clock.enter(ImmersiveStage.seam, PanoramaProgress.seam);
  final generated = decodePngPicture(File(generatedPath).readAsBytesSync());
  final inpaint = models.openInpaint();
  final SeamJoin joined;
  try {
    joined = joinSeam(generated.rgba, generated.width, generated.height, inpaint, isCancelled: clock.isCancelled);
  } finally {
    inpaint.close();
  }
  final wrapped = wrapColumns(joined.rgba, generated.width, generated.height, sizes.padding);
  File(wrappedPath).writeAsBytesSync(
    encodePngPicture(SbsDecoded(width: generated.width + 2 * sizes.padding, height: generated.height, rgba: wrapped)),
    flush: true,
  );
  return _Joined(before: joined.before, after: joined.after, regions: joined.regions);
}

/// Step 7 (see the top of this file)
_Written _finish(
  _StepClock clock, {
  required PanoramaJob job,
  required Uint8List bytes,
  required SbsDecoded? decoded,
  required List<SbsCodec> codecs,
  required String upscaledPath,
  required PanoramaSizes sizes,
  required double hfov,
  required ImmersiveExif exif,
  required String xmp,
  required PartWriter writePart,
}) {
  final upscaled = decodePngPicture(File(upscaledPath).readAsBytesSync());
  final wide = (sizes.generationWidth + 2 * sizes.padding) * sizes.scale;
  if (upscaled.width != wide || upscaled.height != sizes.outputHeight) {
    throw _Stop(
      ImmersiveErrorCode.outputRejected,
      'The upscaled image is ${upscaled.width} x ${upscaled.height}, not $wide x ${sizes.outputHeight}',
    );
  }
  final cut = sizes.padding * sizes.scale;
  final generated = SbsDecoded(
    width: sizes.outputWidth,
    height: sizes.outputHeight,
    rgba: cropColumns(upscaled.rgba, upscaled.width, upscaled.height, cut),
  );
  final upright = _decodeUpright(job, bytes, decoded, codecs);
  final photo = photoForFrame(upright.photo, hfov: hfov, frameWidth: sizes.outputWidth);
  final pasted = pastePhotoBack(generated, photo, hfov: hfov, isCancelled: clock.isCancelled);

  clock.enter(ImmersiveStage.encoding, PanoramaProgress.encoding);
  final Uint8List jpeg;
  final String encoder;
  try {
    (jpeg, encoder) = encodeScenePicture(
      codecs,
      SbsDecoded(
        width: sizes.outputWidth,
        height: sizes.outputHeight,
        rgba: pasted,
        iccProfile: upright.photo.iccProfile,
      ),
      quality: PanoV1.quality,
      exif: minimalExif(exif),
      xmp: xmp,
    );
  } on SbsCodecException catch (error) {
    throw _Stop(
      isMemoryRefusal(error) ? ImmersiveErrorCode.outOfMemory : ImmersiveErrorCode.writeFailed,
      error.message,
    );
  }

  clock.enter(ImmersiveStage.writing, PanoramaProgress.writing);
  try {
    writePart(job.partPath, jpeg);
  } catch (error) {
    final failure = writeFailureOf(error);
    throw _Stop(failure.errorCode, error is FileSystemException ? error.osError?.message ?? error.message : '$error');
  }
  return _Written(bytes: jpeg.length, encoder: encoder);
}

/// Steps 1 to 3 as a step on the processor
class _PrepareStep implements _Step<_Prepared> {
  const _PrepareStep({
    required this.job,
    required this.bytes,
    required this.decoded,
    required this.codecs,
    required this.models,
    required this.sizes,
    required this.controlPath,
  });

  final PanoramaJob job;
  final Uint8List bytes;
  final SbsDecoded? decoded;
  final List<SbsCodec> Function() codecs;
  final PanoramaModelsSpec models;
  final PanoramaSizes sizes;
  final String controlPath;

  @override
  ImmersiveStage get first => ImmersiveStage.reading;

  @override
  _Prepared run(_StepClock clock) => _prepare(
    clock,
    job: job,
    bytes: bytes,
    decoded: decoded,
    codecs: codecs(),
    models: models,
    sizes: sizes,
    controlPath: controlPath,
  );
}

/// The check of the generated image and step 5 as a step on the processor
class _JoinStep implements _Step<_Joined> {
  const _JoinStep({
    required this.generatedPath,
    required this.controlPath,
    required this.wrappedPath,
    required this.sizes,
    required this.models,
  });

  final String generatedPath;
  final String controlPath;
  final String wrappedPath;
  final PanoramaSizes sizes;
  final PanoramaModelsSpec models;

  @override
  ImmersiveStage get first => ImmersiveStage.generating;

  @override
  _Joined run(_StepClock clock) => _join(
    clock,
    generatedPath: generatedPath,
    controlPath: controlPath,
    wrappedPath: wrappedPath,
    sizes: sizes,
    models: models,
  );
}

/// Step 7 as a step on the processor
class _FinishStep implements _Step<_Written> {
  const _FinishStep({
    required this.job,
    required this.bytes,
    required this.decoded,
    required this.codecs,
    required this.upscaledPath,
    required this.sizes,
    required this.hfov,
    required this.exif,
    required this.xmp,
    required this.writePart,
  });

  final PanoramaJob job;
  final Uint8List bytes;
  final SbsDecoded? decoded;
  final List<SbsCodec> Function() codecs;
  final String upscaledPath;
  final PanoramaSizes sizes;
  final double hfov;
  final ImmersiveExif exif;
  final String xmp;
  final PartWriter writePart;

  @override
  ImmersiveStage get first => ImmersiveStage.upscale;

  @override
  _Written run(_StepClock clock) {
    clock.enter(ImmersiveStage.pasteBack, PanoramaProgress.pasteBack);
    return _finish(
      clock,
      job: job,
      bytes: bytes,
      decoded: decoded,
      codecs: codecs(),
      upscaledPath: upscaledPath,
      sizes: sizes,
      hfov: hfov,
      exif: exif,
      xmp: xmp,
      writePart: writePart,
    );
  }
}

/// See the top of this file
class PanoramaEngine implements ImmersiveEngine {
  PanoramaEngine({
    required this.generator,
    required this.upscaler,
    required this.models,
    AiWorkFolders? folders,
    this.requiredFiles = const {},
    this.decodeOther,
    this.codecs = _autoCodecs,
    this.compute = panoramaInIsolate,
    this.sizes = const PanoramaSizes(),
    this.loraId = _loraId,
    this.upscalerId = _upscalerId,
    this.writePart = writePartFile,
  }) : folders = folders ?? AiWorkFolders.system();

  /// The generator and the upscaler, on the graphics card
  final GeneratorBackend generator;
  final UpscaleBackend upscaler;

  /// MoGe-2 and MI-GAN, on the processor
  final PanoramaModelsSpec models;

  /// Where the work folder of each job goes
  final AiWorkFolders folders;

  /// The files of the components by path, with their size in bytes where known: checked before each job
  final Map<String, int?> requiredFiles;
  final PanoramaPhotoDecoder? decodeOther;

  /// The JPEG codecs, made in the isolate of each step
  final List<SbsCodec> Function() codecs;
  final PanoramaCompute compute;
  final PanoramaSizes sizes;

  /// The LoRA and the upscaler by their catalogue id, written in the XMP
  final String loraId;
  final String upscalerId;
  final PartWriter writePart;

  Future<void> _last = Future.value();
  var _running = false;
  var _disposed = false;

  /// Whether a job runs: the components are not removed meanwhile
  bool get isRunning => _running;

  @override
  Future<ImmersiveResult> run(
    PanoramaJob job, {
    required NativeCancelFlag cancel,
    void Function(ImmersiveProgress progress)? onProgress,
  }) {
    // One job at a time: a second call waits for the first
    final result = _last.then((_) => _run(job, cancel, onProgress));
    _last = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<ImmersiveResult> _run(
    PanoramaJob job,
    NativeCancelFlag cancel,
    void Function(ImmersiveProgress progress)? onProgress,
  ) async {
    final times = <ImmersiveStage, Duration>{};
    var stage = ImmersiveStage.reading;
    void tell(ImmersiveProgress progress) {
      stage = progress.stage;
      onProgress?.call(progress);
    }

    ImmersiveResult failed(ImmersiveErrorCode code, [String? message]) =>
        ImmersiveResult.failed(code, message: message, stageTimes: times);

    if (_disposed) {
      return failed(ImmersiveErrorCode.modelFailed, 'The engine was disposed');
    }
    _running = true;
    Directory? folder;
    bool? partExisted;
    var made = false;
    final watch = Stopwatch()..start();
    void timed(ImmersiveStage stage) {
      times[stage] = (times[stage] ?? Duration.zero) + watch.elapsed;
      watch.reset();
    }

    void merge(Map<ImmersiveStage, Duration> step) {
      for (final MapEntry(key: stage, value: time) in step.entries) {
        times[stage] = (times[stage] ?? Duration.zero) + time;
      }
    }

    try {
      tell(const ImmersiveProgress(ImmersiveStage.reading, PanoramaProgress.reading));
      if (cancel.isCancelled) {
        return failed(ImmersiveErrorCode.cancelled);
      }
      final missing = await _missingComponent();
      if (missing != null) {
        return failed(ImmersiveErrorCode.componentsMissing, missing);
      }
      final source = job.source;
      final Uint8List bytes;
      try {
        bytes = source.bytes ?? await File(source.path!).readAsBytes();
      } on FileSystemException catch (error) {
        return failed(ImmersiveErrorCode.sourceLost, error.osError?.message ?? error.message);
      }
      if (!_isJpeg(bytes) && decodeOther == null) {
        return failed(ImmersiveErrorCode.unsupportedFormat, 'Only JPEG photos here');
      }
      // A photo that is not a JPEG is decoded here, for the first step, then again for the last one, as a JPEG is
      // decoded by each of its steps: its pixels (about 200 MB at 48 Mpx) are not held through the minutes of the
      // generation, while sd-cli takes up to 6 GB (M3, section 9, point 10)
      var decoded = await _decodedOther(bytes);
      timed(ImmersiveStage.reading);
      partExisted = File(job.partPath).existsSync();
      folder = folders.create(job.id);
      final control = p.join(folder.path, 'control.png');
      final generated = p.join(folder.path, 'generated.png');
      final wrapped = p.join(folder.path, 'wrapped.png');
      final upscaled = p.join(folder.path, 'upscaled.png');
      final light = _withoutBytes(job);
      void entered(_Entered step) => tell(ImmersiveProgress(step.stage, step.perMille));

      // 1 to 3
      watch.reset();
      final prepared = await _onProcessor(
        compute,
        cancel.address,
        _PrepareStep(
          job: light,
          bytes: bytes,
          decoded: decoded,
          codecs: codecs,
          models: models,
          sizes: sizes,
          controlPath: control,
        ),
        onEntered: entered,
        onTimes: merge,
      );
      decoded = null;
      _log.info('${job.id}: ${prepared.fov}, ${(100 * prepared.coverage).toStringAsFixed(2)} % of the sphere');

      // 4, made once more when the image is refused
      var seed = job.seed;
      _Joined? joined;
      for (var attempt = 0; attempt < 2 && joined == null; attempt++) {
        if (cancel.isCancelled) {
          return failed(ImmersiveErrorCode.cancelled);
        }
        if (attempt == 0) {
          tell(const ImmersiveProgress(ImmersiveStage.loadingModels, PanoramaProgress.loadingModels));
        } else {
          seed = nextPanoramaSeed(seed);
        }
        watch.reset();
        String? refusal;
        try {
          await generator.generate(
            GeneratorRequest(
              controlPath: control,
              outputPath: generated,
              workFolder: folder.path,
              prompt: panoramaPrompt,
              seed: seed,
              steps: job.steps,
              width: sizes.generationWidth,
              height: sizes.generationHeight,
            ),
            cancel: cancel,
            onProgress: (progress) {
              if (stage == ImmersiveStage.loadingModels) {
                timed(ImmersiveStage.loadingModels);
              }
              final steps = math.max(1, progress.steps);
              tell(
                ImmersiveProgress(
                  ImmersiveStage.generating,
                  PanoramaProgress.generating +
                      (PanoramaProgress.seam - PanoramaProgress.generating) * progress.step.clamp(0, steps) ~/ steps,
                  step: progress.step,
                  steps: progress.steps,
                  remaining: progress.remaining,
                ),
              );
            },
          );
        } on BackendException catch (error) {
          if (error.code != ImmersiveErrorCode.outputRejected) {
            rethrow;
          }
          refusal = error.message;
        }
        timed(stage == ImmersiveStage.loadingModels ? ImmersiveStage.loadingModels : ImmersiveStage.generating);
        if (refusal == null) {
          final step = await _onProcessor(
            compute,
            cancel.address,
            _JoinStep(
              generatedPath: generated,
              controlPath: control,
              wrappedPath: wrapped,
              sizes: sizes,
              models: models,
            ),
            onEntered: entered,
            onTimes: merge,
          );
          refusal = step.refusal;
          if (refusal == null) {
            joined = step;
          }
        }
        if (refusal != null) {
          _log.warning('${job.id}: the generated image was refused (seed $seed): $refusal');
          if (attempt == 1) {
            return failed(ImmersiveErrorCode.outputRejected, refusal);
          }
        }
      }
      final seam = joined!;

      // 6
      if (cancel.isCancelled) {
        return failed(ImmersiveErrorCode.cancelled);
      }
      tell(const ImmersiveProgress(ImmersiveStage.upscale, PanoramaProgress.upscale));
      watch.reset();
      await upscaler.upscale(
        UpscaleRequest(inputPath: wrapped, outputPath: upscaled, workFolder: folder.path, scale: sizes.scale),
        cancel: cancel,
        onProgress: (progress) {
          final steps = math.max(1, progress.steps);
          tell(
            ImmersiveProgress(
              ImmersiveStage.upscale,
              PanoramaProgress.upscale +
                  (PanoramaProgress.pasteBack - PanoramaProgress.upscale) * progress.step.clamp(0, steps) ~/ steps,
            ),
          );
        },
      );
      timed(ImmersiveStage.upscale);

      // 7
      final flags = <ReliefQualityFlag>{
        if (prepared.fov.guessed) ReliefQualityFlag.fovGuessed,
        if (seam.after > PanoV1.seamRatio) ReliefQualityFlag.seam,
        if (1 - prepared.coverage > PanoV1.mostlyInvented) ReliefQualityFlag.mostlyInvented,
      };
      final photo = job.original;
      final xmp = PanoramaXmp.generated(
        width: sizes.outputWidth,
        height: sizes.outputHeight,
        region: PhotoRegion(yaw: 0, pitch: 0, hfov: _rounded(prepared.fov.hfov), vfov: _rounded(prepared.fov.vfov)),
        sourceCoverage: _rounded(prepared.coverage, digits: 4),
        generator: job.generator,
        generatorSha256: generator.generatorSha256,
        generatorLora: loraId,
        generatorLoraSha256: generator.loraSha256,
        seed: seed,
        steps: job.steps,
        upscaler: upscalerId,
        sourceName: photo.name,
        sourceSize: photo.size,
        sourceSha1: photo.sha1,
        sourceQuarterTurns: job.quarterTurns,
        created: job.created,
        creatorTool: job.creatorTool,
        derivativeId: job.derivativeId,
        qualityFlags: flags.toList(),
      );
      if (cancel.isCancelled) {
        return failed(ImmersiveErrorCode.cancelled);
      }
      watch.reset();
      decoded = await _decodedOther(bytes);
      if (decoded != null) {
        timed(ImmersiveStage.decoding);
      }
      final written = await _onProcessor(
        compute,
        cancel.address,
        _FinishStep(
          job: light,
          bytes: bytes,
          decoded: decoded,
          codecs: codecs,
          upscaledPath: upscaled,
          sizes: sizes,
          hfov: prepared.fov.hfov,
          exif: prepared.exif,
          xmp: xmp.toXml(),
          writePart: writePart,
        ),
        onEntered: entered,
        onTimes: merge,
      );
      if (cancel.isCancelled) {
        return failed(ImmersiveErrorCode.cancelled);
      }
      made = true;
      tell(const ImmersiveProgress(ImmersiveStage.writing, PanoramaProgress.done));
      final result = ImmersiveResult.made(
        details: PanoramaResultDetails(
          width: sizes.outputWidth,
          height: sizes.outputHeight,
          seed: seed,
          steps: job.steps,
          sourceCoverage: prepared.coverage,
        ),
        bytesWritten: written.bytes,
        qualityFlags: ReliefQualityFlag.values.where(flags.contains).toList(),
        stageTimes: times,
      );
      _log.info(
        '${job.id}: panorama of ${written.bytes} bytes, seed $seed, seam ${seam.before.toStringAsFixed(2)} to '
        '${seam.after.toStringAsFixed(2)} in ${seam.regions} regions; decoder ${prepared.decoder}, encoder '
        '${written.encoder}; ${_timesOf(times)}',
      );
      return result;
    } on _Stop catch (stop) {
      return failed(stop.code, stop.message);
    } on BackendException catch (error) {
      return failed(error.code, error.message);
    } catch (error, stack) {
      _log.warning('The panorama ${job.id} failed', error, stack);
      return failed(ImmersiveErrorCode.modelFailed, '$error');
    } finally {
      final existed = partExisted;
      if (existed != null && !made) {
        _restorePart(job.partPath, existed);
      }
      if (folder != null) {
        folders.delete(folder);
      }
      _running = false;
    }
  }

  /// [bytes] decoded by [decodeOther] when they are not a JPEG, upright; null for a JPEG, which the steps decode. Throws
  /// a [_Stop] decodeFailed when the decoder cannot.
  Future<SbsDecoded?> _decodedOther(Uint8List bytes) async {
    final decode = decodeOther;
    if (_isJpeg(bytes) || decode == null) {
      return null;
    }
    try {
      return await decode(bytes);
    } on SbsCodecException catch (error) {
      throw _Stop(ImmersiveErrorCode.decodeFailed, error.message);
    }
  }

  /// Why the components cannot run, null when their files are all there with their sizes
  Future<String?> _missingComponent() async {
    for (final MapEntry(key: path, value: size) in requiredFiles.entries) {
      final file = File(path);
      if (!file.existsSync()) {
        return 'An AI component is missing: $path';
      }
      if (size != null) {
        final length = await file.length();
        if (length != size) {
          return 'An AI component is damaged: $path has $length bytes, not $size';
        }
      }
    }
    return null;
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _last;
  }
}

List<SbsCodec> _autoCodecs() => SbsCodecChoice.auto.codecs();

/// The LoRA and the upscaler by their id in the catalogue (panoramaLoraComponent, upscalerComponent)
const _loraId = 'flux2-klein-4b-360-erp-lora-v1';
const _upscalerId = 'realesrgan-x4plus';

bool _isJpeg(Uint8List bytes) => bytes.length > 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;

/// [value] rounded to [digits] decimals, as the XMP writes it
double _rounded(double value, {int digits = 2}) {
  final factor = math.pow(10, digits);
  return (value * factor).round() / factor;
}

String _timesOf(Map<ImmersiveStage, Duration> times) => [
  for (final MapEntry(key: stage, value: time) in times.entries) '${stage.name} ${time.inMilliseconds} ms',
].join(', ');

/// The .part as it was before the write: absent, or empty as the write probe left it
void _restorePart(String path, bool existed) {
  final file = File(path);
  try {
    if (existed) {
      file.writeAsBytesSync(const [], flush: true);
    } else if (file.existsSync()) {
      file.deleteSync();
    }
  } on FileSystemException {
    // The caller deletes the .part in any case
  }
}

/// [job] without the bytes of its source, which travel apart to the steps
PanoramaJob _withoutBytes(PanoramaJob job) => PanoramaJob(
  id: job.id,
  source: ImmersiveSource(
    name: job.source.name,
    size: job.source.size,
    sha1: job.source.sha1,
    path: job.source.path,
    bytes: job.source.path == null ? Uint8List(0) : null,
  ),
  partPath: job.partPath,
  derivativeId: job.derivativeId,
  creatorTool: job.creatorTool,
  created: job.created,
  generator: job.generator,
  steps: job.steps,
  seed: job.seed,
  quarterTurns: job.quarterTurns,
  exif: job.exif,
);
