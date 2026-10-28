// The engine of the 3D versions of the 360° panoramas, relief-360-v1, behind ImmersiveEngine (design-final 2026-10-27,
// sections 4.4, 4.5 and 8.1; lot P1). A StereoPanoramaJob in, `<name>_360_3D.jpg` (or `<name>_3D.jpg` when the name
// of the source already says 360 or pano) written to its .part out: top and bottom, the left eye on top and equal to
// the panorama, a square of 4096 x 4096 at most, with GPano and our XMP, which every 360° viewer of the app reads as a
// stereo sphere. The source is a 360° photo of the user, or a panorama the app generated (lot P3), whose 3D version
// is a version of the photo it was generated from: then the job names that photo and the packet of the panorama.
//
// Like the 3D photo and the 3D scene, the root isolate reads the source, checks the files of the components, decodes
// on the engine of Flutter a panorama that is not a JPEG, then hands the job to a worker isolate of its own as a task
// (ai_worker.dart), which runs it as one synchronous event: StereoPanoramaChain below, with Depth Anything V2 Small of
// phase 1 on ONNX Runtime, its session kept by the worker between jobs. The queue runs one job at a time on the lane
// of the processor, so a 3D panorama never runs beside a 3D photo or a scene.
//
// The chain, in the steps the screens show (ImmersiveStage.stereoPanorama), its shares of the job from the design's
// estimate on the i9 (about 10 s: 6 s of depth, 1 to 2 s of shift, 1 s of JPEG):
//  1. reading (0 to 4 %): the SHA-1 of the bytes read when the source is the original (a 360° photo of the user); a
//     panorama the app generated has no sum of its own in the queue;
//  2. decoding (to 10 %): the memory the job needs for a panorama of its size against what the system gives now, then
//     the panorama upright by its EXIF orientation, never turned by the quarter turns of the job: a 360° photo does
//     not turn in the viewers, and a generated panorama is upright already (its photo was turned before it was
//     generated). A frame that is not 2:1 within 10 % is no whole sphere and is refused. The left eye is the panorama
//     at 4096 x 2048 at most (an exact 2:1, by area), the map of the depth half as wide (2048 x 1024 at most);
//  3. panoramaDepth (to 70 %): the 20 tangent views through the depth model, "step k of 20", then merged
//     (pano_depth.dart); a flat map is refused here, before the right eye, and so is a map with pixels no view kept
//     sees (views the model read the wrong way round left out);
//  4. rightEye (to 85 %): relief-360-v1 (relief_360.dart) into the lower half of the frame; refused past 8 % filled;
//  5. encoding (to 97 %): the JPEG at quality 90, with the EXIF the 3D photo keeps, the XMP (StereoPanoramaXmp: GPano
//     of a whole sphere, the IPTC digital source type, the parent panorama when there is one) and the ICC profile of
//     the panorama;
//  6. writing (to 100 %): the file in one write to the .part.
// The flags: hiddenAreas from the right eye, and the seam and mostlyInvented of the panorama it was made from. A
// refusal is notEnoughRelief ("Not enough relief for a comfortable 3D panorama") and writes nothing: the mono panorama
// stays. The cancel flag is read between two steps, two views and every 64 rows of the right eye; a cancelled or
// failed job leaves the .part as it found it. The source is never opened for writing.

import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/codec/dart_sbs_codec.dart' show orientDecoded;
import 'package:immich_mobile/desktop/ai/codec/engine_picture.dart';
import 'package:immich_mobile/desktop/ai/codec/exif_minimal.dart';
import 'package:immich_mobile/desktop/ai/codec/jpeg_segments.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/creator/safe_writer.dart' show writeFailureOf;
import 'package:immich_mobile/desktop/ai/engine/ai_worker.dart';
import 'package:immich_mobile/desktop/ai/engine/dart_immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/engine/depth_backend.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_chain.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/engine/thread_priority.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/desktop/ai/panorama/erp_math.dart';
import 'package:immich_mobile/desktop/ai/panorama/pano_depth.dart';
import 'package:immich_mobile/desktop/ai/panorama/relief_360.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_map.dart';
import 'package:immich_mobile/desktop/ai/relief/right_eye.dart' show ReliefCancelledException;
import 'package:immich_mobile/desktop/ai/scene/scene_textures.dart' show encodeScenePicture;
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/desktop/library/native_sha1.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:logging/logging.dart';

