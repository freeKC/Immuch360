// Brush 0.3.0 on the graphics card, the training of the copy of a splat scene for the headset (plan 2026-11-01, sections
// 2.2 and 3, lot SP4; design engineering-first of 1 November 2026, sections 4.4 and 4.5; measures of 1 November 2026 and
// lots SP2 and M1). brush_app, our build without its window, rerun and the LPIPS weights (lot SP2), is one child process
// started through SidecarRun (process/sidecar_run.dart), so through the job object of the app on Windows and
// immuch360-run on Linux: an app that dies, or is killed, takes Brush with it and the graphics card gets its memory back.
//  - Before it starts, the graphics card is asked again ([BrushCardCheck], the budget of gpu_budget.dart in the app): a
//    game or a 3D app opened during the poses may hold its memory. While the card has less than the job needs free,
//    the run waits, says what is free ([BrushRunner.train], onWaiting) and asks again every 30 s; cancelled meanwhile,
//    nothing starts; a card gone fails as gpuUnavailable.
//  - The card is named to Brush: CUBECL_WGPU_DEFAULT_DEVICE=DiscreteGpu(n), n the rank of the card of the gate among
//    the dedicated cards Vulkan lists (the measure: the variable is read). Brush says the card it took ("Using adapter
//    AdapterInfo { name: ..., device_type: DiscreteGpu ... }", with RUST_LOG naming cubecl_wgpu): another one stops it
//    at once, gpuUnavailable.
//  - Its working folder is a folder of the card ([brushCacheFolderOf]: name, ids and driver), not the folder of the job:
//    cubecl keeps there, in target/autotune, the kernels it picked, under one key for every card, and a card that finds
//    the kernels of another panics at its first one (lot SP2: the Intel UHD on the cache of the RTX, "plane
//    instructions"). Kept from one job to the next, the cache spares the tuning of the first steps.
//  - Its arguments are frozen against the help of brush_app 0.3.0 (brush_help.txt of lot SP2): 20 000 steps, at most
//    150 000 gaussians, spherical harmonics of degree 3, 1 024 pixels (M1), one export at the end into brush/ of the job;
//    no view held out (the plan, section 2.2).
//  - Its progress is read from its output with RUST_LOG=brush_cli=info,brush_process=info,cubecl_wgpu=info: "Refine
//    iter 12401, 148213 splats." every 200 steps (2 to 8 s apart in the measure), "Done training! Took ..."; silent for
//    300 s, it is stopped (trainingStalled).
//  - A panic ("thread 'main' panicked at ...", then its message) stops it at once, without waiting for its end:
//    Windows Error Reporting held the real one 80 s after its panic (lot SP2). Its message is every line up to the note
//    Rust writes after it ("note: run with `RUST_BACKTRACE=1` ..."), a backtrace or another panic, or what came within
//    a second: wgpu 26.0.2 (that of Brush 0.3.0) panics with "wgpu error: Validation Error", a blank line, "Caused by:"
//    and the causes below, so a blank line ends nothing. The message names the failure: the memory of the card ("failed
//    to reserve", "BufferTooBig", "ErrorOutOfDeviceMemory" of Brush issues 551 and 500; "Out of Memory" and "Not enough
//    memory left." of wgpu, read without case) is gpuOutOfMemory, kernels the card refuses ("plane instructions")
//    gpuUnavailable, anything else trainingFailed. The same words before an exit code other than 0 are gpuOutOfMemory.
//  - A file of the work folder that cannot be made, rewritten or removed is trainingFailed (diskFull when the disk is
//    full), before Brush starts.
//  - Brush 0.3.0 reads the first 16 387 bytes of each image at once (get_image_data of brush-dataset, lot SP2): a
//    smaller image fails the whole dataset with "early eof". Such an image is made longer first, by a comment (a COM
//    segment of a JPEG, a tEXt chunk of a PNG), its pixels untouched.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/process/sidecar_run.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_work_folder.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:path/path.dart' as p;

