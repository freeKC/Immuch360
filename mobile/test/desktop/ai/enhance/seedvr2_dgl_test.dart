import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/enhance/enhance_pixels.dart';
import 'package:immich_mobile/desktop/ai/enhance/seedvr2_dgl.dart';

void main() {
  group('the program', () {
    final tiles = planTiles(1000, 600);
    final program = seedVr2Program(
      ditPath: r'C:\AI\models\seedvr2\seedvr2_3b_int8_convrot.safetensors',
      vaePath: '/home/a/vae "q".safetensors',
      inputPath: r'C:\Temp\work\input.png',
      tiles: tiles,
      tileFolder: r'C:\Temp\work\tiles',
      seed: 42,
    );

    test('is the phased program of the probe: encode every tile, sample every tile, decode every tile', () {
      expect(program, startsWith('# version: 0.0.0\n'));
      final encode = program.indexOf('conditions = map(tiles, process = encode_tile');
      final sample = program.indexOf('latents = map(conditions, process = sample_tile');
      final decode = program.indexOf('shapes = map(indices, process = decode_tile');
      expect(encode, greaterThan(0));
      expect(sample, greaterThan(encode));
      expect(decode, greaterThan(sample));
      expect(program, contains('sigmas = tensor::vector([1.0, 0.0])'));
      expect(program, contains('seedvr2::positive_embedding(dit)'));
      expect(program, contains('tensor::arange(0, ${tiles.length})'));
    });

    test('pins the direct convolution on both loaders, which the flag of the command line cannot do', () {
      expect(program, contains('dit = load_dit(dit_path, conv_direct_mode = "on")'));
      expect(program, contains('vae = load_vae(vae_path, conv_direct_mode = "on")'));
    });

    test('tiles the VAE in 512 px with a quarter of overlap', () {
      expect(program, contains('tiling = tiling(tile_size_w = 512, tile_size_h = 512, target_overlap = 0.25)'));
    });

    test('names every tile with its corner, paths in forward slashes and quoted', () {
      expect(program, contains('dit_path = "C:/AI/models/seedvr2/seedvr2_3b_int8_convrot.safetensors"'));
      expect(program, contains(r'vae_path = "/home/a/vae \"q\".safetensors"'));
      expect(program, contains('input_path = "C:/Temp/work/input.png"'));
      expect(program, contains('{x = 488, y = 88, path = "C:/Temp/work/tiles/${seedVr2TileName(5)}"}'));
      expect(program, contains('tile_w = 512'));
      expect(program, contains('tile_h = 512'));
      expect(program, contains('seed = 42'));
      expect(program, contains('factor = 1'));
    });
  });

  group('the log of sd-cli', () {
    test('the progress of each phase', () {
      expect(seedVr2ProgressOf('[V] map encode_tile: item 1/63 --- executor.cpp:168'), (
        phase: SeedVr2Phase.encode,
        item: 1,
        of: 63,
      ));
      expect(seedVr2ProgressOf('[V] map sample_tile: item 20/20 --- executor.cpp:168'), (
        phase: SeedVr2Phase.sample,
        item: 20,
        of: 20,
      ));
      expect(seedVr2ProgressOf('[V] map decode_tile: item 7/9 --- executor.cpp:168'), (
        phase: SeedVr2Phase.decode,
        item: 7,
        of: 9,
      ));
      expect(seedVr2ProgressOf('[I] map encode_tile: 63 items --- executor.cpp:166'), isNull);
    });

    test('the steps of the whole run: three phases of equal count', () {
      expect(seedVr2Step((phase: SeedVr2Phase.encode, item: 1, of: 63)), 1);
      expect(seedVr2Step((phase: SeedVr2Phase.sample, item: 1, of: 63)), 64);
      expect(seedVr2Step((phase: SeedVr2Phase.decode, item: 63, of: 63)), 189);
    });

    test('the integer dot product of each card', () {
      const nvidia =
          'ggml_vulkan: 1 = NVIDIA GeForce RTX 4060 Laptop GPU (NVIDIA) | uma: 0 | rebar: 1 | fp16: 1 | bf16: 1 | '
          'fp4: 0 | warp size: 32 | shared memory: 49152 | int dot: 1 | matrix cores: NV_coopmat2';
      expect(ggmlIntDotOf(nvidia), (index: 1, intDot: true));
      expect(ggmlIntDotOf(nvidia.replaceFirst('int dot: 1', 'int dot: 0')), (index: 1, intDot: false));
      expect(ggmlIntDotOf('ggml_vulkan: Found 2 Vulkan devices:'), isNull);
    });

    test('the refusals of its memory checks, which ask to close other programs', () {
      expect(
        seedVr2MemoryRefusal(
          '[E] RAM graph capacity exceeded. Requested 3892568608 bytes, 708513792 bytes available, 0 bytes resident '
          '--- model_manager.cpp:1307',
        ),
        isTrue,
      );
      expect(seedVr2MemoryRefusal('[E] RAM weight capacity exceeded. Requested 3458481408 bytes'), isTrue);
      expect(seedVr2MemoryRefusal('[V] processing 1 tiles --- tiling.cpp:179'), isFalse);
    });

    test('a fall back of the matrix products to the processor', () {
      expect(seedVr2ProcessorFallback('[W] int8 matmul: device lacks H256, fall back to CPU'), isTrue);
      expect(seedVr2ProcessorFallback('[W] falling back to CPU for op MUL_MAT'), isTrue);
      expect(seedVr2ProcessorFallback('load_backend: loaded CPU backend from ggml-cpu-alderlake.dll'), isFalse);
    });
  });
}
