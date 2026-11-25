// The photos "Enhance (AI)" takes beyond a flat one (release 53): 360° photos and 3D photos. FreeKC, 25 November 2026:
// Enhance works on every source and every kind of photo the app shows.
//
// A 3D photo: its two eyes, side by side or one above the other, are cut apart and each is given to the model of the
// level on its own, with the same seed and the same strength, then put back where they were. Both eyes get the same
// treatment: Sharpen is a network without noise, the same pixels give the same result; Natural draws its noise from
// the seed again for each eye, tile for tile. Rebuild details invents details, and nothing ties what it invents in one
// eye to the other: the two eyes would no longer match, and the 3D would shimmer. It is not offered on 3D photos (the
// dialog says why).
//
// A 360° photo (an equirectangular picture of the sphere, or each eye of a 360° 3D photo):
//  - the seam: the picture is widened on both sides with the columns of the other side, so that the model sees
//    across the seam, then cut back; the columns just right of the seam are blended from the copy that was enhanced
//    next to the right edge, so that the two edges of the result meet as they did on the photo;
//  - the poles: the rows near a pole stand for a small circle of the sphere stretched to the width of the picture,
//    where a model sees no real shape. A face of a cube looking at the pole (90°) is drawn from the photo, enhanced
//    as an ordinary picture, and drawn back over the rows beyond 56° of latitude, blended in from 52°;
//  - a 360° photo whose GPano crop leaves part of the sphere out wraps only when it goes all the way round, and takes
//    the face of a pole only when it reaches that pole;
//  - its GPano tags are written again in the enhanced photo (enhance_engine.dart), as they were, or those of a whole
//    sphere for one only its camera tells.
// A VR180 photo (two half spheres side by side), an Apple spatial photo (two pictures in one HEIC file) and a raw photo
// of a 360° camera (its two lenses not stitched) are still skipped.
//
// Every picture here is RGBA bytes, rows top to bottom, alpha 255. The pixel work is pure and synchronous; the engine
// runs it in isolates of its own.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart' show SbsDecoded;
import 'package:immich_mobile/desktop/ai/enhance/enhance_pixels.dart' show cropRgbaAt;
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart' show enhanceGPanoNames;

/// Where the two eyes of a 3D photo are in its frame
enum EnhanceEyes {
  /// A photo of one eye
  none,

  /// The left eye in the left half (or the right one, [EnhanceLayout.rightFirst])
  sideBySide,

  /// The left eye in the top half
  topBottom,
}

/// What the engine does with the picture of a photo: one picture, two eyes, and each of them a picture of the sphere
/// or not
class EnhanceLayout {
  const EnhanceLayout({
    this.eyes = EnhanceEyes.none,
    this.sphere = false,
    this.halfEyes = false,
    this.rightFirst = false,
  });

  /// A flat photo, enhanced whole
  static const flat = EnhanceLayout();

  final EnhanceEyes eyes;

  /// Each eye (or the photo) is an equirectangular picture of the sphere: the seam wrapped and the poles taken apart
  final bool sphere;

  /// Side by side eyes each squeezed into half the width of one (half side by side): written in the XMP of the result
  final bool halfEyes;

  /// Side by side eyes, the right one first (crossed eyes)
  final bool rightFirst;

  /// Two eyes
  bool get isStereo => eyes != EnhanceEyes.none;

  bool get isFlat => !isStereo && !sphere;

  /// Immuch360:EnhanceInput of the result: what the photo was; null for a flat one
  String? get xmp => switch ((eyes, sphere)) {
    (EnhanceEyes.none, false) => null,
    (EnhanceEyes.none, true) => 'Sphere',
    (EnhanceEyes.sideBySide, false) => 'SideBySide',
    (EnhanceEyes.topBottom, false) => 'TopBottom',
    (EnhanceEyes.sideBySide, true) => 'SphereSideBySide',
    (EnhanceEyes.topBottom, true) => 'SphereTopBottom',
  };

