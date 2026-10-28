// The seams behind the engines of phases 2 and 3 (design-final 2026-10-27, sections 4.5 and 8.1), each with its fake
// in test/desktop/ai/fakes, so that the engines, the queue and the screens are built and tested before any model is
// there:
//  - GeometryBackend: the metric point map of a photo (MoGe-2 ViT-S through ONNX Runtime, lot S1);
//  - InpaintBackend: the areas a layer hides, filled in through ONNX Runtime: LaMa for the bands of a scene, MI-GAN for
//    the seam of a panorama (the decision of M2: LaMa leaves no ghost of the near layer);
//  - GeneratorBackend and UpscaleBackend: the panorama around a photo and its upscale (stable-diffusion.cpp as a child
//    process, lot P2, or the ComfyUI of the user, lot P5);
//  - SceneBackend: the empty place of a model that makes a whole scene from one or several photos, none in version 1;
//  - GpuProbe: what the graphics cards of the computer offer, read by a child process (lot C6);
//  - ProcessRunner: a program started, read line by line and stopped (lot P2), for the generator and the probe.
// The geometry and the filling run inside the worker isolate as one synchronous event, as DepthBackend; the
// generator, the upscale, the probe and the processes are asynchronous.

import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// Thrown by a backend; the job then fails with [code] and this message
class BackendException implements Exception {
  const BackendException(this.code, this.message);

  final ImmersiveErrorCode code;
  final String message;

  @override
  String toString() => 'BackendException(${code.name}): $message';
}

/// What the model of the geometry gives for a photo of [width] x [height] (its input): per pixel the point x, y, z in
/// the frame of the camera up to the shift MoGe leaves (found by recover_focal_shift, focal_shift.dart), in [points]
/// as x, y, z one pixel after the other; how sure it is that the pixel has a depth, 0 to 1, in [mask] (under
/// SceneV1.validMask: sky or nothing); the normals when the model gives them; and the scale that makes the points
/// metres
class GeometryMaps {
  GeometryMaps({
    required this.width,
    required this.height,
    required this.points,
    required this.mask,
    required this.metricScale,
    this.normals,
  }) : assert(points.length == 3 * width * height && mask.length == width * height, 'Maps of $width x $height');

  final int width;
  final int height;
  final Float32List points;
  final Float32List mask;
  final double metricScale;
  final Float32List? normals;
}

/// The geometry of a photo
abstract interface class GeometryBackend {
  /// The longest side of the input, SceneV1.mapLongSide
  int get inputLongSide;

  /// The SHA-256 of the model file, written as GeometryModelSha256
  String get modelSha256;

  /// The maps of [nchw], the photo as [1, 3, height, width] float32 in [0, 1]. Throws [BackendException]
  /// (modelFailed, cancelled when the run was stopped).
  GeometryMaps estimate(Float32List nchw, {required int width, required int height});

  /// Frees the session; [estimate] loads it again when called after
  void close();
}

/// A region to fill in: [width] x [height] pixels of [rgb] (three bytes a pixel), [mask] 255 where the pixel is known
/// and 0 where it is to be filled. Each backend turns it into what its model takes: LaMa float32 in [0, 1] with 1 on
/// the holes, MI-GAN these bytes as they are.
class InpaintRegion {
  InpaintRegion({required this.width, required this.height, required this.rgb, required this.mask})
    : assert(rgb.length == 3 * width * height && mask.length == width * height, 'A region of $width x $height');

  final int width;
  final int height;
  final Uint8List rgb;
  final Uint8List mask;
}

/// Fills in what a region hides: LaMa for the bands of a scene, MI-GAN for the seam of a panorama
abstract interface class InpaintBackend {
  /// The largest side of a region the model takes whole (512 for LaMa and for MI-GAN): a larger one is cut by the
  /// caller
  int get regionMax;

  /// The SHA-256 of the model file, written as InpaintModelSha256
  String get modelSha256;

  /// The pixels of [region] with the holes filled in, three bytes a pixel, the known ones as they were. Throws
  /// [BackendException].
  Uint8List fill(InpaintRegion region);

  void close();
}

