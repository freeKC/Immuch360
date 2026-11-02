// A small program that makes splat scenes through the engine of the app (lot SP6: splat_engine.dart, with the runners
// of lot SP4, the files of lot SP3, COLMAP and Brush started through the launcher of the app), with no Flutter:
// compiled by `dart compile exe` in the windows job of the desktop workflow (artifact Immuch360-AI-tools-windows-x64,
// beside the fakes and the other probes) and in the test job on Linux, it is the essay of the lot on a PC with a
// graphics card while no Flutter build runs there. It prints one JSON line per event, with the milliseconds since its
// start:
//   installed  an archive of the mirror checked and unpacked, or found installed already with the same sum
//   start      the job: its photos, its work root, its settings
//   stage      a step of the engine entered, with its share of the job in thousandths
//   progress   a count of a step (photos, images of COLMAP, steps of Brush) with the time left of the whole job
//   card       the graphics card asked before Brush starts: its name, the memory free, the need
//   cancel     the flag raised, at --cancel-at
//   done       the scene written: its files, gaussians, bytes, the head the probe of the app reads, the times
//   failed     the code of the failure and its message
//
//   splat_probe install --mirror DIR --components DIR [--platform windows|linux]
//       the archives of COLMAP and Brush of the mirror (colmap-cpu-<system>-x64.zip, brush-vulkan-<system>-x64.zip,
//       the names of the catalogue), each checked against its SHA-256 in DIR/SHA256SUMS before anything is unpacked,
//       unpacked once into DIR/engines/<id>/ with their licences (licenses/ must be there); an archive installed
//       already with the same sum is left as it is
//   splat_probe run (--components DIR | --colmap EXE --brush EXE) --photos DIR --out DIR [--name salon]
//       [--work-root DIR] [--cache DIR] [--steps N] [--max-gaussians N] [--resolution N] [--subject place|object]
//       [--ply] [--video] [--card nvidia-smi|fake-rtx] [--need-mib N] [--cancel-at STAGE[:COUNT]] [--launcher RUN]
//       [--env NAME=VALUE]...
//       a scene of the JPEG photos of DIR (in the order of their names, each a member read in place and summed, as a
//       photo of the library is) written to <out>/<name>_splat.spz (and .ply), through the engine of the app. The
//       photos are copied as they are into one camera: the preparation of lot SP5 needs Flutter, so the photos of an
//       essay are given prepared already (1 600 pixels at most). The card is read from nvidia-smi on the PC, or is
//       the RTX the fake Brush knows. A second run of the same photos and settings in the same work root starts again
//       from the poses the first one kept (Retry). --env goes to COLMAP and Brush (the fakes take their modes so).
//
// Exit codes: 0 done, 1 a failure (its code and message in the last JSON line), 2 bad arguments, 3 cancelled.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// ignore: depend_on_referenced_packages
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/process/managed_process.dart';
import 'package:immich_mobile/desktop/ai/splat/brush_runner.dart';
import 'package:immich_mobile/desktop/ai/splat/colmap_runner.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_engine.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_work_folder.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:path/path.dart' as p;

final _clock = Stopwatch()..start();

void _event(String name, [Map<String, Object?> values = const {}]) =>
    stdout.writeln(jsonEncode({'event': name, 'ms': _clock.elapsedMilliseconds, ...values}));

Never _usage(String message) {
  stderr.writeln('splat_probe: $message');
  exit(2);
}

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) {
    _usage('install or run');
  }
  final options = <String, String>{};
  final environment = <String, String>{};
  for (var i = 1; i < arguments.length; i++) {
    final name = arguments[i];
    if (!name.startsWith('--')) {
      _usage('unexpected $name');
    }
    final key = name.substring(2);
    if (key == 'ply' || key == 'video') {
      options[key] = 'true';
    } else if (i + 1 < arguments.length) {
      final value = arguments[++i];
      if (key == 'env') {
        final at = value.indexOf('=');
        environment[value.substring(0, at)] = value.substring(at + 1);
      } else {
        options[key] = value;
      }
    } else {
      _usage('$name needs a value');
    }
  }
  switch (arguments.first) {
    case 'install':
      exit(await _install(options));
    case 'run':
      exit(await _run(options, environment));
    default:
      _usage('unknown command ${arguments.first}');
  }
}

/// The components of a splat scene of [platform], by the names of the catalogue
List<AiComponent> _componentsOf(String platform) => platform == 'linux'
    ? const [colmapLinuxComponent, brushLinuxComponent]
    : const [colmapWindowsComponent, brushWindowsComponent];