/// The program of Brush in its folder (`engines/brush-vulkan-*/` of the AI components)
String brushIn(String folder, {bool? windows}) =>
    p.join(folder, (windows ?? Platform.isWindows) ? 'brush_app.exe' : 'brush_app');

/// What Brush logs: its training, its process, and the card cubecl took
const brushRustLog = 'brush_cli=info,brush_process=info,cubecl_wgpu=info';

/// The texts of a memory of the graphics card too short, read without case: Brush issues 551 and 500, and the words of
/// wgpu 26.0.2 for its own ("Out of Memory" of an error of that kind, "Not enough memory left." of a device)
const brushOutOfMemoryTexts = [
  'failed to reserve',
  'buffertoobig',
  'erroroutofdevicememory',
  'out of memory',
  'not enough memory',
];

/// Whether [text] says the memory of the graphics card was too short ([brushOutOfMemoryTexts])
bool brushSaysOutOfMemory(String text) {
  final lower = text.toLowerCase();
  return brushOutOfMemoryTexts.any(lower.contains);
}

/// The most lines of a panic its message keeps
const brushPanicLines = 12;

/// The text of kernels the card refuses (lot SP2: the Intel UHD on the autotune cache of the RTX; lavapipe)
const brushPlaneText = 'plane instructions';

/// The fewest bytes Brush 0.3.0 reads of an image at once
const brushMinImageBytes = 16387;

/// Brush to its run; its words of memory are read by the runner, without case ([brushSaysOutOfMemory])
const brushProgram = SidecarProgram(
  name: 'Brush',
  failed: ImmersiveErrorCode.trainingFailed,
  stalled: ImmersiveErrorCode.trainingStalled,
  outOfMemory: ImmersiveErrorCode.gpuOutOfMemory,
);

/// What the graphics card answers before Brush starts
sealed class BrushCard {
  const BrushCard();
}

/// The card has the memory free: Brush starts on [card], one of the cards of [report]
final class BrushCardReady extends BrushCard {
  const BrushCardReady(this.card, this.report);

  final GpuAdapter card;
  final GpuReport report;
}

/// Other programs hold the memory of the card: Brush waits, [free] bytes being free now
final class BrushCardWait extends BrushCard {
  const BrushCardWait(this.free);

  final int free;
}

/// No card can train now, for [reason] (a reason of the gate)
final class BrushCardRefused extends BrushCard {
  const BrushCardRefused(this.reason);

  final String reason;
}

/// Asks the graphics card again (the budget of gpu_budget.dart in the app)
typedef BrushCardCheck = Future<BrushCard> Function();

/// The device of cubecl for [card] among the cards of [report]: "DiscreteGpu(n)", n its rank among the dedicated cards
/// Vulkan lists, in the order of the loader (that of wgpu); "IntegratedGpu(n)" for an integrated one; null when it is
/// not one Vulkan lists
String? cubeclDeviceOf(GpuReport report, GpuAdapter card) {
  final kind = switch (card.kind) {
    GpuKind.discrete => 'DiscreteGpu',
    GpuKind.integrated => 'IntegratedGpu',
    _ => null,
  };
  if (kind == null) {
    return null;
  }
  final same = [
    for (final adapter in report.adapters)
      if (adapter.source == 'vulkan' && adapter.kind == card.kind) adapter,
  ];
  // The order of the loader: by the index of the probe, a card without one after the others in their order
  final ordered = [...same]..sort((a, b) => (a.vulkanIndex ?? 1 << 30).compareTo(b.vulkanIndex ?? 1 << 30));
  final rank = ordered.indexWhere(
    (adapter) =>
        identical(adapter, card) ||
        (adapter.vulkanIndex != null && adapter.vulkanIndex == card.vulkanIndex) ||
        (adapter.uuid != null && adapter.uuid == card.uuid),
  );
  return rank < 0 ? null : '$kind($rank)';
}

