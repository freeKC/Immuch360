// The runner of sd-cli (lot P2) with the fake runner of C0: its frozen arguments, what it reads of the lines M3 saw
// (and the lines of the auto-fit plan of the pinned build, lot 13c), a graph cut into segments that goes on, the named
// failures, the stop, the silence of 180 s on a fake clock, and the checks of the image it wrote. Since release 44, the
// card it runs on: the list sd-cli prints at its start (the lines of the laptop of the owner, 8 November 2026), the
// verdict on it, a run started again on the index sd-cli gives the chosen card, shared with the upscaler of the job and
// kept for the session, and the refusals. The same runner against a real child process, the compiled fake sd-cli, is
// sdcpp_fake_cli_test.dart.

import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/gen/sdcpp_runner.dart';
import 'package:immich_mobile/desktop/ai/gpu/gpu_budget.dart';
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../fakes/fake_process_runner.dart';

/// The lines of a generation as the real sd-cli wrote them in M3 (base_q4_1536_s20, p02_landscape), cut short: the
/// version, the bars of the loading (MB/s) and of the tiles of the VAE (it/s), the sampling of 20 steps, the decoding
const _version = '[V] version: stable-diffusion.cpp version unknown, commit be48649 --- main.cpp:694';
const _generating = '[I] generating image: 1/1 - seed 1002 --- image.cpp:920';
const _oneSegment =
    '[V] flux compute buffer size: 2607.97 MB(VRAM) on Vulkan1 (peak across 1 segment) --- ggml_runner.cpp:1022';

/// The card lines of the auto-fit plan of the pinned build, as the measure of 5 November 2026 read them (run
/// G_full_seg3, --max-vram 3, on the laptop of the owner: the Intel chip first, the RTX second)
const _planIntel =
    '[I]     Vulkan0      Intel(R) RaptorLake-S Mobile Graphics Controller free   7350 MiB, budget   3072 MiB '
    '--- backend_fit.cpp:328';
const _planRtx =
    '[I]     Vulkan1      NVIDIA GeForce RTX 4060 Laptop GPU free   7188 MiB, budget   3072 MiB --- backend_fit.cpp:328';
const _planRam = '[I]     RAM          free   4737 MiB, params budget   2689 MiB --- backend_fit.cpp:334';

/// Below the floor of the cut (run F_full_2600 of the same measure, a budget of 2 600 MiB): the budget 14 MiB short
/// for the first single block, the card itself not
const _planBelowFloor =
    '[I]     Vulkan1      NVIDIA GeForce RTX 4060 Laptop GPU free   7188 MiB, budget   2600 MiB --- backend_fit.cpp:328';
const _belowFloor = [
  (
    '[W] [E] model manager memory on Vulkan1: reported free 6705.71 MB / total 7956.00 MB, tracked weights 121.22 MB '
        '/ other runtime 0.00 MB / current runtime 108.00 MB --- model_manager.cpp:1788',
    isError: false,
  ),
  (
    '[W] model manager cannot make enough memory available on Vulkan1: need 2896.82 MB device / 2492.82 MB budget, '
        'available 6705.71 MB device / 2478.82 MB budget --- model_manager.cpp:2018',
    isError: false,
  ),
  ('flux segment 7/27 (flux.single_blocks.0) failed during weight preparation --- ggml_runner.cpp:899', isError: false),
  ('[E] diffusion model compute failed --- diffusion_engine.cpp:2655', isError: true),
  ('[E] Diffusion model sampling failed --- diffusion_engine.cpp:2888', isError: true),
  ('[E] sampling for image 1/1 failed after 6.74s --- image.cpp:961', isError: true),
  ('[E] generate failed --- main.cpp:926', isError: true),
];

/// A shortfall sd-cli recovers from (run F_full_2700 of the same measure, a budget of 2 700 MiB: four such lines in
/// segments, then its image): 48.50 MiB short of the budget
const _recovered =
    '[W] model manager cannot make enough memory available on Vulkan1: need 687.21 MB device / 2560.04 MB budget, '
    'available 4290.52 MB device / 2511.54 MB budget --- model_manager.cpp:2018';

/// The list sd-cli printed on the laptop of the owner before it loaded anything (panorama-vulkan-2026-11-08,
/// sd-cli-2.log, lines 2 to 4, given the --backend diffusion=Vulkan0 of desktop build 23): the Intel chip first, where
/// the probe of the app put the RTX 4060 first
const _listedIntel =
    'ggml_vulkan: 0 = Intel(R) RaptorLake-S Mobile Graphics Controller (Intel Corporation) | uma: 1 | fp16: 1 '
    '| bf16: 0 | fp4: 0 | warp size: 32 | shared memory: 32768 | int dot: 1 | matrix cores: none';
const _listedRtx =
    'ggml_vulkan: 1 = NVIDIA GeForce RTX 4060 Laptop GPU (NVIDIA) | uma: 0 | fp16: 1 | bf16: 1 | fp4: 0 '
    '| warp size: 32 | shared memory: 49152 | int dot: 1 | matrix cores: NV_coopmat2';

/// The list of sd-cli-4.log, with the workaround of the owner (GGML_VK_VISIBLE_DEVICES=1): the RTX 4060 alone, as 0
const _listedRtxAlone =
    'ggml_vulkan: 0 = NVIDIA GeForce RTX 4060 Laptop GPU (NVIDIA) | uma: 0 | fp16: 1 | bf16: 1 | fp4: 0 '
    '| warp size: 32 | shared memory: 49152 | int dot: 1 | matrix cores: NV_coopmat2';

/// The line of the RTX 4060 alone in the auto-fit plan of that run
const _planRtxAlone =
    '[I]     Vulkan0      NVIDIA GeForce RTX 4060 Laptop GPU free   7188 MiB, budget   6674 MiB '
    '--- backend_fit.cpp:328';

/// The cards the gate chooses on that laptop: the RTX 4060, or the Intel chip when "Try on integrated graphics" is on
const _rtx = SdCppCard(name: 'NVIDIA GeForce RTX 4060 Laptop GPU', integrated: false);
const _intel = SdCppCard(name: 'Intel(R) RaptorLake-S Mobile Graphics Controller', integrated: true);

/// A device line of the list for the cases no PC printed
String _line(int index, String name, {bool uma = false, String driver = 'NVIDIA'}) =>
    'ggml_vulkan: $index = $name ($driver) | uma: ${uma ? 1 : 0} | fp16: 1 | bf16: 1 | warp size: 32';

/// The list as sd-cli prints it at its start: its count, then its devices, on the error output (ggml's default logger)
List<(String, {bool isError})> _listing(List<String> devices) => [
  ('ggml_vulkan: Found ${devices.length} Vulkan devices:', isError: true),
  for (final device in devices) (device, isError: true),
];

/// A device of the list as the tests write it, "index|name|driver|uma"; null for a line that is none
String? _deviceOf(String line) {
  final device = ggmlVulkanDeviceOf(line);
  return device == null ? null : '${device.index}|${device.name}|${device.driver}|${device.uma}';
}

/// A card of the auto-fit plan as the tests write it, "device|name|free MiB|budget MiB"; null for a line that is none
String? _planOf(String line) {
  final plan = sdCppPlanCardOf(line);
  return plan == null ? null : '${plan.device}|${plan.name}|${plan.free >> 20}|${plan.budget >> 20}';
}

/// The verdict on the device lines [lines] for [card], sd-cli given the index [given]
SdCppDeviceVerdict _verdictOf(List<String> lines, SdCppCard card, int given, {String? visibleDevices}) {
  final listed = [for (final line in lines) ggmlVulkanDeviceOf(line)!];
  return sdCppDeviceVerdict(listed, card, given, visibleDevices: visibleDevices);
}

/// A verdict as the tests write it: "run 1", "restart 0", "refuse", and " by kind" when no name matched
String _said(SdCppDeviceVerdict verdict) {
  final device = verdict.device;
  return '${verdict.action.name}${device == null ? '' : ' ${device.index}'}${verdict.byKind ? ' by kind' : ''}';
}

/// The --backend a launch was given
String _backendOf(ProcessLaunch launch) => launch.arguments[launch.arguments.indexOf('--backend') + 1];

