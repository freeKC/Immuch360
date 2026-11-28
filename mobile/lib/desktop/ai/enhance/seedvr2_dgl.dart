// "Rebuild details": SeedVR2 3B through the script mode of stable-diffusion.cpp (DGL, `sd-cli -M dgl --script`), the
// only way that commit runs SeedVR2 (PR #2396: "Currently supported only through dgl"). The program is the one the
// probe of 23 November 2026 measured (probe-e0.md, section 7; scripts/make_dgl_phased.py), the upstream image script
// docs/dgl/seedvr2/seedvr2-3b-image-upscale.dgl at 0d71f963 cut into app tiles:
//  - every tile of 512 px (64 of overlap) is encoded by the VAE, then the DiT samples every tile (one Euler step from
//    sigma 1 to 0 with the checkpoint's positive embedding, its 3.3 GB of weights loaded once), then every tile is
//    decoded and saved as a PNG of its own; tile by tile instead, the weights went back to disk for each tile and the
//    12 MP photo took 366 s instead of 204 s;
//  - the VAE in tiles of 512 px with a quarter of overlap;
//  - conv_direct_mode "on" on both loaders: sd-cli times both 3D convolution paths at its start and its "auto" choice
//    flipped between runs, the other path taking 2 GB of compute buffers instead of 0.45 GB and 3 to 4 times longer;
//    the --conv-direct flag of the command line is ignored in DGL mode;
//  - the factor 1 (the photo restored at its own size), a fixed seed.
// The app blends the tiles (enhance_pixels.dart), then takes the colour fix and the strength.
//
// A photo of more than 24 tiles runs in several programs, one sd-cli each (release 54, [seedVr2Batches]): 3 tiles
// first, then runs of at most 40. The memory check of sd-cli runs at every tile of the DiT, and the run of 27
// November 2026 (77 tiles, 14 MP) was refused at one of them after 4 min 37 s, every tile lost with the process: a
// refusal now costs the run under way only, the tiles of the runs before stay on disk, and the 3 tiles of the first
// run reach the DiT within seconds of the start, so that a computer short of memory is told so at once. Each run
// loads the DiT again (6.4 s in the probe, the start of sd-cli about as much again): some 26 s more for 77 tiles
// in three runs (3, 37 and 37 tiles).
// Each run takes the seed of the job plus the index of its first tile, so that the noise of its tiles is its own and
// a run made again gives the same tiles. The tiles are the same as in one program; only their noise differs, as with
// another seed.
//
// What its output tells, read by the engine: the item of each phase ("map encode_tile: item 12/63"), the integer dot
// product of each Vulkan device (without it the INT8 matrix products of the convrot weights fall back to the
// processor: minutes instead of a second per tile, the risk the review of the study named), a line about a fall back
// to the processor, and the refusals of its own memory checks ("RAM graph capacity exceeded"), which the app turns
// into "close other programs".

import 'dart:convert';
import 'dart:math' as math;

import 'package:immich_mobile/desktop/ai/enhance/enhance_pixels.dart';
import 'package:immich_mobile/desktop/ai/gen/sdcpp_runner.dart' show sdCppMetalFailure;

/// The commit of stable-diffusion.cpp the program is written for (tag master-1117-0d71f96)
const seedVr2SdCppCommit = '0d71f963af9c94941f4a67e8ea145935651dd756';

/// The VAE tiles inside each app tile
const seedVr2VaeTile = 512;

/// The seed of every run: the same photo gives the same result
const seedVr2Seed = 42;

/// The budget of graphics memory sd-cli is given, in GiB (the probe's --max-vram 6 on the 8 GB card)
const seedVr2MaxVramGib = 6;

/// The name of the PNG of tile [index] in the tile folder
String seedVr2TileName(int index) => 'tile_${index.toString().padLeft(3, '0')}.png';