/// The working folder of Brush for [card] under [cacheRoot]: its name, its ids and its driver, so that no other card
/// and no other driver finds the autotune cache of cubecl it keeps there
Directory brushCacheFolderOf(Directory cacheRoot, GpuAdapter card) {
  String hex(int? value) => value == null ? 'x' : value.toRadixString(16).padLeft(4, '0');
  final name = card.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  final driver = (card.driverVersion ?? 'x').replaceAll(RegExp(r'[^A-Za-z0-9.]+'), '_');
  final key = '${name.isEmpty ? 'card' : name}-${hex(card.vendorId)}-${hex(card.deviceId)}-$driver';
  return Directory(p.join(cacheRoot.path, key.length > 96 ? key.substring(0, 96) : key));
}

/// The arguments of one training, frozen (brush_help.txt of lot SP2)
List<String> brushArguments({
  required String dataset,
  required String export,
  required int steps,
  required int maxGaussians,
  required int shDegree,
  required int resolution,
}) => [
  dataset,
  '--total-steps',
  '$steps',
  '--max-splats',
  '$maxGaussians',
  '--sh-degree',
  '$shDegree',
  '--max-resolution',
  '$resolution',
  '--export-every',
  '$steps',
  '--export-path',
  export,
  '--export-name',
  'export_{iter}.ply',
];

/// The file of the export of a training of [steps] steps in [export]
File brushExportOf(Directory export, int steps) => File(p.join(export.path, 'export_$steps.ply'));

/// The card Brush says it took
class BrushAdapter {
  const BrushAdapter({required this.name, required this.vendor, required this.device, required this.type});

  final String name;
  final int vendor;
  final int device;

  /// DiscreteGpu, IntegratedGpu, Cpu...
  final String type;

  @override
  String toString() => '$name ($type)';
}

final _adapter = RegExp(
  r'Using adapter AdapterInfo \{ name: "((?:[^"\\]|\\.)*)", vendor: (\d+), device: (\d+), device_type: (\w+)',
);
final _refine = RegExp(r'\] Refine iter (\d+), (\d+) splats\.');
final _eval = RegExp(r'\] Eval iter (\d+): PSNR ([\d.]+), ssim ([\d.]+)');
final _loaded = RegExp(r'\] Loaded dataset with (\d+) training, (\d+) eval views');
const _done = '] Done training!';
const _panic = 'panicked at';

