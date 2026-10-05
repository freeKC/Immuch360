// One way to read the raw videos of every 360° camera the app stitches: for a direction of the sphere, which input
// textures to read, where, and with what weight. The fisheye pairs (Insta360 side by side frames, Insta360 and DJI two
// track files, Insta360 split pairs) and the GoPro EAC tracks answer the same question, so that the CPU reference
// stitch below, the tests and the shaders of the native players follow the same steps (docs/18-design-projections-
// and-parsers.md, sections 4 and 6.3).
//
// Pure Dart: the photo path stitches on the CPU with it where the shader cannot run, and the tests render and stitch
// synthetic inputs with it.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/raw/dual_fisheye_calibration.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_math.dart';
import 'package:immich_mobile/domain/services/raw/gopro_eac.dart';

/// One read of an input texture: which texture, where (continuous pixels of its declared size, top left origin, pixel
/// centres at half pixels), and the share of the output pixel (the shares of a pixel add up to 1)
typedef RawSample = ({int texture, double x, double y, double weight});

/// The size of an input texture, in pixels
typedef RawTextureSize = ({int width, int height});

/// What the input textures of a raw video give to each direction of the sphere
abstract interface class RawSampler {
  /// Sizes of the input textures, in the order of the tracks of the rawProjection JSON
  List<RawTextureSize> get textureSizes;

  /// What the textures give to the direction of longitude [lon] and latitude [lat] (radians); empty when nothing sees
  /// it
  List<RawSample> sample(double lon, double lat);
}

/// Where the square of a lens lies: its texture and its rectangle, fractions of that texture (top left origin)
typedef LensRegion = ({int texture, double x, double y, double width, double height});

/// The fisheye pair of [calibration] read from [regions] of textures of [textureSizes] (section 4.1): lens i is read
/// less than [DualFisheyeCalibration.maxTheta] off its axis, only where it lands inside its own square of the canvas,
/// whose whole maps onto its region; the two lenses blend between [DualFisheyeCalibration.blendStart] and
/// [DualFisheyeCalibration.blendEnd]
class FisheyePairSampler implements RawSampler {
  FisheyePairSampler(this.calibration, {required this.regions, required this.textureSizes})
    : _viewToLens = viewToLens(calibration);

  final DualFisheyeCalibration calibration;

  /// The region of each lens, lens 0 first
  final List<LensRegion> regions;

  @override
  final List<RawTextureSize> textureSizes;

  final List<Mat3> _viewToLens;

  /// The regions of a side by side frame: lens 0 in the left half, lens 1 in the right half of texture 0
  static List<LensRegion> sideBySideRegions() => const [
    (texture: 0, x: 0.0, y: 0.0, width: 0.5, height: 1.0),
    (texture: 0, x: 0.5, y: 0.0, width: 0.5, height: 1.0),
  ];

  /// Whole textures: lens i fills texture [textureOfLens][i]
  static List<LensRegion> wholeTextureRegions(List<int> textureOfLens) => [
    for (final texture in textureOfLens) (texture: texture, x: 0.0, y: 0.0, width: 1.0, height: 1.0),
  ];

  @override
  List<RawSample> sample(double lon, double lat) => [for (final (lens: _, :sample) in sampleLenses(lon, lat)) sample];

  /// What each lens gives to the direction of longitude [lon] and latitude [lat] (radians), with the lens of each read:
  /// the weights are made to add up to 1; where no lens has weight (both past the blend, or the other one off its
  /// square) the lens closer to its axis is taken alone. Empty when no lens sees the direction.
  List<({int lens, RawSample sample})> sampleLenses(double lon, double lat) {
    final v = viewDirection(lon, lat);
    final square = calibration.canvasSquare;
    final found = <({int lens, RawSample sample, double theta})>[];
    final count = math.min(math.min(_viewToLens.length, regions.length), calibration.lenses.length);
    for (var i = 0; i < count; i++) {
      final d = _viewToLens[i].apply(v);
      final canvas = projectLens(calibration.model, calibration.lenses[i], d, maxTheta: calibration.maxTheta);
      if (canvas == null) {
        continue;
      }
      // Lens-local fractions of its square of the canvas
      final lx = (canvas.x - i * square) / square;
      final ly = canvas.y / square;
      if (!(lx >= 0 && lx < 1 && ly >= 0 && ly < 1)) {
        continue;
      }
      final region = regions[i];
      if (region.texture < 0 || region.texture >= textureSizes.length) {
        continue;
      }
      final size = textureSizes[region.texture];
      final left = region.x * size.width;
      final right = (region.x + region.width) * size.width;
      final top = region.y * size.height;
      final bottom = (region.y + region.height) * size.height;
      // Kept half a pixel inside the region, so that bilinear sampling never reads the other lens of a side by side
      // frame
      final x = _within(left + lx * (right - left), left + 0.5, right - 0.5);
      final y = _within(top + ly * (bottom - top), top + 0.5, bottom - 0.5);
      final theta = offAxisDegrees(d);
      final weight = blendWeight(theta, start: calibration.blendStart, end: calibration.blendEnd);
      found.add((lens: i, sample: (texture: region.texture, x: x, y: y, weight: weight), theta: theta));
    }
    final total = found.fold(0.0, (sum, entry) => sum + entry.sample.weight);
    // A lens past the blend adds nothing to the pixel: it is left out rather than read for nothing
    if (total > 0) {
      return [
        for (final (:lens, :sample, theta: _) in found)
          if (sample.weight > 0)
            (lens: lens, sample: (texture: sample.texture, x: sample.x, y: sample.y, weight: sample.weight / total)),
      ];
    }
    if (found.isEmpty) {
      return const [];
    }
    final closest = found.reduce((a, b) => b.theta < a.theta ? b : a);
    final sample = closest.sample;
    return [(lens: closest.lens, sample: (texture: sample.texture, x: sample.x, y: sample.y, weight: 1.0))];
  }
}