Future<int> _install(Map<String, String> options) async {
  final mirror = Directory(options['mirror'] ?? _usage('--mirror'));
  final components = Directory(options['components'] ?? _usage('--components'));
  final sumsFile = File(p.join(mirror.path, 'SHA256SUMS'));
  if (!sumsFile.existsSync()) {
    _event('failed', {'code': 'componentsMissing', 'message': 'No SHA256SUMS in ${mirror.path}'});
    return 1;
  }
  final sums = <String, String>{
    for (final line in sumsFile.readAsLinesSync())
      if (RegExp(r'^([0-9a-f]{64})\s+\*?(.+)$').firstMatch(line.trim()) case final match?)
        p.basename(match.group(2)!): match.group(1)!,
  };
  for (final component in _componentsOf(options['platform'] ?? (Platform.isWindows ? 'windows' : 'linux'))) {
    final archive = File(p.join(mirror.path, component.assetName));
    final expected = sums[component.assetName];
    if (!archive.existsSync() || expected == null) {
      _event('failed', {'code': 'componentsMissing', 'message': '${component.assetName}: not in the mirror'});
      return 1;
    }
    final bytes = archive.readAsBytesSync();
    final sum = sha256.convert(bytes).toString();
    if (sum != expected) {
      _event('failed', {'code': 'componentsMissing', 'message': '${component.assetName}: $sum, not $expected'});
      return 1;
    }
    final folder = Directory(p.join(components.path, component.installPath));
    final marker = File(p.join(folder.path, '.installed'));
    if (marker.existsSync() && marker.readAsStringSync().trim() == sum) {
      _event('installed', {'id': component.id, 'sha256': sum, 'already': true, 'folder': folder.path});
      continue;
    }
    if (folder.existsSync()) {
      folder.deleteSync(recursive: true);
    }
    var files = 0;
    var size = 0;
    for (final entry in ZipDecoder().decodeBytes(bytes)) {
      final name = p.normalize(entry.name);
      if (p.isAbsolute(name) || name.split(RegExp(r'[\\/]')).contains('..')) {
        _event('failed', {'code': 'componentsMissing', 'message': '${component.assetName}: unsafe name ${entry.name}'});
        return 1;
      }
      if (!entry.isFile) {
        continue;
      }
      final content = entry.content;
      final file = File(p.join(folder.path, name))
        ..createSync(recursive: true)
        ..writeAsBytesSync(content);
      // The programs of a Linux archive keep their executable bit
      if (!Platform.isWindows && entry.mode & 0x49 != 0) {
        Process.runSync('chmod', ['+x', file.path]);
      }
      files++;
      size += content.length;
    }
    final licences = Directory(p.join(folder.path, 'licenses'));
    if (!licences.existsSync() || licences.listSync().isEmpty) {
      _event('failed', {'code': 'componentsMissing', 'message': '${component.assetName}: no licences'});
      return 1;
    }
    marker.writeAsStringSync(sum);
    _event('installed', {
      'id': component.id,
      'sha256': sum,
      'already': false,
      'files': files,
      'bytes': size,
      'licences': licences.listSync().length,
      'folder': folder.path,
    });
  }
  return 0;
}

/// A photo of the essay: read in place, summed at each read
class _Photo implements SplatMember {
  _Photo(this.file, this.taken);

  final File file;
  @override
  final DateTime taken;

  @override
  String get name => p.basename(file.path);

  @override
  String? get camera => null;

  @override
  Future<ImmersiveSource> load(NativeCancelFlag cancel) async {
    final bytes = await file.readAsBytes();
    return ImmersiveSource(
      name: name,
      size: bytes.length,
      sha1: base64.encode(sha1.convert(bytes).bytes),
      path: file.path,
    );
  }

  @override
  Future<void> release() async {}
}

/// The photos copied as they are, in their order, into one camera (or the frames of a video, the same way)
Future<SplatPrepared> _copyPhotos(
  List<SplatMember> members, {
  required bool video,
  required String imagesFolder,
  required NativeCancelFlag cancel,
  required void Function(int done, int total) onProgress,
}) async {
  final folder = Directory(p.join(imagesFolder, video ? 'video' : 'cam1'))..createSync(recursive: true);
  for (final (index, member) in members.indexed) {
    if (cancel.isCancelled) {
      throw const BackendException(ImmersiveErrorCode.cancelled, 'Cancelled');
    }
    final source = await member.load(cancel);
    try {
      await File(source.path!).copy(p.join(folder.path, '${'${index + 1}'.padLeft(5, '0')}.jpg'));
    } finally {
      await member.release();
    }
    onProgress(index + 1, members.length);
  }
  return SplatPrepared(images: members.length, total: members.length);
}