  @override
  bool operator ==(Object other) =>
      other is EnhanceLayout &&
      other.eyes == eyes &&
      other.sphere == sphere &&
      other.halfEyes == halfEyes &&
      other.rightFirst == rightFirst;

  @override
  int get hashCode => Object.hash(eyes, sphere, halfEyes, rightFirst);

  @override
  String toString() => 'EnhanceLayout(${eyes.name}${sphere ? ', sphere' : ''}${halfEyes ? ', half' : ''})';
}

/// The part of the sphere a 360° picture covers, as its GPano crop tells: whether it goes all the way round (its seam
/// wraps) and whether it reaches each pole
class EnhanceSphereCover {
  const EnhanceSphereCover({this.wraps = true, this.north = true, this.south = true});

  /// The whole sphere
  static const whole = EnhanceSphereCover();

  final bool wraps;
  final bool north;
  final bool south;

  /// The cover of a GPano crop of [left], [top], [width] and [height] parts of the whole sphere (0 to 1); the whole
  /// sphere without a crop
  factory EnhanceSphereCover.ofCrop({double? left, double? top, double? width, double? height}) {
    if (left == null || top == null || width == null || height == null) {
      return whole;
    }
    const near = 0.002;
    return EnhanceSphereCover(wraps: width >= 1 - near, north: top <= near, south: top + height >= 1 - near);
  }

  @override
  bool operator ==(Object other) =>
      other is EnhanceSphereCover && other.wraps == wraps && other.north == north && other.south == south;

  @override
  int get hashCode => Object.hash(wraps, north, south);

  @override
  String toString() => 'EnhanceSphereCover(wraps: $wraps, north: $north, south: $south)';
}

/// The latitudes, in degrees, from which the face of a pole is blended in, and beyond which it alone is used
const enhancePoleBlendFrom = 52.0;
const enhancePoleBlendTo = 56.0;

/// The columns a 360° picture of [width] pixels is widened by on each side: 1/64 of it, 32 to 256 pixels, never more
/// than a quarter of it
int sphereSeamPad(int width) => math.min(width ~/ 4, (width ~/ 64).clamp(32, 256));

/// The side of the face of a pole of a 360° picture [height] pixels high: as many pixels per degree at its centre as
/// the picture has across its height
int poleFaceSize(int height) => math.max(8, (2 * height / math.pi).round());

/// [rgba] of [width] x [height], [pad] columns wider on each side: those of the other side of the seam
Uint8List wrapPad(Uint8List rgba, int width, int height, int pad) {
  final wide = width + 2 * pad;
  final out = Uint8List(wide * height * 4);
  for (var y = 0; y < height; y++) {
    final from = 4 * y * width;
    final to = 4 * y * wide;
    // The last columns, then the picture, then the first columns
    out.setRange(to, to + 4 * pad, rgba, from + 4 * (width - pad));
    out.setRange(to + 4 * pad, to + 4 * (pad + width), rgba, from);
    out.setRange(to + 4 * (pad + width), to + 4 * wide, rgba, from);
  }
  return out;
}

/// The picture of [width] x [height] in [padded] (made by [wrapPad] with [pad] and enhanced), cut back: its first
/// [blend] columns go from the copy enhanced past the right edge (at the seam) to the one enhanced in place, so that
/// the right edge and the left one meet as they did on the photo
Uint8List unwrapSeam(Uint8List padded, int width, int height, int pad, {int? blend}) {
  final wide = width + 2 * pad;
  final across = math.min(blend ?? pad ~/ 2, pad);
  final out = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    final row = 4 * y * wide;
    final to = 4 * y * width;
    out.setRange(to, to + 4 * width, padded, row + 4 * pad);
    for (var x = 0; x < across; x++) {
      // 0 at the seam (the copy past the right edge), 1 once [across] columns in (the picture itself)
      final share = (x + 0.5) / across;
      final seam = row + 4 * (pad + width + x);
      final inPlace = row + 4 * (pad + x);
      for (var c = 0; c < 3; c++) {
        out[to + 4 * x + c] = _byte(padded[seam + c] + share * (padded[inPlace + c] - padded[seam + c]));
      }
      out[to + 4 * x + 3] = 255;
    }
  }
  return out;
}