final _log = Logger('StereoPanoramaEngine');

/// Where each step of a 3D panorama starts, in thousandths of the job
abstract final class StereoPanoramaProgress {
  static const reading = 0;
  static const sum = 20;
  static const decoding = 40;
  static const panoramaDepth = 100;
  static const rightEye = 700;
  static const encoding = 850;
  static const writing = 970;
  static const done = 1000;
}

/// The name under which the worker of the 3D panoramas keeps the session of the depth model
const stereoPanoramaDepthSession = 'depth360';

/// A frame of [width] x [height] is a whole sphere: 2:1 within 10 %
bool isWholeSphereFrame(int width, int height) => height > 0 && (width / height - 2).abs() <= 0.2;

/// The size of the left eye of a panorama [width] wide: 4096 x 2048 at most, an exact 2:1, never wider than the
/// panorama (an even width, 2 at least)
(int, int) stereoPanoramaEyeSize(int width) {
  final eye = math.max(2, math.min(Relief360V1.eyeWidth, width) & ~1);
  return (eye, eye ~/ 2);
}

/// The size of the map of the depth of an eye [eyeWidth] wide: 2048 x 1024 at most, never wider than the eye
(int, int) stereoPanoramaMapSize(int eyeWidth) {
  final map = math.max(2, math.min(Relief360V1.mapWidth, eyeWidth) & ~1);
  return (map, map ~/ 2);
}

/// What the job of a 3D panorama of a source of [sourceWidth] x [sourceHeight] needs at its peak, in bytes: the
/// panorama decoded and upright (4 bytes a pixel each), the eye, the frame of both eyes and the copy the encoder works
/// on, the JPEG, the map and the 20 maps of the views (a double and a float a value), plus the session of the depth
/// model when it is not open yet and a margin for the rest
int stereoPanoramaJobMemoryNeed({required int sourceWidth, required int sourceHeight, bool sessionOpen = false}) {
  final (eyeWidth, eyeHeight) = stereoPanoramaEyeSize(sourceWidth);
  final (mapWidth, mapHeight) = stereoPanoramaMapSize(eyeWidth);
  final eye = eyeWidth * eyeHeight;
  return 2 * 4 * sourceWidth * sourceHeight +
      4 * eye + // the eye
      2 * 4 * 2 * eye + // the frame of both eyes, and the copy the encoder works on
      2 * 2 * eye + // the JPEG, generously
      4 * mapWidth * mapHeight + // the picture the views are read from
      2 * 8 * mapWidth * mapHeight + // the map and its normalised copy
      Relief360V1.tangentViews * 12 * depthModelInputWidth * depthModelInputHeight + // the maps of the views
      16 * depthModelInputWidth * depthModelInputHeight + // the input of one view
      (sessionOpen ? 0 : depthSessionMemory) +
      64 * 1024 * 1024;
}

/// How a 3D panorama ended, with the codecs it used
class StereoPanoramaOutcome {
  const StereoPanoramaOutcome(this.result, {this.decoder, this.encoder, this.alignments = const []});

  final ImmersiveResult result;

  /// The codec that decoded the panorama ("native", "dart"), "engine" for pixels Flutter decoded; the one that wrote
  final String? decoder;
  final String? encoder;

  /// How each tangent view was aligned, for the logs
  final List<ViewAlignment> alignments;
}

/// The chain of one 3D panorama, in one synchronous call: see the top of this file
class StereoPanoramaChain {
  StereoPanoramaChain({
    required this.backend,
    List<SbsCodec>? codecs,
    ComputePriority? priority,
    this.writePart = writePartFile,
    Sha1Engine? sha1,
    this.memory,
    this.sessionOpen = false,
    this.memoryAllowance = 0,
    this.maxShiftDegrees = Relief360V1.maxShiftDegrees,
  }) : codecs = codecs ?? SbsCodecChoice.auto.codecs(),
       priority = priority ?? ComputePriority(ThreadPriorityPlatform.system()),
       sha1 = sha1 ?? Sha1Engine.system() {
    if (this.codecs.isEmpty) {
      throw ArgumentError('A chain needs a JPEG codec');
    }
  }

