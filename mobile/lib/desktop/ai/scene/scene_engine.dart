// The engine of the 3D scenes, scene-v1, behind ImmersiveEngine (design-final 2026-10-27, sections 2.3 to 2.6, 8.1 and
// 8.2; measure M2; lot S1). A SceneJob in, <name>_scene3D.jpg written to its .part out: the photo that carries a
// glb-layers-v1 scene, which the headset explores (S2, S3) and the computers preview (S4).
//
// Like the 3D photo of phase 1 (dart_immersive_engine.dart), the root isolate reads the original, checks the files of
// the components, decodes on the engine of Flutter a photo that is not a JPEG, then hands the job to a worker isolate
// as a task (ai_worker.dart, lot C1), which runs it as one synchronous event: SceneChain below, with MoGe-2 ViT-S and
// LaMa on ONNX Runtime, their sessions kept by the worker between jobs (two at most, given back after two minutes) and
// every run taking the RunOptions of the job, so that a cancel stops a pass of MoGe or LaMa within milliseconds. The
// worker is the engine's own: the queue runs one job at a time on the lane of the processor, so a scene never runs
// beside a 3D photo.
//
// The chain, in the steps the screens show (ImmersiveStage.scene), its shares of the job from the times of M2 on ai1:
//  1. reading (0 to 4 %): the SHA-1 of the bytes read, the one the job was queued with, or the photo changed;
//  2. decoding (to 8 %): first the memory the job still needs for a photo of its size (sceneJobMemoryNeed, less what
//     the sessions the worker keeps open hold) against what the system can give now (1 GiB more on Windows, which
//     trims idle programs: sceneTrimAllowance), "out of memory" with both figures when it cannot, as for a 3D photo;
//     then the photo upright and turned as the user sees it (phase 1), its texture at 4 096, its preview at 2 048 and
//     the map of MoGe at 1 024 (scene_textures.dart);
//  3. geometry (to 25 %): MoGe-2 on the map, 2 500 tokens;
//  4. layers (to 27 %): the focal length and the shift (focal_shift.dart; the EXIF's focal length when the photo has
//     one, fovGuessed beyond 25 % of it or without it), the metric depth, then scene-v1 (scene_layout.dart): sky,
//     comfort scale, breaks, bands, mask of the filling, depth behind the bands, grid, zone; the regions to fill;
//  5. inpaint (to 88 %): LaMa on each region, "region k of n" (LaMa is not even loaded for a scene without a break);
//  6. mesh (to 90 %): the photo layer (its grid, then the cells a break cuts, so that the start shows the photo) and
//     the background layer (scene_mesh.dart), cut at 65 535 vertices;
//  7. textures (to 97 %): the JPEG of the photo (quality 90) and of the filled map (85), the profile of the photo kept;
//  8. writing (to 100 %): the glb, the packet, the preview, the file in one write to the .part (and the glb to
//     SceneJob.glbPartPath when given, which the app does not do: its .glb copy is SceneGlbCopies), as the 3D photo is
//     written.
// The flags: lowRelief, hiddenAreas, sky and smallZone from scene-v1, dark as relief-v1 tells it (on the map),
// fovGuessed, and wideGamut for a profile other than sRGB. The cancel flag is read between two steps and two regions;
// a cancelled or failed job leaves the .part as it found it. The original is never opened for writing.