int _byte(double value) => value <= 0 ? 0 : (value >= 255 ? 255 : (value + 0.5).toInt());

/// The face of the cube of [size] x [size] pixels looking at the north pole ([north]) or the south one of the 360°
/// picture [rgba] of [width] x [height], 90° across, drawn from it with a bilinear sample (the columns wrapping)
Uint8List poleFace(Uint8List rgba, int width, int height, int size, {required bool north}) {
  final out = Uint8List(size * size * 4);
  final pixel = Float64List(3);
  for (var j = 0; j < size; j++) {
    final v = (j + 0.5) / size * 2 - 1;
    for (var i = 0; i < size; i++) {
      final u = (i + 0.5) / size * 2 - 1;
      final reach = math.atan2(1, math.sqrt(u * u + v * v));
      final latitude = north ? reach : -reach;
      final longitude = math.atan2(u, v);
      _sampleSphere(rgba, width, height, longitude, latitude, pixel);
      final at = 4 * (j * size + i);
      out[at] = _byte(pixel[0]);
      out[at + 1] = _byte(pixel[1]);
      out[at + 2] = _byte(pixel[2]);
      out[at + 3] = 255;
    }
  }
  return out;
}

/// The face [face] of [size] x [size] (made by [poleFace] and enhanced) drawn back over the rows of [target] near its
/// pole, in place: alone beyond [to] degrees of latitude, blended in from [from]
void pastePoleFace(
  Uint8List target,
  int width,
  int height,
  Uint8List face,
  int size, {
  required bool north,
  double from = enhancePoleBlendFrom,
  double to = enhancePoleBlendTo,
}) {
  final start = from * math.pi / 180;
  final full = to * math.pi / 180;
  final pixel = Float64List(3);
  for (var y = 0; y < height; y++) {
    final latitude = math.pi / 2 - (y + 0.5) / height * math.pi;
    final reach = north ? latitude : -latitude;
    if (reach < start) {
      continue;
    }
    final t = full <= start ? 1.0 : ((reach - start) / (full - start)).clamp(0.0, 1.0);
    final share = t * t * (3 - 2 * t);
    final cosLat = math.cos(latitude);
    final sinLat = math.sin(latitude).abs();
    for (var x = 0; x < width; x++) {
      final longitude = (x + 0.5) / width * 2 * math.pi - math.pi;
      // The direction on the plane of the face, one unit from the centre of the sphere
      final u = cosLat * math.sin(longitude) / sinLat;
      final v = cosLat * math.cos(longitude) / sinLat;
      _sampleFace(face, size, u, v, pixel);
      final at = 4 * (y * width + x);
      for (var c = 0; c < 3; c++) {
        target[at + c] = _byte(target[at + c] + share * (pixel[c] - target[at + c]));
      }
      target[at + 3] = 255;
    }
  }
}

void _sampleSphere(Uint8List rgba, int width, int height, double longitude, double latitude, Float64List into) {
  final fx = (longitude + math.pi) / (2 * math.pi) * width - 0.5;
  final fy = ((math.pi / 2 - latitude) / math.pi * height - 0.5).clamp(0.0, height - 1.0);
  final x0 = fx.floor();
  final y0 = fy.floor();
  final dx = fx - x0;
  final dy = fy - y0;
  final y1 = math.min(y0 + 1, height - 1);
  final xa = x0 % width;
  final xb = (x0 + 1) % width;
  for (var c = 0; c < 3; c++) {
    final top = rgba[4 * (y0 * width + xa) + c] * (1 - dx) + rgba[4 * (y0 * width + xb) + c] * dx;
    final bottom = rgba[4 * (y1 * width + xa) + c] * (1 - dx) + rgba[4 * (y1 * width + xb) + c] * dx;
    into[c] = top * (1 - dy) + bottom * dy;
  }
}