List<(String, {bool isError})> _generation({
  int steps = 20,
  List<String> listed = const [],
  List<String> plan = const [],
  List<String> beforeSteps = const [_oneSegment],
}) => [
  (_version, isError: false),
  if (listed.isNotEmpty) ..._listing(listed),
  for (final line in plan) (line, isError: false),
  ('  |##################################################| 108/108 - 325.06MB/s', isError: false),
  ('  |=>                                                |  1/40 -   3.40it/s', isError: false),
  ('  |==================================================| 40/40 -  32.26it/s', isError: false),
  (_generating, isError: false),
  ('  |################                                  |  47/149 -  25.21MB/s', isError: false),
  for (final line in beforeSteps) (line, isError: false),
  for (var step = 1; step <= steps; step++)
    (
      '  |=====>                                            | ${'$step'.padLeft(2)}/$steps -   8.${30 + step}s/it'
          ' - ETA 01:13',
      isError: false,
    ),
  ('  |=>                                                |  1/55 -  16.95it/s - ETA 00:02', isError: false),
  ('  |==================================================| 55/55 -  17.54it/s', isError: false),
  ('[I] generate_image completed in 198.39s --- image.cpp:1140', isError: false),
];

/// The texts M3 read when the memory ran short (section 5), on the outputs sd-cli writes them to
const _outOfMemory = [
  (
    '[W] model manager cannot make enough memory available on Vulkan1: need 4109.22 MB device / 3597.22 MB budget, '
        'available 2892.77 MB device / unlimited budget --- model_manager.cpp:2018',
    isError: false,
  ),
  ('flux segment 1/1 (graph) failed during weight preparation --- ggml_runner.cpp:899', isError: false),
  ('[E] diffusion model compute failed --- diffusion_engine.cpp:2655', isError: true),
  ('[E] generate failed --- main.cpp:926', isError: true),
];

/// The fake runner, writing [image] at the output of each launch as sd-cli would before it ends
class _WritingRunner implements ProcessRunner {
  _WritingRunner(this.inner, {this.image});

  final FakeProcessRunner inner;
  final img.Image? image;

  @override
  Future<RunningProcess> start(ProcessLaunch launch) async {
    final out = launch.arguments[launch.arguments.indexOf('-o') + 1];
    if (image != null) {
      File(out).writeAsBytesSync(img.encodePng(image!));
    }
    return inner.start(launch);
  }
}

/// The fake runner, writing [bytes] at the output of each launch: a file sd-cli would leave broken
class _BytesRunner implements ProcessRunner {
  _BytesRunner(this.inner, this.bytes);

  final FakeProcessRunner inner;
  final List<int> bytes;

  @override
  Future<RunningProcess> start(ProcessLaunch launch) async {
    File(launch.arguments[launch.arguments.indexOf('-o') + 1]).writeAsBytesSync(bytes);
    return inner.start(launch);
  }
}

/// [image] with its first row the pure green of the control frame: 32 of the 480 pixels outside the photo
img.Image _greenRow(img.Image image) {
  for (var x = 0; x < image.width; x++) {
    image.setPixelRgb(x, 0, 0, 255, 0);
  }
  return image;
}

img.Image _varied(int width, int height) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgb(x, y, (x * 255) ~/ width, (y * 255) ~/ height, 120);
    }
  }
  return image;
}