import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/codec/dart_sbs_codec.dart' show orientDecoded;
import 'package:immich_mobile/desktop/ai/codec/engine_picture.dart';
import 'package:immich_mobile/desktop/ai/codec/exif_minimal.dart';
import 'package:immich_mobile/desktop/ai/codec/jpeg_segments.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart' show readFileHead;
import 'package:immich_mobile/desktop/ai/creator/safe_writer.dart' show writeFailureOf;
import 'package:immich_mobile/desktop/ai/engine/ai_worker.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/dart_immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/engine/depth_backend.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_chain.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/engine/thread_priority.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';
import 'package:immich_mobile/desktop/ai/scene/focal_shift.dart';
import 'package:immich_mobile/desktop/ai/scene/glb_writer.dart';
import 'package:immich_mobile/desktop/ai/scene/lama_inpaint.dart';
import 'package:immich_mobile/desktop/ai/scene/moge_geometry.dart';
import 'package:immich_mobile/desktop/ai/scene/scene_container_writer.dart';
import 'package:immich_mobile/desktop/ai/scene/scene_layers.dart';
import 'package:immich_mobile/desktop/ai/scene/scene_layout.dart';
import 'package:immich_mobile/desktop/ai/scene/scene_mesh.dart';
import 'package:immich_mobile/desktop/ai/scene/scene_textures.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/desktop/library/native_sha1.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:logging/logging.dart';

final _log = Logger('SceneEngine');

/// Where each step of a scene starts, in thousandths of the job (the times of M2 on ai1, section 8)
abstract final class SceneProgress {
  static const reading = 0;
  static const sum = 20;
  static const decoding = 40;
  static const geometry = 80;
  static const layers = 250;
  static const inpaint = 270;
  static const mesh = 880;
  static const textures = 900;
  static const writing = 970;
  static const done = 1000;
}

/// The names under which the worker keeps the sessions of a scene
const mogeSession = 'moge';
const lamaSession = 'lama';

/// What a scene is made with: its geometry and its filling, with the catalogue ids of their models
class SceneModels {
  const SceneModels({
    required this.geometry,
    required this.inpaint,
    required this.geometryModel,
    required this.inpaintModel,
  });

  final GeometryBackend geometry;
  final InpaintBackend inpaint;

  /// Immuch360:GeometryModel and InpaintModel
  final String geometryModel;
  final String inpaintModel;
}

/// How a scene ended, with the codecs it used
class SceneOutcome {
  const SceneOutcome(this.result, {this.decoder, this.encoder, this.regions = 0});

  final ImmersiveResult result;

  /// The codec that decoded the photo ("native", "dart"), "engine" for pixels Flutter decoded; the one that wrote
  final String? decoder;
  final String? encoder;

  /// The regions LaMa filled
  final int regions;
}

/// The chain of one scene, in one synchronous call: see the top of this file
class SceneChain {
  SceneChain({
    required this.models,
    List<SbsCodec>? codecs,
    this.writePart = writePartFile,
    Sha1Engine? sha1,
    this.memory,
    this.sessionsOpen = const {},
    this.memoryAllowance = 0,
  }) : codecs = codecs ?? SbsCodecChoice.auto.codecs(),
       sha1 = sha1 ?? Sha1Engine.system() {
    if (this.codecs.isEmpty) {
      throw ArgumentError('A chain needs a JPEG codec');
    }
  }

  final SceneModels models;
  final List<SbsCodec> codecs;
  final PartWriter writePart;
  final Sha1Engine sha1;

  /// The memory of the computer, read before the photo is decoded; null: not checked (a chain the tests run alone)
  final MemoryProbe? memory;

  /// The sessions the worker kept open from earlier jobs when this one started ([mogeSession], [lamaSession])
  final Set<String> sessionsOpen;

  /// What the system gives beyond the memory it says available, in bytes (sceneMemoryAllowanceFor)
  final int memoryAllowance;

  /// Makes the scene of [job] from [original] into its .part. Never throws: a failure is in the result.
  SceneOutcome run(
    SceneJob job,
    ChainOriginal original, {
    required bool Function() isCancelled,
    void Function(ImmersiveProgress progress)? onProgress,
    Map<ImmersiveStage, Duration> earlierTimes = const {},
  }) => _SceneRun(this, job, original, isCancelled, onProgress, earlierTimes).go();
}

/// Raised inside a run to end it with [code]
class _Stop implements Exception {
  const _Stop(this.code, [this.message]);