// [value] clamped to [low, high], the middle of the two when the range is empty (a region under a pixel wide)
double _within(double value, double low, double high) => low > high ? (low + high) / 2 : value.clamp(low, high);

/// The two EAC tracks of a GoPro .360 (section 4.2), turned from the view frame into the camera frame of the face table
/// by [viewToCamera], row major: the one of the model by default (see [goProViewToCamera])
class GoProEacSampler implements RawSampler {
  GoProEacSampler(this.geometry, {List<double>? viewToCamera})
    : viewToCamera = viewToCamera ?? goProViewToCamera(geometry);

  final GoProEacGeometry geometry;
  final List<double> viewToCamera;

  @override
  List<RawTextureSize> get textureSizes => [
    for (var track = 0; track < 2; track++) (width: geometry.trackWidth, height: geometry.trackHeight),
  ];

  @override
  List<RawSample> sample(double lon, double lat) => goProEacSamples(geometry, viewToCamera, viewDirection(lon, lat));
}

/// An RGBA image in memory, for the CPU path and the tests
typedef RgbaTexture = ({Uint8List rgba, int width, int height});

/// The RGBA pixels of an equirect picture of [width] x [height] stitched by [sampler] from [textures] (one per sampler
/// texture, in that order), bilinear as the GPU samples, opaque, black where nothing sees. A texture of another size
/// than [RawSampler.textureSizes] declares (a transcoded stream, a frame decoded smaller) is read scaled on each axis.
Uint8List stitchRawRgba(List<RgbaTexture> textures, RawSampler sampler, {required int width, required int height}) {
  final declared = sampler.textureSizes;
  final output = Uint8List(width * height * 4);
  final colour = Float64List(3);
  for (var j = 0; j < height; j++) {
    for (var i = 0; i < width; i++) {
      final (:lon, :lat) = equirectAngles(i, j, width, height);
      colour.fillRange(0, 3, 0);
      for (final sample in sampler.sample(lon, lat)) {
        if (sample.texture >= textures.length || sample.texture >= declared.length) {
          continue;
        }
        final texture = textures[sample.texture];
        final size = declared[sample.texture];
        addBilinearRgba(
          texture,
          sample.x * texture.width / size.width,
          sample.y * texture.height / size.height,
          sample.weight,
          colour,
        );
      }
      final at = (j * width + i) * 4;
      output[at] = colour[0].round().clamp(0, 255);
      output[at + 1] = colour[1].round().clamp(0, 255);
      output[at + 2] = colour[2].round().clamp(0, 255);
      output[at + 3] = 255;
    }
  }
  return output;
}

/// Adds [weight] times the colour of [texture] at ([x], [y]) (continuous pixels, centres at half pixels) to the red,
/// green and blue of [colour], interpolated between the four nearest pixels, the edges clamped: GPU texture sampling
/// with a linear filter
void addBilinearRgba(RgbaTexture texture, double x, double y, double weight, Float64List colour) {
  final (:rgba, :width, :height) = texture;
  final tx = x - 0.5;
  final ty = y - 0.5;
  final x0 = tx.floor();
  final y0 = ty.floor();
  final fx = tx - x0;
  final fy = ty - y0;
  final left = x0.clamp(0, width - 1);
  final right = (x0 + 1).clamp(0, width - 1);
  final top = y0.clamp(0, height - 1);
  final bottom = (y0 + 1).clamp(0, height - 1);
  for (var c = 0; c < 3; c++) {
    final upper = rgba[(top * width + left) * 4 + c] * (1 - fx) + rgba[(top * width + right) * 4 + c] * fx;
    final lower = rgba[(bottom * width + left) * 4 + c] * (1 - fx) + rgba[(bottom * width + right) * 4 + c] * fx;
    colour[c] += weight * (upper * (1 - fy) + lower * fy);
  }
}