void _sampleFace(Uint8List face, int size, double u, double v, Float64List into) {
  final fx = ((u + 1) / 2 * size - 0.5).clamp(0.0, size - 1.0);
  final fy = ((v + 1) / 2 * size - 0.5).clamp(0.0, size - 1.0);
  final x0 = fx.floor();
  final y0 = fy.floor();
  final x1 = math.min(x0 + 1, size - 1);
  final y1 = math.min(y0 + 1, size - 1);
  final dx = fx - x0;
  final dy = fy - y0;
  for (var c = 0; c < 3; c++) {
    final top = face[4 * (y0 * size + x0) + c] * (1 - dx) + face[4 * (y0 * size + x1) + c] * dx;
    final bottom = face[4 * (y1 * size + x0) + c] * (1 - dx) + face[4 * (y1 * size + x1) + c] * dx;
    into[c] = top * (1 - dy) + bottom * dy;
  }
}

/// Where each eye of a picture of [width] x [height] laid out as [eyes] is: x, y, width, height
List<({int x, int y, int width, int height})> eyeRects(int width, int height, EnhanceEyes eyes) => switch (eyes) {
  EnhanceEyes.none => [(x: 0, y: 0, width: width, height: height)],
  EnhanceEyes.sideBySide => [
    (x: 0, y: 0, width: width ~/ 2, height: height),
    (x: width ~/ 2, y: 0, width: width - width ~/ 2, height: height),
  ],
  EnhanceEyes.topBottom => [
    (x: 0, y: 0, width: width, height: height ~/ 2),
    (x: 0, y: height ~/ 2, width: width, height: height - height ~/ 2),
  ],
};

/// [part] of [partWidth] pixels across written into [target] ([width] across) with its top left corner at [x], [y]
void pasteRgbaAt(Uint8List target, int width, Uint8List part, int partWidth, int partHeight, int x, int y) {
  for (var row = 0; row < partHeight; row++) {
    target.setRange(4 * ((y + row) * width + x), 4 * ((y + row) * width + x + partWidth), part, 4 * row * partWidth);
  }
}

/// The pieces the model is given for a picture of [width] x [height] laid out as [layout]: their sizes, in the order
/// [enhanceLaidOut] gives them. For the time and the progress of a job.
List<({int width, int height})> enhancePiecesOf(
  int width,
  int height,
  EnhanceLayout layout, {
  EnhanceSphereCover cover = EnhanceSphereCover.whole,
}) => [
  for (final eye in eyeRects(width, height, layout.eyes))
    if (!layout.sphere)
      (width: eye.width, height: eye.height)
    else ...[
      (width: eye.width + (cover.wraps ? 2 * sphereSeamPad(eye.width) : 0), height: eye.height),
      if (cover.north) (width: poleFaceSize(eye.height), height: poleFaceSize(eye.height)),
      if (cover.south) (width: poleFaceSize(eye.height), height: poleFaceSize(eye.height)),
    ],
];

/// The pixels the model works on for a photo of [width] x [height] laid out as [layout]: those of the photo for a flat
/// or a 3D one, more for a 360° one (the seam and the faces of the poles)
int enhanceWorkPixels(int width, int height, EnhanceLayout layout) => [
  for (final piece in enhancePiecesOf(width, height, layout)) piece.width * piece.height,
].fold(0, (sum, pixels) => sum + pixels);

/// Runs a piece of pixel work, in an isolate for the engine, in place for the tests
typedef EnhanceCompute = Future<Uint8List> Function(Uint8List Function() work);

Future<Uint8List> _inPlace(Uint8List Function() work) async => work();