/// The cards nvidia-smi lists, as dedicated cards of Vulkan in its order (the PC of the essay has one)
Future<GpuReport> _nvidiaSmi() async {
  final result = await Process.run('nvidia-smi', [
    '--query-gpu=index,name,memory.total,memory.used,pci.device_id,driver_version',
    '--format=csv,noheader,nounits',
  ]);
  if (result.exitCode != 0) {
    return const GpuReport(problem: GpuProbeProblem.failed);
  }
  const mib = 1024 * 1024;
  return GpuReport(
    adapters: [
      for (final line in LineSplitter.split('${result.stdout}'))
        if (line.trim().isNotEmpty)
          () {
            final fields = line.split(',').map((field) => field.trim()).toList();
            final pci = int.parse(fields[4].replaceFirst('0x', ''), radix: 16);
            final total = int.parse(fields[2]) * mib;
            return GpuAdapter(
              name: fields[1],
              kind: GpuKind.discrete,
              localMemory: total,
              vendorId: pci & 0xFFFF,
              deviceId: pci >> 16,
              driverVersion: fields[5],
              budget: total,
              usage: int.parse(fields[3]) * mib,
              vulkanIndex: int.parse(fields[0]),
            );
          }(),
    ],
  );
}

/// The RTX the fake Brush knows
const _fakeRtx = GpuAdapter(
  name: 'NVIDIA GeForce RTX 4060 Laptop GPU',
  kind: GpuKind.discrete,
  localMemory: 8 << 30,
  vendorId: 0x10DE,
  deviceId: 0x28A0,
  driverVersion: '616.56',
  vulkanIndex: 0,
);

