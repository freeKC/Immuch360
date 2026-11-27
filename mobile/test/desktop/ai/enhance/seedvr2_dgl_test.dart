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

  group('the runs of a large photo (release 54)', () {
    test('one program up to 24 tiles, else 3 tiles first and even runs of at most 40', () {
      expect(seedVr2Batches(1), [(start: 0, end: 1)]);
      expect(seedVr2Batches(24), [(start: 0, end: 24)]);
      expect(seedVr2Batches(25), [(start: 0, end: 3), (start: 3, end: 25)]);
      // The 14 MP photo of 27 November 2026, 77 tiles of 512
      expect(seedVr2Batches(77), [(start: 0, end: 3), (start: 3, end: 40), (start: 40, end: 77)]);
      expect(seedVr2Batches(63), [(start: 0, end: 3), (start: 3, end: 33), (start: 33, end: 63)]);
      for (final tiles in [25, 43, 44, 77, 200, 351]) {
        final runs = seedVr2Batches(tiles);
        expect(runs.first.start, 0);
        expect(runs.last.end, tiles);
        for (var run = 1; run < runs.length; run++) {
          expect(runs[run].start, runs[run - 1].end);
          expect(runs[run].end - runs[run].start, inInclusiveRange(1, seedVr2MostPerRun));
        }
      }
    });

    test('a run names its tiles from the index of its first one, and says which they are', () {
      final tiles = planTiles(4592, 3056);
      final program = seedVr2Program(
        ditPath: '/m/dit.safetensors',
        vaePath: '/m/vae.safetensors',
        inputPath: '/w/input.png',
        tiles: tiles.sublist(3, 40),
        firstIndex: 3,
        tileFolder: '/w/tiles',
        seed: 45,
      );
      expect(program, contains('# (tiles 4 to 40)'));
      expect(program, contains('/w/tiles/tile_003.png'));
      expect(program, contains('/w/tiles/tile_039.png'));
      expect(program, isNot(contains('tile_002.png')));
      expect(program, isNot(contains('tile_040.png')));
      expect(program, contains('seed = 45'));
      expect(program, contains('tensor::arange(0, 37)'));
    });
  });

  group('the figures of a refusal, on the lines sd-cli wrote', () {
    test('the run of 27 November 2026 on the RTX 4060 Laptop, and those of the probe', () {
      expect(
        seedVr2RefusalOf(
          '[E] RAM graph capacity exceeded. Requested 363834672 bytes, 337764352 bytes available, 0 bytes resident '
          '--- model_manager.cpp:1307',
        ),
        (weights: false, requested: 363834672, available: 337764352, resident: 0),
      );
      expect(
        seedVr2RefusalOf(
          '[E] line 59, column 16: line 43, column 14: diffusion output shape [] does not match input [250, 188, 1, '
          '16, 1]. RAM graph capacity exceeded. Requested 1232112224 bytes, 1224269824 bytes available, 0 bytes '
          'resident --- dgl.cpp:142',
        ),
        (weights: false, requested: 1232112224, available: 1224269824, resident: 0),
      );
      expect(
        seedVr2RefusalOf(
          '[E] RAM weight capacity exceeded. Requested 3458481408 bytes, 2116759552 bytes available, 0 bytes resident '
          '--- model_manager.cpp:1307',
        ),
        (weights: true, requested: 3458481408, available: 2116759552, resident: 0),
      );
      expect(
        seedVr2RefusalOf('[E] RAM graph capacity exceeded. Requested 3892568608 bytes, 708513792 bytes available'),
        (weights: false, requested: 3892568608, available: 708513792, resident: 0),
      );
      expect(seedVr2RefusalOf('[V] free compute buffer: 1.69 MB(RAM) on CPU --- compute_workspace.cpp:317'), isNull);
    });
  });

  group('the pace of the runs', () {
    SeedVr2Progress at(SeedVr2Phase phase, int item, int of) => (phase: phase, item: item, of: of);
    Duration ms(int value) => Duration(milliseconds: value);

    test('no time left while it loads, nor before each phase timed a tile', () {
      final pace = SeedVr2Pace(seedVr2Batches(77));
      pace.started(0, Duration.zero);
      expect(pace.where, isNull);
      expect(pace.left(ms(140000)), isNull, reason: 'the silent start of 2 min 20 s tells nothing');
      // The first run, 3 tiles: encode at 0.3 s a tile, then the DiT read (6.4 s) inside its first tile
      pace.read(at(SeedVr2Phase.encode, 1, 3), ms(140000));
      pace.read(at(SeedVr2Phase.encode, 2, 3), ms(140300));
      expect(pace.left(ms(140300)), isNull, reason: 'encode timed, not the other two');
      pace.read(at(SeedVr2Phase.encode, 3, 3), ms(140600));
      pace.read(at(SeedVr2Phase.sample, 1, 3), ms(140900));
      pace.read(at(SeedVr2Phase.sample, 2, 3), ms(147650));
      pace.read(at(SeedVr2Phase.sample, 3, 3), ms(148000));
      expect(pace.left(ms(148000)), isNull, reason: 'decode not timed yet');
      pace.read(at(SeedVr2Phase.decode, 1, 3), ms(148350));
      pace.read(at(SeedVr2Phase.decode, 2, 3), ms(149000));
      final left = pace.left(ms(149000))!;
      // Left: 2 tiles of decode here (one under way), then two runs of 37: a start (the probe's 6.5 s until one is
      // timed), the DiT read, 37 tiles of each phase
      const tile = 300 + 350 + 650;
      final expected = ms(2 * 650 + 2 * (6500 + 6400 + 37 * tile));
      expect((left - expected).inMilliseconds.abs(), lessThan(5));
      expect(pace.where, (phase: SeedVr2Phase.decode, tile: 2, tiles: 77));
    });

    test('the work done follows the three phases at their cost, a tile counted once the next one started', () {
      final pace = SeedVr2Pace(seedVr2Batches(10));
      pace.started(0, Duration.zero);
      expect(pace.all, seedVr2DitLoadCost + 10 * (30 + 34 + 65));
      pace.read(at(SeedVr2Phase.encode, 1, 10), ms(100));
      expect(pace.done, 0);
      pace.read(at(SeedVr2Phase.encode, 4, 10), ms(200));
      expect(pace.done, 3 * 30);
      pace.read(at(SeedVr2Phase.sample, 1, 10), ms(300));
      expect(pace.done, 10 * 30);
      pace.read(at(SeedVr2Phase.sample, 2, 10), ms(7000));
      expect(pace.done, 10 * 30 + 34 + seedVr2DitLoadCost);
      pace.read(at(SeedVr2Phase.decode, 10, 10), ms(9000));
      expect(pace.done, 10 * (30 + 34) + seedVr2DitLoadCost + 9 * 65);
      pace.ended();
      expect(pace.done, pace.all);
      // The share of decode is the half of a tile, as in the probe (40.8 s of 18.6 + 21.6 + 40.8)
      expect(65 / (30 + 34 + 65), closeTo(40.8 / (18.6 + 21.6 + 40.8), 0.01));
    });

    test('a run made again keeps the percent going forward', () {
      final pace = SeedVr2Pace(seedVr2Batches(30));
      pace.started(0, Duration.zero);
      pace.read(at(SeedVr2Phase.decode, 3, 3), ms(1000));
      pace.ended();
      pace.started(1, ms(2000));
      pace.read(at(SeedVr2Phase.sample, 2, 27), ms(9000));
      final before = pace.done;
      final allBefore = pace.all;
      pace.again();
      pace.started(1, ms(10000));
      expect(pace.done, before);
      expect(pace.all, greaterThan(allBefore));
      pace.read(at(SeedVr2Phase.encode, 2, 27), ms(16000));
      expect(pace.done, greaterThan(before));
      pace.read(at(SeedVr2Phase.decode, 27, 27), ms(30000));
      pace.ended();
      expect(pace.done, pace.all);
    });

    test('the start of a later run is timed, and replaces the probe figure', () {
      final pace = SeedVr2Pace(seedVr2Batches(50));
      pace.started(0, Duration.zero);
      pace.read(at(SeedVr2Phase.encode, 1, 3), ms(1000));
      pace.ended();
      pace.started(1, ms(10000));
      pace.read(at(SeedVr2Phase.encode, 1, 24), ms(12000));
      expect(pace.summary, contains('start of a later run 2000 ms'));
    });
  });
}