void main() {
  late Directory folder;
  late NativeCancelFlag cancel;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('sdcpp-runner-');
    cancel = NativeCancelFlag();
    SdCppDevice.forgetLearned();
  });

  tearDown(() {
    cancel.free();
    folder.deleteSync(recursive: true);
  });

  SdCppSettings settings({Duration stall = const Duration(seconds: 180)}) => SdCppSettings(
    sdCli: '/engines/sd-cpp-vulkan-linux-x64/sd-cli',
    models: const SdCppModels(
      diffusionModel: '/ai/models/flux-2-klein-base-4b-Q4_0.gguf',
      vae: '/ai/models/flux2-vae.safetensors',
      textEncoder: '/ai/models/Qwen3-4B-Q4_K_M.gguf',
      lora: '/ai/models/lora/flux-2-klein-4B-360-erp-outpaint-lora_V1.safetensors',
      upscaler: '/ai/models/RealESRGAN_x4plus.pth',
    ),
    device: 'Vulkan1',
    threads: 30,
    stallTimeout: stall,
  );

  /// The laptop of the owner: sd-cli given [device] for [card]
  SdCppSettings laptop({String device = 'Vulkan0', SdCppCard card = _rtx}) => SdCppSettings(
    sdCli: settings().sdCli,
    models: settings().models,
    device: device,
    card: card,
    threads: 30,
  );

  /// The messages of the logger [name] at [level] and above, from now to the end of the test
  List<String> recorded(String name, {Level level = Level.ALL}) {
    final heard = <String>[];
    final before = Logger.root.level;
    Logger.root.level = Level.ALL;
    final listening = Logger.root.onRecord
        .where((record) => record.loggerName == name && record.level >= level)
        .listen((record) => heard.add(record.message));
    addTearDown(() async {
      Logger.root.level = before;
      await listening.cancel();
    });
    return heard;
  }

  GeneratorRequest request({int width = 1536, int height = 768, int? graphicsBudget}) => GeneratorRequest(
    controlPath: p.join(folder.path, 'control.png'),
    outputPath: p.join(folder.path, 'generated.png'),
    workFolder: folder.path,
    prompt: 'Fill the green spaces according to the image.',
    seed: 1002,
    width: width,
    height: height,
    graphicsBudget: graphicsBudget,
  );

  SdCppGenerator generator(ProcessRunner runner, {bool checkImages = false, Duration Function()? elapsed}) =>
      SdCppGenerator(
        runner: runner,
        settings: settings(),
        generatorSha256: 'c3a28545',
        loraSha256: '567cc22d',
        checkImages: checkImages,
        elapsed: elapsed,
      );

  group('the arguments', () {
    test('are those M3 ran: the card named, flash attention, the encoder on the processor, 1536 x 768, 20 steps', () {
      expect(generator(FakeProcessRunner([const FakeProcessScript()])).argumentsOf(request()), [
        '--diffusion-model',
        '/ai/models/flux-2-klein-base-4b-Q4_0.gguf',
        '--vae',
        '/ai/models/flux2-vae.safetensors',
        '--llm',
        '/ai/models/Qwen3-4B-Q4_K_M.gguf',
        '--lora-model-dir',
        '/ai/models/lora',
        '--backend',
        'diffusion=Vulkan1,vae=Vulkan1,te=CPU',
        '--flash-attn',
        'on',
        '--conv-direct',
        'auto,vae=on',
        '--vae-tiling',
        '-r',
        p.join(folder.path, 'control.png'),
        '-W',
        '1536',
        '-H',
        '768',
        '--steps',
        '20',
        '--cfg-scale',
        '5.0',
        '--sampling-method',
        'euler',
        '-s',
        '1002',
        '-p',
        'Fill the green spaces according to the image.<lora:flux-2-klein-4B-360-erp-outpaint-lora_V1:0.9>',
        '-n',
        'text, worst quality, blurry, ugly',
        '-t',
        '30',
        '-v',
        '-o',
        p.join(folder.path, 'generated.png'),
      ]);
      final upscale = SdCppUpscaler(runner: FakeProcessRunner([]), settings: settings(), modelSha256: '4fa0d389');
      expect(
        upscale.argumentsOf(UpscaleRequest(inputPath: 'wrapped.png', outputPath: 'x4.png', workFolder: folder.path)),
        [
          '-M',
          'upscale',
          '-i',
          'wrapped.png',
          '--upscale-model',
          '/ai/models/RealESRGAN_x4plus.pth',
          '--backend',
          'Vulkan1',
          '-t',
          '30',
          '-v',
          '-o',
          'x4.png',
        ],
      );
    });

    test('the budget the queue read: --max-vram after the card, in GiB rounded down to four decimals, as measured', () {
      // The measure of 5 November 2026 gave sd-cli "2.7344" for 2 800 MiB, "3" and "4": a single value, every card
      final full = generator(FakeProcessRunner([])).argumentsOf(request());
      final given = generator(FakeProcessRunner([])).argumentsOf(request(graphicsBudget: 5018 * 1024 * 1024));
      final card = given.indexOf('--backend');

      expect(given.sublist(card, card + 4), [
        '--backend',
        'diffusion=Vulkan1,vae=Vulkan1,te=CPU',
        '--max-vram',
        '4.9003',
      ]);
      expect([...given]..removeRange(card + 2, card + 4), full);
      expect(full, isNot(contains('--max-vram')), reason: 'no budget read: the free memory sd-cli reads itself');
      expect(sdCppVramBudget(2800 * 1024 * 1024), '2.7343');
      expect(sdCppVramBudget(3 * 1024 * 1024 * 1024), '3.0000');
      expect(sdCppVramBudget(5160 * 1024 * 1024), '5.0390');
      expect(sdCppVramBudget(16 * 1024 * 1024 * 1024 - 1), '15.9999');
      expect(double.parse(sdCppVramBudget(4404 * 1024 * 1024)) * 1024, lessThanOrEqualTo(4404));
    });

    test('the budget from the probe on Windows only: on Linux no --max-vram, sd-cli keeps its own reserve', () {
      // Review of lot 13c: the probe read 4 906 MiB free. On Windows sd-cli's Vulkan figure leaves other programs out
      // and is given the probe's less 512 MiB; on Linux both read VK_EXT_memory_budget, and a budget from the probe
      // would drop sd-cli's reserve when sd-cli reads less
      const probed = 4906 * 1024 * 1024;
      final linux = generator(
        FakeProcessRunner([]),
      ).argumentsOf(request(graphicsBudget: panoramaGeneratorBudget(probed, windows: false)));
      final windows = generator(
        FakeProcessRunner([]),
      ).argumentsOf(request(graphicsBudget: panoramaGeneratorBudget(probed, windows: true)));

      expect(linux, isNot(contains('--max-vram')));
      expect(linux, generator(FakeProcessRunner([])).argumentsOf(request()));
      final card = windows.indexOf('--backend');
      expect(windows.sublist(card + 2, card + 4), ['--max-vram', '4.2910']);
    });

    test('every option is one the pinned sd-cli lists in its --help, and none is deprecated there', () {
      final help = File('test/fixtures/ai_immersive/sd_cli_help.txt').readAsLinesSync();
      final options = <String>{
        for (final argument in [
          ...generator(FakeProcessRunner([])).argumentsOf(request(graphicsBudget: 3 * 1024 * 1024 * 1024)),
          ...SdCppUpscaler(
            runner: FakeProcessRunner([]),
            settings: settings(),
            modelSha256: '',
          ).argumentsOf(const UpscaleRequest(inputPath: 'a', outputPath: 'b', workFolder: 'c')),
        ])
          if (argument.startsWith('-') && !argument.contains(' ')) argument,
      };
      // "  -o, --output <string>   path..." or "  --vae <string>   path...": each option with its line
      final listed = <String, String>{};
      for (final line in help) {
        final match = RegExp(r'^  (?:(-\w), )?(--[\w-]+)').firstMatch(line);
        if (match != null) {
          listed[match.group(2)!] = line;
          if (match.group(1) != null) {
            listed[match.group(1)!] = line;
          }
        }
      }
      expect(listed.length, greaterThan(150));
      for (final option in options) {
        expect(listed.keys, contains(option), reason: '$option is not in sd_cli_help.txt');
        expect(listed[option], isNot(contains('deprecated')), reason: option);
      }
      expect(help.first, 'stable-diffusion.cpp version unknown, commit be48649');
      // The options of the design that the build no longer wants
      expect(options, isNot(contains('--clip-on-cpu')));
      expect(options, isNot(contains('--diffusion-fa')));
      // The reference sd-cli makes itself, for every card since lot 13c (desktop build 21 capped it on some)
      expect(options, isNot(contains('--ref-image-args')));
      // The two options of lot 13c in the form the build documents: a budget in GiB as a single value, and the
      // convolution of the VAE as an assignment after auto
      expect(options, containsAll(['--max-vram', '--conv-direct']));
      expect(listed['--max-vram'], contains('budget in GiB'));
      final maxVram = help.indexWhere((line) => line.startsWith('  --max-vram'));
      expect(help.sublist(maxVram, maxVram + 4).join(' '), contains('Accepts a single value'));
      expect(listed['--conv-direct'], contains('diffusion/vae/controlnet assignments'));
      expect(help[help.indexWhere((line) => line.startsWith('  --conv-direct')) + 1], contains('auto,vae=off'));
      expect(sdCppConvDirect, matches(RegExp(r'^auto,vae=(on|off)$')));
    });

    test('the threads are the logical processors less two, the card a Vulkan device of ggml', () {
      final defaults = SdCppSettings(sdCli: 'sd-cli', models: settings().models, device: 'Vulkan0');
      expect(defaults.threads, Platform.numberOfProcessors > 2 ? Platform.numberOfProcessors - 2 : 1);
      expect(defaults.stallTimeout, const Duration(seconds: 180));
      expect(() => SdCppSettings(sdCli: 'sd-cli', models: settings().models, device: 'cuda0'), throwsAssertionError);
      expect(sdCliIn('/e', windows: true), p.join('/e', 'sd-cli.exe'));
      expect(sdCliIn('/e', windows: false), p.join('/e', 'sd-cli'));
    });
  });

  group('the lines', () {
    test('a bar gives its step, its total and the seconds of a step; the loading bars give none', () {
      expect(
        sdCppBarOf('  |============>                                     |  12/20 -   8.65s/it - ETA 01:13'),
        const GeneratorProgress(12, 20, secondsPerStep: 8.65),
      );
      expect(
        sdCppBarOf('  |==>                                               |  2/40 -  30.30it/s')!.secondsPerStep,
        closeTo(1 / 30.3, 1e-9),
      );
      expect(sdCppBarOf('  |####                                              |   7/108 -   8.91MB/s'), isNull);
      expect(sdCppBarOf('[I] generating image: 1/1 - seed 1002 --- image.cpp:920'), isNull);
    });

    test('the free memory and the budget sd-cli read on its card, from the line of its auto-fit plan', () {
      expect(sdCppCardMemoryOf(_planRtx, 'Vulkan1'), (free: 7188 * 1024 * 1024, budget: 3072 * 1024 * 1024));
      expect(sdCppCardMemoryOf(_planIntel, 'Vulkan0'), (free: 7350 * 1024 * 1024, budget: 3072 * 1024 * 1024));
      // Another card, the memory of the computer, any other line
      expect(sdCppCardMemoryOf(_planIntel, 'Vulkan1'), isNull);
      expect(sdCppCardMemoryOf(_planRam, 'Vulkan1'), isNull);
      expect(sdCppCardMemoryOf(_oneSegment, 'Vulkan1'), isNull);
      expect(sdCppCardMemoryOf('[I] auto-fit plan: --- backend_fit.cpp:323', 'Vulkan1'), isNull);
    });

    test(
      'how short sd-cli was on its card, from the line of its model manager: the larger of the card and the budget',
      () {
        const mib = 1024 * 1024;
        expect(sdCppShortOf(_belowFloor[1].$1, 'Vulkan1'), 14 * mib, reason: '2492.82 less 2478.82, to the byte');
        // M3: the card 1 216.45 MiB short, no budget
        expect(sdCppShortOf(_outOfMemory.first.$1, 'Vulkan1'), (121645 * mib + 99) ~/ 100);
        expect(sdCppShortOf(_recovered, 'Vulkan1'), 4850 * mib ~/ 100, reason: '2560.04 less 2511.54');
        expect(sdCppShortOf(_belowFloor[1].$1, 'Vulkan0'), isNull);
        expect(sdCppShortOf(_belowFloor.first.$1, 'Vulkan1'), isNull);
        expect(sdCppShortOf(_planRtx, 'Vulkan1'), isNull);
      },
    );

    test('what sd-cli read of its card, at the head of a failure: written, then read back by the panel', () {
      const mib = 1024 * 1024;
      const read = GeneratorMemoryRead(free: 3584 * mib, budget: 3072 * mib, short: 14 * mib);
      expect(read.message, 'Generator memory read: free 3584 MiB, budget 3072 MiB, short 14 MiB');
      expect(GeneratorMemoryRead.of('${read.message}\n[E] generate failed'), read);
      expect(
        GeneratorMemoryRead.of('Generator memory read: free 7188 MiB, budget 6676 MiB\n[E] generate failed'),
        const GeneratorMemoryRead(free: 7188 * mib, budget: 6676 * mib),
      );
      // A part of a MiB short is said a MiB
      expect(const GeneratorMemoryRead(free: 0, short: 1).message, 'Generator memory read: free 0 MiB, short 1 MiB');
      // Without the free memory, or without the head: nothing to say
      expect(GeneratorMemoryRead.of('Generator memory read: short 14 MiB'), isNull);
      expect(GeneratorMemoryRead.of('need 4109.22 MB device\nGenerator memory read: free 1 MiB'), isNull);
      expect(GeneratorMemoryRead.of(null), isNull);
    });

    test('the segments of the graph of the generator, read from either line sd-cli writes', () {
      expect(sdCppSegmentsOf('[V] flux using 27 segments --- ggml_runner.cpp:879'), 27);
      expect(
        sdCppSegmentsOf(
          '[V] flux compute buffer size: 2687.96 MB(VRAM) on Vulkan1 (peak across 27 segments) --- ggml_runner.cpp:1022',
        ),
        27,
      );
      // Whole: the plan of one segment, and the line in the singular when the live check of sd-cli lets a cut run go
      // back to one (ggml_runner.cpp 878, review of lot 13c)
      expect(sdCppSegmentsOf(_oneSegment), 1);
      expect(sdCppSegmentsOf('[V] flux using 1 segment --- ggml_runner.cpp:878'), 1);
      expect(sdCppSegmentsOf('[V] vae compute buffer size: 97.00 MB(VRAM) on Vulkan1 (peak across 1 segment)'), isNull);
      expect(sdCppSegmentsOf('flux segment 7/27 (flux.single_blocks.0) failed during weight preparation'), isNull);
    });
  });

  group('the cards sd-cli lists', () {
    test('a device: its index, its name with parentheses of its own, its driver, and uma for an integrated chip', () {
      expect(_deviceOf(_listedIntel), '0|Intel(R) RaptorLake-S Mobile Graphics Controller|Intel Corporation|true');
      expect(_deviceOf(_listedRtx), '1|NVIDIA GeForce RTX 4060 Laptop GPU|NVIDIA|false');
      expect(_deviceOf(_listedRtxAlone), '0|NVIDIA GeForce RTX 4060 Laptop GPU|NVIDIA|false');
      // The one card of the fake sd-cli, and a name of Mesa that carries parentheses of its own
      expect(
        _deviceOf('ggml_vulkan: 0 = Fake graphics card (Immuch360) | uma: 0 | fp16: 1 | bf16: 1 | warp size: 32'),
        '0|Fake graphics card|Immuch360|false',
      );
      expect(
        _deviceOf('ggml_vulkan: 1 = AMD Radeon RX 7600 (RADV NAVI33) (radv) | uma: 0 | fp16: 1 | bf16: 0'),
        '1|AMD Radeon RX 7600 (RADV NAVI33)|radv|false',
      );
      expect(_deviceOf('ggml_vulkan: Found 2 Vulkan devices:'), isNull);
      expect(_deviceOf(_version), isNull);
    });

    test('the count before the list: "Found 2" gives 2, "No devices found." 0, any other line none', () {
      expect(ggmlVulkanCountOf('ggml_vulkan: Found 2 Vulkan devices:'), 2);
      expect(ggmlVulkanCountOf('ggml_vulkan: Found 1 Vulkan devices:'), 1);
      expect(ggmlVulkanCountOf('ggml_vulkan: No devices found.'), 0);
      expect(ggmlVulkanCountOf(_listedRtx), isNull);
      expect(ggmlVulkanCountOf(_version), isNull);
    });

    test('a card of the auto-fit plan: its device, its name, its free memory and its budget', () {
      expect(_planOf(_planIntel), 'Vulkan0|Intel(R) RaptorLake-S Mobile Graphics Controller|7350|3072');
      expect(_planOf(_planRtx), 'Vulkan1|NVIDIA GeForce RTX 4060 Laptop GPU|7188|3072');
      // A short name padded to 32 columns, as the pinned build writes it, and a line without a name
      expect(
        _planOf('[I]     Vulkan0      Fake graphics card               free   7188 MiB, budget   6676 MiB --- x.cpp:1'),
        'Vulkan0|Fake graphics card|7188|6676',
      );
      expect(_planOf('[I]     Vulkan0      free   7188 MiB, budget   6676 MiB'), 'Vulkan0||7188|6676');
      expect(_planOf(_planRam), isNull);
      expect(_planOf('[I] auto-fit plan: --- backend_fit.cpp:323'), isNull);
      // What the generator reads of its card, as before
      expect(sdCppCardMemoryOf(_planRtx, 'Vulkan1'), (free: 7188 * 1024 * 1024, budget: 3072 * 1024 * 1024));
      expect(sdCppCardMemoryOf(_planIntel, 'Vulkan1'), isNull);
    });
  });

  group('the verdict on the list', () {
    test('the laptop of 8 November, the RTX 4060 chosen: given Vulkan0, started again on 1; given Vulkan1, run', () {
      expect(_said(_verdictOf([_listedIntel, _listedRtx], _rtx, 0)), 'restart 1');
      expect(_said(_verdictOf([_listedIntel, _listedRtx], _rtx, 1)), 'run 1');
    });

    test('the workaround of the owner still set, the RTX 4060 alone as 0: given Vulkan1, started again on 0', () {
      expect(_said(_verdictOf([_listedRtxAlone], _rtx, 1)), 'restart 0');
      expect(_said(_verdictOf([_listedRtxAlone], _rtx, 0)), 'run 0');
    });

    test('a dedicated card with only the Intel chip listed: refused, the list and the variable of the user said', () {
      final refused = _verdictOf([_listedIntel], _rtx, 0, visibleDevices: '0');
      expect(_said(refused), 'refuse');
      expect(refused.refusal, contains('NVIDIA GeForce RTX 4060 Laptop GPU'));
      expect(refused.refusal, contains('0 = Intel(R) RaptorLake-S Mobile Graphics Controller, integrated'));
      expect(refused.refusal, contains('GGML_VK_VISIBLE_DEVICES=0'));
      expect(_verdictOf([_listedIntel], _rtx, 0).refusal, isNot(contains('GGML_VK_VISIBLE_DEVICES')));
    });

    test('the integrated chip allowed by the switch: given Vulkan0, run; given Vulkan1, started again on 0', () {
      expect(_said(_verdictOf([_listedIntel, _listedRtx], _intel, 0)), 'run 0');
      expect(_said(_verdictOf([_listedIntel, _listedRtx], _intel, 1)), 'restart 0');
      // Never the RTX 4060 for the integrated chip
      expect(_said(_verdictOf([_listedRtxAlone], _intel, 0)), 'refuse');
    });

    test('two identical dedicated cards: the one given, else the first of them', () {
      const card = SdCppCard(name: 'NVIDIA GeForce RTX 4090', integrated: false);
      final twins = [_line(0, card.name), _line(1, card.name)];
      expect(_said(_verdictOf(twins, card, 1)), 'run 1');
      expect(_said(_verdictOf(twins, card, 0)), 'run 0');
      final afterIntel = [
        _line(0, 'Intel(R) UHD Graphics 770', uma: true, driver: 'Intel Corporation'),
        _line(1, card.name),
        _line(2, card.name),
      ];
      expect(_said(_verdictOf(afterIntel, card, 0)), 'restart 1');
      expect(_said(_verdictOf(afterIntel, card, 2)), 'run 2');
    });

    test('a name that differs in case and spaces only is the same card', () {
      const spaced = SdCppCard(name: '  nvidia geforce  RTX 4060 laptop gpu ', integrated: false);
      expect(_said(_verdictOf([_listedIntel, _listedRtx], spaced, 1)), 'run 1');
      expect(_said(_verdictOf([_listedIntel, _listedRtx], spaced, 0)), 'restart 1');
    });

    test('no name matching and a single dedicated device listed: taken by its kind, which the log warns of', () {
      final renamed = [_listedIntel, _line(1, 'NVIDIA GeForce RTX 4060 Laptop')];
      expect(_said(_verdictOf(renamed, _rtx, 1)), 'run 1 by kind');
      expect(_said(_verdictOf(renamed, _rtx, 0)), 'restart 1 by kind');
      // Two dedicated devices and neither name: refused; an integrated chip is never taken by its kind
      expect(_said(_verdictOf([...renamed, _line(2, 'Another card')], _rtx, 1)), 'refuse');
      const otherIntel = SdCppCard(name: 'Intel(R) Graphics', integrated: true);
      expect(_said(_verdictOf([_listedIntel, _listedRtx], otherIntel, 0)), 'refuse');
    });

    test('an empty list: refused, saying so', () {
      final refused = _verdictOf(const [], _rtx, 0);
      expect(_said(refused), 'refuse');
      expect(refused.refusal, contains('no Vulkan device'));
    });
  });

  group('the card a generation runs on', () {
    // A generation on the laptop of the owner, sd-cli listing the Intel chip first: given Vulkan0, started again on
    // Vulkan1
    Future<(SdCppGenerator, FakeProcessRunner, List<GeneratorProgress>)> restarted() async {
      final runner = FakeProcessRunner([
        FakeProcessScript(
          lines: _generation(listed: [_listedIntel, _listedRtx], plan: [_planIntel, _planRtx]),
        ),
      ]);
      final generator = SdCppGenerator(
        runner: _WritingRunner(runner, image: _varied(16, 8)),
        settings: laptop(),
        generatorSha256: '',
        loraSha256: '',
        checkImages: false,
      );
      final heard = <GeneratorProgress>[];
      await generator.generate(request(), cancel: cancel, onProgress: heard.add);
      return (generator, runner, heard);
    }

    // The failure of a generation on [runner] for the laptop of the owner, null when it made its image
    Future<BackendException?> failureOf(ProcessRunner runner, {String device = 'Vulkan0'}) async {
      final generator = SdCppGenerator(
        runner: runner,
        settings: laptop(device: device),
        generatorSha256: '',
        loraSha256: '',
        checkImages: false,
      );
      try {
        await generator.generate(request(), cancel: cancel);
        return null;
      } on BackendException catch (error) {
        return error;
      }
    }

    test('the Intel chip listed first: stopped before any step, started again on Vulkan1, the image made', () async {
      final logged = recorded('SdCpp');
      final (generator, runner, heard) = await restarted();

      expect(runner.launches, hasLength(2));
      expect(runner.processes.first.killed, isTrue);
      expect(_backendOf(runner.launches.first), 'diffusion=Vulkan0,vae=Vulkan0,te=CPU');
      expect(_backendOf(runner.launches.last), 'diffusion=Vulkan1,vae=Vulkan1,te=CPU');
      expect(heard.map((progress) => progress.step), List.generate(20, (index) => index + 1));
      expect(File(request().outputPath).existsSync(), isTrue);
      expect(generator.device.name, 'Vulkan1');
      expect(generator.argumentsOf(request()), contains('diffusion=Vulkan1,vae=Vulkan1,te=CPU'));
      // The restart warned of once, the card named once, and the plan of the card it runs on with its name
      const again = 'sd-cli lists NVIDIA GeForce RTX 4060 Laptop GPU as Vulkan1, not Vulkan0: started again on Vulkan1';
      expect(logged.where((line) => line.startsWith(again)), hasLength(1));
      const named =
          'sd-cli lists the chosen card, NVIDIA GeForce RTX 4060 Laptop GPU, as Vulkan1 (0 = Intel(R) RaptorLake-S '
          'Mobile Graphics Controller, integrated; 1 = NVIDIA GeForce RTX 4060 Laptop GPU)';
      expect(logged.where((line) => line == named), hasLength(1));
      const read = 'sd-cli read 7188 MiB free on Vulkan1 (NVIDIA GeForce RTX 4060 Laptop GPU), budget 3072 MiB';
      expect(logged, contains(read));
      // Both runs in the log of the job, each after a line of its own
      final log = File(p.join(folder.path, 'logs', 'sd-cli.log')).readAsLinesSync();
      expect(log.where((line) => line.startsWith('===== ')), hasLength(2));
      expect(log.where((line) => line.contains('sd-cli on Vulkan1, attempt 2: generation, seed 1002')), hasLength(1));
      expect(log.where((line) => line == _listedRtx), hasLength(2));
    });

    test('the upscaler of the job starts on that card, and so does the next job of the session', () async {
      final (generator, _, _) = await restarted();
      final input = p.join(folder.path, 'wrapped.png');
      File(input).writeAsBytesSync(img.encodePng(_varied(20, 10)));
      final upscaleLines = [
        (_version, isError: false),
        ..._listing([_listedIntel, _listedRtx]),
        ('[I] upscaling from (20 x 10) to (80 x 40) --- upscaler.cpp:214', isError: false),
      ];
      final upscaling = FakeProcessRunner([FakeProcessScript(lines: upscaleLines)]);
      final upscaler = SdCppUpscaler(
        runner: _WritingRunner(upscaling, image: _varied(80, 40)),
        settings: laptop(),
        modelSha256: '',
        device: generator.device,
      );
      await upscaler.upscale(
        UpscaleRequest(inputPath: input, outputPath: p.join(folder.path, 'x4.png'), workFolder: folder.path),
        cancel: cancel,
      );
      expect(upscaling.launches, hasLength(1));
      expect(_backendOf(upscaling.launches.single), 'Vulkan1');

      // The next job of the session, with the same sd-cli and card: Vulkan1 from the start, run there
      final next = FakeProcessRunner([
        FakeProcessScript(
          lines: _generation(listed: [_listedIntel, _listedRtx], plan: [_planIntel, _planRtx]),
        ),
      ]);
      final again = SdCppGenerator(
        runner: _WritingRunner(next, image: _varied(16, 8)),
        settings: laptop(),
        generatorSha256: '',
        loraSha256: '',
        checkImages: false,
      );
      expect(again.device.name, 'Vulkan1');
      await again.generate(request(), cancel: cancel);
      expect(next.launches, hasLength(1));
      expect(_backendOf(next.launches.single), 'diffusion=Vulkan1,vae=Vulkan1,te=CPU');
    });

    test('a list still at odds once started again: gpuUnavailable after two launches, never three', () async {
      final runner = FakeProcessRunner([
        FakeProcessScript(lines: _generation(listed: [_listedIntel, _listedRtx])),
        // The order turned between the two runs: the card is never where sd-cli was told to run
        FakeProcessScript(lines: _generation(listed: [_line(0, _rtx.name), _line(1, _intel.name, uma: true)])),
      ]);
      final failure = await failureOf(runner);
      expect(failure?.code, ImmersiveErrorCode.gpuUnavailable);
      expect(failure?.message, contains('still lists'));
      expect(runner.launches, hasLength(2));
      expect(runner.processes.every((process) => process.killed), isTrue);
    });

    test('a list without the chosen card: gpuUnavailable after one launch, the list in its message', () async {
      final runner = FakeProcessRunner([
        FakeProcessScript(lines: _generation(listed: [_listedIntel])),
      ]);
      final failure = await failureOf(runner);
      expect(failure?.code, ImmersiveErrorCode.gpuUnavailable);
      expect(failure?.message, contains('0 = Intel(R) RaptorLake-S Mobile Graphics Controller, integrated'));
      expect(runner.launches, hasLength(1));
      expect(runner.processes.single.killed, isTrue);
    });

    test('no list at all: one warning, and the run goes on to its image', () async {
      final warnings = recorded('SdCpp', level: Level.WARNING);
      final runner = FakeProcessRunner([FakeProcessScript(lines: _generation())]);
      final heard = <GeneratorProgress>[];
      final generator = SdCppGenerator(
        runner: _WritingRunner(runner, image: _varied(16, 8)),
        settings: laptop(),
        generatorSha256: '',
        loraSha256: '',
        checkImages: false,
      );
      await generator.generate(request(), cancel: cancel, onProgress: heard.add);
      expect(heard, hasLength(20));
      expect(runner.launches, hasLength(1));
      expect(warnings, hasLength(1));
      expect(warnings.single, startsWith('sd-cli did not list its devices: the card could not be checked'));
    });

    test('no list but the plan of its device naming the chosen card: run on, no warning', () async {
      final warnings = recorded('SdCpp', level: Level.WARNING);
      final runner = FakeProcessRunner([
        FakeProcessScript(lines: _generation(plan: [_planRtxAlone])),
      ]);
      expect(await failureOf(_WritingRunner(runner, image: _varied(16, 8))), isNull);
      expect(runner.launches, hasLength(1));
      expect(warnings, isEmpty);
    });

    test('cancelled while the first run is stopped: cancelled, never started again', () async {
      final runner = FakeProcessRunner([
        FakeProcessScript(lines: _generation(listed: [_listedIntel, _listedRtx])),
      ]);
      final failure = await failureOf(_KillHook(runner, () => cancel.cancel()));
      expect(failure?.code, ImmersiveErrorCode.cancelled);
      expect(runner.launches, hasLength(1));
    });

    test('the plan of its device naming another card: gpuUnavailable, with the list or without it', () async {
      // Listed as Vulkan1, planned as the Intel chip
      const planned =
          '[I]     Vulkan1      Intel(R) RaptorLake-S Mobile Graphics Controller free   7350 MiB, budget   6674 MiB '
          '--- backend_fit.cpp:328';
      final listed = FakeProcessRunner([
        FakeProcessScript(
          lines: _generation(listed: [_listedIntel, _listedRtx], plan: [planned]),
        ),
      ]);
      final withList = await failureOf(listed, device: 'Vulkan1');
      expect(withList?.code, ImmersiveErrorCode.gpuUnavailable);
      expect(withList?.message, contains('Intel(R) RaptorLake-S Mobile Graphics Controller'));
      expect(listed.launches, hasLength(1));
      // No list: the plan stands in for it, and the Intel chip is no RTX 4060
      final unlisted = FakeProcessRunner([
        FakeProcessScript(lines: _generation(plan: [_planIntel])),
      ]);
      final withoutList = await failureOf(unlisted);
      expect(withoutList?.code, ImmersiveErrorCode.gpuUnavailable);
      expect(unlisted.launches, hasLength(1));
    });

    test('the plan read before the list, the list on the other output: the list decides, Vulkan1', () async {
      final lines = [
        (_version, isError: false),
        (_planIntel, isError: false),
        (_planRtx, isError: false),
        ..._listing([_listedIntel, _listedRtx]),
        ..._generation().skip(1),
      ];
      final runner = FakeProcessRunner([FakeProcessScript(lines: lines)]);
      expect(await failureOf(_WritingRunner(runner, image: _varied(16, 8))), isNull);
      expect(runner.launches, hasLength(2));
      expect(_backendOf(runner.launches.last), 'diffusion=Vulkan1,vae=Vulkan1,te=CPU');
    });
  });

  group('a generation', () {
    test('reports the 20 steps of the sampling only, with the pace, and checks nothing when told not to', () async {
      final runner = FakeProcessRunner([FakeProcessScript(lines: _generation())]);
      final heard = <GeneratorProgress>[];
      File(request().outputPath).writeAsStringSync('an earlier image');

      final writing = _WritingRunner(runner, image: _varied(16, 8));
      await generator(writing).generate(request(), cancel: cancel, onProgress: heard.add);

      expect(heard.map((progress) => progress.step), List.generate(20, (index) => index + 1));
      expect(heard.every((progress) => progress.steps == 20), isTrue);
      expect(heard.last.secondsPerStep, 8.5);
      expect(heard[11].remaining, Duration(milliseconds: (8 * 8.42 * 1000).round()));
      final launch = runner.launches.single;
      expect(launch.executable, '/engines/sd-cpp-vulkan-linux-x64/sd-cli');
      expect(launch.workingDirectory, folder.path);
      expect(launch.lowPriority, isTrue);
      expect(runner.processes.single.killed, isFalse);
    });

    test(
      'a bar of as many tiles as steps before the sampling is no step: only the bars after "generating image"',
      () async {
        // 40 steps, and the VAE encodes the reference in 40 tiles before the sampling starts
        final runner = FakeProcessRunner([FakeProcessScript(lines: _generation(steps: 40))]);
        final heard = <GeneratorProgress>[];
        final request40 = GeneratorRequest(
          controlPath: request().controlPath,
          outputPath: request().outputPath,
          workFolder: folder.path,
          prompt: 'p',
          seed: 1,
          steps: 40,
        );
        await expectLater(
          generator(runner).generate(request40, cancel: cancel, onProgress: heard.add),
          throwsA(isA<BackendException>().having((error) => error.code, 'code', ImmersiveErrorCode.generatorFailed)),
        );
        expect(heard.map((progress) => progress.step), List.generate(40, (index) => index + 1));
        expect(heard.first.secondsPerStep, 8.31);
      },
    );

    test('cut into segments, it goes on to its image, each step saying how many; the log keeps them with what sd-cli '
        'read of the card', () async {
      // The measure of 5 November 2026: 27 segments give the same bytes as one, slower
      final runner = FakeProcessRunner([
        FakeProcessScript(
          lines: _generation(
            plan: [_planIntel, _planRtx, _planRam],
            beforeSteps: [
              '[I] flux build cached graph cut plan done (taking 2 ms) --- ggml_graph_cut.cpp:1034',
              '[V] flux using 27 segments --- ggml_runner.cpp:879',
            ],
          ),
        ),
      ]);
      final logged = <String>[];
      final level = Logger.root.level;
      Logger.root.level = Level.ALL;
      final listening = Logger.root.onRecord.where((record) => record.loggerName == 'SdCpp').listen((record) {
        logged.add(record.message);
      });
      addTearDown(() async {
        Logger.root.level = level;
        await listening.cancel();
      });
      final heard = <GeneratorProgress>[];

      await generator(
        _WritingRunner(runner, image: _varied(16, 8)),
      ).generate(request(), cancel: cancel, onProgress: heard.add);

      expect(heard.map((progress) => progress.step), List.generate(20, (index) => index + 1));
      expect(heard.every((progress) => progress.segments == 27), isTrue);
      expect(heard.first, const GeneratorProgress(1, 20, secondsPerStep: 8.31, segments: 27));
      expect(runner.processes.single.killed, isFalse);
      expect(File(request().outputPath).existsSync(), isTrue);
      const cut =
          'sd-cli runs the generator in 27 segments (7188 MiB free read on Vulkan1, budget 3072 MiB): slower, the same image';
      expect(logged, [
        'sd-cli read 7188 MiB free on Vulkan1 (NVIDIA GeForce RTX 4060 Laptop GPU), budget 3072 MiB',
        cut,
      ]);
    });

    test('in one segment, its steps say none', () async {
      final runner = FakeProcessRunner([
        FakeProcessScript(lines: _generation(plan: [_planRtx])),
      ]);
      final heard = <GeneratorProgress>[];
      await generator(
        _WritingRunner(runner, image: _varied(16, 8)),
      ).generate(request(), cancel: cancel, onProgress: heard.add);
      expect(heard, hasLength(20));
      expect(heard.every((progress) => progress.segments == null), isTrue);
    });

    test('taken back to one segment in the middle, its steps say none from then on, and the log says so', () async {
      // "flux using 1 segment" once the live check of sd-cli allows it (review of lot 13c)
      final lines = _generation(plan: [_planRtx], beforeSteps: ['[V] flux using 27 segments --- ggml_runner.cpp:879']);
      final third = lines.indexWhere((line) => line.$1.contains(' 3/20 '));
      lines.insert(third, ('[V] flux using 1 segment --- ggml_runner.cpp:878', isError: false));
      final runner = FakeProcessRunner([FakeProcessScript(lines: lines)]);
      final logged = <String>[];
      final level = Logger.root.level;
      Logger.root.level = Level.ALL;
      final listening = Logger.root.onRecord.where((record) => record.loggerName == 'SdCpp').listen((record) {
        logged.add(record.message);
      });
      addTearDown(() async {
        Logger.root.level = level;
        await listening.cancel();
      });
      final heard = <GeneratorProgress>[];

      await generator(
        _WritingRunner(runner, image: _varied(16, 8)),
      ).generate(request(), cancel: cancel, onProgress: heard.add);

      expect(heard.map((progress) => progress.segments), [27, 27, for (var step = 3; step <= 20; step++) null]);
      expect(logged.last, 'sd-cli runs the generator whole again (7188 MiB free read on Vulkan1, budget 3072 MiB)');
    });

    test('shortfalls sd-cli recovers from: the run goes on to its image, nothing of a failure in the log', () async {
      // Run F_full_2700 of the measure of 5 November 2026: four such lines in segments, then its image (exit 0)
      final lines = _generation(
        plan: [_planIntel, _planRtx, _planRam],
        beforeSteps: ['[V] flux using 27 segments --- ggml_runner.cpp:879', _recovered],
      );
      for (final step in [' 1/20 ', ' 2/20 ', ' 3/20 ']) {
        lines.insert(lines.indexWhere((line) => line.$1.contains(step)) + 1, (_recovered, isError: false));
      }
      final runner = FakeProcessRunner([FakeProcessScript(lines: lines)]);
      final warnings = <String>[];
      final level = Logger.root.level;
      Logger.root.level = Level.ALL;
      final listening = Logger.root.onRecord
          .where((record) => record.loggerName == 'SdCpp' && record.level >= Level.WARNING)
          .listen((record) => warnings.add(record.message));
      addTearDown(() async {
        Logger.root.level = level;
        await listening.cancel();
      });
      final heard = <GeneratorProgress>[];

      await generator(
        _WritingRunner(runner, image: _varied(16, 8)),
      ).generate(request(), cancel: cancel, onProgress: heard.add);

      expect(heard.map((progress) => progress.step), List.generate(20, (index) => index + 1));
      expect(heard.every((progress) => progress.segments == 27), isTrue);
      expect(File(request().outputPath).existsSync(), isTrue);
      expect(warnings, isEmpty);
    });

    test(
      'shortfalls it recovered from, then a failure for another reason: generatorFailed, not out of memory',
      () async {
        final runner = FakeProcessRunner([
          FakeProcessScript(
            lines: [
              ..._generation(
                steps: 3,
                plan: [_planRtx],
                beforeSteps: ['[V] flux using 27 segments --- ggml_runner.cpp:879', _recovered, _recovered],
              ),
              ('[E] save result image 0 failed: disk full --- main.cpp:495', isError: true),
            ],
            exitCode: 3,
          ),
        ]);

        final failure = await generator(runner)
            .generate(request(), cancel: cancel)
            .then<BackendException?>((_) => null, onError: (Object error) => error as BackendException);

        expect(failure?.code, ImmersiveErrorCode.generatorFailed);
        expect(failure?.message, endsWith('[E] save result image 0 failed: disk full --- main.cpp:495'));
        expect(GeneratorMemoryRead.of(failure?.message), isNull);
      },
    );

    test('short of memory, it fails as gpuOutOfMemory with the end of its error output', () async {
      final runner = FakeProcessRunner([
        FakeProcessScript(lines: [..._generation(steps: 0), ..._outOfMemory], exitCode: 1),
      ]);
      await expectLater(
        generator(runner).generate(request(), cancel: cancel),
        throwsA(
          isA<BackendException>()
              .having((error) => error.code, 'code', ImmersiveErrorCode.gpuOutOfMemory)
              .having((error) => error.message, 'message', contains('[E] generate failed'))
              // No plan read: the panel keeps the words of any other program
              .having((error) => GeneratorMemoryRead.of(error.message), 'read', isNull),
        ),
      );
    });

    test('short of memory even in segments, below the floor as measured: what sd-cli read heads its failure', () async {
      final runner = FakeProcessRunner([
        FakeProcessScript(
          lines: [
            ..._generation(
              steps: 0,
              plan: [_planIntel, _planBelowFloor, _planRam],
              // A larger shortfall it recovered from first: the failure says the one of the segment that failed
              beforeSteps: ['[V] flux using 27 segments --- ggml_runner.cpp:879', _recovered],
            ),
            ..._belowFloor,
          ],
          exitCode: 1,
        ),
      ]);
      final warnings = <String>[];
      final level = Logger.root.level;
      Logger.root.level = Level.ALL;
      final listening = Logger.root.onRecord
          .where((record) => record.loggerName == 'SdCpp' && record.level >= Level.WARNING)
          .listen((record) => warnings.add(record.message));
      addTearDown(() async {
        Logger.root.level = level;
        await listening.cancel();
      });

      final failure = await generator(runner)
          .generate(request(graphicsBudget: 2600 * 1024 * 1024), cancel: cancel)
          .then<BackendException?>((_) => null, onError: (Object error) => error as BackendException);

      expect(failure?.code, ImmersiveErrorCode.gpuOutOfMemory);
      expect(
        GeneratorMemoryRead.of(failure?.message),
        const GeneratorMemoryRead(free: 7188 * 1024 * 1024, budget: 2600 * 1024 * 1024, short: 14 * 1024 * 1024),
      );
      expect(failure!.message.split('\n').first, 'Generator memory read: free 7188 MiB, budget 2600 MiB, short 14 MiB');
      expect(failure.message, endsWith('[E] generate failed --- main.cpp:926'));
      const warned =
          'sd-cli ran out of the memory of Vulkan1 in 27 segments: Generator memory read: free 7188 MiB, budget 2600 '
          'MiB, short 14 MiB';
      expect(warnings, [warned]);
    });

    test('a memory error of Vulkan after the plan: the free memory sd-cli read, nothing of a shortfall', () async {
      final runner = FakeProcessRunner([
        FakeProcessScript(
          lines: [
            ..._generation(steps: 0, plan: [_planRtx]),
            ('ggml_vulkan: vk::Device::allocateMemory: ErrorOutOfDeviceMemory', isError: true),
            ('[E] generate failed --- main.cpp:926', isError: true),
          ],
          exitCode: 1,
        ),
      ]);
      final failure = await generator(runner)
          .generate(request(), cancel: cancel)
          .then<BackendException?>((_) => null, onError: (Object error) => error as BackendException);

      expect(failure?.code, ImmersiveErrorCode.gpuOutOfMemory);
      expect(
        GeneratorMemoryRead.of(failure?.message),
        const GeneratorMemoryRead(free: 7188 * 1024 * 1024, budget: 3072 * 1024 * 1024),
      );
    });

    test('another failure is generatorFailed with the last 20 lines of its error output, the bars left out', () async {
      final runner = FakeProcessRunner([
        FakeProcessScript(
          lines: [
            (_version, isError: false),
            for (var line = 1; line <= 25; line++) ('[E] trouble $line', isError: true),
          ],
          exitCode: 3,
        ),
      ]);
      final failure = await generator(runner)
          .generate(request(), cancel: cancel)
          .then<BackendException?>((_) => null, onError: (Object error) => error as BackendException);
      expect(failure!.code, ImmersiveErrorCode.generatorFailed);
      expect(failure.message, startsWith('sd-cli ended with 3: [E] trouble 6\n'));
      expect(failure.message, endsWith('[E] trouble 25'));
      expect('\n'.allMatches(failure.message).length, 19);

      // Nothing on the error output: the end of the output instead
      final quiet = FakeProcessRunner([
        const FakeProcessScript(
          lines: [(_version, isError: false), ('[I] no control image', isError: false)],
          exitCode: 1,
        ),
      ]);
      await expectLater(
        generator(quiet).generate(request(), cancel: cancel),
        throwsA(isA<BackendException>().having((error) => error.message, 'message', endsWith('[I] no control image'))),
      );
    });

    test('ended well without its image, it failed', () async {
      final runner = FakeProcessRunner([FakeProcessScript(lines: _generation())]);
      await expectLater(
        generator(runner).generate(request(), cancel: cancel),
        throwsA(isA<BackendException>().having((error) => error.code, 'code', ImmersiveErrorCode.generatorFailed)),
      );
    });

    test('a program that cannot start is generatorFailed', () async {
      await expectLater(
        generator(_FailingRunner()).generate(request(), cancel: cancel),
        throwsA(
          isA<BackendException>()
              .having((error) => error.code, 'code', ImmersiveErrorCode.generatorFailed)
              .having((error) => error.message, 'message', contains('could not start')),
        ),
      );
    });

    test('silent for 180 s on the clock, it is stopped as generatorStalled; 179 s are not enough', () {
      fakeAsync((async) {
        final runner = FakeProcessRunner([FakeProcessScript(lines: _generation(steps: 3), hangs: true)]);
        Object? failure;
        unawaited(
          generator(
            runner,
            elapsed: () => async.elapsed,
          ).generate(request(), cancel: cancel).then<void>((_) {}, onError: (Object error) => failure = error),
        );
        async.elapse(const Duration(seconds: 179));
        expect(failure, isNull);
        expect(runner.processes.single.killed, isFalse);
        async.elapse(const Duration(seconds: 2));
        expect(runner.processes.single.killed, isTrue);
        expect(failure, isA<BackendException>().having((e) => e.code, 'code', ImmersiveErrorCode.generatorStalled));
      });
    });

    test('a line now and then keeps it alive, however long it takes', () {
      fakeAsync((async) {
        final runner = FakeProcessRunner([FakeProcessScript(lines: _generation(steps: 0), hangs: true)]);
        var finished = false;
        unawaited(
          generator(
            runner,
            elapsed: () => async.elapsed,
          ).generate(request(), cancel: cancel).whenComplete(() => finished = true).catchError((Object _) {}),
        );
        async.elapse(const Duration(seconds: 170));
        // A step every 170 s: never silent for 180
        for (var i = 0; i < 3; i++) {
          runner.processes.single.emit('  | ${i + 1}/20 - 170.00s/it');
          async.elapse(const Duration(seconds: 170));
        }
        expect(finished, isFalse);
        expect(runner.processes.single.killed, isFalse);
        cancel.cancel();
        async.elapse(const Duration(seconds: 1));
        expect(finished, isTrue);
      });
    });

    test('cancelled, it is stopped within the interval of the watch and fails as cancelled', () async {
      fakeAsync((async) {
        final runner = FakeProcessRunner([FakeProcessScript(lines: _generation(steps: 2), hangs: true)]);
        Object? failure;
        unawaited(
          generator(runner).generate(request(), cancel: cancel).then<void>((_) {}, onError: (Object e) => failure = e),
        );
        async.elapse(const Duration(seconds: 5));
        cancel.cancel();
        async.elapse(const Duration(milliseconds: 250));
        expect(runner.processes.single.killed, isTrue);
        expect(failure, isA<BackendException>().having((e) => e.code, 'code', ImmersiveErrorCode.cancelled));
      });
      // Cancelled before it started: nothing starts
      final runner = FakeProcessRunner([const FakeProcessScript()]);
      await expectLater(
        generator(runner).generate(request(), cancel: cancel),
        throwsA(isA<BackendException>().having((e) => e.code, 'code', ImmersiveErrorCode.cancelled)),
      );
      expect(runner.launches, isEmpty);
    });
  });

  group('the image', () {
    void writeControl() {
      // The photo in the middle, pure green around it
      final control = img.Image(width: 64, height: 32)..clear(img.ColorRgb8(0, 255, 0));
      img.fillRect(control, x1: 24, y1: 12, x2: 39, y2: 19, color: img.ColorRgb8(90, 120, 30));
      File(request().controlPath).writeAsBytesSync(img.encodePng(control));
    }

    Future<BackendException?> run(img.Image image, {int width = 32, int height = 16}) async {
      writeControl();
      final runner = _WritingRunner(FakeProcessRunner([FakeProcessScript(lines: _generation(steps: 1))]), image: image);
      return generator(runner, checkImages: true)
          .generate(
            request(width: width, height: height),
            cancel: cancel,
          )
          .then<BackendException?>((_) => null, onError: (Object error) => error as BackendException);
    }

    test('a varied image of the size asked is kept', () async {
      expect(await run(_varied(32, 16)), isNull);
      expect(File(request().outputPath).existsSync(), isTrue);
    });

    test('a grey image, an image of another size, or green left outside the photo is refused and deleted', () async {
      for (final (image, reason) in [
        (img.Image(width: 32, height: 16)..clear(img.ColorRgb8(128, 128, 128)), 'a grey image'),
        (_varied(48, 16), 'an image of 48 x 16, not 32 x 16'),
        (_greenRow(_varied(32, 16)), 'of pure green left outside the photo'),
      ]) {
        final failure = await run(image);
        expect(failure?.code, ImmersiveErrorCode.outputRejected, reason: reason);
        expect(failure?.message, contains(reason));
        expect(File(request().outputPath).existsSync(), isFalse, reason: reason);
      }
    });

    test('a file that is no image, or a PNG cut short, is refused and deleted', () async {
      writeControl();
      for (final (bytes, reason) in [
        (List<int>.filled(64, 7), 'no image'),
        (img.encodePng(_varied(32, 16)).sublist(0, 60), 'cut short'),
      ]) {
        final runner = _BytesRunner(FakeProcessRunner([FakeProcessScript(lines: _generation(steps: 1))]), bytes);
        final failure = await generator(runner, checkImages: true)
            .generate(request(width: 32, height: 16), cancel: cancel)
            .then<Object?>((_) => null, onError: (Object error) => error);
        expect(
          failure,
          isA<BackendException>().having((error) => error.code, 'code', ImmersiveErrorCode.outputRejected),
          reason: reason,
        );
        expect(File(request().outputPath).existsSync(), isFalse, reason: reason);
      }
    });

    test('the check runs in an isolate whatever the progress callback of the caller holds', () async {
      // The progress callback of the app reaches the queue, its settings store and their futures, which no isolate can
      // take: the closure of the check must not carry it (V3: every panorama of the app was refused so)
      writeControl();
      final pending = Completer<void>();
      final runner = _WritingRunner(
        FakeProcessRunner([FakeProcessScript(lines: _generation())]),
        image: _varied(32, 16),
      );
      final failure = await generator(runner, checkImages: true)
          .generate(
            request(width: 32, height: 16),
            cancel: cancel,
            onProgress: (progress) {
              if (!pending.isCompleted) {
                pending.complete();
              }
            },
          )
          .then<Object?>((_) => null, onError: (Object error) => error);
      expect(failure, isNull);
      expect(pending.isCompleted, isTrue, reason: 'the callback was called');
      expect(File(request().outputPath).existsSync(), isTrue);
    });

    test('pure green inside the photo is the photo: kept', () async {
      // The photo of the control frame covers x 12 to 19, y 6 to 9 of a 32 x 16 image
      final image = _varied(32, 16);
      for (var x = 13; x < 19; x++) {
        image.setPixelRgb(x, 7, 0, 255, 0);
      }
      expect(await run(image), isNull);
    });
  });

  group('an upscale', () {
    test('reports its tiles and checks the size of what it wrote: four times its input', () async {
      final input = p.join(folder.path, 'wrapped.png');
      File(input).writeAsBytesSync(img.encodePng(_varied(20, 10)));
      final upscaleLines = [
        (_version, isError: false),
        ('[I] upscaling from (20 x 10) to (80 x 40) --- upscaler.cpp:214', isError: false),
        for (var tile = 1; tile <= 4; tile++) ('  |=====>      |  $tile/4 -   3.75it/s', isError: false),
      ];
      UpscaleRequest request(String out) => UpscaleRequest(inputPath: input, outputPath: out, workFolder: folder.path);
      final good = _WritingRunner(FakeProcessRunner([FakeProcessScript(lines: upscaleLines)]), image: _varied(80, 40));
      final heard = <GeneratorProgress>[];
      await SdCppUpscaler(
        runner: good,
        settings: settings(),
        modelSha256: '4fa0d389',
      ).upscale(request(p.join(folder.path, 'x4.png')), cancel: cancel, onProgress: heard.add);
      expect(heard.map((progress) => (progress.step, progress.steps)), [(1, 4), (2, 4), (3, 4), (4, 4)]);

      final small = _WritingRunner(FakeProcessRunner([FakeProcessScript(lines: upscaleLines)]), image: _varied(40, 20));
      await expectLater(
        SdCppUpscaler(
          runner: small,
          settings: settings(),
          modelSha256: '',
        ).upscale(request(p.join(folder.path, 'x2.png')), cancel: cancel),
        throwsA(
          isA<BackendException>()
              .having((error) => error.code, 'code', ImmersiveErrorCode.outputRejected)
              .having((error) => error.message, 'message', contains('40 x 20, not 80 x 40')),
        ),
      );
      expect(File(p.join(folder.path, 'x2.png')).existsSync(), isFalse);
      await expectLater(
        SdCppUpscaler(runner: good, settings: settings(), modelSha256: '').upscale(
          UpscaleRequest(inputPath: p.join(folder.path, 'none.png'), outputPath: 'x.png', workFolder: folder.path),
          cancel: cancel,
        ),
        throwsA(isA<BackendException>().having((error) => error.code, 'code', ImmersiveErrorCode.generatorFailed)),
      );
    });
  });

  test('PanoV1 gives the generation its default size and steps', () {
    const defaults = GeneratorRequest(controlPath: 'c', outputPath: 'o', workFolder: 'w', prompt: 'p', seed: 1);
    expect((defaults.width, defaults.height, defaults.steps), (1536, 768, 20));
    expect((defaults.guidance, defaults.loraStrength), (PanoV1.guidance, PanoV1.loraStrength));
  });
}

class _FailingRunner implements ProcessRunner {
  @override
  Future<RunningProcess> start(ProcessLaunch launch) async => throw const ProcessException('sd-cli', [], 'not found');
}

/// The runner [inner], whose processes call [onKill] when they are killed, before they go
class _KillHook implements ProcessRunner {
  _KillHook(this.inner, this.onKill);

  final ProcessRunner inner;
  final void Function() onKill;

  @override
  Future<RunningProcess> start(ProcessLaunch launch) async => _Killed(await inner.start(launch), onKill);
}

class _Killed implements RunningProcess {
  _Killed(this.inner, this.onKill);

  final RunningProcess inner;
  final void Function() onKill;

  @override
  int get pid => inner.pid;

  @override
  IOSink get stdin => inner.stdin;

  @override
  Stream<String> get stdoutLines => inner.stdoutLines;

  @override
  Stream<String> get stderrLines => inner.stderrLines;

  @override
  Future<int> get exitCode => inner.exitCode;

  @override
  void kill() {
    onKill();
    inner.kill();
  }
}