  /// The depth model of phase 1
  final DepthBackend backend;
  final List<SbsCodec> codecs;
  final ComputePriority priority;
  final PartWriter writePart;
  final Sha1Engine sha1;

  /// The memory of the computer, read before the panorama is decoded; null: not checked (a chain the tests run alone)
  final MemoryProbe? memory;

  /// Whether the session of the depth model was open when the job started
  final bool sessionOpen;

  /// What the system gives beyond the memory it says available, in bytes (sceneMemoryAllowanceFor)
  final int memoryAllowance;

  /// The shift of the nearest at the equator: the 1° of relief-360-v1, which the packet of the file says. Another
  /// value is for the tests only, to reach the refusals of the right eye through the chain.
  final double maxShiftDegrees;

  /// Makes the 3D version of the panorama of [job] from [original] into its .part. Never throws: a failure is in the
  /// result.
  StereoPanoramaOutcome run(
    StereoPanoramaJob job,
    ChainOriginal original, {
    required bool Function() isCancelled,
    void Function(ImmersiveProgress progress)? onProgress,
    Map<ImmersiveStage, Duration> earlierTimes = const {},
  }) => _StereoPanoramaRun(this, job, original, isCancelled, onProgress, earlierTimes).go();
}

/// Raised inside a run to end it with [code]
class _Stop implements Exception {
  const _Stop(this.code, [this.message]);

  final ImmersiveErrorCode code;
  final String? message;
}

class _StereoPanoramaRun {
  _StereoPanoramaRun(
    this.chain,
    this.job,
    this.original,
    this.isCancelled,
    this.onProgress,
    Map<ImmersiveStage, Duration> earlier,
  ) : times = {...earlier};

  final StereoPanoramaChain chain;
  final StereoPanoramaJob job;
  final ChainOriginal original;
  final bool Function() isCancelled;
  final void Function(ImmersiveProgress progress)? onProgress;
  final Map<ImmersiveStage, Duration> times;
  final _watch = Stopwatch();
  var _stage = ImmersiveStage.reading;
  String? _decoder;
  String? _encoder;
  var _alignments = const <ViewAlignment>[];
  bool? _partExisted;

  StereoPanoramaOutcome go() {
    _watch.start();
    ImmersiveResult result;
    try {
      result = _steps();
    } on _Stop catch (stop) {
      result = _failed(stop.code, stop.message);
    } on ReliefCancelledException {
      result = _failed(ImmersiveErrorCode.cancelled);
    } on OutOfMemoryError {
      result = _failed(ImmersiveErrorCode.outOfMemory, 'Out of memory at the step ${_stage.name}');
    } catch (error) {
      result = _failed(switch (_stage) {
        ImmersiveStage.reading => ImmersiveErrorCode.sourceLost,
        ImmersiveStage.decoding => ImmersiveErrorCode.decodeFailed,
        ImmersiveStage.encoding || ImmersiveStage.writing => ImmersiveErrorCode.writeFailed,
        _ => ImmersiveErrorCode.modelFailed,
      }, '$error');
    }
    if (!result.isDone) {
      _restorePart();
    }
    return StereoPanoramaOutcome(result, decoder: _decoder, encoder: _encoder, alignments: _alignments);
  }

  void _enter(ImmersiveStage stage, int perMille, {int? step, int? steps}) {
    _closeStage();
    _stage = stage;
    onProgress?.call(ImmersiveProgress(stage, perMille, step: step, steps: steps));
    if (isCancelled()) {
      throw const _Stop(ImmersiveErrorCode.cancelled);
    }
  }

  void _closeStage() {
    times[_stage] = (times[_stage] ?? Duration.zero) + _watch.elapsed;
    _watch.reset();
  }

  ImmersiveResult _failed(ImmersiveErrorCode code, [String? message]) {
    _closeStage();
    return ImmersiveResult.failed(code, message: message, stageTimes: times);
  }