  final ImmersiveErrorCode code;
  final String? message;
}

class _SceneRun {
  _SceneRun(
    this.chain,
    this.job,
    this.original,
    this.isCancelled,
    this.onProgress,
    Map<ImmersiveStage, Duration> earlier,
  ) : times = {...earlier};

  final SceneChain chain;
  final SceneJob job;
  final ChainOriginal original;
  final bool Function() isCancelled;
  final void Function(ImmersiveProgress progress)? onProgress;
  final Map<ImmersiveStage, Duration> times;
  final _watch = Stopwatch();
  var _stage = ImmersiveStage.reading;
  String? _decoder;
  String? _encoder;
  var _regions = 0;
  final _written = <String, bool>{};

  SceneOutcome go() {
    _watch.start();
    ImmersiveResult result;
    try {
      result = _steps();
    } on _Stop catch (stop) {
      result = _failed(stop.code, stop.message);
    } on BackendException catch (error) {
      result = _failed(error.code, error.message);
    } on OutOfMemoryError {
      result = _failed(ImmersiveErrorCode.outOfMemory, 'Out of memory at the step ${_stage.name}');
    } catch (error) {
      result = _failed(switch (_stage) {
        ImmersiveStage.reading => ImmersiveErrorCode.sourceLost,
        ImmersiveStage.decoding => ImmersiveErrorCode.decodeFailed,
        ImmersiveStage.textures || ImmersiveStage.writing => ImmersiveErrorCode.writeFailed,
        _ => ImmersiveErrorCode.modelFailed,
      }, '$error');
    }
    if (!result.isDone) {
      _restoreParts();
    }
    return SceneOutcome(result, decoder: _decoder, encoder: _encoder, regions: _regions);
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
    if (job.sources.length != 1) {
      throw _Stop(ImmersiveErrorCode.modelFailed, 'scene-v1 makes a scene of one photo, not ${job.sources.length}');
    }
    final source = job.original;
    _enter(ImmersiveStage.reading, SceneProgress.sum);
    final sum = sha1OfBytes(original.bytes, engine: chain.sha1);
    if (sum != source.sha1) {
      throw _Stop(ImmersiveErrorCode.sourceLost, 'The photo changed after it was chosen (its SHA-1 is now $sum)');
    }

    _enter(ImmersiveStage.decoding, SceneProgress.decoding);
    final upright = _decodeUpright();
    final pictures = ScenePictures.of(upright.photo);
    final map = pictures.map;

    _enter(ImmersiveStage.geometry, SceneProgress.geometry);
    final maps = chain.models.geometry.estimate(nchwOf(map), width: map.width, height: map.height);

    _enter(ImmersiveStage.layers, SceneProgress.layers);
    final width = map.width;
    final height = map.height;
    final spans = viewPlaneSpans(width, height);
    final samples = FocalShiftSamples.ofMap(maps.points, maps.mask, width, height);
    final modelFit = recoverFocalShift(samples);
    final exifFocal = focalOfExif35(upright.focal35?.toDouble());
    final fit = exifFocal == null ? modelFit : recoverFocalShift(samples, exifFocal: exifFocal);
    final depth = Float64List(width * height);
    final valid = Float64List(width * height);
    for (var i = 0; i < depth.length; i++) {
      final z = (maps.points[3 * i + 2] + fit.shift) * maps.metricScale;
      final ok = maps.mask[i] >= SceneV1.validMask && z.isFinite && z > 0;
      depth[i] = ok ? z : 0;
      valid[i] = ok ? 1 : 0;
    }
    final focal = focalPixels(fit.focal, width, spans.x);
    final layout = SceneLayout.build(depth, valid, width, height, focal, SceneV1.gridStepFor(width, height));
    final tiles = inpaintTilesOf(layout.inpaintMask, width, height);
    final flags = {
      ...layout.flags,
      if (meanLumaOf(map) < ReliefV1.darkLuma) ReliefQualityFlag.dark,
      if (fovGuessedOf(modelFit.focal, exifFocal)) ReliefQualityFlag.fovGuessed,
      if (isWideGamutProfile(upright.photo.iccProfile)) ReliefQualityFlag.wideGamut,
    };

    _enter(ImmersiveStage.inpaint, SceneProgress.inpaint, step: 0, steps: tiles.length);
    final filled = rgbOf(map.rgba);
    final known = Uint8List.fromList(filled);
    for (final (index, region) in tiles.indexed) {
      if (isCancelled()) {
        throw const _Stop(ImmersiveErrorCode.cancelled);
      }
      _fill(region, known, filled, layout.inpaintMask, width);
      _regions++;
      onProgress?.call(
        ImmersiveProgress(
          ImmersiveStage.inpaint,
          SceneProgress.inpaint + (SceneProgress.mesh - SceneProgress.inpaint) * (index + 1) ~/ tiles.length,
          step: index + 1,
          steps: tiles.length,
        ),
      );
    }

    _enter(ImmersiveStage.mesh, SceneProgress.mesh);
    final background = layout.backgroundLayer;
    final meshes = [...meshesOf(layout.photoLayer, 0), if (background != null) ...meshesOf(background, 1)];
    if (meshes.length > SceneV1.maxMeshes) {
      throw _Stop(ImmersiveErrorCode.tooLarge, '${meshes.length} meshes, at most ${SceneV1.maxMeshes}');
    }

    _enter(ImmersiveStage.textures, SceneProgress.textures);
    final photoTexture = _encode(pictures.texture, SceneV1.photoTextureQuality);
    final textures = [
      photoTexture,
      if (background != null)
        _encode(
          SbsDecoded(width: width, height: height, rgba: _rgbaOf(filled), iccProfile: map.iccProfile),
          SceneV1.backgroundTextureQuality,
        ),
    ];

    _enter(ImmersiveStage.writing, SceneProgress.writing);
    final parts = SceneParts(
      meshes: meshes,
      textures: textures,
      safe: layout.safe,
      scale: layout.scale,
      gridStep: layout.grid.step,
      fieldOfView: horizontalFovDegrees(spans.x, fit.focal),
      fieldOfViewSource: fit.fromExif ? FieldOfViewSource.exif : FieldOfViewSource.model,
      hiddenFraction: layout.hiddenFraction,
      qualityFlags: ReliefQualityFlag.values.where(flags.contains).toList(),
      geometryModel: chain.models.geometryModel,
      geometryModelSha256: chain.models.geometry.modelSha256,
      inpaintModel: chain.models.inpaintModel,
      inpaintModelSha256: chain.models.inpaint.modelSha256,
    );
    final SceneFileBytes file;
    try {
      file = writeSceneFile(
        parts: parts,
        original: SceneOriginal(
          name: source.name,
          size: source.size,
          sha1: source.sha1,
          quarterTurns: job.quarterTurns,
        ),
        preview: pictures.preview,
        codecs: chain.codecs,
        textureMax: math.max(pictures.texture.width, pictures.texture.height),
        derivativeId: job.derivativeId,
        created: job.created,
        creatorTool: job.creatorTool,
        exif: minimalExif(upright.exif),
      );
    } on GlbLayersException catch (error) {
      throw _Stop(ImmersiveErrorCode.tooLarge, error.message);
    } on SbsCodecException catch (error) {
      throw _Stop(
        isMemoryRefusal(error) ? ImmersiveErrorCode.outOfMemory : ImmersiveErrorCode.writeFailed,
        error.message,
      );
    }
    _encoder = file.encoder;
    final glbPath = job.glbPartPath;
    if (glbPath != null) {
      _write(glbPath, file.glb);
    }
    _write(job.partPath, file.bytes);
    if (isCancelled()) {
      throw const _Stop(ImmersiveErrorCode.cancelled);
    }
    _closeStage();
    onProgress?.call(const ImmersiveProgress(ImmersiveStage.writing, SceneProgress.done));
    return ImmersiveResult.made(
      details: SceneResultDetails(
        meshes: meshes.length,
        vertices: parts.vertices,
        triangles: parts.triangles,
        safe: layout.safe,
        scale: layout.scale,
        hiddenFraction: layout.hiddenFraction,
        fieldOfView: parts.fieldOfView,
      ),
      bytesWritten: file.bytes.length,
      qualityFlags: parts.qualityFlags,
      stageTimes: times,
    );
  }

