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
// Release 54, after the run of 27 November 2026 that sd-cli refused for memory after 4 min 37 s, its 77 tiles lost:
//  - a photo of more than 24 tiles runs in several programs (seedVr2Batches): the tiles of the runs done stay in the
//    tile folder, and a refusal costs the run under way only;
//  - a refusal of the memory checks of sd-cli is made again once, the run under way only, when the memory available
//    is back to the need of the photo within [rebuildRetryWait] (sd-cli gave its own back as it ended); otherwise, or
//    when it is refused again, the job fails with the figures: the memory available and the need of the photo
//    (enhanceMemoryShortMessage), or how short sd-cli was while it ran (enhanceMemoryRanShortMessage). Never more
//    than one try again: nothing else lowers the need (the check is the engine's, before each graph of the DiT, see
//    enhance_plan.dart);
//  - the memory available is read every 2 s while sd-cli runs, and the least of it goes to the log, with the last
//    lines of sd-cli (the home folder written ~), whenever a run fails, before the work folder is deleted;
//  - the progress follows the three phases at the pace this computer takes them (SeedVr2Pace): the engine tells no
//    time left until each phase timed a tile.
// On a Mac with an Apple chip (release 53, not tried on a Mac yet) the Metal build of the same commit runs the same
// program: no --backend (sd-cli takes the one GPU itself, sdCppMetalDevice), the same budget; a line that says Metal
// did not start or the plan put the DiT on the processor stops the run (enhanceNoMetalMessage), as int dot 0 does on
// Vulkan.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_engine.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_pixels.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_plan.dart';
import 'package:immich_mobile/desktop/ai/enhance/seedvr2_dgl.dart';
import 'package:immich_mobile/desktop/ai/gen/sdcpp_runner.dart';
import 'package:immich_mobile/desktop/ai/memory_probe.dart';
import 'package:immich_mobile/desktop/ai/panorama/control_image.dart' show decodePngPicture, encodePngPicture;
import 'package:immich_mobile/desktop/ai/process/sidecar_run.dart' show sidecarStopwatch;
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

/// The arguments of the run of [script] on [vulkan]; on a Mac ([sdCppMetalDevice]) no --backend
List<String> rebuildArguments(String script, String vulkan, {required String budget, required int threads}) => [
  '-M',
  'dgl',
  '--script',
  script,
  if (vulkan != sdCppMetalDevice) ...['--backend', vulkan],
  '--max-vram',
  budget,
  '-t',
  '$threads',
  '-v',
];

/// How long sd-cli may write nothing in Rebuild details on a dedicated card: its first run after the engine was
/// installed was silent for 2 min 20 s after its start on 27 November 2026 (the 180 s of the panoramas nearly reached),
/// before it read its first tile
const rebuildStallTimeout = Duration(seconds: 300);

/// How long a refusal for memory waits for the memory available to come back to the need before its one try again
const rebuildRetryWait = Duration(seconds: 15);

/// How often the memory available is read while sd-cli runs
const rebuildMemoryPoll = Duration(seconds: 2);

/// The lines of sd-cli the log keeps of a run that failed
const rebuildLogLines = 30;