  ImmersiveResult _steps() {
    final source = job.source;
    _enter(ImmersiveStage.reading, StereoPanoramaProgress.sum);
    // A 360° photo of the user is the original: its sum is the one it was queued with, or it changed meanwhile and
    // SourceSha1 would name another photo. A generated panorama has no sum of its own in the queue.
    if (job.photo == null && source.sha1.isNotEmpty) {
      final sum = sha1OfBytes(original.bytes, engine: chain.sha1);
      if (sum != source.sha1) {
        throw _Stop(ImmersiveErrorCode.sourceLost, 'The panorama changed after it was chosen (its SHA-1 is now $sum)');
      }
    }

    _enter(ImmersiveStage.decoding, StereoPanoramaProgress.decoding);
    final upright = _decodeUpright();
    final panorama = upright.picture;
    if (!isWholeSphereFrame(panorama.width, panorama.height)) {
      throw _Stop(
        ImmersiveErrorCode.unsupportedFormat,
        'A panorama of ${panorama.width} x ${panorama.height} is no 2:1 frame of the whole sphere',
      );
    }
    final (eyeWidth, eyeHeight) = stereoPanoramaEyeSize(panorama.width);
    final eye = resampleArea(panorama, eyeWidth, eyeHeight);
    final (mapWidth, mapHeight) = stereoPanoramaMapSize(eyeWidth);
    final picture = resampleArea(eye, mapWidth, mapHeight);

    final views = relief360Views(inputWidth: chain.backend.inputWidth, inputHeight: chain.backend.inputHeight);
    const depthShare = StereoPanoramaProgress.rightEye - StereoPanoramaProgress.panoramaDepth;
    _enter(ImmersiveStage.panoramaDepth, StereoPanoramaProgress.panoramaDepth, step: 0, steps: views.length);
    final maps = <DepthMap>[];
    try {
      openWithLowThreads(chain.backend, chain.priority);
      for (final (index, view) in views.indexed) {
        if (isCancelled()) {
          throw const _Stop(ImmersiveErrorCode.cancelled);
        }
        final map = chain.backend.estimate(tangentViewInput(picture, view));
        maps.add(map);
        onProgress?.call(
          ImmersiveProgress(
            ImmersiveStage.panoramaDepth,
            StereoPanoramaProgress.panoramaDepth + depthShare * (index + 1) ~/ views.length,
            step: index + 1,
            steps: views.length,
          ),
        );
      }
    } on DepthBackendException catch (error) {
      // A run that failed once the session was open: its memory is given back now, not at the next job
      chain.backend.close();
      throw _Stop(ImmersiveErrorCode.modelFailed, error.message);
    }
    final depth = mergeViewDepths(views, maps, width: mapWidth, height: mapHeight);
    _alignments = depth.alignments;
    if (depth.uncovered > 0) {
      // Views the model read the wrong way round were left out, and nothing else saw these pixels: their depth would
      // be made up
      throw _Stop(
        ImmersiveErrorCode.notEnoughRelief,
        '${depth.uncovered} pixels of the sphere have no depth the views agree on',
      );
    }
    final normalised = normaliseDepth(depth.map);
    if (normalised.lowRelief) {
      throw const _Stop(ImmersiveErrorCode.notEnoughRelief, 'The panorama has too little relief');
    }

    _enter(ImmersiveStage.rightEye, StereoPanoramaProgress.rightEye);
    final half = 4 * eyeWidth * eyeHeight;
    final frame = Uint8List(2 * half)..setAll(0, eye.rgba);
    const eyeShare = StereoPanoramaProgress.encoding - StereoPanoramaProgress.rightEye;
    final right = writeRelief360RightEye(
      left: frame,
      width: eyeWidth,
      height: eyeHeight,
      map: normalised.depth,
      lowRelief: normalised.lowRelief,
      maxShiftDegrees: chain.maxShiftDegrees,
      target: frame,
      targetOffset: half,
      isCancelled: isCancelled,
      onRows: (rows) => onProgress?.call(
        ImmersiveProgress(ImmersiveStage.rightEye, StereoPanoramaProgress.rightEye + eyeShare * rows ~/ eyeHeight),
      ),
    );
    if (right.refused) {
      throw _Stop(
        ImmersiveErrorCode.notEnoughRelief,
        '${(100 * right.filledFraction).toStringAsFixed(1)} % of the right eye would be filled in',
      );
    }

    _enter(ImmersiveStage.encoding, StereoPanoramaProgress.encoding);
    final kept = qualityFlagsOf(ImmersiveKind.stereoPanorama360);
    final flags = {
      ...right.flags,
      ...?job.parent?.qualityFlags.where((flag) => flag != ReliefQualityFlag.hiddenAreas),
    }.where(kept.contains).toList();
    final photo = job.original;
    final xmp = StereoPanoramaXmp.estimated(
      width: eyeWidth,
      height: 2 * eyeHeight,
      depthModelSha256: chain.backend.modelSha256,
      sourceName: photo.name,
      sourceSize: photo.size,
      sourceSha1: photo.sha1,
      sourceQuarterTurns: job.quarterTurns,
      created: job.created,
      creatorTool: job.creatorTool,
      parent: job.parent,
      derivativeId: job.derivativeId,
      qualityFlags: flags,
    );
    final Uint8List jpeg;
    try {
      final (bytes, encoder) = encodeScenePicture(
        chain.codecs,
        SbsDecoded(width: eyeWidth, height: 2 * eyeHeight, rgba: frame, iccProfile: eye.iccProfile),
        quality: PanoV1.quality,
        exif: minimalExif(upright.exif),
        xmp: xmp.toXml(),
      );
      jpeg = bytes;
      _encoder = encoder;
    } on SbsCodecException catch (error) {
      throw _Stop(
        isMemoryRefusal(error) ? ImmersiveErrorCode.outOfMemory : ImmersiveErrorCode.writeFailed,
        error.message,
      );
    }

    _enter(ImmersiveStage.writing, StereoPanoramaProgress.writing);
    _write(jpeg);
    if (isCancelled()) {
      throw const _Stop(ImmersiveErrorCode.cancelled);
    }
    _closeStage();
    onProgress?.call(const ImmersiveProgress(ImmersiveStage.writing, StereoPanoramaProgress.done));
    return ImmersiveResult.made(
      details: StereoPanoramaResultDetails(
        width: eyeWidth,
        height: 2 * eyeHeight,
        filledFraction: right.filledFraction,
      ),
      bytesWritten: jpeg.length,
      qualityFlags: flags,
      stageTimes: times,
    );
  }