  /// Fills the holes of [region] in [filled] from the filling of its window, read in [known] (the map as decoded)
  void _fill(InpaintTile region, Uint8List known, Uint8List filled, Uint8List holes, int width) {
    final window = region.window;
    final rgb = Uint8List(3 * window.width * window.height);
    final mask = Uint8List(window.width * window.height);
    for (var y = 0; y < window.height; y++) {
      for (var x = 0; x < window.width; x++) {
        final from = (window.top + y) * width + window.left + x;
        final at = y * window.width + x;
        rgb.setRange(3 * at, 3 * at + 3, known, 3 * from);
        mask[at] = holes[from] == 1 ? 0 : 255;
      }
    }
    final out = chain.models.inpaint.fill(
      InpaintRegion(width: window.width, height: window.height, rgb: rgb, mask: mask),
    );
    if (out.length != rgb.length) {
      throw BackendException(ImmersiveErrorCode.modelFailed, 'The filling gave ${out.length} bytes for ${rgb.length}');
    }
    final tile = region.tile;
    for (var y = tile.top; y < tile.bottom; y++) {
      for (var x = tile.left; x < tile.right; x++) {
        final at = y * width + x;
        if (holes[at] == 1) {
          final local = (y - window.top) * window.width + x - window.left;
          filled.setRange(3 * at, 3 * at + 3, out, 3 * local);
        }
      }
    }
  }