/// [line] of sd-cli as the log of the app keeps it: the home folder of the account written ~
String rebuildLogLine(String line, {String? home}) {
  final folder = home ?? Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
  if (folder == null || folder.length < 3) {
    return line;
  }
  var kept = line;
  for (final form in {folder, folder.replaceAll(r'\', '/'), folder.replaceAll('/', r'\')}) {
    kept = kept.replaceAll(RegExp(RegExp.escape(form), caseSensitive: false), '~');
  }
  return kept;
}

/// Whether [line] is a redraw of a progress bar of sd-cli, which the log leaves out
bool _isBar(String line) => line.contains('|###') || line.contains('|===') || line.contains('\u001b[K');

/// See the top of this file
class SdCppRebuildBackend implements EnhanceBackend {
  SdCppRebuildBackend({
    required this.runner,
    required this.settings,
    required this.files,
    required this.modelSha256,
    this.graphicsFree,
    this.memory = const SystemMemoryProbe(),
    this.retryWait = rebuildRetryWait,
    this.memoryPoll = rebuildMemoryPoll,
    Duration Function()? elapsed,
    String Function(String path)? asciiPath,
  }) : _asciiPath = asciiPath ?? rebuildAsciiPath,
       _elapsed = elapsed ?? sidecarStopwatch();

  final ProcessRunner runner;

  /// sd-cli, the card and its watchdogs; its models are those of the panoramas and are not read
  final SdCppSettings settings;
  final RebuildFiles files;

  /// The free memory of the card the queue read before the job, null when unknown
  final int? graphicsFree;

  /// The memory of the computer, read while sd-cli runs and before its one try again
  final MemoryProbe memory;

  /// How long a refusal waits for the memory to come back ([rebuildRetryWait]), and how often it is read
  final Duration retryWait;
  final Duration memoryPoll;
  final Duration Function() _elapsed;

  /// The ASCII path of a file or folder that exists, for sd-cli (rebuildAsciiPath; the tests give theirs)
  final String Function(String path) _asciiPath;

  @override
  final String modelSha256;

  @override
  String get model => 'SeedVR2 3B int8 convrot';

  @override
  bool fellBack = false;

  SeedVr2Pace? _pace;

  @override
  EnhanceTileProgress? get tileProgress {
    final pace = _pace;
    final where = pace?.where;
    if (pace == null || where == null) {
      return null;
    }
    return (
      phase: ImmersiveTilePhase.values[where.phase.index],
      tile: where.tile,
      tiles: where.tiles,
      left: pace.left(_elapsed()),
    );
  }

  int? _available() => memory.read().sdCppAvailable;

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
    final batches = seedVr2Batches(tiles.length);
    final pace = _pace = SeedVr2Pace(batches);
    final need = rebuildFreeMemoryOf(width * height);
    final budget = rebuildVramBudget(graphicsFree);
    final ditPath = _asciiPath(files.dit);
    final vaePath = _asciiPath(files.vae);
    final what = 'SeedVR2 3B on ${tiles.length} tiles of ${width}x$height';
    // One card for every run: the index sd-cli gave it in the first is kept for the others
    final device = SdCppDevice(settings);
    // The memory available while sd-cli runs: at the start, and the least of it
    final atStart = _available();
    var least = atStart;
    void readMemory() {
      final now = _available();
      if (now != null && (least == null || now < least!)) {
        least = now;
      }
    }

    final watch = Timer.periodic(memoryPoll, (_) => readMemory());
    final tail = <String>[];
    SeedVr2Refusal? refused;
    var retried = false;
    final started = _elapsed();
    String mib(int? bytes) => bytes == null ? 'unknown' : '${bytes >> 20} MiB';
    String memoryWords() =>
        'memory available ${mib(atStart)} at the start, the least ${mib(least)} while sd-cli ran, ${mib(_available())} '
        'now; ${mib(need)} needed at the start, ${mib(rebuildTileMemory)} at each tile of the DiT';
    try {
      for (var index = 0; index < batches.length; index++) {
        final batch = batches[index];
        final name = batches.length == 1 ? 'rebuild.dgl' : 'rebuild-${index + 1}.dgl';
        final script = p.join(folder, name);
        await File(script).writeAsString(
          seedVr2Program(
            ditPath: ditPath,
            vaePath: vaePath,
            inputPath: input,
            tiles: tiles.sublist(batch.start, batch.end),
            firstIndex: batch.start,
            tileFolder: tileFolder.path,
            seed: seed + batch.start,
          ),
          flush: true,
        );
        refused = null;
        try {
          await SdCppScriptRun(runner: runner, device: device, elapsed: _elapsed).run(
            arguments: (vulkan) => rebuildArguments(script, vulkan, budget: budget, threads: settings.threads),
            workFolder: folder,
            what: batches.length == 1
                ? what
                : '$what, run ${index + 1} of ${batches.length}: tiles ${batch.start + 1} to ${batch.end}',
            cancel: cancel,
            onStart: () => pace.started(index, _elapsed()),
            onLine: (line, vulkan) {
              if (!_isBar(line)) {
                tail.add(line);
                if (tail.length > rebuildLogLines) {
                  tail.removeAt(0);
                }
              }
              if (ggmlIntDotOf(line) case (:final index, :final intDot) when 'Vulkan$index' == vulkan && !intDot) {
                return BackendException(ImmersiveErrorCode.gpuUnavailable, '$enhanceNoIntDotMessage: $line');
              }
              if (vulkan == sdCppMetalDevice && seedVr2MetalUnavailable(line)) {
                return BackendException(ImmersiveErrorCode.gpuUnavailable, '$enhanceNoMetalMessage: $line');
              }
              if (seedVr2MemoryRefusal(line)) {
                readMemory();
                refused = seedVr2RefusalOf(line);
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
                // Each tile told, its phase and the time left with it
                pace.read(progress, _elapsed());
                onStep(pace.done, pace.all);
              }
              return null;
            },
          );
        } on BackendException catch (error) {
          if (error.code != ImmersiveErrorCode.outOfMemory || retried || cancel.isCancelled) {
            rethrow;
          }
          // sd-cli gave its memory back as it ended: once, the run under way again when the photo's need is there
          final now = await _memoryBack(need, cancel);
          if (now != null && now < need) {
            throw BackendException(
              ImmersiveErrorCode.outOfMemory,
              '${enhanceMemoryShortMessage(now, need)}: ${error.message}',
            );
          }
          retried = true;
          _log.warning(
            'sd-cli refused run ${index + 1} of ${batches.length} of $what for memory (${error.message}); '
            '${memoryWords()}: made again once',
          );
          pace.again();
          index--;
          continue;
        }
        pace.ended();
        onStep(pace.done, pace.all);
      }
    } on BackendException catch (error) {
      if (error.code != ImmersiveErrorCode.cancelled && !cancel.isCancelled) {
        final where = pace.where;
        final at = where == null
            ? 'before its first tile'
            : 'at ${where.phase.name} tile ${where.tile} of ${where.tiles}';
        _log.warning(
          'Rebuild details failed $at (${error.code.name}${retried ? ', after its one try again' : ''}); '
          '${memoryWords()}; ${pace.summary}; the last lines of sd-cli:\n'
          '${[for (final line in tail) rebuildLogLine(line)].join('\n')}',
        );
        final short = refused;
        if (error.code == ImmersiveErrorCode.outOfMemory && short != null && retried) {
          final now = _available();
          if (now != null && now < need) {
            throw BackendException(
              ImmersiveErrorCode.outOfMemory,
              '${enhanceMemoryShortMessage(now, need)}: ${error.message}',
            );
          }
          throw BackendException(
            ImmersiveErrorCode.outOfMemory,
            '${enhanceMemoryRanShortMessage(short.requested - short.available)}: ${error.message}',
          );
        }
      }
      rethrow;
    } finally {
      watch.cancel();
      _pace = null;
    }
    _log.info(
      'Rebuild details made $what in ${batches.length} run${batches.length == 1 ? '' : 's'}, '
      '${(_elapsed() - started).inSeconds} s${retried ? ' (one made again after a refusal for memory)' : ''}; '
      '${pace.summary}; ${memoryWords()}',
    );
    final paths = [for (var index = 0; index < tiles.length; index++) p.join(tileFolder.path, seedVr2TileName(index))];
    try {
      return await blendTileFilesInIsolate(tiles, paths, width, height);
    } on FormatException catch (error) {
      throw BackendException(ImmersiveErrorCode.outputRejected, error.message);
    }
  }

  /// The memory available once it is back to [need], read every second for [retryWait] at most; the last reading when
  /// it is not; null when the system does not say it
  Future<int?> _memoryBack(int need, NativeCancelFlag cancel) async {
    final until = _elapsed() + retryWait;
    var now = _available();
    while (now != null && now < need && _elapsed() < until && !cancel.isCancelled) {
      await Future<void>.delayed(const Duration(seconds: 1));
      now = _available();
    }
    return now;
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