  /// The panorama upright by its EXIF orientation alone, with the EXIF its 3D version keeps
  _Upright _decodeUpright() {
    final engineDecoded = original.decoded;
    if (engineDecoded != null) {
      _checkMemory(engineDecoded.width, engineDecoded.height);
      _decoder = 'engine';
      return _Upright(engineDecoded, exif: job.exif);
    }
    final JpegHeader header;
    try {
      header = JpegHeader.read(original.bytes);
    } on FormatException catch (error) {
      throw _Stop(ImmersiveErrorCode.decodeFailed, 'Not a JPEG this app reads: ${error.message}');
    }
    _checkMemory(header.width, header.height);
    SbsDecoded? decoded;
    for (final (index, codec) in chain.codecs.indexed) {
      try {
        decoded = codec.decodeJpeg(original.bytes);
        _decoder = codec.name;
        break;
      } on SbsCodecException catch (error) {
        if (isMemoryRefusal(error)) {
          throw _Stop(ImmersiveErrorCode.outOfMemory, error.message);
        }
        if (index == chain.codecs.length - 1) {
          throw _Stop(ImmersiveErrorCode.decodeFailed, error.message);
        }
      }
    }
    return _Upright(
      orientDecoded(decoded!, orientation: exifOrientation(header.exif)),
      exif: mergedExif(job.exif, keptExif(header.exif)),
    );
  }

  /// Fails the job when a panorama of [width] x [height] needs more memory than the system can give now (where it
  /// says), before it is decoded
  void _checkMemory(int width, int height) {
    final available = chain.memory?.read().available;
    if (available == null || width < 1 || height < 1) {
      return;
    }
    final need = stereoPanoramaJobMemoryNeed(sourceWidth: width, sourceHeight: height, sessionOpen: chain.sessionOpen);
    if (need > available + chain.memoryAllowance) {
      const mb = 1000 * 1000;
      throw _Stop(
        ImmersiveErrorCode.outOfMemory,
        'This panorama needs about ${need ~/ mb} MB of memory, ${available ~/ mb} MB are free',
      );
    }
  }

