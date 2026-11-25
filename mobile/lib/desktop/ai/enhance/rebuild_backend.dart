// "Rebuild details" on the graphics card: SeedVR2 3B through the sd-cli of stable-diffusion.cpp at 0d71f963 in script
// mode (seedvr2_dgl.dart), the program of the probe of 23 November 2026:
//  - the photo, as the app decoded it, written as a PNG in the work folder, which sd-cli reads (image::load);
//  - the program written beside it, the tiles of 512 px with 64 of overlap, each saved as a PNG of its own;
//  - `sd-cli -M dgl --script <program> --backend Vulkan<n> --max-vram <GiB> -t <threads> -v` on the card the queue
//    asked (the device list of sd-cli checked as for the panoramas, sdcpp_runner.dart): --max-vram is 6 GiB as the probe
//    ran it, or the free memory of the card less 512 MiB when that is less;
//  - its lines read: the tile of each phase (encode, sample, decode: three steps per tile), the integer dot product of
//    the device it runs on (without it the INT8 matrix products would fall back to the processor: the run is stopped
//    with enhanceNoIntDotMessage, the panel then names Natural), a line of a fall back to the processor (kept, said in
//    the panel), and a refusal of its memory checks (outOfMemory with enhanceMemoryMessage: "close other programs");
//  - the tiles blended with their feather into the picture (enhance_pixels.dart), in an isolate.
// The paths sd-cli reads in the program (the work folder, the DiT, the VAE) are given as ASCII paths
// (rebuildAsciiPath): on Windows an account named with an accent (C:\Users\Frédéric) puts one in the temporary folder
// and in the folder of the components, and sd-cli may open a file through the narrow code page, as COLMAP did for
// the splat scenes (splat_work_folder.dart, asciiPathOf). Where Windows has no short name, the path stays as it is.
// Measured on the RTX 4060 Laptop: 35.0 s for 3 MP, 93.9 s for 12 MP, 3.7 to 3.9 GB of the card.

import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_engine.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_pixels.dart';
import 'package:immich_mobile/desktop/ai/enhance/seedvr2_dgl.dart';
import 'package:immich_mobile/desktop/ai/gen/sdcpp_runner.dart';
import 'package:immich_mobile/desktop/ai/panorama/control_image.dart' show decodePngPicture, encodePngPicture;
import 'package:immich_mobile/desktop/ai/splat/splat_work_folder.dart' show isAsciiPath, windowsShortPath;
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('EnhanceRebuild');

/// The files of Rebuild details: the sd-cli of the script mode, the DiT and the VAE of SeedVR2
class RebuildFiles {
  const RebuildFiles({required this.sdCli, required this.dit, required this.vae, this.linuxLauncher});

  final String sdCli;
  final String dit;
  final String vae;
  final String? linuxLauncher;
}

/// The budget of the card sd-cli is given: 6 GiB, or what is free less 512 MiB when that is less (at least 1 GiB)
String rebuildVramBudget(int? free) {
  const gib = 1024 * 1024 * 1024;
  final budget = free == null ? seedVr2MaxVramGib * gib : math.min(seedVr2MaxVramGib * gib, free - gib ~/ 2);
  return sdCppVramBudget(math.max(gib, budget));
}

/// [path] (a file or a folder that exists) as sd-cli is given it: its own when it is ASCII, else its short name on
/// Windows ([shortPathOf], GetShortPathNameW by default) when that one is ASCII, else as it is
String rebuildAsciiPath(String path, {bool? isWindows, String? Function(String path)? shortPathOf}) {
  if (isAsciiPath(path) || !(isWindows ?? Platform.isWindows)) {
    return path;
  }
  String? short;
  try {
    short = (shortPathOf ?? windowsShortPath)(path);
  } catch (error) {
    _log.fine('No short name for $path: $error');
  }
  return short != null && isAsciiPath(short) ? short : path;
}

/// The arguments of the run of [script] on [vulkan]
List<String> rebuildArguments(String script, String vulkan, {required String budget, required int threads}) => [
  '-M',
  'dgl',
  '--script',
  script,
  '--backend',
  vulkan,
  '--max-vram',
  budget,
  '-t',
  '$threads',
  '-v',
];

/// See the top of this file
class SdCppRebuildBackend implements EnhanceBackend {
  SdCppRebuildBackend({
    required this.runner,
    required this.settings,
    required this.files,
    required this.modelSha256,
    this.graphicsFree,
    String Function(String path)? asciiPath,
  }) : _asciiPath = asciiPath ?? rebuildAsciiPath;

  final ProcessRunner runner;

  /// sd-cli, the card and its watchdogs; its models are those of the panoramas and are not read
  final SdCppSettings settings;
  final RebuildFiles files;

  /// The free memory of the card the queue read before the job, null when unknown
  final int? graphicsFree;

  /// The ASCII path of a file or folder that exists, for sd-cli (rebuildAsciiPath; the tests give theirs)
  final String Function(String path) _asciiPath;