  Uint8List _encode(SbsDecoded picture, int quality) {
    try {
      final (jpeg, encoder) = encodeScenePicture(chain.codecs, picture, quality: quality);
      _encoder = encoder;
      return jpeg;
    } on SbsCodecException catch (error) {
      throw _Stop(
        isMemoryRefusal(error) ? ImmersiveErrorCode.outOfMemory : ImmersiveErrorCode.writeFailed,
        error.message,
      );
    }
  }

  /// The photo upright and turned as the user sees it, with the EXIF its preview keeps and its focal length
  /// equivalent to 35 mm
  _Upright _decodeUpright() {
    final engineDecoded = original.decoded;
    if (engineDecoded != null) {
      _checkMemory(engineDecoded.width, engineDecoded.height);
      _decoder = 'engine';
      return _Upright(orientDecoded(engineDecoded, quarterTurns: job.quarterTurns), exif: job.exif);
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
      orientDecoded(decoded!, orientation: exifOrientation(header.exif), quarterTurns: job.quarterTurns),
      exif: mergedExif(job.exif, keptExif(header.exif)),
      focal35: exifFocalLength35mm(header.exif),
    );
  }

  /// Fails the job when the scene of a photo of [width] x [height] needs more memory than the system can give now
  /// (where it says), before the photo is decoded: see the top of this file
  void _checkMemory(int width, int height) {
    final available = chain.memory?.read().available;
    if (available == null || width < 1 || height < 1) {
      return;
    }
    final need = sceneJobMemoryNeed(
      sourceWidth: width,
      sourceHeight: height,
      mogeOpen: chain.sessionsOpen.contains(mogeSession),
      lamaOpen: chain.sessionsOpen.contains(lamaSession),
    );
    if (need > available + chain.memoryAllowance) {
      const mb = 1000 * 1000;
      throw _Stop(
        ImmersiveErrorCode.outOfMemory,
        'This photo needs about ${need ~/ mb} MB of memory, ${available ~/ mb} MB are free',
      );
    }
  }