  void _write(Uint8List bytes) {
    final path = job.partPath;
    _partExisted = File(path).existsSync();
    try {
      chain.writePart(path, bytes);
    } catch (error) {
      final failure = writeFailureOf(error);
      throw _Stop(failure.errorCode, error is FileSystemException ? error.osError?.message ?? error.message : '$error');
    }
  }

  /// The .part as it was before the write: absent, or empty as the write probe left it; untouched when nothing was
  /// written
  void _restorePart() {
    final existed = _partExisted;
    if (existed == null) {
      return;
    }
    final file = File(job.partPath);
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
}

class _Upright {
  const _Upright(this.picture, {required this.exif});

  final SbsDecoded picture;
  final ImmersiveExif exif;
}

/// The depth model of the 3D photo, which the worker of the 3D panoramas never runs as a 3D photo
class _NoPhotoChain implements DepthBackendSpec {
  const _NoPhotoChain();

  @override
  DepthBackend create() => throw StateError('The worker of the 3D panoramas makes no 3D photo');
}

/// One 3D panorama as a task of the worker: the job without the bytes of its source, the bytes and the pixels moved
/// apart; the depth model made in the worker from [model] and kept there between jobs
class StereoPanoramaTask implements AiWorkerTask<StereoPanoramaOutcome> {
  StereoPanoramaTask({
    required this.job,
    required Uint8List bytes,
    SbsDecoded? decoded,
    required this.model,
    this.codec = SbsCodecChoice.auto,
    this.priority,
    this.memory = const SystemMemoryProbe(),
    this.earlierTimes = const {},
  }) : _bytes = TransferableTypedData.fromList([bytes]),
       _pixels = decoded == null ? null : TransferableTypedData.fromList([decoded.rgba]),
       _width = decoded?.width,
       _height = decoded?.height,
       _iccProfile = decoded?.iccProfile;

  final StereoPanoramaJob job;
  final DepthBackendSpec model;
  final SbsCodecChoice codec;

  /// The system of thread priorities, this computer's when null
  final ThreadPriorityPlatform? priority;

  /// The memory of the computer, read by the chain before it decodes the panorama
  final MemoryProbe memory;
  final Map<ImmersiveStage, Duration> earlierTimes;
  final TransferableTypedData _bytes;
  final TransferableTypedData? _pixels;
  final int? _width;
  final int? _height;
  final Uint8List? _iccProfile;

  @override
  StereoPanoramaOutcome run(AiWorkerContext context) {
    final pixels = _pixels;
    final original = ChainOriginal(
      bytes: _bytes.materialize().asUint8List(),
      decoded: pixels == null
          ? null
          : SbsDecoded(
              width: _width!,
              height: _height!,
              rgba: pixels.materialize().asUint8List(),
              iccProfile: _iccProfile,
            ),
    );
    final lowered = ComputePriority(priority ?? ThreadPriorityPlatform.system());
    final StereoPanoramaChain chain;
    try {
      final open = context.sessions.openNames.contains(stereoPanoramaDepthSession);
      final backend = context.sessions.open<DepthBackend>(
        stereoPanoramaDepthSession,
        model.create,
        (backend) => backend.close(),
      );
      chain = StereoPanoramaChain(
        backend: backend,
        codecs: codec.codecs(),
        priority: lowered,
        memory: memory,
        sessionOpen: open,
        memoryAllowance: sceneMemoryAllowanceFor(isWindows: Platform.isWindows),
      );
    } catch (error) {
      return StereoPanoramaOutcome(ImmersiveResult.failed(ImmersiveErrorCode.modelFailed, message: '$error'));
    }
    return lowered.whileLowered(
      () => chain.run(
        job,
        original,
        isCancelled: () => context.isCancelled,
        onProgress: context.progress,
        earlierTimes: earlierTimes,
      ),
    );
  }
}

/// See the top of this file
class StereoPanoramaEngine implements ImmersiveEngine {
  StereoPanoramaEngine({
    required this.model,
    this.requiredFiles = const {},
    OtherPhotoDecoder? decodeOther,
    this.codec = SbsCodecChoice.auto,
    this.keepSession = aiSessionKeep,
    this.priority,
    this.memory = const SystemMemoryProbe(),
  }) : _decodeOther = decodeOther ?? decodeWithEngine;

