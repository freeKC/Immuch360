// The engine of the 3D conversions on a computer, behind ImmersiveEngine (design-final 2026-10-26, sections 2.3 and
// 2.7): Depth Anything V2 Small on ONNX Runtime, relief-v1 in Dart and the JPEG codec, in a worker isolate
// (ai_worker.dart) that keeps the model's session between photos. The queue (lot A5a) runs one job at a time through
// it; a second call waits for the first.
//
// The root isolate does what only it can do, then hands the job over: it reads the original (asynchronously, the
// window never waits), and decodes a photo that is not a JPEG with the engine of Flutter (engine_picture.dart: PNG,
// WebP, GIF and BMP everywhere, HEIC, AVIF, TIFF and the raw files where the system has a decoder), since dart:ui
// decodes on the root isolate only. A JPEG is decoded in the worker, without any colour conversion, so that its ICC
// profile still describes its pixels.
//
// Before each job the files of the model are checked (still there, still their size; their SHA-256 was checked at the
// download): a component removed or damaged meanwhile ends the job with componentsMissing, never with a model
// that fails halfway. A worker that dies (an error nobody caught) fails its job; the next job starts a new one.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/codec/engine_picture.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/ai_worker.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_chain.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:logging/logging.dart';

final _log = Logger('DartImmersiveEngine');

/// Decodes a photo that is not a JPEG on the root isolate, [maxWidth] wide at most when given
typedef OtherPhotoDecoder = Future<SbsDecoded> Function(Uint8List bytes, {int? maxWidth});

/// What a photo is, from its first bytes
enum PhotoFormat {
  jpeg,
  png,
  gif,
  webp,
  bmp,
  heif,
  avif,
  tiff,
  unknown;

  /// Decoded by the codecs of Flutter's engine itself, on every system: a failure is a damaged file
  bool get isEngineOwn => this == png || this == gif || this == webp || this == bmp;
}