/// One generation: the control frame at [controlPath] (the photo projected on pure green), the fixed [prompt], the
/// [steps], the [seed], the [guidance] and the strength of the LoRA; the image of [width] x [height] goes to
/// [outputPath] (PNG), the generator works in [workFolder]
class GeneratorRequest {
  const GeneratorRequest({
    required this.controlPath,
    required this.outputPath,
    required this.workFolder,
    required this.prompt,
    required this.seed,
    this.steps = PanoV1.steps,
    this.width = PanoV1.generationWidth,
    this.height = PanoV1.generationHeight,
    this.guidance = PanoV1.guidance,
    this.loraStrength = PanoV1.loraStrength,
  });

  final String controlPath;
  final String outputPath;
  final String workFolder;
  final String prompt;
  final int steps;
  final int seed;
  final int width;
  final int height;
  final double guidance;
  final double loraStrength;
}

/// Where a generation or an upscale is: the step done of [steps], and the seconds a step takes when the generator
/// says it
class GeneratorProgress {
  const GeneratorProgress(this.step, this.steps, {this.secondsPerStep});

  final int step;
  final int steps;
  final double? secondsPerStep;

  /// The time left at this pace, null until the generator gave its pace
  Duration? get remaining => secondsPerStep == null
      ? null
      : Duration(milliseconds: ((steps - step).clamp(0, steps) * secondsPerStep! * 1000).round());

  @override
  bool operator ==(Object other) =>
      other is GeneratorProgress &&
      other.step == step &&
      other.steps == steps &&
      other.secondsPerStep == secondsPerStep;

  @override
  int get hashCode => Object.hash(step, steps, secondsPerStep);

  @override
  String toString() => 'GeneratorProgress($step of $steps, ${secondsPerStep}s)';
}

/// Generates the panorama around a photo
abstract interface class GeneratorBackend {
  /// The SHA-256 of the transformer and of the LoRA, written in the XMP of the panorama
  String get generatorSha256;
  String get loraSha256;

  /// Writes the image of [request]. [cancel] stops the generator within a second. Throws [BackendException]:
  /// gpuOutOfMemory, generatorStalled (180 s without a line), generatorFailed (with the end of the error output),
  /// cancelled.
  Future<void> generate(
    GeneratorRequest request, {
    required NativeCancelFlag cancel,
    void Function(GeneratorProgress progress)? onProgress,
  });
}

/// Upscales an image by [scale] from [inputPath] to [outputPath]
class UpscaleRequest {
  const UpscaleRequest({
    required this.inputPath,
    required this.outputPath,
    required this.workFolder,
    this.scale = PanoV1.upscale,
  });

  final String inputPath;
  final String outputPath;
  final String workFolder;
  final int scale;
}

/// Increases the detail of a generated panorama (Real-ESRGAN x4)
abstract interface class UpscaleBackend {
  /// The SHA-256 of the model file
  String get modelSha256;

  /// Writes the upscaled image of [request]; throws [BackendException] as [GeneratorBackend.generate]
  Future<void> upscale(
    UpscaleRequest request, {
    required NativeCancelFlag cancel,
    void Function(GeneratorProgress progress)? onProgress,
  });
}

/// One mesh of a scene, as glb-layers-v1 holds it: [positions] x, y, z in metres in the frame of the camera (x right,
/// y up, looking towards -z), [uvs] u, v in the texture (0, 0 its top left), [indices] three per triangle, each under
/// 65 536, and the index of its texture
class SceneMeshData {
  SceneMeshData({required this.positions, required this.uvs, required this.indices, required this.texture})
    : assert(positions.length % 3 == 0 && uvs.length * 3 == positions.length * 2, 'Three coordinates, two uvs');

  final Float32List positions;
  final Float32List uvs;
  final Uint32List indices;
  final int texture;

  int get vertices => positions.length ~/ 3;
  int get triangles => indices.length ~/ 3;
}

/// A scene ready to be written: its meshes, its textures (JPEG), its zone, its comfort scale, its field of view and
/// the part of the photo that was filled in
class SceneLayers {
  const SceneLayers({
    required this.meshes,
    required this.textures,
    required this.safe,
    required this.scale,
    required this.fieldOfView,
    required this.hiddenFraction,
    this.qualityFlags = const [],
  });