  /// Depth Anything V2 Small on ONNX Runtime from the files of the AI components; their sizes are checked before each
  /// job
  factory StereoPanoramaEngine.onnx({
    required String libraryPath,
    required String modelPath,
    String modelSha256 = depthModelOnnxSha256,
    int? librarySize,
    int? modelSize,
    SbsCodecChoice codec = SbsCodecChoice.auto,
    Duration keepSession = aiSessionKeep,
  }) => StereoPanoramaEngine(
    model: OrtBackendSpec(libraryPath: libraryPath, modelPath: modelPath, modelSha256: modelSha256),
    requiredFiles: {libraryPath: librarySize, modelPath: modelSize},
    codec: codec,
    keepSession: keepSession,
  );

  /// How the worker makes the depth model
  final DepthBackendSpec model;

  /// The files of the model by path, with their size in bytes where known
  final Map<String, int?> requiredFiles;
  final SbsCodecChoice codec;
  final Duration keepSession;
  final ThreadPriorityPlatform? priority;

  /// The memory of the computer, checked by each job before it decodes its panorama
  final MemoryProbe memory;
  final OtherPhotoDecoder _decodeOther;

  AiWorker? _worker;
  Future<AiWorker>? _starting;
  Future<void> _last = Future.value();
  var _running = false;
  var _disposed = false;

  /// Whether a job runs: the components are not removed meanwhile
  bool get isRunning => _running;

  /// The worker, for the tests: null before the first job and after it died
  AiWorker? get worker => _worker;

  /// The last job's outcome, for the logs and the tests
  StereoPanoramaOutcome? get lastOutcome => _lastOutcome;
  StereoPanoramaOutcome? _lastOutcome;

