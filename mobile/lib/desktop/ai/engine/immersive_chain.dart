// The chain of one 2D to 3D job on a computer, in order (design-final 2026-10-26, section 2.3): the sum of the bytes
// read, the decoding, the photo turned upright and by the quarter turns the user sees it with, the eye capped, the
// pair, the depth, the right eye of relief-v1, the JPEG with its EXIF, XMP and ICC profile, and the .part. The left
// eye is the original as decoded, never changed; only the right eye is computed.
//
// Synchronous from end to end: the worker isolate runs a whole job as one event (ai_worker.dart), so that its thread
// never changes on the way (its priority, thread_priority.dart) and the cancel flag, in native memory, is read without
// waiting for a message: between two steps and every 64 rows of the right eye. A run of the model goes to its end and
// its result is dropped. The tests run the chain in their own isolate, with fakes for the model, the codecs, the
// memory and the system of thread priorities.
//
// The original is never opened here: the worker gets its bytes (and the pixels the engine of Flutter decoded on the
// root isolate when it is not a JPEG). The only file written is the .part of the job; a cancelled or failed job
// leaves it as it found it (absent, or empty as the write probe made it), so that no JPEG ever sits there unfinished.
//
// The JPEG codec: the native one of lot A2c whenever this build has it, at every size (a pair of 24 Mpx is written in
// 0.3 s, against 1.5 s in Dart), and the Dart one of lot A2b without it, or when the native one refuses to decode a
// file. A photo too large for the memory is not tried again in Dart, which is slower and needs more.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/codec/dart_sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/codec/exif_minimal.dart';
import 'package:immich_mobile/desktop/ai/codec/jpeg_segments.dart';
import 'package:immich_mobile/desktop/ai/codec/native_sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/creator/safe_writer.dart' show writeFailureOf;
import 'package:immich_mobile/desktop/ai/engine/depth_backend.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/engine/thread_priority.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_depth_backend.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_input.dart';
import 'package:immich_mobile/desktop/ai/relief/relief_map.dart';
import 'package:immich_mobile/desktop/ai/relief/right_eye.dart';
import 'package:immich_mobile/desktop/library/native_sha1.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';

/// Where each step starts, in thousandths of the whole job. The right eye takes the largest share, row by row.
abstract final class ChainProgress {
  static const reading = 0;
  static const sum = 20;
  static const decoding = 40;
  static const depth = 150;
  static const rightEye = 300;
  static const encoding = 750;
  static const writing = 950;
  static const done = 1000;
}

/// Which JPEG codecs a job uses
enum SbsCodecChoice {
  /// The native codec when this build has it, at every size, then the Dart one when it refuses to decode a file;
  /// the Dart one alone without the native library
  auto,

  /// The Dart codec only (the tests, and a measure)
  dart,

  /// The native codec only (a measure)
  native;

  /// The codecs to try, in order
  List<SbsCodec> codecs() => switch (this) {
    auto => [if (NativeSbsCodec.available) const NativeSbsCodec(), const DartSbsCodec()],
    dart => const [DartSbsCodec()],
    native => const [NativeSbsCodec()],
  };
}

/// The original of a job as the chain gets it
class ChainOriginal {
  const ChainOriginal({required this.bytes, this.decoded});

  /// The bytes of the original, as read
  final Uint8List bytes;

  /// The pixels of a photo that is not a JPEG (PNG, WebP, HEIC...), decoded by the engine of Flutter on the root
  /// isolate (engine_picture.dart), upright, with the profile they are in; null for a JPEG, which the chain decodes
  final SbsDecoded? decoded;
}

/// How a run ended, with what the logs and the tests want to know of it
class ChainOutcome {
  const ChainOutcome(this.result, {this.decoder, this.encoder, this.threadsLowered = 0, this.memoryNeed});

  final ImmersiveResult result;