String _path(String path) => jsonEncode(path.replaceAll(r'\', '/'));

/// The DGL program that restores [tiles] of the picture at [inputPath] (a PNG of the photo as the app decoded it)
/// into PNGs of [tileFolder] named by [seedVr2TileName] from [firstIndex] on (the index of the first of them among
/// the tiles of the photo), with the DiT at [ditPath] and the VAE at [vaePath]
String seedVr2Program({
  required String ditPath,
  required String vaePath,
  required String inputPath,
  required List<EnhanceTile> tiles,
  required String tileFolder,
  int firstIndex = 0,
  int seed = seedVr2Seed,
  int vaeTile = seedVr2VaeTile,
}) {
  if (tiles.isEmpty) {
    throw ArgumentError('A picture has one tile at least');
  }
  final tileWidth = tiles.first.width;
  final tileHeight = tiles.first.height;
  final folder = tileFolder.replaceAll(r'\', '/');
  final list = [
    for (final (index, tile) in tiles.indexed)
      '{x = ${tile.x}, y = ${tile.y}, path = ${_path('$folder/${seedVr2TileName(firstIndex + index)}')}}',
  ].join(',\n        ');
  final tiling = ', tiling = tiling(tile_size_w = $vaeTile, tile_size_h = $vaeTile, target_overlap = 0.25)';
  return '''# version: 0.0.0
# Immuch360, Enhance (AI), Rebuild details: SeedVR2 3B in app tiles, encode all, sample all, decode all
# (tiles ${firstIndex + 1} to ${firstIndex + tiles.length})
# (stable-diffusion.cpp $seedVr2SdCppCommit, docs/dgl/seedvr2/seedvr2-3b-image-upscale.dgl)

var {
    dit_path = ${_path(ditPath)}
    vae_path = ${_path(vaePath)}
    input_path = ${_path(inputPath)}
    seed = $seed
    factor = 1
    tile_w = $tileWidth
    tile_h = $tileHeight
    tiles = [
        $list
    ]
}

fn prepare_seedvr2_frames(frames, width, height, count) {
    aligned_width = math::ceil_div(width, 16) * 16
    aligned_height = math::ceil_div(height, 16) * 16
    padded_count = math::ceil_div(count - 1, 4) * 4 + 1
    planar = tensor::permute(tensor::cast(frames, "f32"), axes = [1, 2, 3, 0])
    pixels = tensor::div(planar, 255.0)
    scaled = tensor::clamp(tensor::interpolate(pixels, [width, height], mode = "bicubic"), min = 0, max = 1)
    padded = tensor::pad(scaled, [0, aligned_width - width, 0, aligned_height - height])
    tail = tensor::full([padded_count - count], count - 1, dtype = "i64")
    indices = tensor::concat([tensor::arange(0, count), tail], axis = 0)
    extended = tensor::index_select(padded, axis = 2, indices = indices)
    return tensor::reshape(extended, [aligned_width, aligned_height, padded_count, 3, 1])
}

fn encode_tile(tile, image, vae, rng, tile_w, tile_h, factor) {
    crop = tensor::crop(image, axes = [1, 2], start = [tile.x, tile.y], size = [tile_w, tile_h])
    frames = tensor::unsqueeze(crop, axis = 3)
    shape = tensor::shape(frames)
    pixels = prepare_seedvr2_frames(frames, shape[1] * factor, shape[2] * factor, shape[3])
    encoded = vae_encode(vae, pixels, rng = rng, posterior = "mode"$tiling)
    return vae_to_dit_latents(vae, encoded)
}

fn sample_tile(condition_latent, dit, embedding, rng) {
    s = tensor::shape(condition_latent)
    mask = tensor::full([s[0], s[1], s[2], 1, s[4]], 1)
    condition = { crossattn = embedding, concat = tensor::concat([condition_latent, mask], axis = 3) }
    noise = tensor::randn_like(condition_latent, rng = rng)
    sigmas = tensor::vector([1.0, 0.0])
    return sample(noise, sigmas, predict = predictor(dit, condition), method = "euler", rng = rng)
}

fn decode_tile(index, latents, tiles, vae, tile_w, tile_h, factor) {
    tile = tiles[index]
    width = tile_w * factor
    height = tile_h * factor
    decoded = vae_decode(vae, dit_to_vae_latents(vae, latents[index]), dtype = "f32"$tiling)
    cropped = tensor::crop(decoded, axes = [0, 1, 2], start = [0, 0, 0], size = [width, height, 1])
    planar = tensor::reshape(cropped, [width, height, 1, 3])
    output = tensor::cast(tensor::mul(tensor::permute(planar, axes = [3, 0, 1, 2]), 255.0), "u8")
    image::save(tile.path, output[:, :, :, 0])
    return tensor::shape(output)
}

fn main() {
    dit = load_dit(dit_path, conv_direct_mode = "on")
    vae = load_vae(vae_path, conv_direct_mode = "on")
    image = image::load(input_path)
    rng = make_rng("cuda", seed = seed)
    embedding = seedvr2::positive_embedding(dit)
    conditions = map(tiles, process = encode_tile, image = image, vae = vae, rng = rng, tile_w = tile_w, tile_h = tile_h, factor = factor)
    latents = map(conditions, process = sample_tile, dit = dit, embedding = embedding, rng = rng)
    indices = tensor::to_list(tensor::arange(0, ${tiles.length}))
    shapes = map(indices, process = decode_tile, latents = latents, tiles = tiles, vae = vae, tile_w = tile_w, tile_h = tile_h, factor = factor)
    return shapes
}
''';
}

/// The three phases of the program, in their order
enum SeedVr2Phase { encode, sample, decode }

/// Where a run is: the phase, and the tile of it under way, from 1
typedef SeedVr2Progress = ({SeedVr2Phase phase, int item, int of});

final _item = RegExp(r'\bmap (encode|sample|decode)_tile: item (\d+)/(\d+)');

/// The tile [line] says a phase starts, null for any other line
SeedVr2Progress? seedVr2ProgressOf(String line) {
  final match = _item.firstMatch(line);
  if (match == null) {
    return null;
  }
  return (
    phase: SeedVr2Phase.values.byName(match.group(1)!),
    item: int.parse(match.group(2)!),
    of: int.parse(match.group(3)!),
  );
}

/// The step of the whole run [progress] stands for, of three times its count
int seedVr2Step(SeedVr2Progress progress) => progress.phase.index * progress.of + progress.item;

final _device = RegExp(r'^ggml_vulkan: (\d+) = .*\| int dot: (\d)');

/// Whether the Vulkan device a line of sd-cli's list names has the integer dot product ("int dot: 1"); null for any
/// other line
({int index, bool intDot})? ggmlIntDotOf(String line) {
  final match = _device.firstMatch(line);
  return match == null ? null : (index: int.parse(match.group(1)!), intDot: match.group(2) == '1');
}

/// Whether [line] is a refusal of the memory checks of sd-cli, which ask for memory the computer does not have free
bool seedVr2MemoryRefusal(String line) =>
    line.contains('RAM graph capacity exceeded') || line.contains('RAM weight capacity exceeded');

/// A refusal of the memory checks of sd-cli: what it asked, what it found available once its headroom of 1 GiB was
/// kept back, and the weights it held in the memory of the computer
typedef SeedVr2Refusal = ({bool weights, int requested, int available, int resident});

final _refusal = RegExp(
  r'RAM (graph|weight) capacity exceeded\. Requested (\d+) bytes, (\d+) bytes available(?:, (\d+) bytes resident)?',
);

/// The figures of the refusal [line] tells (model_manager.cpp at 0d71f963); null for any other line
SeedVr2Refusal? seedVr2RefusalOf(String line) {
  final match = _refusal.firstMatch(line);
  if (match == null) {
    return null;
  }
  return (
    weights: match.group(1) == 'weight',
    requested: int.parse(match.group(2)!),
    available: int.parse(match.group(3)!),
    resident: int.parse(match.group(4) ?? '0'),
  );
}

/// The tiles of a photo of [tiles] up to which it runs in one program
const seedVr2OneRun = 24;

/// The tiles of the first program of a larger photo: three, so that its DiT runs early and its pace is measured
const seedVr2FirstRun = 3;

/// The most tiles of each of the other programs
const seedVr2MostPerRun = 40;

/// The runs of a photo of [tiles], as ranges of their indices (see the top of this file): one up to [seedVr2OneRun],
/// else [seedVr2FirstRun] tiles, then the rest in even runs of at most [seedVr2MostPerRun]
List<({int start, int end})> seedVr2Batches(int tiles) {
  if (tiles <= seedVr2OneRun) {
    return [(start: 0, end: tiles)];
  }
  final rest = tiles - seedVr2FirstRun;
  final runs = (rest + seedVr2MostPerRun - 1) ~/ seedVr2MostPerRun;
  final batches = [(start: 0, end: seedVr2FirstRun)];
  var start = seedVr2FirstRun;
  for (var run = 0; run < runs; run++) {
    final size = rest ~/ runs + (run < rest % runs ? 1 : 0);
    batches.add((start: start, end: start + size));
    start += size;
  }
  return batches;
}

/// What each part of the program took in the probe (12 MP, 63 tiles of 512 in one program: 93.9 s), in hundredths of
/// a second: a tile of each phase (18.6 s, 28.0 s less the DiT read, 40.8 s for the 63), the read of the DiT at the
/// first tile of its phase, and the start of sd-cli before its first tile. The percent of a run follows them.
const seedVr2TileCost = {SeedVr2Phase.encode: 30, SeedVr2Phase.sample: 34, SeedVr2Phase.decode: 65};
const seedVr2DitLoadCost = 640;
const seedVr2StartCost = 650;

/// The start of sd-cli the time left counts for a run still to come until one after the first was timed: the probe's
const _probeStart = Duration(milliseconds: 6500);

/// The progress of the runs of a photo (see the top of this file), from the lines of sd-cli and the time they came:
///  - the work done and all of it, in hundredths of a second of the probe ([seedVr2TileCost]): a tile counts once its
///    phase moved to the next tile, so that "item 12/40" is 11 tiles done;
///  - the time left, from what this computer took: each phase timed between two tiles of it, the read of the DiT
///    between its first two tiles, the start of sd-cli before the first tile of a run after the first (the first one
///    loads everything for the first time); null until each of the three phases timed a tile;
///  - the phase under way, and its tile among those of the photo.
class SeedVr2Pace {
  SeedVr2Pace(List<({int start, int end})> batches)
    : _sizes = [for (final batch in batches) batch.end - batch.start],
      _starts = [for (final batch in batches) batch.start];

  final List<int> _sizes;
  final List<int> _starts;

  final _times = {for (final phase in SeedVr2Phase.values) phase: <Duration>[]};
  final _loads = <Duration>[];
  final _launches = <Duration>[];

  var _batch = 0;
  Duration? _launched;
  SeedVr2Progress? _at;
  Duration? _atTime;
  Duration? _firstSample;

  /// The work of the runs done before the one under way, and of the tries made again
  var _before = 0;
  var _extra = 0;

  /// The work of the run under way that is done
  var _inRun = 0;

  int _costOf(int batch) =>
      (batch == 0 ? 0 : seedVr2StartCost) +
      seedVr2DitLoadCost +
      _sizes[batch] * seedVr2TileCost.values.fold(0, (sum, cost) => sum + cost);

  /// All the work of the photo
  int get all => _extra + [for (var batch = 0; batch < _sizes.length; batch++) _costOf(batch)].fold(0, (a, b) => a + b);

  /// The work done
  int get done => _before + _inRun;

  /// The phase and its tile among the [tiles] of the photo told last, from 1: kept between two runs, so that the
  /// panel never falls back to the work units of [done] and [all]; null before the first line of a tile
  ({SeedVr2Phase phase, int tile, int tiles})? get where => _shown;
  ({SeedVr2Phase phase, int tile, int tiles})? _shown;

  /// sd-cli started the run [batch] at [time]; the tile told last ([where]) stays told until this run tells its first
  void started(int batch, Duration time) {
    _batch = batch;
    _launched = time;
    _at = null;
    _atTime = null;
    _firstSample = null;
    _inRun = 0;
    _runEnded = false;
  }

  /// Whether the run under way ended well ([ended]) and the next did not start yet
  var _runEnded = false;

  /// The run under way failed and is made again: what it did stays counted, and its work is added again
  void again() {
    _extra += _inRun;
    _before += _inRun;
    _inRun = 0;
  }

  /// The run under way ended well. Its last tile stays where the progress is until the next run tells its first:
  /// between two runs the panel keeps "Writing the result, tile N of M", never a count of the work units above
  void ended() {
    _before += _costOf(_batch);
    _inRun = 0;
    _at = null;
    _atTime = null;
    _runEnded = true;
  }

  /// The run under way (or the one that just ended), from 0, and the runs of the photo
  int get run => _batch;
  int get runs => _sizes.length;

  /// The phase and the tile among the [tiles] of the photo the run under way is at, from 1; null before its first
  /// tile and once it ended (the log of a failure says where it stopped)
  ({SeedVr2Phase phase, int tile, int tiles})? get whereInRun {
    final at = _at;
    return at == null ? null : (phase: at.phase, tile: _starts[_batch] + at.item, tiles: _starts.last + _sizes.last);
  }

  /// Reads the tile [progress] says at [time]
  void read(SeedVr2Progress progress, Duration time) {
    final previous = _at;
    final previousTime = _atTime;
    if (previous == null && _batch > 0 && _launched != null) {
      _launches.add(time - _launched!);
    }
    if (previous != null && previousTime != null && previous.phase == progress.phase && progress.item > previous.item) {
      final took = (time - previousTime) ~/ (progress.item - previous.item);
      if (progress.phase == SeedVr2Phase.sample && previous.item == 1) {
        // The DiT is read at its first tile: told apart once a tile of its own was timed
        _firstSample = took;
      } else {
        _times[progress.phase]!.add(took);
      }
    }
    final sampling = _times[SeedVr2Phase.sample]!;
    if (_firstSample != null && sampling.isNotEmpty) {
      _loads
        ..clear()
        ..add(_firstSample! - _mean(sampling) < Duration.zero ? Duration.zero : _firstSample! - _mean(sampling));
    }
    _at = progress;
    _atTime = time;
    _shown = whereInRun;
    final size = _sizes[_batch];
    var work = _batch == 0 ? 0 : seedVr2StartCost;
    final phase = progress.phase.index;
    for (final other in SeedVr2Phase.values) {
      final cost = seedVr2TileCost[other]!;
      if (other.index < phase) {
        work += size * cost;
      } else if (other.index == phase) {
        work += (progress.item - 1).clamp(0, size) * cost;
      }
    }
    if (phase > SeedVr2Phase.sample.index || (phase == SeedVr2Phase.sample.index && progress.item > 1)) {
      work += seedVr2DitLoadCost;
    }
    _inRun = math.max(_inRun, work);
  }

  static Duration _mean(List<Duration> times) =>
      Duration(microseconds: times.fold(0, (sum, time) => sum + time.inMicroseconds) ~/ times.length);

  /// The time the runs still take at [time], as this computer took them; null until each phase timed a tile
  Duration? left(Duration time) {
    final paces = {for (final phase in SeedVr2Phase.values) phase: _times[phase]!};
    if (paces.values.any((times) => times.isEmpty) || _loads.isEmpty) {
      return null;
    }
    final pace = {for (final entry in paces.entries) entry.key: _mean(entry.value)};
    final load = _loads.single;
    final start = _launches.isEmpty ? _probeStart : _mean(_launches);
    var left = Duration.zero;
    final at = _at;
    final size = _sizes[_batch];
    if (at != null) {
      for (final phase in SeedVr2Phase.values) {
        if (phase.index > at.phase.index) {
          left += pace[phase]! * size;
        } else if (phase == at.phase) {
          left += pace[phase]! * (size - at.item + 1);
        }
      }
      if (at.phase == SeedVr2Phase.encode || (at.phase == SeedVr2Phase.sample && at.item == 1)) {
        left += load;
      }
      // The tile under way has run since its line came
      final since = _atTime == null ? Duration.zero : time - _atTime!;
      left -= since > pace[at.phase]! ? pace[at.phase]! : since;
    } else if (!_runEnded) {
      // A run started that told no tile yet: its start (what is left of it), the read of the DiT and all its tiles
      final since = _launched == null ? Duration.zero : time - _launched!;
      left += since > start ? Duration.zero : start - since;
      left += load;
      for (final phase in SeedVr2Phase.values) {
        left += pace[phase]! * size;
      }
    }
    for (var batch = _batch + 1; batch < _sizes.length; batch++) {
      left += start + load;
      for (final phase in SeedVr2Phase.values) {
        left += pace[phase]! * _sizes[batch];
      }
    }
    return left.isNegative ? Duration.zero : left;
  }

  /// What the runs took, for the log: the time of a tile of each phase, the read of the DiT, the start of sd-cli
  String get summary {
    String ms(Duration? time) => time == null ? '?' : '${time.inMilliseconds} ms';
    final paces = [
      for (final phase in SeedVr2Phase.values)
        '${phase.name} ${ms(_times[phase]!.isEmpty ? null : _mean(_times[phase]!))}',
    ];
    return '${paces.join(', ')} a tile, DiT read ${ms(_loads.isEmpty ? null : _loads.single)}, '
        'start of a later run ${ms(_launches.isEmpty ? null : _mean(_launches))}';
  }
}

final _fallback = RegExp(r'fall(?:s|ing)? back to (?:the )?CPU', caseSensitive: false);

/// The line of sd-cli's auto-fit plan that puts the diffusion model on the processor (release 53)
final _ditOnProcessor = RegExp(r'auto-fit: --backend .*\bdiffusion=cpu\b', caseSensitive: false);

/// Whether [line], on a Mac, says sd-cli does not run on its GPU (sdCppMetalFailure) or put the DiT on the processor:
/// Rebuild details would then run on the processor, minutes a tile, or crash, so the run is stopped
bool seedVr2MetalUnavailable(String line) => sdCppMetalFailure(line) || _ditOnProcessor.hasMatch(line);

/// Whether [line] says a part of the work fell back to the processor
bool seedVr2ProcessorFallback(String line) => _fallback.hasMatch(line);