/// The card of a "Using adapter" line, null for another line
BrushAdapter? brushAdapterOf(String line) {
  final match = _adapter.firstMatch(line);
  if (match == null) {
    return null;
  }
  return BrushAdapter(
    name: match.group(1)!.replaceAll(r'\"', '"').replaceAll(r'\\', r'\'),
    vendor: int.parse(match.group(2)!),
    device: int.parse(match.group(3)!),
    type: match.group(4)!,
  );
}

/// Whether Brush took [card]: of its kind, and of its ids when the probe read them, else of its name
bool brushTook(BrushAdapter adapter, GpuAdapter card) {
  final type = switch (card.kind) {
    GpuKind.discrete => 'DiscreteGpu',
    GpuKind.integrated => 'IntegratedGpu',
    GpuKind.virtual => 'VirtualGpu',
    GpuKind.cpu => 'Cpu',
    GpuKind.other => 'Other',
  };
  if (adapter.type != type) {
    return false;
  }
  if (card.vendorId != null && card.deviceId != null) {
    return adapter.vendor == card.vendorId && adapter.device == card.deviceId;
  }
  return adapter.name.trim().toLowerCase() == card.name.trim().toLowerCase();
}

/// Where the training is: [step] of [steps], [splats] gaussians, [elapsed] since the training started
class BrushProgress {
  const BrushProgress(this.step, this.steps, {required this.splats, required this.elapsed});

  final int step;
  final int steps;
  final int splats;
  final Duration elapsed;

  @override
  String toString() => 'BrushProgress($step of $steps, $splats splats, ${elapsed.inSeconds} s)';
}

/// What a training gave: its export, the gaussians of the last count, the card, the views it learned from, its PSNR
/// when it had views held out (never in splat-v1), and how long it took
class BrushResult {
  const BrushResult({
    required this.ply,
    required this.splats,
    required this.adapter,
    required this.views,
    required this.time,
    this.psnr,
  });

  final File ply;
  final int splats;

  /// The card Brush said it took, null when it never said (a build that logs it otherwise)
  final BrushAdapter? adapter;
  final int views;
  final Duration time;
  final double? psnr;
}

/// The training of the copy of a splat scene for the headset by Brush (see the top of this file)
class BrushRunner {
  BrushRunner({
    required this.runner,
    required this.brush,
    required this.cardCheck,
    required this.cacheRoot,
    this.stallTimeout = SplatV1.brushSilence,
    this.pollInterval = const Duration(milliseconds: 200),
    this.recheck = const Duration(seconds: 30),
    this.panicGrace = const Duration(seconds: 1),
    this.environment = const {},
    Duration Function()? elapsed,
  }) : _elapsed = elapsed ?? sidecarStopwatch();

  final ProcessRunner runner;

  /// brush_app.exe, or brush_app on Linux
  final String brush;
  final BrushCardCheck cardCheck;

  /// Where each card has its working folder ([brushCacheFolderOf])
  final Directory cacheRoot;
  final Duration stallTimeout;
  final Duration pollInterval;

  /// How long the run waits before it asks the card again
  final Duration recheck;

  /// How long a panic may go without its message before Brush is stopped all the same
  final Duration panicGrace;

  /// Added to the environment of Brush
  final Map<String, String> environment;
  final Duration Function() _elapsed;

  /// Trains the dataset of [work] (dataset/images and dataset/sparse/0) into `brush/export_<steps>.ply` with the steps,
  /// the gaussians, the degree and the definition of [settings]; throws a BackendException: cancelled, gpuUnavailable,
  /// gpuOutOfMemory, trainingFailed, trainingStalled, diskFull
  Future<BrushResult> train(
    SplatWorkFolder work, {
    required SplatSettings settings,
    required NativeCancelFlag cancel,
    void Function(BrushProgress progress)? onProgress,
    void Function(int free)? onWaiting,
    void Function(int pid)? onStarted,
  }) async {
    final steps = settings.steps;
    _files(() => lengthenShortImages(work.images));
    final ready = await _waitForCard(cancel, onWaiting);
    final card = ready.card;
    final device = cubeclDeviceOf(ready.report, card);
    if (device == null) {
      throw BackendException(ImmersiveErrorCode.gpuUnavailable, '${card.name} is not a card Vulkan lists for Brush');
    }
    final folder = brushCacheFolderOf(cacheRoot, card);
    _files(() {
      folder.createSync(recursive: true);
      if (work.export.existsSync()) {
        work.export.deleteSync(recursive: true);
      }
      work.export.createSync(recursive: true);
      work.logs.createSync(recursive: true);
    });

    BrushAdapter? adapter;
    var views = 0;
    var splats = 0;
    var done = 0;
    double? psnr;
    Duration? trainingStarted;
    Duration? panicAt;
    final panicLines = <String>[];
    var saidOutOfMemory = false;

    BackendException panicFailure() {
      final words = panicLines.isEmpty ? 'no message' : panicLines.join(' ');
      if (brushSaysOutOfMemory(words)) {
        return BackendException(ImmersiveErrorCode.gpuOutOfMemory, 'Brush ran out of graphics memory: $words');
      }
      if (words.contains(brushPlaneText)) {
        return BackendException(
          ImmersiveErrorCode.gpuUnavailable,
          'Brush cannot run its kernels on ${card.name}: $words',
        );
      }
      return BackendException(ImmersiveErrorCode.trainingFailed, 'Brush panicked: $words');
    }

    final run = SidecarRun(
      runner: runner,
      program: brushProgram,
      launch: ProcessLaunch(
        executable: brush,
        arguments: brushArguments(
          dataset: work.dataset.path,
          export: work.export.path,
          steps: steps,
          maxGaussians: settings.maxGaussians,
          shDegree: settings.shDegree,
          resolution: settings.trainingResolution,
        ),
        workingDirectory: folder.path,
        environment: {
          'RUST_LOG': brushRustLog,
          'RUST_BACKTRACE': '0',
          'CUBECL_WGPU_DEFAULT_DEVICE': device,
          ...environment,
        },
      ),
      cancel: cancel,
      elapsed: _elapsed,
      stallTimeout: stallTimeout,
      pollInterval: pollInterval,
      log: work.logOf('brush'),
      onStarted: onStarted,
      onTick: () => panicAt != null && _elapsed() - panicAt! >= panicGrace ? panicFailure() : null,
      onLine: (line, {required isError}) {
        if (brushSaysOutOfMemory(line)) {
          saidOutOfMemory = true;
        }
        if (panicAt != null) {
          // The message of the panic: its lines on the error output, blank ones too (wgpu puts one before its causes),
          // up to the note of Rust, a backtrace or another panic
          if (!isError) {
            return null;
          }
          final text = line.trim();
          if (text.startsWith('note:') || text.startsWith('stack backtrace:') || text.contains(_panic)) {
            return panicFailure();
          }
          if (text.isNotEmpty && panicLines.length < brushPanicLines) {
            panicLines.add(text);
          }
          return null;
        }
        if (isError && line.contains(_panic)) {
          panicAt = _elapsed();
          return null;
        }
        final took = brushAdapterOf(line);
        if (took != null) {
          adapter = took;
          if (!brushTook(took, card)) {
            return BackendException(
              ImmersiveErrorCode.gpuUnavailable,
              'Brush took $took instead of ${card.name}, the card of the gate',
            );
          }
          return null;
        }
        final loaded = _loaded.firstMatch(line);
        if (loaded != null) {
          views = int.parse(loaded.group(1)!);
          return null;
        }
        if (line.contains('] Start training loop.')) {
          trainingStarted = _elapsed();
          return null;
        }
        final refine = _refine.firstMatch(line);
        if (refine != null) {
          final step = int.parse(refine.group(1)!).clamp(0, steps);
          splats = int.parse(refine.group(2)!);
          if (step > done) {
            done = step;
            onProgress?.call(
              BrushProgress(step, steps, splats: splats, elapsed: _elapsed() - (trainingStarted ?? Duration.zero)),
            );
          }
          return null;
        }
        final eval = _eval.firstMatch(line);
        if (eval != null) {
          psnr = double.parse(eval.group(2)!);
          return null;
        }
        if (line.contains(_done) && done < steps) {
          done = steps;
          onProgress?.call(
            BrushProgress(steps, steps, splats: splats, elapsed: _elapsed() - (trainingStarted ?? Duration.zero)),
          );
        }
        return null;
      },
    );
    final started = _elapsed();
    try {
      await run.run();
    } on SidecarFailure catch (failure) {
      // Ended before the end of its panic was read, or after it said its memory was short
      if (panicAt != null) {
        throw panicFailure();
      }
      if (saidOutOfMemory && failure.code == ImmersiveErrorCode.trainingFailed) {
        throw SidecarFailure(
          ImmersiveErrorCode.gpuOutOfMemory,
          'Brush ran out of graphics memory: ${failure.message}',
          exitCode: failure.exitCode,
        );
      }
      rethrow;
    }
    final ply = brushExportOf(work.export, steps);
    if (!ply.existsSync()) {
      throw BackendException(
        ImmersiveErrorCode.trainingFailed,
        'Brush ended without writing ${p.basename(ply.path)}: ${run.tail}',
      );
    }
    return BrushResult(
      ply: ply,
      splats: splats,
      adapter: adapter,
      views: views,
      time: _elapsed() - started,
      psnr: psnr,
    );
  }

  /// [action] on the files of the work folder; a file that cannot be made, rewritten or removed is trainingFailed, or
  /// diskFull
  T _files<T>(T Function() action) {
    try {
      return action();
    } on FileSystemException catch (error) {
      throw splatFileFailure(error, 'Brush', ImmersiveErrorCode.trainingFailed);
    }
  }

  /// Asks the card until it has the memory free (see the top of this file)
  Future<BrushCardReady> _waitForCard(NativeCancelFlag cancel, void Function(int free)? onWaiting) async {
    while (true) {
      if (cancel.isCancelled) {
        throw const BackendException(ImmersiveErrorCode.cancelled, 'Cancelled before Brush started');
      }
      final BrushCard answer;
      try {
        answer = await cardCheck();
      } catch (error) {
        throw BackendException(ImmersiveErrorCode.gpuUnavailable, 'The graphics card did not answer: $error');
      }
      switch (answer) {
        case BrushCardReady():
          return answer;
        case BrushCardRefused(:final reason):
          throw BackendException(ImmersiveErrorCode.gpuUnavailable, reason);
        case BrushCardWait(:final free):
          onWaiting?.call(free);
          for (var waited = Duration.zero; waited < recheck; waited += pollInterval) {
            if (cancel.isCancelled) {
              break;
            }
            await Future<void>.delayed(pollInterval);
          }
      }
    }
  }
}

/// Makes each JPEG or PNG under [folder] shorter than [brushMinImageBytes] longer by a comment, its pixels untouched;
/// returns how many were
int lengthenShortImages(Directory folder) {
  if (!folder.existsSync()) {
    return 0;
  }
  var lengthened = 0;
  for (final entry in folder.listSync(recursive: true)) {
    if (entry is! File) {
      continue;
    }
    final length = entry.lengthSync();
    if (length >= brushMinImageBytes) {
      continue;
    }
    final bytes = entry.readAsBytesSync();
    final longer = lengthenedImage(bytes, brushMinImageBytes);
    if (longer != null) {
      entry.writeAsBytesSync(longer, flush: true);
      lengthened++;
    }
  }
  return lengthened;
}

const _padding = 'Immuch360: padded for Brush 0.3.0, which reads 16387 bytes of an image at once';

/// [bytes] of a JPEG or a PNG made [atLeast] bytes long by a comment (a COM segment after the SOI of a JPEG, a tEXt
/// chunk after the IHDR of a PNG); null for anything else
Uint8List? lengthenedImage(Uint8List bytes, int atLeast) {
  final missing = atLeast - bytes.length;
  if (missing <= 0) {
    return bytes;
  }
  if (bytes.length > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    // FF FE, a length that counts itself, the text; at most 65 533 bytes of text, enough for 16 387
    final text = _paddingText(missing - 4);
    final length = text.length + 2;
    return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xFE, length >> 8, length & 0xFF, ...text, ...bytes.sublist(2)]);
  }
  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  if (bytes.length > 33 && [for (var i = 0; i < 8; i++) bytes[i]].join(',') == signature.join(',')) {
    // The IHDR chunk: 8 bytes of length and type, 13 of data, 4 of CRC, after the 8 of the signature
    const ihdrEnd = 8 + 25;
    final keyword = ascii.encode('Comment');
    final text = _paddingText(missing - 12 - keyword.length - 1);
    final data = [...keyword, 0, ...text];
    final type = ascii.encode('tEXt');
    final chunk = BytesBuilder()
      ..add(_u32(data.length))
      ..add(type)
      ..add(data)
      ..add(_u32(_crc32([...type, ...data])));
    return Uint8List.fromList([...bytes.sublist(0, ihdrEnd), ...chunk.takeBytes(), ...bytes.sublist(ihdrEnd)]);
  }
  return null;
}

List<int> _paddingText(int length) {
  final text = StringBuffer(_padding);
  while (text.length < length) {
    text.write(' ');
  }
  return ascii.encode(text.toString().substring(0, length < _padding.length ? _padding.length : length));
}

Uint8List _u32(int value) => Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.big);

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc = _crcTable[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return crc ^ 0xFFFFFFFF;
}