  @override
  final String modelSha256;

  @override
  String get model => 'SeedVR2 3B int8 convrot';

  @override
  bool fellBack = false;

  @override
  Future<Uint8List> enhance(
    SbsDecoded picture, {
    required String workFolder,
    required int seed,
    required NativeCancelFlag cancel,
    required void Function(int done, int all) onStep,
  }) async {
    fellBack = false;
    final width = picture.width;
    final height = picture.height;
    // The work folder as sd-cli reads it, and every file of the run under it
    final folder = _asciiPath(workFolder);
    final input = p.join(folder, 'input.png');
    final tileFolder = Directory(p.join(folder, 'tiles'))..createSync(recursive: true);
    final rgba = picture.rgba;
    final png = await encodePngInIsolate(width, height, rgba);
    await File(input).writeAsBytes(png, flush: true);
    final tiles = planTiles(width, height);
    final script = p.join(folder, 'rebuild.dgl');
    await File(script).writeAsString(
      seedVr2Program(
        ditPath: _asciiPath(files.dit),
        vaePath: _asciiPath(files.vae),
        inputPath: input,
        tiles: tiles,
        tileFolder: tileFolder.path,
        seed: seed,
      ),
      flush: true,
    );
    final steps = 3 * tiles.length;
    var done = 0;
    final budget = rebuildVramBudget(graphicsFree);
    await SdCppScriptRun(runner: runner, device: SdCppDevice(settings)).run(
      arguments: (vulkan) => rebuildArguments(script, vulkan, budget: budget, threads: settings.threads),
      workFolder: folder,
      what: 'SeedVR2 3B on ${tiles.length} tiles of ${width}x$height',
      cancel: cancel,
      onStart: () => done = 0,
      onLine: (line, vulkan) {
        if (ggmlIntDotOf(line) case (:final index, :final intDot) when 'Vulkan$index' == vulkan && !intDot) {
          return BackendException(ImmersiveErrorCode.gpuUnavailable, '$enhanceNoIntDotMessage: $line');
        }
        if (seedVr2MemoryRefusal(line)) {
          return BackendException(ImmersiveErrorCode.outOfMemory, '$enhanceMemoryMessage: $line');
        }
        if (seedVr2ProcessorFallback(line)) {
          if (!fellBack) {
            _log.warning('sd-cli says part of SeedVR2 fell back to the processor: $line');
          }
          fellBack = true;
          return null;
        }
        if (seedVr2ProgressOf(line) case final progress?) {
          final step = seedVr2Step(progress);
          if (step > done) {
            done = step;
            onStep(done, steps);
          }
        }
        return null;
      },
    );
    final paths = [for (var index = 0; index < tiles.length; index++) p.join(tileFolder.path, seedVr2TileName(index))];
    try {
      return await blendTileFilesInIsolate(tiles, paths, width, height);
    } on FormatException catch (error) {
      throw BackendException(ImmersiveErrorCode.outputRejected, error.message);
    }
  }
}

// The isolates of the backend are started by the two functions below, never from inside enhance: its closures (the
// lines of sd-cli) hold the backend and the step callback of the engine, which reaches the queue of the app and its
// futures, and a closure built there would carry them to the isolate (issue 23, see enhance_engine.dart).

/// The PNG of [rgba] of [width] x [height], encoded in an isolate of its own
Future<Uint8List> encodePngInIsolate(int width, int height, Uint8List rgba) => Isolate.run(
  () => encodePngPicture(SbsDecoded(width: width, height: height, rgba: rgba)),
  debugName: 'enhance-input-png',
);

/// [blendTileFiles] in an isolate of its own
Future<Uint8List> blendTileFilesInIsolate(List<EnhanceTile> tiles, List<String> paths, int width, int height) =>
    Isolate.run(() => blendTileFiles(tiles, paths, width, height), debugName: 'enhance-blend');

/// The picture of [width] x [height] made of the PNGs at [paths], one per tile of [tiles], blended with their feather.
/// Throws [FormatException] for a tile missing or of another size. Pure: runs in an isolate.
Uint8List blendTileFiles(List<EnhanceTile> tiles, List<String> paths, int width, int height) {
  final blender = TileBlender(width, height);
  for (final (index, tile) in tiles.indexed) {
    final file = File(paths[index]);
    if (!file.existsSync()) {
      throw FormatException('sd-cli wrote no tile ${p.basename(paths[index])}');
    }
    final decoded = decodePngPicture(file.readAsBytesSync());
    if (decoded.width != tile.width || decoded.height != tile.height) {
      throw FormatException(
        'The tile ${p.basename(paths[index])} is ${decoded.width} x ${decoded.height}, not ${tile.width} x ${tile.height}',
      );
    }
    blender.add(tile, decoded.rgba, overlap: enhanceTileOverlap);
  }
  return blender.toRgba();
}