/// The model of a level run on one piece, its tiles told to [onStep] as done of all
typedef EnhancePieceRun = Future<Uint8List> Function(SbsDecoded piece, void Function(int done, int all) onStep);

/// [picture] enhanced by [run] as [layout] says (see the top of this file): each eye on its own, each picture of the
/// sphere with its seam wrapped and its poles on faces of a cube, as [cover] says. [onStep] is told the tiles done of
/// all the pieces, the count of those not started yet estimated from the pace of the first. The same size as
/// [picture], before the colour fix and the strength.
Future<Uint8List> enhanceLaidOut(
  SbsDecoded picture,
  EnhanceLayout layout,
  EnhancePieceRun run, {
  EnhanceSphereCover cover = EnhanceSphereCover.whole,
  void Function(int done, int all)? onStep,
  EnhanceCompute compute = _inPlace,
}) async {
  final width = picture.width;
  final height = picture.height;
  if (layout.isFlat) {
    return run(picture, (done, all) => onStep?.call(done, all));
  }
  final pieces = enhancePiecesOf(width, height, layout, cover: cover);
  final steps = _Steps([for (final piece in pieces) piece.width * piece.height], onStep);
  var index = 0;
  Future<Uint8List> runPiece(Uint8List rgba, int pieceWidth, int pieceHeight) {
    final at = index++;
    return run(
      SbsDecoded(width: pieceWidth, height: pieceHeight, rgba: rgba, iccProfile: picture.iccProfile),
      (done, all) => steps.tell(at, done, all),
    ).then((result) {
      steps.ended(at);
      return result;
    });
  }

  final source = picture.rgba;
  final result = Uint8List(source.length);
  for (final eye in eyeRects(width, height, layout.eyes)) {
    final eyeWidth = eye.width;
    final eyeHeight = eye.height;
    final x = eye.x;
    final y = eye.y;
    final rgba = layout.isStereo ? await compute(_crop(source, width, x, y, eyeWidth, eyeHeight)) : source;
    Uint8List done;
    if (!layout.sphere) {
      done = await runPiece(rgba, eyeWidth, eyeHeight);
    } else {
      done = await _enhanceSphere(rgba, eyeWidth, eyeHeight, cover, runPiece, compute);
    }
    if (!layout.isStereo) {
      return done;
    }
    pasteRgbaAt(result, width, done, eyeWidth, eyeHeight, x, y);
  }
  return result;
}

Future<Uint8List> _enhanceSphere(
  Uint8List rgba,
  int width,
  int height,
  EnhanceSphereCover cover,
  Future<Uint8List> Function(Uint8List rgba, int width, int height) runPiece,
  EnhanceCompute compute,
) async {
  Uint8List out;
  if (cover.wraps) {
    final pad = sphereSeamPad(width);
    final padded = await compute(_pad(rgba, width, height, pad));
    final enhanced = await runPiece(padded, width + 2 * pad, height);
    out = await compute(_unwrap(enhanced, width, height, pad));
  } else {
    out = await runPiece(rgba, width, height);
  }
  final size = poleFaceSize(height);
  for (final north in [true, false]) {
    if (north ? !cover.north : !cover.south) {
      continue;
    }
    final face = await compute(_face(rgba, width, height, size, north));
    final enhancedFace = await runPiece(face, size, size);
    out = await compute(_paste(out, width, height, enhancedFace, size, north));
  }
  return out;
}

// The pixel work handed to an isolate, each made by a function of its own so that it carries only its pictures, never
// the model, its cancel flag or the progress of the job
Uint8List Function() _crop(Uint8List rgba, int width, int x, int y, int toWidth, int toHeight) =>
    () => cropRgbaAt(rgba, width, x, y, toWidth, toHeight);

Uint8List Function() _pad(Uint8List rgba, int width, int height, int pad) =>
    () => wrapPad(rgba, width, height, pad);

Uint8List Function() _unwrap(Uint8List padded, int width, int height, int pad) =>
    () => unwrapSeam(padded, width, height, pad);

