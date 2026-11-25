// The programs of "Enhance (AI)" as its backends see them, for the tests of the backends and of the isolates the queue
// of the app crosses with them (enhance_isolates_test.dart): sd-cli in script mode for SeedVR2, and x4plus.

import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_pixels.dart';
import 'package:immich_mobile/desktop/ai/panorama/control_image.dart' show decodePngPicture, encodePngPicture;
import 'package:immich_mobile/desktop/library/isolate_cancel.dart';

import 'fake_process_runner.dart';

/// sd-cli in script mode as far as the backend sees it: its device list, the items of each phase, and each tile
/// written as the crop of the input it was given (or not written)
class FakeSeedVr2Runner implements ProcessRunner {
  FakeSeedVr2Runner({this.intDot = 1, this.refuseMemory = false, this.writeTiles = true});

  final int intDot;
  final bool refuseMemory;
  final bool writeTiles;
  final launches = <ProcessLaunch>[];

  @override
  Future<RunningProcess> start(ProcessLaunch launch) async {
    launches.add(launch);
    final script = File(launch.arguments[launch.arguments.indexOf('--script') + 1]).readAsStringSync();
    final input = RegExp(r'input_path = "([^"]+)"').firstMatch(script)!.group(1)!;
    final picture = decodePngPicture(File(input).readAsBytesSync());
    final tiles = RegExp(r'\{x = (\d+), y = (\d+), path = "([^"]+)"\}').allMatches(script).toList();
    final width = int.parse(RegExp(r'tile_w = (\d+)').firstMatch(script)!.group(1)!);
    final height = int.parse(RegExp(r'tile_h = (\d+)').firstMatch(script)!.group(1)!);
    if (writeTiles && !refuseMemory) {
      for (final tile in tiles) {
        final x = int.parse(tile.group(1)!);
        final y = int.parse(tile.group(2)!);
        final crop = cropRgbaAt(picture.rgba, picture.width, x, y, width, height);
        File(tile.group(3)!).writeAsBytesSync(encodePngPicture(SbsDecoded(width: width, height: height, rgba: crop)));
      }
    }
    final count = tiles.length;
    final lines = <(String, {bool isError})>[
      ('ggml_vulkan: Found 2 Vulkan devices:', isError: false),
      (
        'ggml_vulkan: 0 = Intel(R) UHD Graphics (Intel Corporation) | uma: 1 | fp16: 1 | int dot: 1 | matrix cores: none',
        isError: false,
      ),
      (
        'ggml_vulkan: 1 = NVIDIA GeForce RTX 4060 Laptop GPU (NVIDIA) | uma: 0 | fp16: 1 | int dot: $intDot | '
            'matrix cores: NV_coopmat2',
        isError: false,
      ),
      if (refuseMemory)
        ('[E] RAM graph capacity exceeded. Requested 3892568608 bytes, 708513792 bytes available', isError: true),
      if (!refuseMemory)
        for (final phase in ['encode', 'sample', 'decode'])
          for (var item = 1; item <= count; item++)
            ('[V] map ${phase}_tile: item $item/$count --- executor.cpp:168', isError: false),
    ];
    return FakeRunningProcess(
      4000 + launches.length,
      launch,
      FakeProcessScript(lines: lines, exitCode: refuseMemory ? 1 : 0),
    );
  }
}

/// x4plus as far as the backend sees it: each pixel made four by four, or a picture of the wrong size
class FakeX4Upscaler implements UpscaleBackend {
  FakeX4Upscaler({this.wrongSize = false});

  final bool wrongSize;
  final requests = <UpscaleRequest>[];

  @override
  String get modelSha256 => '4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1';

  @override
  Future<void> upscale(
    UpscaleRequest request, {
    required NativeCancelFlag cancel,
    void Function(GeneratorProgress progress)? onProgress,
  }) async {
    requests.add(request);
    final picture = decodePngPicture(File(request.inputPath).readAsBytesSync());
    final scale = wrongSize ? 3 : request.scale;
    final width = picture.width * scale;
    final height = picture.height * scale;
    final out = Uint8List(width * height * 4);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final from = 4 * ((y ~/ scale) * picture.width + x ~/ scale);
        out.setRange(4 * (y * width + x), 4 * (y * width + x) + 4, picture.rgba, from);
      }
    }
    File(request.outputPath).writeAsBytesSync(encodePngPicture(SbsDecoded(width: width, height: height, rgba: out)));
  }
}