Future<int> _run(Map<String, String> options, Map<String, String> environment) async {
  final windows = Platform.isWindows;
  final components = options['components'];
  String program(String option, AiComponent component, String Function(String folder, {bool? windows}) named) =>
      options[option] ??
      (components == null
          ? _usage('--$option or --components')
          : named(p.join(components, component.installPath), windows: windows));
  final colmap = program('colmap', windows ? colmapWindowsComponent : colmapLinuxComponent, colmapIn);
  final brush = program('brush', windows ? brushWindowsComponent : brushLinuxComponent, brushIn);
  final photosFolder = Directory(options['photos'] ?? _usage('--photos'));
  final out = Directory(options['out'] ?? _usage('--out'))..createSync(recursive: true);
  final name = options['name'] ?? 'scene';
  final video = options['video'] == 'true';
  final settings = SplatSettings(
    subject: options['subject'] == 'object' ? SplatSubject.object : SplatSubject.place,
    steps: int.tryParse(options['steps'] ?? '') ?? SplatV1.steps,
    maxGaussians: int.tryParse(options['max-gaussians'] ?? '') ?? SplatV1.maxGaussians,
    trainingResolution: int.tryParse(options['resolution'] ?? '') ?? SplatV1.trainingResolution,
    keepPly: options['ply'] == 'true',
  );
  final photos = [
    for (final entity in photosFolder.listSync())
      if (entity is File && RegExp(r'\.jpe?g$', caseSensitive: false).hasMatch(entity.path)) entity,
  ]..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
  final base = DateTime.utc(2026, 11, 1);
  final members = [for (final (index, file) in photos.indexed) _Photo(file, base.add(Duration(seconds: index)))];
  if (members.isEmpty) {
    _usage('no JPEG photos in ${photosFolder.path}');
  }

  final launcher = options['launcher'];
  final runner = ManagedProcessRunner(linuxLauncher: launcher == null ? null : p.absolute(launcher));
  final need = (int.tryParse(options['need-mib'] ?? '') ?? SplatV1.freeGraphicsMemory ~/ (1 << 20)) << 20;
  final card = options['card'] ?? 'nvidia-smi';
  final roots = [if (options['work-root'] case final root?) SplatWorkRoot(Directory(root)) else ...splatWorkRoots()];
  final engine = SplatEngine(
    images: _copyPhotos,
    colmap: ColmapRunner(runner: runner, colmap: colmap, environment: environment),
    brush: BrushRunner(
      runner: runner,
      brush: brush,
      cacheRoot: Directory(options['cache'] ?? p.join(out.path, 'brush-cache')),
      recheck: const Duration(seconds: 5),
      environment: environment,
      cardCheck: () async {
        if (card == 'fake-rtx') {
          return const BrushCardReady(_fakeRtx, GpuReport(adapters: [_fakeRtx]));
        }
        final report = await _nvidiaSmi();
        final found = report.adapters.isEmpty ? null : report.adapters.first;
        if (found == null) {
          return const BrushCardRefused('gpuNone');
        }
        _event('card', {'name': found.name, 'free': found.freeMemory, 'need': need});
        return found.freeMemory >= need ? BrushCardReady(found, report) : BrushCardWait(found.freeMemory);
      },
    ),
    roots: roots,
  );

  final spz = File(p.join(out.path, splatFileNameFor(name)));
  final ply = settings.keepPly ? File(p.join(out.path, splatFileNameFor(name, ply: true))) : null;
  final spzPart = File('${spz.path}.part')..writeAsBytesSync(const []);
  final plyPart = ply == null ? null : (File('${ply.path}.part')..writeAsBytesSync(const []));
  final job = SplatJob(
    id: 'splat-probe',
    lead: await members.first.load(NativeCancelFlag()),
    members: members,
    isVideo: video,
    settings: settings,
    partPath: spzPart.path,
    plyPartPath: plyPart?.path,
    derivativeId: 'splat-probe',
    creatorTool: 'Immuch360 Desktop splat_probe',
    created: DateTime.now().toIso8601String(),
  );
  _event('start', {
    'photos': members.length,
    'colmap': colmap,
    'brush': brush,
    'workRoot': roots.map((root) => root.folder.path).toList(),
    'key': splatJobKey(job),
    'steps': settings.steps,
    'maxGaussians': settings.maxGaussians,
    'resolution': settings.trainingResolution,
    'subject': settings.subject.name,
    'ply': settings.keepPly,
  });

  final cancel = NativeCancelFlag();
  final cancelAt = options['cancel-at']?.split(':');
  ImmersiveStage? lastStage;
  final result = await engine.run(
    job,
    cancel: cancel,
    onProgress: (progress) {
      if (progress.stage != lastStage) {
        lastStage = progress.stage;
        _event('stage', {'stage': progress.stage.name, 'perMille': progress.perMille});
      }
      _event('progress', {
        'stage': progress.stage.name,
        'perMille': progress.perMille,
        'step': progress.step,
        'steps': progress.steps,
        'remainingMs': progress.remaining?.inMilliseconds,
      });
      if (cancelAt != null &&
          !cancel.isCancelled &&
          progress.stage.name == cancelAt.first &&
          (progress.step ?? 0) >= (cancelAt.length > 1 ? int.parse(cancelAt[1]) : 0)) {
        _event('cancel', {'stage': progress.stage.name, 'step': progress.step});
        cancel.cancel();
      }
    },
  );
  if (!result.isDone) {
    for (final part in [spzPart, plyPart]) {
      if (part != null && part.existsSync()) {
        part.deleteSync();
      }
    }
    final cancelled = result.error == ImmersiveErrorCode.cancelled;
    _event(cancelled ? 'cancelled' : 'failed', {'code': result.error!.name, 'message': result.message});
    return cancelled ? 3 : 1;
  }
  spzPart.renameSync(spz.path);
  plyPart?.renameSync(ply!.path);
  // The work folder, kept until the file is saved
  await result.afterSaved?.call();
  String probe(File file) {
    final bytes = file.readAsBytesSync();
    return '${probeSplatHead(Uint8List.sublistView(bytes, 0, bytes.length.clamp(0, splatHeadBytes)), bytes.length)}';
  }

  final details = result.details! as SplatResultDetails;
  _event('done', {
    'spz': spz.path,
    'spzBytes': result.bytesWritten,
    'spzHead': probe(spz),
    if (ply != null) 'ply': ply.path,
    if (ply != null) 'plyHead': probe(ply),
    'gaussians': details.gaussians,
    'images': details.images,
    'placed': details.placed,
    'scale': details.scale,
    'subject': details.subject.name,
    'seconds': {for (final MapEntry(:key, :value) in result.stageTimes.entries) key.name: value.inMilliseconds / 1000},
  });
  return 0;
}