  /// The codec that decoded the original ("native", "dart"), "engine" for pixels Flutter decoded, null before
  final String? decoder;

  /// The codec that wrote the pair, null before
  final String? encoder;

  /// The threads of the model's session lowered by this run, when it opened the session
  final int threadsLowered;

  /// The memory the job was estimated to need, in bytes
  final int? memoryNeed;
}

/// Writes [bytes] as the whole content of the file at [path]
typedef PartWriter = void Function(String path, Uint8List bytes);

/// The .part written in one go and flushed
void writePartFile(String path, Uint8List bytes) => File(path).writeAsBytesSync(bytes, flush: true);

/// The chain, with the tools of one worker: the model's session is kept between jobs
class ImmersiveChain {
  ImmersiveChain({
    required this.backend,
    List<SbsCodec>? codecs,
    this.memory = const SystemMemoryProbe(),
    ComputePriority? priority,
    this.writePart = writePartFile,
    Sha1Engine? sha1,
  }) : codecs = codecs ?? SbsCodecChoice.auto.codecs(),
       priority = priority ?? ComputePriority(ThreadPriorityPlatform.system()),
       sha1 = sha1 ?? Sha1Engine.system() {
    if (this.codecs.isEmpty) {
      throw ArgumentError('A chain needs a JPEG codec');
    }
  }

  final DepthBackend backend;

  /// Tried in order, the next one when a codec refuses a file (never when the photo is too large for the memory)
  final List<SbsCodec> codecs;
  final MemoryProbe memory;
  final ComputePriority priority;
  final PartWriter writePart;
  final Sha1Engine sha1;

  /// Whether the model's session is open, as far as this chain knows: from a run of the model to [closeSession]
  bool get sessionOpen => _sessionOpen;
  bool _sessionOpen = false;

  /// Gives the memory of the session back; the next job opens it again
  void closeSession() {
    backend.close();
    _sessionOpen = false;
  }

  /// Makes the 3D photo of [job] from [original] into [ImmersiveJob.partPath]. [isCancelled] is read between two
  /// steps and every 64 rows of the right eye; [onProgress] hears each step and the rows of the right eye.
  /// [earlierTimes] are the steps the root isolate already did (reading, the decoding of a photo that is not a JPEG).
  /// Never throws: a failure is in the result.
  ChainOutcome run(
    ImmersiveJob job,
    ChainOriginal original, {
    required bool Function() isCancelled,
    void Function(ImmersiveProgress progress)? onProgress,
    Map<ImmersiveStage, Duration> earlierTimes = const {},
  }) {
    final run = _Run(this, job, original, isCancelled, onProgress, earlierTimes);
    return priority.whileLowered(run.go);
  }
}

/// Raised inside a run to end it with [code]
class _Stop implements Exception {
  const _Stop(this.code, [this.message]);

  final ImmersiveErrorCode code;
  final String? message;
}

class _Run {
  _Run(this.chain, this.job, this.original, this.isCancelled, this.onProgress, Map<ImmersiveStage, Duration> earlier)
    : times = {...earlier};

  final ImmersiveChain chain;
  final ImmersiveJob job;
  final ChainOriginal original;
  final bool Function() isCancelled;
  final void Function(ImmersiveProgress progress)? onProgress;
  final Map<ImmersiveStage, Duration> times;
  final _watch = Stopwatch();
  var _stage = ImmersiveStage.reading;
  String? _decoder;
  String? _encoder;
  var _lowered = 0;
  int? _need;

