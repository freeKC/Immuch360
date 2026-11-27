// The programs of Sharpen and Rebuild details as the app takes them from the installed AI components (issue 24). The
// components service gives the main file of an archive, its first program by the order of the paths (mainPath):
// immuch360-run in the Linux archives of sd-cli. Taken as sd-cli, the launcher was started as its own program, read
// "-M" as an option it does not know, printed its usage and ended with 2: Sharpen and Rebuild details never ran on
// Linux in desktop 31 to 34.
//
// With the Linux launcher and the compiled fake sd-cli of the test job (IMMUCH360_RUN_LAUNCHER, IMMUCH360_FAKE_SD_CLI)
// the command of the app is also run through the real parser of immuch360-run. With IMMUCH360_ENHANCE_COMPONENTS
// naming a folder where the linux job of the desktop workflow unpacked the published archives of sd-cli
// (ai-components-3 and 7) as the app installs them, the published launcher starts the published sd-cli of each level.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_files.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_levels.dart';
import 'package:immich_mobile/desktop/ai/enhance/sharpen_backend.dart';
import 'package:immich_mobile/desktop/ai/gen/sdcpp_runner.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/ai/process/managed_process.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart' show AiComponentState;
import 'package:path/path.dart' as p;

/// The components as the service gives them: the folder of the components and the main file of each
class _Installed implements AiComponentFiles {
  _Installed(this.root, {this.mustExist = false});

  final String root;
  final bool mustExist;

  @override
  Future<File?> verifiedFile(AiComponent component) async {
    final file = File(p.joinAll([root, ...component.mainPath.split('/')]));
    return !mustExist || file.existsSync() ? file : null;
  }

  @override
  AiComponentState stateOf(AiComponent component) => AiComponentState.installed;
}

final _launcher = Platform.environment['IMMUCH360_RUN_LAUNCHER'];
final _fakeSdCli = Platform.environment['IMMUCH360_FAKE_SD_CLI'];
final _published = Platform.environment['IMMUCH360_ENHANCE_COMPONENTS'];

Future<EnhanceFiles> _filesOf(EnhanceLevel level, AiPlatform platform, AiComponentFiles components) async {
  final found = await enhanceComponentFiles(level, platform, components, macRebuildOffered: true);
  expect(found.notInThisVersion, isFalse, reason: '$level on $platform');
  expect(found.missing, isEmpty, reason: '$level on $platform');
  return found.files!;
}

({String sdCli, String? launcher}) _programOf(EnhanceFiles files) => files.sharpen != null
    ? (sdCli: files.sharpen!.sdCli, launcher: files.sharpen!.linuxLauncher)
    : (sdCli: files.rebuild!.sdCli, launcher: files.rebuild!.linuxLauncher);