  final List<SceneMeshData> meshes;
  final List<Uint8List> textures;
  final SceneSafeZone safe;
  final double scale;
  final double fieldOfView;
  final double hiddenFraction;
  final List<ReliefQualityFlag> qualityFlags;
}

/// The place of a model that makes a whole scene from one or several photos (a single photo model under Apache 2.0 or
/// MIT one day, several photos later): none in version 1, scene-v1 builds its layers itself. Whatever it is, the file
/// and the viewer stay those of glb-layers-v1.
abstract interface class SceneBackend {
  /// The SHA-256 of its model, for the settings key of its scenes
  String get modelSha256;

  /// The scene of [photos]; throws [BackendException]
  Future<SceneLayers> reconstruct(List<ImmersiveSource> photos, {required NativeCancelFlag cancel});
}

/// What a graphics card is to Vulkan (VkPhysicalDeviceType)
enum GpuKind {
  discrete('discrete'),
  integrated('integrated'),
  virtual('virtual'),
  cpu('cpu'),
  other('other');

  const GpuKind(this.json);

  /// The value of "type" in the JSON of the probe
  final String json;

  static GpuKind fromJson(Object? value) => values.firstWhere((kind) => kind.json == value, orElse: () => other);
}

/// One graphics card as the probe saw it: its [name], its kind, its vendor and device ids, the versions of its driver
/// and of its Vulkan, the memory local to it, and when VK_EXT_memory_budget answers, the budget the system gives the
/// probe (what other programs hold already left out) and what the probe uses of it (nothing: it allocates nothing), all
/// in bytes. [source] says who told: "vulkan", or "dxgi" for an adapter Windows lists that Vulkan does not.
///
/// A card of Vulkan also tells its place in the list of the loader ([vulkanIndex]), its deviceUUID and deviceLUID in
/// hexadecimal, its VkDriverId and whether it has 16 bit storage buffers: what ggml looks at to number the cards
/// (lot C6, gpu_probe.dart), which stable-diffusion.cpp must be told (M3: Vulkan0 is the integrated graphics of a
/// laptop, its dedicated card Vulkan1).
class GpuAdapter {
  const GpuAdapter({
    required this.name,
    required this.kind,
    required this.localMemory,
    this.vendorId,
    this.deviceId,
    this.driverVersion,
    this.apiVersion,
    this.budget,
    this.usage,
    this.source = 'vulkan',
    this.vulkanIndex,
    this.uuid,
    this.luid,
    this.driverId,
    this.storage16Bit,
  });

  final String name;
  final GpuKind kind;
  final int localMemory;
  final int? vendorId;
  final int? deviceId;
  final String? driverVersion;

  /// "1.4.303"
  final String? apiVersion;
  final int? budget;
  final int? usage;
  final String source;

  /// Null when not told (an adapter of DXGI, a device of Vulkan 1.0)
  final int? vulkanIndex;
  final String? uuid;
  final String? luid;
  final int? driverId;
  final bool? storage16Bit;

  /// The memory free for a job now: the budget less what is used, the local memory when the budget is not known
  int get freeMemory => budget == null ? localMemory : (budget! - (usage ?? 0)).clamp(0, budget!);

  /// The major and minor of [apiVersion], (0, 0) when it is not known
  (int, int) get vulkanVersion => vulkanMajorMinor(apiVersion);

  Map<String, Object?> toJson() => {
    'name': name,
    'type': kind.json,
    'localMemory': localMemory,
    'vendorId': vendorId,
    'deviceId': deviceId,
    'driverVersion': driverVersion,
    'apiVersion': apiVersion,
    'budget': budget,
    'usage': usage,
    'source': source,
    'vulkanIndex': vulkanIndex,
    'uuid': uuid,
    'luid': luid,
    'driverId': driverId,
    'storage16Bit': storage16Bit,
  };