  ChainOutcome go() {
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
      // What an unexpected error means at each step
      result = _failed(switch (_stage) {
        ImmersiveStage.reading => ImmersiveErrorCode.sourceLost,
        ImmersiveStage.decoding => ImmersiveErrorCode.decodeFailed,
        ImmersiveStage.depth || ImmersiveStage.rightEye => ImmersiveErrorCode.modelFailed,
        ImmersiveStage.encoding || ImmersiveStage.writing => ImmersiveErrorCode.writeFailed,
        // The steps of the other kinds of job are never those of this chain
        _ => ImmersiveErrorCode.modelFailed,
      }, '$error');
    }
    return ChainOutcome(result, decoder: _decoder, encoder: _encoder, threadsLowered: _lowered, memoryNeed: _need);
  }

  void _enter(ImmersiveStage stage, int perMille) {
    _closeStage();
    _stage = stage;
    onProgress?.call(ImmersiveProgress(stage, perMille));
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
    if (job.maxEyeWidth < 1) {
      throw ArgumentError.value(job.maxEyeWidth, 'maxEyeWidth');
    }

    // The sum of the bytes read: the one the job was queued with, or the photo changed meanwhile, and SourceSha1
    // would name another photo than the left eye
    _enter(ImmersiveStage.reading, ChainProgress.sum);
    final sum = sha1OfBytes(original.bytes, engine: chain.sha1);
    if (sum != job.source.sha1) {
      throw _Stop(ImmersiveErrorCode.sourceLost, 'The photo changed after it was chosen (its SHA-1 is now $sum)');
    }

    _enter(ImmersiveStage.decoding, ChainProgress.decoding);
    final picture = _decodeUpright();
    final eye = fitEye(picture.eye, maxWidth: job.maxEyeWidth, maxHeight: 2 * job.maxEyeWidth);
    final reduced = !identical(eye, picture.eye);
    final width = eye.width;
    final height = eye.height;

    // The pair: the original on the left, the right eye written beside it
    final pair = pairWithLeftEye(eye);
    final stride = 8 * width;

    _enter(ImmersiveStage.depth, ChainProgress.depth);
    final input = reliefInputOf(
      pair,
      width: width,
      height: height,
      stride: stride,
      inputWidth: chain.backend.inputWidth,
      inputHeight: chain.backend.inputHeight,
    );
    final DepthMap map;
    try {
      _lowered = openWithLowThreads(chain.backend, chain.priority);
      map = chain.backend.estimate(input.nchw);
    } on DepthBackendException catch (error) {
      // A run that failed once the session was open: its memory is given back now, not at the next job
      chain.closeSession();
      throw _Stop(ImmersiveErrorCode.modelFailed, error.message);
    }
    chain._sessionOpen = true;
    // The run went to its end; when the job was cancelled meanwhile, its map is dropped here

    _enter(ImmersiveStage.rightEye, ChainProgress.rightEye);
    final ReliefDepth depth;
    try {
      depth = cropToPhoto(map, input.frame);
    } on ArgumentError catch (error) {
      throw _Stop(ImmersiveErrorCode.modelFailed, '${error.message}');
    }
    const share = ChainProgress.encoding - ChainProgress.rightEye;
    final relief = reliefV1RightEye(
      left: pair,
      width: width,
      height: height,
      leftStride: stride,
      depth: depth,
      parallax: job.parallax,
      convergence: job.convergence,
      target: pair,
      targetOffset: 4 * width,
      targetStride: stride,
      isCancelled: isCancelled,
      onRows: (rows) =>
          onProgress?.call(ImmersiveProgress(ImmersiveStage.rightEye, ChainProgress.rightEye + share * rows ~/ height)),
    );

    _enter(ImmersiveStage.encoding, ChainProgress.encoding);
    final xmp = StereoPhotoXmp.estimated(
      eyeWidth: width,
      eyeHeight: height,
      depthModelSha256: chain.backend.modelSha256,
      sourceName: job.source.name,
      sourceSize: job.source.size,
      sourceSha1: job.source.sha1,
      sourceQuarterTurns: job.quarterTurns,
      created: job.created,
      creatorTool: job.creatorTool,
      derivativeId: job.derivativeId,
      parallax: job.parallax,
      convergence: job.convergence,
      qualityFlags: relief.flags,
    );
    final jpeg = _encode(
      SbsPicture(width: 2 * width, height: height, rgba: pair),
      SbsEncodeOptions(
        quality: picture.quality,
        subsampling: picture.subsampling,
        exif: minimalExif(picture.exif),
        xmp: xmp.toXml(),
        iccProfile: eye.iccProfile,
      ),
    );

    _enter(ImmersiveStage.writing, ChainProgress.writing);
    _write(jpeg);
    if (isCancelled()) {
      _restorePart();
      throw const _Stop(ImmersiveErrorCode.cancelled);
    }
    _closeStage();
    onProgress?.call(const ImmersiveProgress(ImmersiveStage.writing, ChainProgress.done));
    return ImmersiveResult.done(
      eyeWidth: width,
      eyeHeight: height,
      bytesWritten: jpeg.length,
      reduced: reduced,
      qualityFlags: relief.flags,
      stageTimes: times,
    );
  }

  /// The original upright and turned, with the quality, the subsampling and the EXIF its pair is written with
  _Upright _decodeUpright() {
    final engineDecoded = original.decoded;
    if (engineDecoded != null) {
      // Already upright: only the quarter turns of the user
      _decoder = 'engine';
      final turned = (job.quarterTurns & 1) == 1;
      _checkMemory(
        engineDecoded.width,
        engineDecoded.height,
        turned ? engineDecoded.height : engineDecoded.width,
        turned ? engineDecoded.width : engineDecoded.height,
      );
      return _Upright(
        orientDecoded(engineDecoded, quarterTurns: job.quarterTurns),
        quality: sbsDefaultQuality,
        subsampling: sbsSubsamplingFor(null),
        exif: job.exif,
      );
    }

    final JpegHeader header;
    try {
      header = JpegHeader.read(original.bytes);
    } on FormatException catch (error) {
      throw _Stop(ImmersiveErrorCode.decodeFailed, 'Not a JPEG this app reads: ${error.message}');
    }
    final orientation = exifOrientation(header.exif);
    final swaps = (orientation >= 5) != ((job.quarterTurns & 1) == 1);
    _checkMemory(
      header.width,
      header.height,
      swaps ? header.height : header.width,
      swaps ? header.width : header.height,
    );
    final decoded = _decodeJpeg(original.bytes);
    return _Upright(
      orientDecoded(decoded, orientation: orientation, quarterTurns: job.quarterTurns),
      quality: sbsQualityFor(header.estimatedQuality),
      subsampling: sbsSubsamplingFor(header.subsampling),
      exif: mergedExif(job.exif, keptExif(header.exif)),
    );
  }

  /// Fails the job when its photo needs more memory than the system can give now (where it says)
  void _checkMemory(int sourceWidth, int sourceHeight, int uprightWidth, int uprightHeight) {
    if (sourceWidth < 1 || sourceHeight < 1) {
      return;
    }
    final (eyeWidth, eyeHeight) = fittedEyeSize(
      uprightWidth,
      uprightHeight,
      maxWidth: job.maxEyeWidth,
      maxHeight: 2 * job.maxEyeWidth,
    );
    final need = _need = jobMemoryNeed(
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      eyeWidth: eyeWidth,
      eyeHeight: eyeHeight,
      sessionOpen: chain.sessionOpen,
    );
    final available = chain.memory.read().available;
    if (available != null && need > available) {
      const mb = 1000 * 1000;
      throw _Stop(
        ImmersiveErrorCode.outOfMemory,
        'This photo needs about ${need ~/ mb} MB of memory, ${available ~/ mb} MB are free',
      );
    }
  }

  SbsDecoded _decodeJpeg(Uint8List bytes) {
    for (final (index, codec) in chain.codecs.indexed) {
      try {
        final decoded = codec.decodeJpeg(bytes);
        _decoder = codec.name;
        return decoded;
      } on SbsCodecException catch (error) {
        if (isMemoryRefusal(error)) {
          throw _Stop(ImmersiveErrorCode.outOfMemory, error.message);
        }
        if (index == chain.codecs.length - 1) {
          throw _Stop(ImmersiveErrorCode.decodeFailed, error.message);
        }
      }
    }
    throw StateError('No codec');
  }

  Uint8List _encode(SbsPicture picture, SbsEncodeOptions options) {
    for (final (index, codec) in chain.codecs.indexed) {
      try {
        final jpeg = codec.encodeSbs(picture, options);
        _encoder = codec.name;
        return jpeg;
      } on SbsCodecException catch (error) {
        if (isMemoryRefusal(error)) {
          throw _Stop(ImmersiveErrorCode.outOfMemory, error.message);
        }
        if (index == chain.codecs.length - 1) {
          throw _Stop(ImmersiveErrorCode.writeFailed, error.message);
        }
      }
    }
    throw StateError('No codec');
  }

  late final bool _partExisted;

  void _write(Uint8List jpeg) {
    final path = job.partPath;
    _partExisted = File(path).existsSync();
    try {
      chain.writePart(path, jpeg);
    } catch (error) {
      _restorePart();
      final failure = writeFailureOf(error);
      throw _Stop(failure.errorCode, error is FileSystemException ? error.osError?.message ?? error.message : '$error');
    }
  }

  /// The .part as it was before the write: absent, or empty as the write probe left it
  void _restorePart() {
    final file = File(job.partPath);
    try {
      if (_partExisted) {
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
  const _Upright(this.eye, {required this.quality, required this.subsampling, required this.exif});

  final SbsDecoded eye;
  final int quality;
  final ChromaSubsampling subsampling;
  final ImmersiveExif exif;
}

/// A codec that refused for the memory: the photo is too large for it, or the system gave no memory. Not tried again
/// with another codec.
bool isMemoryRefusal(SbsCodecException error) =>
    error.message.startsWith('outOfMemory') || error.message.startsWith('tooLarge');

/// Opens the session of [backend] when it is ONNX Runtime and closed, with its threads lowered (thread_priority.dart);
/// gives how many were. The library is loaded first, so that what loading it starts is not taken for a thread of the
/// session. Throws [DepthBackendException].
int openWithLowThreads(DepthBackend backend, ComputePriority priority) {
  if (backend is! OrtDepthBackend || backend.isOpen) {
    return 0;
  }
  try {
    OrtRuntime.load(backend.libraryPath);
  } on OrtException catch (error) {
    throw DepthBackendException(error.message);
  }
  return priority.lowerThreadsBornDuring(backend.open).lowered;
}

/// The EXIF of the 3D photo: what the job gives first (the queue, from the library), completed by what the original's
/// own EXIF holds. The date and its offset go together, and so do the three GPS values; Software is always the app's.
ImmersiveExif mergedExif(ImmersiveExif job, ImmersiveExif original) {
  final dated = job.dateTimeOriginal != null;
  final placed = job.latitude != null && job.longitude != null;
  return ImmersiveExif(
    dateTimeOriginal: dated ? job.dateTimeOriginal : original.dateTimeOriginal,
    offsetTimeOriginal: dated ? job.offsetTimeOriginal : original.offsetTimeOriginal,
    latitude: placed ? job.latitude : original.latitude,
    longitude: placed ? job.longitude : original.longitude,
    altitude: placed ? job.altitude : original.altitude,
    software: job.software,
  );
}

/// The pair of [eye]: twice its width, the eye on the left, the right half to be written (transparent zeros until then)
Uint8List pairWithLeftEye(SbsDecoded eye) {
  final width = eye.width;
  final rowBytes = 4 * width;
  final pair = Uint8List(2 * rowBytes * eye.height);
  for (var y = 0; y < eye.height; y++) {
    pair.setRange(2 * rowBytes * y, 2 * rowBytes * y + rowBytes, eye.rgba, rowBytes * y);
  }
  return pair;
}

/// The size of an eye of [width] x [height] once fitted within [maxWidth] x [maxHeight], proportions kept (rounded,
/// never under 1 nor over the bounds)
(int, int) fittedEyeSize(int width, int height, {required int maxWidth, required int maxHeight}) {
  if (width <= maxWidth && height <= maxHeight) {
    return (width, height);
  }
  final scale = math.min(maxWidth / width, maxHeight / height);
  return (
    math.min(maxWidth, math.max(1, (width * scale).round())),
    math.min(maxHeight, math.max(1, (height * scale).round())),
  );
}

/// [eye] itself when it fits within [maxWidth] x [maxHeight], otherwise reduced to fit by area average, its
/// proportions kept: the eye is capped at 8192 pixels wide so that the pair fits in 16384, the largest texture of ANGLE
/// and of Metal, and its height at 16384 for the same reason. The profile goes with the pixels.
SbsDecoded fitEye(SbsDecoded eye, {required int maxWidth, required int maxHeight}) {
  final (width, height) = fittedEyeSize(eye.width, eye.height, maxWidth: maxWidth, maxHeight: maxHeight);
  if (width == eye.width && height == eye.height) {
    return eye;
  }
  final across = _reduceAxis(eye.rgba, count: eye.height, from: eye.width, to: width, horizontal: true);
  final rgba = _reduceAxis(across, count: width, from: eye.height, to: height, horizontal: false);
  return SbsDecoded(width: width, height: height, rgba: rgba, iccProfile: eye.iccProfile);
}

/// [rgba] reduced along one axis from [from] to [to] pixels by area average, [count] lines across the other: rows
/// when [horizontal], columns otherwise. Each pixel of the result covers [from] / [to] pixels of the source; the
/// overlaps are counted exactly in units of 1 / [to] of a source pixel, and each channel rounded half up.
Uint8List _reduceAxis(
  Uint8List rgba, {
  required int count,
  required int from,
  required int to,
  required bool horizontal,
}) {
  final first = Int32List(to + 1);
  final sources = <int>[];
  final weights = <int>[];
  for (var i = 0; i < to; i++) {
    first[i] = sources.length;
    final start = i * from;
    final end = (i + 1) * from;
    for (var j = start ~/ to; j * to < end && j < from; j++) {
      final overlap = math.min<int>(end, (j + 1) * to) - math.max<int>(start, j * to);
      if (overlap > 0) {
        sources.add(j);
        weights.add(overlap);
      }
    }
  }
  first[to] = sources.length;
  final source = Int32List.fromList(sources);
  final weight = Int32List.fromList(weights);

  // Along a row the step from one pixel to the next is 4 bytes and from one row to the next the width of a row;
  // along a column the other way round
  final otherWidth = horizontal ? from : count;
  final outWidth = horizontal ? to : count;
  final out = Uint8List(4 * to * count);
  final half = from ~/ 2;
  for (var line = 0; line < count; line++) {
    for (var i = 0; i < to; i++) {
      var r = 0;
      var g = 0;
      var b = 0;
      var a = 0;
      for (var k = first[i]; k < first[i + 1]; k++) {
        final at = horizontal ? 4 * (line * otherWidth + source[k]) : 4 * (source[k] * otherWidth + line);
        final w = weight[k];
        r += w * rgba[at];
        g += w * rgba[at + 1];
        b += w * rgba[at + 2];
        a += w * rgba[at + 3];
      }
      final to4 = horizontal ? 4 * (line * outWidth + i) : 4 * (i * outWidth + line);
      out[to4] = (r + half) ~/ from;
      out[to4 + 1] = (g + half) ~/ from;
      out[to4 + 2] = (b + half) ~/ from;
      out[to4 + 3] = (a + half) ~/ from;
    }
  }
  return out;
}