  @override
  Future<ImmersiveResult> run(
    StereoPanoramaJob job, {
    required NativeCancelFlag cancel,
    void Function(ImmersiveProgress progress)? onProgress,
  }) {
    // One job at a time: a second call waits for the first
    final result = _last.then((_) => _run(job, cancel, onProgress));
    _last = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<ImmersiveResult> _run(
    StereoPanoramaJob job,
    NativeCancelFlag cancel,
    void Function(ImmersiveProgress progress)? onProgress,
  ) async {
    final times = <ImmersiveStage, Duration>{};
    ImmersiveResult failed(ImmersiveErrorCode code, [String? message]) =>
        ImmersiveResult.failed(code, message: message, stageTimes: times);

    if (_disposed) {
      return failed(ImmersiveErrorCode.modelFailed, 'The engine was disposed');
    }
    _running = true;
    final watch = Stopwatch()..start();
    try {
      onProgress?.call(const ImmersiveProgress(ImmersiveStage.reading, StereoPanoramaProgress.reading));
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
      times[ImmersiveStage.reading] = watch.elapsed;
      if (cancel.isCancelled) {
        return failed(ImmersiveErrorCode.cancelled);
      }

      SbsDecoded? decoded;
      final format = photoFormatOf(bytes);
      if (format != PhotoFormat.jpeg) {
        watch.reset();
        onProgress?.call(const ImmersiveProgress(ImmersiveStage.decoding, StereoPanoramaProgress.decoding));
        try {
          // No wider than the left eye: the larger pixels would only be averaged away
          decoded = await _decodeOther(bytes, maxWidth: Relief360V1.eyeWidth);
        } on SbsCodecException catch (error) {
          return failed(
            format.isEngineOwn ? ImmersiveErrorCode.decodeFailed : ImmersiveErrorCode.unsupportedFormat,
            '${format.name}: ${error.message}',
          );
        }
        times[ImmersiveStage.decoding] = watch.elapsed;
        if (cancel.isCancelled) {
          return failed(ImmersiveErrorCode.cancelled);
        }
      }

      final worker = await _workerReady();
      final StereoPanoramaOutcome outcome;
      try {
        outcome = await worker.runTask(
          StereoPanoramaTask(
            job: _withoutBytes(job),
            bytes: bytes,
            decoded: decoded,
            model: model,
            codec: codec,
            priority: priority,
            memory: memory,
            earlierTimes: times,
          ),
          cancelAddress: cancel.address,
          onProgress: onProgress,
        );
      } on AiWorkerTaskFailed catch (error) {
        return failed(error.cancelled ? ImmersiveErrorCode.cancelled : ImmersiveErrorCode.modelFailed, error.message);
      }
      _lastOutcome = outcome;
      _logOutcome(job, outcome);
      return outcome.result;
    } on AiWorkerStopped catch (error) {
      _worker = null;
      return failed(ImmersiveErrorCode.modelFailed, error.message);
    } catch (error, stack) {
      _log.warning('The 3D panorama ${job.id} failed', error, stack);
      return failed(ImmersiveErrorCode.modelFailed, '$error');
    } finally {
      _running = false;
    }
  }

  Future<AiWorker> _workerReady() {
    final worker = _worker;
    if (worker != null && worker.isAlive) {
      return Future.value(worker);
    }
    return _starting ??=
        AiWorker.spawn(
          AiWorkerSetup(backend: const _NoPhotoChain(), keepSession: keepSession, priority: priority),
        ).then(
          (started) {
            _starting = null;
            return _worker = started;
          },
          onError: (Object error) {
            _starting = null;
            throw AiWorkerStopped('The worker of the 3D panoramas could not start: $error');
          },
        );
  }

  /// Why the model cannot run, null when its files are all there with their sizes
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

  void _logOutcome(StereoPanoramaJob job, StereoPanoramaOutcome outcome) {
    final result = outcome.result;
    final steps = [
      for (final MapEntry(key: stage, value: time) in result.stageTimes.entries)
        '${stage.name} ${time.inMilliseconds} ms',
    ].join(', ');
    final how = 'decoder ${outcome.decoder}, encoder ${outcome.encoder}';
    if (result.isDone) {
      final details = result.details;
      final size = details is StereoPanoramaResultDetails
          ? ', ${details.width} x ${details.height}, ${(100 * details.filledFraction).toStringAsFixed(2)} % filled'
          : '';
      _log.info('${job.id}: 3D panorama of ${result.bytesWritten} bytes$size; $steps; $how');
    } else {
      _log.info('${job.id}: ${result.error?.name} (${result.message}), $steps; $how');
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _last;
    final worker = _worker ?? await _starting?.then<AiWorker?>((worker) => worker, onError: (_) => null);
    _worker = null;
    await worker?.close();
  }
}

/// The key of the settings a 3D panorama of a source seen with [quarterTurns] would carry (StereoPanoramaXmp
/// .settingsKey), its depth model summed [depthModelSha256]: the same for every panorama, the photo telling the rest
String? stereoPanoramaSettingsKeyOf(int quarterTurns, {required String depthModelSha256}) => StereoPanoramaXmp(
  pipeline: Relief360V1.pipeline,
  depthModelSha256: depthModelSha256,
  maxShiftDegrees: Relief360V1.maxShiftDegrees,
  sourceQuarterTurns: quarterTurns & 3,
).settingsKey;

/// [job] without the bytes of its sources, which travel apart to the worker
StereoPanoramaJob _withoutBytes(StereoPanoramaJob job) {
  ImmersiveSource light(ImmersiveSource source) => ImmersiveSource(
    name: source.name,
    size: source.size,
    sha1: source.sha1,
    path: source.path,
    bytes: source.path == null ? Uint8List(0) : null,
  );
  final photo = job.photo;
  return StereoPanoramaJob(
    id: job.id,
    source: light(job.source),
    photo: photo == null ? null : light(photo),
    parent: job.parent,
    partPath: job.partPath,
    derivativeId: job.derivativeId,
    creatorTool: job.creatorTool,
    created: job.created,
    quarterTurns: job.quarterTurns,
    exif: job.exif,
  );
}