  /// The adapter of [json], null when its name or its memory is missing
  static GpuAdapter? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final name = json['name'];
    final memory = json['localMemory'];
    if (name is! String || memory is! int) {
      return null;
    }
    int? integer(String key) => json[key] is int ? json[key] as int : null;
    String? text(String key) => json[key] is String ? json[key] as String : null;
    return GpuAdapter(
      name: name,
      kind: GpuKind.fromJson(json['type']),
      localMemory: memory,
      vendorId: integer('vendorId'),
      deviceId: integer('deviceId'),
      driverVersion: text('driverVersion'),
      apiVersion: text('apiVersion'),
      budget: integer('budget'),
      usage: integer('usage'),
      source: text('source') ?? 'vulkan',
      vulkanIndex: integer('vulkanIndex'),
      uuid: text('uuid'),
      luid: text('luid'),
      driverId: integer('driverId'),
      storage16Bit: json['storage16Bit'] is bool ? json['storage16Bit'] as bool : null,
    );
  }
}

/// The major and minor of a version written "1.4.312", (0, 0) when it is not known
(int, int) vulkanMajorMinor(String? version) {
  final parts = (version ?? '').split('.');
  return (parts.isNotEmpty ? int.tryParse(parts[0]) ?? 0 : 0, parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0);
}

/// Why the probe has no adapter to tell
enum GpuProbeProblem {
  /// No Vulkan loader on the system (vulkan-1.dll, libvulkan.so.1)
  noVulkan,

  /// The probe did not answer within 10 s and was stopped
  noAnswer,

  /// The probe ended without its JSON
  failed,

  /// No Vulkan on this system at all (macOS: the chip and the memory are read otherwise)
  notSupported,
}

/// What the probe found: the adapters, or why there are none; and the version of the Vulkan loader, "1.4.309"
/// (vkEnumerateInstanceVersion), when there is one
class GpuReport {
  const GpuReport({this.adapters = const [], this.problem, this.instanceVersion});

  final List<GpuAdapter> adapters;
  final GpuProbeProblem? problem;
  final String? instanceVersion;

  /// The dedicated card with the most local memory, null when there is none
  GpuAdapter? get bestDiscrete {
    GpuAdapter? best;
    for (final adapter in adapters) {
      if (adapter.kind == GpuKind.discrete && (best == null || adapter.localMemory > best.localMemory)) {
        best = adapter;
      }
    }
    return best;
  }

  Map<String, Object?> toJson() => {
    'instanceVersion': instanceVersion,
    'adapters': [for (final adapter in adapters) adapter.toJson()],
    'problem': problem?.name,
  };

  /// The report of the JSON the probe writes; an adapter that does not read is left out
  static GpuReport fromJson(Object? json) {
    if (json is! Map) {
      return const GpuReport(problem: GpuProbeProblem.failed);
    }
    final adapters = json['adapters'];
    final problem = json['problem'];
    final instanceVersion = json['instanceVersion'];
    return GpuReport(
      adapters: [if (adapters is List) ...adapters.map(GpuAdapter.fromJson).nonNulls],
      problem: GpuProbeProblem.values.where((value) => value.name == problem).firstOrNull,
      instanceVersion: instanceVersion is String ? instanceVersion : null,
    );
  }
}

/// Reads what the graphics cards offer, in a child process: started again before each job on the graphics card
abstract interface class GpuProbe {
  Future<GpuReport> probe();
}

/// A program to start: its [executable] and [arguments], its working folder and environment, at a lower priority
/// ("below normal" on Windows, nice 10 elsewhere) when [lowPriority]
class ProcessLaunch {
  const ProcessLaunch({
    required this.executable,
    this.arguments = const [],
    this.workingDirectory,
    this.environment = const {},
    this.lowPriority = true,
  });

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final Map<String, String> environment;
  final bool lowPriority;
}

/// A program running: its id, its output and error output line by line, its end; [kill] stops it within a second, and
/// it never outlives the app (a job object on Windows, PR_SET_PDEATHSIG on Linux)
abstract interface class RunningProcess {
  int get pid;
  Stream<String> get stdoutLines;
  Stream<String> get stderrLines;
  Future<int> get exitCode;
  void kill();
}

/// Starts programs
abstract interface class ProcessRunner {
  Future<RunningProcess> start(ProcessLaunch launch);
}