  void _write(String path, Uint8List bytes) {
    _written[path] = File(path).existsSync();
    try {
      chain.writePart(path, bytes);
    } catch (error) {
      final failure = writeFailureOf(error);
      throw _Stop(failure.errorCode, error is FileSystemException ? error.osError?.message ?? error.message : '$error');
    }
  }

  /// Each .part written as it was before: absent, or empty as the write probe left it
  void _restoreParts() {
    for (final MapEntry(key: path, value: existed) in _written.entries) {
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
  }
}

class _Upright {
  const _Upright(this.photo, {required this.exif, this.focal35});

  final SbsDecoded photo;
  final ImmersiveExif exif;
  final int? focal35;
}

Uint8List _rgbaOf(Uint8List rgb) {
  final out = Uint8List(rgb.length ~/ 3 * 4);
  for (var i = 0, j = 0; i < rgb.length; i += 3, j += 4) {
    out[j] = rgb[i];
    out[j + 1] = rgb[i + 1];
    out[j + 2] = rgb[i + 2];
    out[j + 3] = 0xFF;
  }
  return out;
}

/// How the worker makes the models of a scene: a plain object sent to the worker isolate, where [create] runs with
/// what the worker keeps
abstract interface class SceneModelsSpec {
  SceneModels create(AiWorkerContext context, ComputePriority priority);
}

/// MoGe-2 ViT-S and LaMa on ONNX Runtime, the files of the AI components (lot C2)
class OrtSceneModelsSpec implements SceneModelsSpec {
  const OrtSceneModelsSpec({
    required this.libraryPath,
    required this.mogePath,
    required this.mogeSha256,
    required this.lamaPath,
    required this.lamaSha256,
    required this.geometryModel,
    required this.inpaintModel,
    this.tokens = mogeTokens,
  });

  final String libraryPath;
  final String mogePath;
  final String mogeSha256;
  final String lamaPath;
  final String lamaSha256;
  final String geometryModel;
  final String inpaintModel;
  final int tokens;

  @override
  SceneModels create(AiWorkerContext context, ComputePriority priority) {
    OrtSession open(
      String path,
      OrtSessionSettings settings,
      String? Function(List<OrtTensorSpec>, List<OrtTensorSpec>) refusalOf,
    ) {
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

    final settings = OrtSessionSettings.forThisComputer();
    OrtRunOptions options() => context.runOptions(libraryPath);
    return SceneModels(
      geometry: OrtMogeGeometry(
        // Without the arena of ONNX Runtime: 0.9 GB less at the peak of MoGe for the same time (M2)
        session: () => context.sessions.open<OrtSession>(
          mogeSession,
          () => open(mogePath, settings.withCpuMemArena(false), mogeRefusalOf),
          (session) => session.close(),
        ),
        options: options,
        modelSha256: mogeSha256,
        tokens: tokens,
      ),
      inpaint: OrtLamaInpaint(
        session: () => context.sessions.open<OrtSession>(
          lamaSession,
          () => open(lamaPath, settings, lamaRefusalOf),
          (session) => session.close(),
        ),
        options: options,
        modelSha256: lamaSha256,
      ),
      geometryModel: geometryModel,
      inpaintModel: inpaintModel,
    );
  }
}

/// The depth model of the 3D photo, which the worker of the scenes never makes
class _NoDepthModel implements DepthBackendSpec {
  const _NoDepthModel();