Uint8List Function() _face(Uint8List rgba, int width, int height, int size, bool north) =>
    () => poleFace(rgba, width, height, size, north: north);

Uint8List Function() _paste(Uint8List target, int width, int height, Uint8List face, int size, bool north) => () {
  pastePoleFace(target, width, height, face, size, north: north);
  return target;
};

/// The tiles done of all the pieces of a picture: the count of a piece known once its model tells it, that of the
/// pieces not started estimated from it by their pixels
class _Steps {
  _Steps(this._pixels, this._onStep) : _all = List<int?>.filled(_pixels.length, null);

  final List<int> _pixels;
  final void Function(int done, int all)? _onStep;
  final List<int?> _all;
  var _before = 0;
  double? _perPixel;

  void tell(int index, int done, int all) {
    _all[index] = all;
    if (all > 0 && _perPixel == null) {
      _perPixel = all / _pixels[index];
    }
    final rate = _perPixel ?? 0;
    var total = _before;
    for (var i = index; i < _pixels.length; i++) {
      total += _all[i] ?? math.max(1, (_pixels[i] * rate).round());
    }
    _onStep?.call(_before + done, math.max(total, _before + done));
  }

  void ended(int index) => _before += _all[index] ?? 0;
}

/// The window at the head of a file, and at its tail, where its GPano tags are looked for (that of the viewers)
const _gpanoWindow = 131072;

final _gpanoValue = RegExp(r'^[A-Za-z0-9.+-]+$');

/// The GPano tags of the photo [bytes], written as attributes (GPano:Name="value", as cameras do) or as elements, in
/// its head, else its tail: those of enhanceGPanoNames whose value can be written again as it is (letters, digits,
/// dots, signs; a software name with spaces is left out). Empty when it has none.
List<(String, String)> gpanoTagsOfFile(Uint8List bytes) {
  for (final window in [
    bytes.sublist(0, math.min(bytes.length, _gpanoWindow)),
    if (bytes.length > _gpanoWindow) bytes.sublist(bytes.length - _gpanoWindow),
  ]) {
    final text = String.fromCharCodes(window);
    if (!text.contains('GPano')) {
      continue;
    }
    final tags = <(String, String)>[];
    for (final name in enhanceGPanoNames) {
      final match = RegExp(
        '(?:GPano:$name\\s*=\\s*["\']([^"\']*)["\']|<GPano:$name>\\s*([^<]*?)\\s*</GPano:$name>)',
      ).firstMatch(text);
      final value = match == null ? null : (match.group(1) ?? match.group(2))!.trim();
      if (value != null && _gpanoValue.hasMatch(value)) {
        tags.add((name, value));
      }
    }
    if (tags.isNotEmpty) {
      return tags;
    }
  }
  return const [];
}

/// The part of the sphere [tags] (see [gpanoTagsOfFile]) say the picture covers: the whole sphere without a crop
EnhanceSphereCover sphereCoverOfTags(List<(String, String)> tags) {
  double? tag(String name) => double.tryParse(tags.where((tag) => tag.$1 == name).firstOrNull?.$2 ?? '');
  final fullWidth = tag('FullPanoWidthPixels');
  final fullHeight = tag('FullPanoHeightPixels');
  final left = tag('CroppedAreaLeftPixels');
  final top = tag('CroppedAreaTopPixels');
  final width = tag('CroppedAreaImageWidthPixels');
  final height = tag('CroppedAreaImageHeightPixels');
  if (fullWidth == null || fullHeight == null || fullWidth <= 0 || fullHeight <= 0) {
    return EnhanceSphereCover.whole;
  }
  return EnhanceSphereCover.ofCrop(
    left: left == null ? null : left / fullWidth,
    top: top == null ? null : top / fullHeight,
    width: width == null ? null : width / fullWidth,
    height: height == null ? null : height / fullHeight,
  );
}