/// The format of the photo [bytes] by its signature: the brand of the ftyp box for HEIF and AVIF, TIFF for the raw
/// files built on it (DNG, CR2, NEF, ARW)
PhotoFormat photoFormatOf(Uint8List bytes) {
  bool at(int offset, List<int> signature) {
    if (bytes.length < offset + signature.length) {
      return false;
    }
    for (var index = 0; index < signature.length; index++) {
      if (bytes[offset + index] != signature[index]) {
        return false;
      }
    }
    return true;
  }

  if (at(0, const [0xFF, 0xD8, 0xFF])) {
    return PhotoFormat.jpeg;
  }
  if (at(0, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return PhotoFormat.png;
  }
  if (at(0, 'GIF8'.codeUnits)) {
    return PhotoFormat.gif;
  }
  if (at(0, 'RIFF'.codeUnits) && at(8, 'WEBP'.codeUnits)) {
    return PhotoFormat.webp;
  }
  if (at(0, 'BM'.codeUnits)) {
    return PhotoFormat.bmp;
  }
  if (at(0, const [0x49, 0x49, 0x2A, 0x00]) || at(0, const [0x4D, 0x4D, 0x00, 0x2A])) {
    return PhotoFormat.tiff;
  }
  if (at(4, 'ftyp'.codeUnits) && bytes.length >= 12) {
    final brand = String.fromCharCodes(bytes.sublist(8, 12));
    if (brand == 'avif' || brand == 'avis') {
      return PhotoFormat.avif;
    }
    if (const {'heic', 'heix', 'hevc', 'hevx', 'heim', 'heis', 'mif1', 'msf1'}.contains(brand)) {
      return PhotoFormat.heif;
    }
  }
  return PhotoFormat.unknown;
}

/// See the top of this file
class DartImmersiveEngine implements ImmersiveEngine {
  DartImmersiveEngine({required this.setup, this.requiredFiles = const {}, OtherPhotoDecoder? decodeOther})
    : _decodeOther = decodeOther ?? decodeWithEngine;

  /// Depth Anything V2 Small on ONNX Runtime from the files of the AI components. [librarySize] and [modelSize] are
  /// checked before each job when given: the AI screens give those of the catalogue (AiComponent.size).
  factory DartImmersiveEngine.onnx({
    required String libraryPath,
    required String modelPath,
    int? librarySize,
    int? modelSize,
    String modelSha256 = depthModelOnnxSha256,
    SbsCodecChoice codec = SbsCodecChoice.auto,
    Duration keepSession = aiSessionKeep,
  }) => DartImmersiveEngine(
    setup: AiWorkerSetup(
      backend: OrtBackendSpec(libraryPath: libraryPath, modelPath: modelPath, modelSha256: modelSha256),
      codec: codec,
      keepSession: keepSession,
    ),
    requiredFiles: {libraryPath: librarySize, modelPath: modelSize},
  );

  /// What the worker is made with
  final AiWorkerSetup setup;

  /// The files of the model by path, with their size in bytes where known
  final Map<String, int?> requiredFiles;
  final OtherPhotoDecoder _decodeOther;

  AiWorker? _worker;
  Future<AiWorker>? _starting;
  Future<void> _last = Future.value();
  var _running = false;
  var _disposed = false;

  /// Whether a job runs: the AI components are not removed meanwhile (AiComponentsService.inUse)
  bool get isRunning => _running;

  /// The last job's outcome, with the codecs it used and the threads it lowered, for the logs and the tests
  ChainOutcome? get lastOutcome => _lastOutcome;
  ChainOutcome? _lastOutcome;

  /// The worker, for the tests: null before the first job and after it died
  AiWorker? get worker => _worker;

  @override
  Future<ImmersiveResult> run(
    ImmersiveJob job, {
    required NativeCancelFlag cancel,
    void Function(ImmersiveProgress progress)? onProgress,
  }) {
    // One job at a time: a second call waits for the first
    final result = _last.then((_) => _run(job, cancel, onProgress));
    _last = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<ImmersiveResult> _run(
    ImmersiveJob job,
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
      onProgress?.call(const ImmersiveProgress(ImmersiveStage.reading, ChainProgress.reading));
      if (cancel.isCancelled) {
        return failed(ImmersiveErrorCode.cancelled);
      }
      final missing = await _missingComponent();
      if (missing != null) {
        return failed(ImmersiveErrorCode.componentsMissing, missing);
      }

      final Uint8List bytes;
      try {
        bytes = job.source.bytes ?? await File(job.source.path!).readAsBytes();
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
        onProgress?.call(const ImmersiveProgress(ImmersiveStage.decoding, ChainProgress.decoding));
        try {
          // Capped at the width of an eye when the photo keeps its width; a photo turned a quarter is capped by the
          // chain once turned
          decoded = await _decodeOther(bytes, maxWidth: job.quarterTurns.isEven ? job.maxEyeWidth : null);
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
      final outcome = await worker.run(
        AiWorkerJob(
          job: _withoutBytes(job),
          bytes: bytes,
          decoded: decoded,
          cancelAddress: cancel.address,
          earlierTimes: times,
        ),
        onProgress: onProgress,
      );
      _lastOutcome = outcome;
      _logOutcome(job, outcome);
      return outcome.result;
    } on AiWorkerStopped catch (error) {
      _worker = null;
      return failed(ImmersiveErrorCode.modelFailed, error.message);
    } catch (error, stack) {
      _log.warning('The job ${job.id} failed', error, stack);
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
    return _starting ??= AiWorker.spawn(setup).then(
      (started) {
        _starting = null;
        return _worker = started;
      },
      onError: (Object error) {
        _starting = null;
        throw AiWorkerStopped('The worker of the AI features could not start: $error');
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

  void _logOutcome(ImmersiveJob job, ChainOutcome outcome) {
    final result = outcome.result;
    final steps = [
      for (final MapEntry(key: stage, value: time) in result.stageTimes.entries)
        '${stage.name} ${time.inMilliseconds} ms',
    ].join(', ');
    final how = 'decoder ${outcome.decoder}, encoder ${outcome.encoder}, ${outcome.threadsLowered} threads lowered';
    if (result.isDone) {
      _log.info('${job.id}: ${result.eyeWidth} x ${result.eyeHeight} per eye, $steps; $how');
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

/// [job] without the bytes of its source, which travel apart to the worker
ImmersiveJob _withoutBytes(ImmersiveJob job) => ImmersiveJob(
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
  quarterTurns: job.quarterTurns,
  maxEyeWidth: job.maxEyeWidth,
  parallax: job.parallax,
  convergence: job.convergence,
  exif: job.exif,
);
