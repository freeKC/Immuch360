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
// What its output tells, read by the engine: the item of each phase ("map encode_tile: item 12/63"), the integer dot
// product of each Vulkan device (without it the INT8 matrix products of the convrot weights fall back to the
// processor: minutes instead of a second per tile, the risk the review of the study named), a line about a fall back
// to the processor, and the refusals of its own memory checks ("RAM graph capacity exceeded"), which the app turns
// into "close other programs".

import 'dart:convert';

import 'package:immich_mobile/desktop/ai/enhance/enhance_pixels.dart';

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
/// into PNGs of [tileFolder] named by [seedVr2TileName], with the DiT at [ditPath] and the VAE at [vaePath]
String seedVr2Program({
  required String ditPath,
  required String vaePath,
  required String inputPath,
  required List<EnhanceTile> tiles,
  required String tileFolder,
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
      '{x = ${tile.x}, y = ${tile.y}, path = ${_path('$folder/${seedVr2TileName(index)}')}}',
  ].join(',\n        ');
  final tiling = ', tiling = tiling(tile_size_w = $vaeTile, tile_size_h = $vaeTile, target_overlap = 0.25)';
  return '''# version: 0.0.0
# Immuch360, Enhance (AI), Rebuild details: SeedVR2 3B in app tiles, encode all, sample all, decode all
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

final _fallback = RegExp(r'fall(?:s|ing)? back to (?:the )?CPU', caseSensitive: false);

/// Whether [line] says a part of the work fell back to the processor
bool seedVr2ProcessorFallback(String line) => _fallback.hasMatch(line);