/// What the launcher and the program of [files] write and end with, started as the app starts them
Future<({int code, String out, String err})> _run(EnhanceFiles files, List<String> arguments, {bool low = true}) async {
  final program = _programOf(files);
  final runner = ManagedProcessRunner(linuxLauncher: program.launcher);
  final process = await runner.start(ProcessLaunch(executable: program.sdCli, arguments: arguments, lowPriority: low));
  final out = StringBuffer();
  final err = StringBuffer();
  final reading = [process.stdoutLines.forEach(out.writeln), process.stderrLines.forEach(err.writeln)];
  final code = await process.exitCode.timeout(const Duration(seconds: 60));
  await Future.wait(reading);
  return (code: code, out: out.toString(), err: err.toString());
}

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('enhance-files-'));
  tearDown(() => root.deleteSync(recursive: true));

  group('the program of the sd-cli levels in the installed archive', () {
    for (final (platform, program, launcher) in [
      (AiPlatform.linuxX64, 'sd-cli', 'immuch360-run'),
      (AiPlatform.windowsX64, 'sd-cli.exe', null),
      (AiPlatform.macosArm64, 'sd-cli', null),
    ]) {
      for (final level in [EnhanceLevel.sharpen, EnhanceLevel.rebuild]) {
        test(
          '${level.name} on ${platform.name}: $program, never the launcher${launcher == null ? '' : ' beside it'}',
          () async {
            final files = await _filesOf(level, platform, _Installed(root.path));
            final engine = enhanceComponentsOf(level, platform).first;
            final folder = p.joinAll([root.path, ...engine.installPath.split('/')]);
            final chosen = _programOf(files);
            expect(chosen.sdCli, p.join(folder, program));
            expect(chosen.launcher, launcher == null ? isNull : p.join(folder, launcher));
            expect(p.basename(chosen.sdCli), isNot(linuxLauncherName));
            // The program is a file of the archive, marked as a program in the catalogue
            final entry = engine.archiveFiles.where((file) => file.path == program).single;
            expect(entry.executable, isTrue);
          },
        );
      }
    }

    test('on Linux the main file of both archives is the launcher, which the levels never start as sd-cli', () async {
      for (final engine in [sdCppLinuxComponent, sdCppSeedVr2LinuxComponent]) {
        expect(p.posix.basename(engine.mainPath), linuxLauncherName, reason: engine.id);
      }
      for (final level in [EnhanceLevel.sharpen, EnhanceLevel.rebuild]) {
        final chosen = _programOf(await _filesOf(level, AiPlatform.linuxX64, _Installed(root.path)));
        expect(chosen.sdCli, isNot(chosen.launcher), reason: level.name);
      }
    });
  });

  group('the command of the app through the parser of immuch360-run', () {
    final skip = !Platform.isLinux
        ? 'Linux only'
        : _launcher == null || _fakeSdCli == null
        ? 'no immuch360-run or fake sd-cli (IMMUCH360_RUN_LAUNCHER, IMMUCH360_FAKE_SD_CLI)'
        : false;

    for (final level in [EnhanceLevel.sharpen, EnhanceLevel.rebuild]) {
      test('${level.name}: sd-cli starts, low and not low', skip: skip, () async {
        final engine = enhanceComponentsOf(level, AiPlatform.linuxX64).first;
        final folder = Directory(p.joinAll([root.path, ...engine.installPath.split('/')]))..createSync(recursive: true);
        File(_launcher!).copySync(p.join(folder.path, linuxLauncherName));
        File(_fakeSdCli!).copySync(p.join(folder.path, 'sd-cli'));
        for (final name in [linuxLauncherName, 'sd-cli']) {
          expect((await Process.run('chmod', ['+x', p.join(folder.path, name)])).exitCode, 0);
        }
        final files = await _filesOf(level, AiPlatform.linuxX64, _Installed(root.path));
        for (final low in [true, false]) {
          // The first options of the app's command, a device the fake does not list: it starts, writes its version
          // and its devices, and ends with 1 at once
          final ran = await _run(files, ['-M', 'upscale', '--backend', 'Vulkan9', '-t', '2', '-v'], low: low);
          expect(ran.err, isNot(contains('usage: immuch360-run')), reason: 'low: $low');
          expect(ran.out, contains('stable-diffusion.cpp'), reason: 'low: $low\n${ran.out}\n${ran.err}');
          expect(ran.err, contains("backend 'Vulkan9' was not found"), reason: 'low: $low');
          expect(ran.code, 1, reason: 'low: $low');
        }
      });
    }

    test('the launcher given as its own program: refused before anything starts', skip: skip, () async {
      final runner = ManagedProcessRunner(linuxLauncher: _launcher);
      await expectLater(
        runner.start(ProcessLaunch(executable: _launcher!, arguments: const ['-M', 'upscale'])),
        throwsA(isA<ProcessException>().having((error) => error.message, 'message', contains(linuxLauncherName))),
      );
    });
  });

  group('the published archives of sd-cli, unpacked as the app installs them (IMMUCH360_ENHANCE_COMPONENTS)', () {
    final skip = !Platform.isLinux
        ? 'Linux only'
        : _published == null
        ? 'no published components (IMMUCH360_ENHANCE_COMPONENTS)'
        : false;

    for (final level in [EnhanceLevel.sharpen, EnhanceLevel.rebuild]) {
      test('${level.name}: the published launcher starts the published sd-cli, low and not low', skip: skip, () async {
        // The models are not needed to start sd-cli: only the engine of the level must be installed
        final engine = enhanceComponentsOf(level, AiPlatform.linuxX64).first;
        final installed = _Installed(_published!, mustExist: true);
        expect(await installed.verifiedFile(engine), isNotNull, reason: engine.mainPath);
        final files = await _filesOf(level, AiPlatform.linuxX64, _Models(installed, engine));
        for (final low in [true, false]) {
          final ran = await _run(files, ['--help'], low: low);
          expect(ran.err, isNot(contains('usage: immuch360-run')), reason: 'low: $low');
          expect(ran.code, 0, reason: 'low: $low\n${ran.out}\n${ran.err}');
          // sd-cli's own help, which names its modes
          expect('${ran.out}${ran.err}', contains('upscale'), reason: 'low: $low');
        }
        // ignore: avoid_print
        print('${level.name}: ${_programOf(files).launcher} -> ${_programOf(files).sdCli}');
      });
    }

    // Sharpen to its end as the app runs it (desktop_enhance.dart, _sdCppBackendOf): the files of the installed
    // components, the runner on the launcher of the archive, x4plus on the Vulkan device IMMUCH360_ENHANCE_DEVICE names
    // (Mesa's software Vulkan in the linux job, which has no graphics card); the card is not checked against sd-cli's list
    test(
      'Sharpen of a small picture to its end through the published launcher and sd-cli',
      skip: skip == false && _device == null ? 'no Vulkan device (IMMUCH360_ENHANCE_DEVICE)' : skip,
      () async {
        final found = await enhanceComponentFiles(
          EnhanceLevel.sharpen,
          AiPlatform.linuxX64,
          _Installed(_published!, mustExist: true),
        );
        expect(found.missing, isEmpty, reason: 'the engine and x4plus must be installed');
        final sharpen = found.files!.sharpen!;
        final picture = _picture(96, 64);
        final backend = SdCppSharpenBackend(
          upscaler: SdCppUpscaler(
            runner: ManagedProcessRunner(linuxLauncher: sharpen.linuxLauncher),
            settings: SdCppSettings(
              sdCli: sharpen.sdCli,
              models: SdCppModels(diffusionModel: '', vae: '', textEncoder: '', lora: '', upscaler: sharpen.upscaler),
              device: _device!,
              stallTimeout: const Duration(minutes: 10),
            ),
            modelSha256: upscalerComponent.sha256!,
          ),
        );
        final work = Directory(p.join(root.path, 'work'))..createSync();
        final watch = Stopwatch()..start();
        try {
          final result = await backend.enhance(
            picture,
            workFolder: work.path,
            seed: 42,
            cancel: NativeCancelFlag(),
            onStep: (_, _) {},
          );
          expect(result.length, picture.rgba.length);
          // ignore: avoid_print
          print('Sharpen 96 x 64 on $_device: ${watch.elapsedMilliseconds} ms, ${result.length} bytes');
        } finally {
          final log = File(p.join(work.path, 'logs', 'sd-cli.log'));
          if (log.existsSync()) {
            // ignore: avoid_print
            print(log.readAsStringSync());
          }
        }
      },
      timeout: const Timeout(Duration(minutes: 20)),
    );
  });
}

final _device = Platform.environment['IMMUCH360_ENHANCE_DEVICE'];

SbsDecoded _picture(int width, int height) {
  final rgba = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = 4 * (y * width + x);
      rgba[i] = x * 255 ~/ width;
      rgba[i + 1] = y * 255 ~/ height;
      rgba[i + 2] = ((x ~/ 16 + y ~/ 16).isEven ? 60 : 190);
      rgba[i + 3] = 255;
    }
  }
  return SbsDecoded(width: width, height: height, rgba: rgba);
}

/// The engine from the installed components, the models of the level answered by a path of their own
class _Models implements AiComponentFiles {
  _Models(this.installed, this.engine);

  final _Installed installed;
  final AiComponent engine;

  @override
  Future<File?> verifiedFile(AiComponent component) async => component.id == engine.id
      ? installed.verifiedFile(component)
      : File(p.joinAll([installed.root, ...component.mainPath.split('/')]));

  @override
  AiComponentState stateOf(AiComponent component) => AiComponentState.installed;
}