  @override
  DepthBackend create() => throw StateError('The worker of the 3D scenes makes no 3D photo');
}

/// One scene as a task of the worker: the job without the bytes of its source, the bytes and the pixels moved apart
class SceneTask implements AiWorkerTask<SceneOutcome> {
  SceneTask({
    required this.job,
    required Uint8List bytes,
    SbsDecoded? decoded,
    required this.models,
    this.codec = SbsCodecChoice.auto,
    this.priority,
    this.memory = const SystemMemoryProbe(),
    this.earlierTimes = const {},
  }) : _bytes = TransferableTypedData.fromList([bytes]),
       _pixels = decoded == null ? null : TransferableTypedData.fromList([decoded.rgba]),
       _width = decoded?.width,
       _height = decoded?.height,
       _iccProfile = decoded?.iccProfile;

  final SceneJob job;
  final SceneModelsSpec models;
  final SbsCodecChoice codec;

  /// The system of thread priorities, this computer's when null
  final ThreadPriorityPlatform? priority;

  /// The memory of the computer, read by the chain before it decodes the photo
  final MemoryProbe memory;
  final Map<ImmersiveStage, Duration> earlierTimes;
  final TransferableTypedData _bytes;
  final TransferableTypedData? _pixels;
  final int? _width;
  final int? _height;
  final Uint8List? _iccProfile;

  @override
  SceneOutcome run(AiWorkerContext context) {
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
    final SceneChain chain;
    try {
      // The sessions open before this job, read before it opens any
      final open = context.sessions.openNames.toSet();
      chain = SceneChain(
        models: models.create(context, lowered),
        codecs: codec.codecs(),
        memory: memory,
        sessionsOpen: open,
        memoryAllowance: sceneMemoryAllowanceFor(isWindows: Platform.isWindows),
      );
    } catch (error) {
      return SceneOutcome(ImmersiveResult.failed(ImmersiveErrorCode.modelFailed, message: '$error'));
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
class SceneEngine implements ImmersiveEngine {
  SceneEngine({
    required this.models,
    this.requiredFiles = const {},
    OtherPhotoDecoder? decodeOther,
    this.codec = SbsCodecChoice.auto,
    this.keepSession = aiSessionKeep,
    this.priority,
    this.memory = const SystemMemoryProbe(),
  }) : _decodeOther = decodeOther ?? decodeWithEngine;

  /// MoGe-2 and LaMa on ONNX Runtime from the files of the AI components; their sizes are checked before each job
  factory SceneEngine.onnx({
    required String libraryPath,
    required String mogePath,
    required String mogeSha256,
    required String lamaPath,
    required String lamaSha256,
    required String geometryModel,
    required String inpaintModel,
    int? librarySize,
    int? mogeSize,
    int? lamaSize,
    SbsCodecChoice codec = SbsCodecChoice.auto,
    Duration keepSession = aiSessionKeep,
  }) => SceneEngine(
    models: OrtSceneModelsSpec(
      libraryPath: libraryPath,
      mogePath: mogePath,
      mogeSha256: mogeSha256,
      lamaPath: lamaPath,
      lamaSha256: lamaSha256,
      geometryModel: geometryModel,
      inpaintModel: inpaintModel,
    ),
    requiredFiles: {libraryPath: librarySize, mogePath: mogeSize, lamaPath: lamaSize},
    codec: codec,
    keepSession: keepSession,
  );

  final SceneModelsSpec models;

  /// The files of the models by path, with their size in bytes where known
  final Map<String, int?> requiredFiles;
  final SbsCodecChoice codec;
  final Duration keepSession;
  final ThreadPriorityPlatform? priority;

  /// The memory of the computer, checked by each job before it decodes its photo
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
  SceneOutcome? get lastOutcome => _lastOutcome;
  SceneOutcome? _lastOutcome;

  @override
  Future<ImmersiveResult> run(
    SceneJob job, {
    required NativeCancelFlag cancel,
    void Function(ImmersiveProgress progress)? onProgress,
  }) {
    // One job at a time: a second call waits for the first
    final result = _last.then((_) => _run(job, cancel, onProgress));
    _last = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<ImmersiveResult> _run(
    SceneJob job,
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
      onProgress?.call(const ImmersiveProgress(ImmersiveStage.reading, SceneProgress.reading));
      if (cancel.isCancelled) {
        return failed(ImmersiveErrorCode.cancelled);
      }
      final missing = await _missingComponent();
      if (missing != null) {
        return failed(ImmersiveErrorCode.componentsMissing, missing);
      }
      final source = job.original;
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
        onProgress?.call(const ImmersiveProgress(ImmersiveStage.decoding, SceneProgress.decoding));
        try {
          decoded = await _decodeOther(bytes, maxWidth: job.quarterTurns.isEven ? SceneV1.photoTextureMax : null);
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
      final SceneOutcome outcome;
      try {
        outcome = await worker.runTask(
          SceneTask(
            job: _withoutBytes(job),
            bytes: bytes,
            decoded: decoded,
            models: models,
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
      _log.warning('The scene ${job.id} failed', error, stack);
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
          AiWorkerSetup(backend: const _NoDepthModel(), keepSession: keepSession, priority: priority),
        ).then(
          (started) {
            _starting = null;
            return _worker = started;
          },
          onError: (Object error) {
            _starting = null;
            throw AiWorkerStopped('The worker of the 3D scenes could not start: $error');
          },
        );
  }

  /// Why the models cannot run, null when their files are all there with their sizes
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

  void _logOutcome(SceneJob job, SceneOutcome outcome) {
    final result = outcome.result;
    final steps = [
      for (final MapEntry(key: stage, value: time) in result.stageTimes.entries)
        '${stage.name} ${time.inMilliseconds} ms',
    ].join(', ');
    final how = 'decoder ${outcome.decoder}, encoder ${outcome.encoder}, ${outcome.regions} regions filled';
    if (result.isDone) {
      final details = result.details;
      final scene = details is SceneResultDetails
          ? ', ${details.vertices} vertices, ${details.triangles} triangles'
          : '';
      _log.info('${job.id}: scene of ${result.bytesWritten} bytes$scene; $steps; $how');
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

/// The key of the settings a scene of [source] seen with [quarterTurns] would carry (SceneXmp.settingsKey), its models
/// summed [geometrySha256] and [inpaintSha256]: the step of its grid comes from the size of the photo, read in the head
/// of a JPEG; null for another format, or a head that does not tell it (the queue then looks for no version, and
/// converts)
Future<String?> sceneSettingsKeyOf(
  ImmersiveSource source,
  int quarterTurns, {
  required String geometrySha256,
  required String inpaintSha256,
}) async {
  final path = source.path;
  final head = path != null ? await readFileHead(path) : source.bytes;
  if (head == null || photoFormatOf(head) != PhotoFormat.jpeg) {
    return null;
  }
  final JpegHeader header;
  try {
    header = JpegHeader.read(head);
  } on FormatException {
    return null;
  }
  if (header.width < 1 || header.height < 1) {
    return null;
  }
  final (width, height) = sceneMapSizeOf(header.width, header.height);
  return SceneXmp(
    pipeline: SceneV1.pipeline,
    geometryModelSha256: geometrySha256,
    inpaintModelSha256: inpaintSha256,
    gridStep: SceneV1.gridStepFor(width, height),
    sourceQuarterTurns: quarterTurns & 3,
  ).settingsKey;
}

/// [job] without the bytes of its sources, which travel apart to the worker
SceneJob _withoutBytes(SceneJob job) => SceneJob(
  id: job.id,
  sources: [
    for (final source in job.sources)
      ImmersiveSource(
        name: source.name,
        size: source.size,
        sha1: source.sha1,
        path: source.path,
        bytes: source.path == null ? Uint8List(0) : null,
      ),
  ],
  partPath: job.partPath,
  derivativeId: job.derivativeId,
  creatorTool: job.creatorTool,
  created: job.created,
  quarterTurns: job.quarterTurns,
  exif: job.exif,
  glbPartPath: job.glbPartPath,
);
