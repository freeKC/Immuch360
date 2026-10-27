// Tells a flat photo that holds two eyes side by side, made by Immuch360 from a 2D photo or by another tool, without
// touching the rules of the 360°, VR180 and Apple spatial media (design-final 2026-10-26, section 4.1). In this order:
//  1. Our XMP (Immuch360:Kind="StereoPhoto", see StereoPhotoXmp), looked for in the head of the file, the window the
//     GPano tags are read in (see readGPanoTags). It decides, whatever the name and the frame. A file of a newer
//     FormatVersion is shown flat, "made by a newer version".
//  2. Without it, a photo the 360° rules take (an equirectangular GPano, or a 360° camera's own equirect photo) stays
//     theirs. Else the words of the name that the Spatial 2.5D player reads (sbs, lr, rl..., see guessSpatialLayout)
//     or that iw3 writes (_LRF_Full_SBS, _LR, _RLF_cross), with a frame that fits: full width eyes when the name says
//     so (then however wide) or when the frame is 2.2 to 4.0 times as wide as high, half width eyes otherwise. The
//     frame alone never decides: a flat 3:1 panorama stays flat.
//  3. Else a flat photo.
//
// A photo of the library is read only when its name or its frame makes it a candidate (see isStereoPhotoCandidate):
// an ordinary photo costs no read. The photos of the shares are read for their GPano tags anyway: their head is looked
// at again, not read again (see NetworkMediaService).
//
// Shared by the computers and the Meta Quest. The rules are pure Dart; FlatStereoService reads the assets.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_pair_requests.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/spatial_media.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:logging/logging.dart';

final _log = Logger('StereoPhotoProbe');

/// A flat photo holding two eyes side by side, as the probe told it
class FlatStereoPhoto {
  const FlatStereoPhoto({required this.eyes, this.eyeOrder = EyeOrder.leftRight, this.xmp});

  /// Full width eyes (the frame is twice as wide as one eye) or half width ones (both squeezed into the width of one)
  final StereoEyes eyes;

  /// Which eye is on the left half of the frame
  final EyeOrder eyeOrder;

  /// Our XMP when the file carries it, which then decided; null for another tool's file, told by its name
  final StereoPhotoXmp? xmp;

  /// Made by Immuch360
  bool get isOurs => xmp != null;

  /// Made by a newer version of the format: shown flat, "made by a newer version"
  bool get isNewerFormat => xmp?.isNewerFormat ?? false;

  /// Whether this build shows it in 3D
  bool get canShowIn3d => !isNewerFormat;

  /// Its relief was estimated by AI from one photo: the honesty label goes with it
  bool get isEstimatedRelief => xmp?.isEstimatedRelief ?? false;

  /// Where its content comes from, unknown for another tool's file
  ImmersiveOrigin get origin => xmp?.origin ?? ImmersiveOrigin.unknown;

  /// What its left eye is, unknown for another tool's file
  LeftEyeSource get leftEye => xmp?.leftEye ?? LeftEyeSource.unknown;

  /// What the immersive viewer of the Meta Quest is asked for (the stereoPair JSON), null when it is shown flat
  SbsPhotoRequest? get request =>
      canShowIn3d ? SbsPhotoRequest(layout: eyeOrder, eyes: eyes, origin: origin, leftEye: leftEye) : null;

  @override
  bool operator ==(Object other) =>
      other is FlatStereoPhoto && other.eyes == eyes && other.eyeOrder == eyeOrder && other.xmp == xmp;

  @override
  int get hashCode => Object.hash(eyes, eyeOrder, xmp);

  @override
  String toString() => 'FlatStereoPhoto(${eyes.json}, ${eyeOrder.json}, ${xmp ?? 'by its name'})';
}

// The frames of full width eyes when the name does not tell the width: two landscape eyes, 1.1:1 to 2:1 each
const _fullFrameMin = 2.2;
const _fullFrameMax = 4.0;

// The shapes an eye may have once shown, from a tall 2:5 to a wide 2.2:1; other frames do not hold two photos. A name
// that says full width eyes is trusted for wider ones (a 21:9 photo, a flat panorama made 3D by iw3): only the floor
// applies to it
const _eyeRatioMin = 0.4;
const _eyeRatioMax = 2.2;

// The words iw3 writes besides those of the Spatial 2.5D player: "_LRF_Full_SBS" (full width eyes, its default), "_LR"
// (half width, already a word of the player) and "_RLF_cross" (full width, the right eye first, for crossed eyes).
// See FULL_SBS_SUFFIX and the others in https://github.com/nagadomi/nunif/blob/master/iw3/utils.py
const _fullLeftRightWords = {'lrf'};
const _fullRightLeftWords = {'rlf'};

// The words that tell the width of the eyes; with none of them the frame tells. "full" and "half" alone are words of
// titles too ("Avatar Full HD SBS", "Half Dome_sbs"): they tell the width next to "sbs" only ("_LRF_Full_SBS",
// "3D-Half-SBS", "SBS_Full")
const _fullWidthWords = {'fsbs', 'fullsbs', 'lrf', 'rlf'};
const _halfWidthWords = {'hsbs', 'halfsbs'};

// Split as guessSpatialLayout splits a name: on dots, underscores, dashes and spaces, in any case
List<String> _wordListOf(String name) => name.toLowerCase().split(RegExp(r'[._\- ]+'));

Set<String> _wordsOf(String name) => _wordListOf(name).toSet();

/// Whether [words] say a width: one of [widthWords], or [plain] ("full", "half") next to "sbs"
bool _saysWidth(List<String> words, Set<String> widthWords, String plain) {
  for (var at = 0; at < words.length; at++) {
    if (widthWords.contains(words[at])) {
      return true;
    }
    if (words[at] == plain &&
        ((at > 0 && words[at - 1] == 'sbs') || (at + 1 < words.length && words[at + 1] == 'sbs'))) {
      return true;
    }
  }
  return false;
}

/// Which eye comes first in a photo named [name] when its name marks two eyes side by side, null when it does not: the
/// words of the Spatial 2.5D player (sbs, lr, fullsbs... and rl for the right eye first, see guessSpatialLayout) and
/// those of iw3 (lrf, and rlf for the right eye first)
EyeOrder? sideBySideOrderOfName(String name) {
  switch (guessSpatialLayout(fileName: name)) {
    case SpatialStereoLayout.sideBySide:
      return EyeOrder.leftRight;
    case SpatialStereoLayout.sideBySideSwapped:
      return EyeOrder.rightLeft;
    default:
      break;
  }
  final words = _wordsOf(name);
  if (words.any(_fullLeftRightWords.contains)) {
    return EyeOrder.leftRight;
  }
  if (words.any(_fullRightLeftWords.contains)) {
    return EyeOrder.rightLeft;
  }
  return null;
}

double? _ratioOf(int? width, int? height) =>
    width == null || height == null || width <= 0 || height <= 0 ? null : width / height;

/// Whether a photo named [name], of [width] x [height] pixels when known, may hold two eyes side by side, so that its
/// head is worth reading: its name marks two eyes side by side (see [sideBySideOrderOfName]), or its frame is 2.2 to
/// 4.0 times as wide as high (two landscape eyes), or 2:1 within 2 percent (two square eyes, a drone's square photo
/// made 3D). Our files always hold full width eyes: one of ours renamed without those words is still read when its
/// eyes are landscape or square, not when they are portrait.
bool isStereoPhotoCandidate({required String name, int? width, int? height}) {
  if (sideBySideOrderOfName(name) != null) {
    return true;
  }
  final ratio = _ratioOf(width, height);
  return ratio != null && ((ratio >= _fullFrameMin && ratio <= _fullFrameMax) || (ratio / 2 - 1).abs() <= 0.02);
}

/// What a photo is, from what its head told: our XMP ([xmp], see StereoPhotoXmp.findIn), whether the 360° rules take
/// it ([isSphere]: an equirectangular GPano, or the equirect photo of a 360° camera), its [name], and its frame of
/// [width] x [height] pixels as stored. Null for a flat photo. See the order at the top of this file.
FlatStereoPhoto? decideStereoPhoto({
  required String name,
  int? width,
  int? height,
  StereoPhotoXmp? xmp,
  bool isSphere = false,
}) {
  if (xmp != null) {
    final kind = xmp.kind;
    // A kind this build does not know, of a newer format, is still ours: shown flat with the reason
    if (kind == ImmersiveKind.stereoPhoto || (kind == null && xmp.isNewerFormat)) {
      return FlatStereoPhoto(eyes: xmp.eyes ?? StereoEyes.full, eyeOrder: xmp.eyeOrder ?? EyeOrder.leftRight, xmp: xmp);
    }
    // Another kind of ours (a 360° panorama, later) is no flat 3D photo, whatever its name
    return null;
  }
  if (isSphere) {
    return null;
  }
  final order = sideBySideOrderOfName(name);
  final ratio = _ratioOf(width, height);
  if (order == null || ratio == null) {
    return null;
  }
  // Two square eyes under a VR180 name are two halves of a sphere (iw3 names them "_180x180_LR"): the 360° viewers
  // show them once the user picks "View as 360°"
  if ((ratio / 2 - 1).abs() <= 0.1 &&
      guessSphereCoverage(fileName: name, width: null, height: null) == SphereCoverage.half) {
    return null;
  }
  final words = _wordListOf(name);
  final namedFull = _saysWidth(words, _fullWidthWords, 'full');
  final StereoEyes eyes;
  if (namedFull) {
    eyes = StereoEyes.full;
  } else if (_saysWidth(words, _halfWidthWords, 'half')) {
    eyes = StereoEyes.half;
  } else {
    eyes = ratio >= _fullFrameMin && ratio <= _fullFrameMax ? StereoEyes.full : StereoEyes.half;
  }
  // A half width eye is shown twice as wide as it is stored
  final eyeRatio = eyes == StereoEyes.full ? ratio / 2 : ratio;
  if (eyeRatio < _eyeRatioMin || (eyeRatio > _eyeRatioMax && !namedFull)) {
    return null;
  }
  return FlatStereoPhoto(eyes: eyes, eyeOrder: order);
}

/// Whether [head] holds the Immuch360 XMP namespace, a quick look before the packet is parsed
bool holdsImmuch360Xmp(Uint8List head) {
  const needle = immuch360XmpNamespace;
  final first = needle.codeUnitAt(0);
  final last = head.length - needle.length;
  for (var at = 0; at <= last; at++) {
    if (head[at] != first) {
      continue;
    }
    var i = 1;
    while (i < needle.length && head[at + i] == needle.codeUnitAt(i)) {
      i++;
    }
    if (i == needle.length) {
      return true;
    }
  }
  return false;
}

/// The size of the picture of a JPEG (its SOFn segment), a PNG (IHDR) or a WebP (VP8X, VP8 or VP8L), read from the head
/// of its file: the frame as stored, before any EXIF orientation. Null for another format or a head too short.
({int width, int height})? frameOfHead(Uint8List head) => _jpegFrame(head) ?? _pngFrame(head) ?? _webpFrame(head);

int _u16be(Uint8List bytes, int at) => bytes[at] << 8 | bytes[at + 1];

int _u32be(Uint8List bytes, int at) => _u16be(bytes, at) << 16 | _u16be(bytes, at + 2);

int _u16le(Uint8List bytes, int at) => bytes[at] | bytes[at + 1] << 8;

int _u24le(Uint8List bytes, int at) => _u16le(bytes, at) | bytes[at + 2] << 16;

bool _isAscii(Uint8List bytes, int at, String text) {
  if (at + text.length > bytes.length) {
    return false;
  }
  for (var i = 0; i < text.length; i++) {
    if (bytes[at + i] != text.codeUnitAt(i)) {
      return false;
    }
  }
  return true;
}

({int width, int height})? _jpegFrame(Uint8List head) {
  if (head.length < 4 || head[0] != 0xff || head[1] != 0xd8) {
    return null;
  }
  var at = 2;
  while (at + 4 <= head.length) {
    if (head[at] != 0xff) {
      return null;
    }
    final marker = head[at + 1];
    if (marker == 0xff) {
      // Fill byte before a marker
      at++;
      continue;
    }
    if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd8)) {
      at += 2;
      continue;
    }
    if (marker == 0xda || marker == 0xd9) {
      // The image data or its end, and no frame before it
      return null;
    }
    final isFrame = marker >= 0xc0 && marker <= 0xcf && marker != 0xc4 && marker != 0xc8 && marker != 0xcc;
    if (isFrame) {
      if (at + 9 > head.length) {
        return null;
      }
      final height = _u16be(head, at + 5);
      final width = _u16be(head, at + 7);
      return width > 0 && height > 0 ? (width: width, height: height) : null;
    }
    at += 2 + _u16be(head, at + 2);
  }
  return null;
}

const _pngSignature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

({int width, int height})? _pngFrame(Uint8List head) {
  if (head.length < 24 || !_isAscii(head, 12, 'IHDR')) {
    return null;
  }
  for (var i = 0; i < _pngSignature.length; i++) {
    if (head[i] != _pngSignature[i]) {
      return null;
    }
  }
  final width = _u32be(head, 16);
  final height = _u32be(head, 20);
  return width > 0 && height > 0 ? (width: width, height: height) : null;
}

({int width, int height})? _webpFrame(Uint8List head) {
  if (!_isAscii(head, 0, 'RIFF') || !_isAscii(head, 8, 'WEBP')) {
    return null;
  }
  // The canvas of an extended file, its 24 bit width and height less one
  if (_isAscii(head, 12, 'VP8X') && head.length >= 30) {
    return (width: _u24le(head, 24) + 1, height: _u24le(head, 27) + 1);
  }
  // A lossy file: the frame tag, the start code 9D 01 2A, then the width and the height on 14 bits each
  if (_isAscii(head, 12, 'VP8 ') && head.length >= 30) {
    if (head[23] != 0x9d || head[24] != 0x01 || head[25] != 0x2a) {
      return null;
    }
    return (width: _u16le(head, 26) & 0x3fff, height: _u16le(head, 28) & 0x3fff);
  }
  // A lossless file: the signature 2F, then the width and the height less one on 14 bits each
  if (_isAscii(head, 12, 'VP8L') && head.length >= 25 && head[20] == 0x2f) {
    final bits = head[21] | head[22] << 8 | head[23] << 16 | head[24] << 24;
    return (width: (bits & 0x3fff) + 1, height: (bits >> 14 & 0x3fff) + 1);
  }
  return null;
}

/// What the [head] of a photo named [name] tells (see [decideStereoPhoto]): our XMP when it holds it, and its frame,
/// read in the head (see [frameOfHead]), else [width] x [height]. [isSphere] when the 360° rules take the file.
FlatStereoPhoto? probeStereoPhotoHead(
  Uint8List head, {
  required String name,
  int? width,
  int? height,
  bool isSphere = false,
}) {
  final xmp = holdsImmuch360Xmp(head) ? StereoPhotoXmp.findIn(head) : null;
  final frame = frameOfHead(head);
  return decideStereoPhoto(
    name: name,
    width: frame?.width ?? width,
    height: frame?.height ?? height,
    xmp: xmp,
    isSphere: isSphere,
  );
}

/// Tells whether the photo named [name], of [width] x [height] pixels when known, holds two eyes side by side (see
/// [decideStereoPhoto]), reading its head through [read] the way its GPano tags are read (see readGPanoTags): one
/// window at its start. Nothing is read when it is no candidate (see [isStereoPhotoCandidate]). Errors of [read] are
/// not caught.
Future<FlatStereoPhoto?> probeStereoPhoto(ByteRangeReader read, {required String name, int? width, int? height}) async {
  if (!isStereoPhotoCandidate(name: name, width: width, height: height)) {
    return null;
  }
  var head = Uint8List(0);
  final gpano = await readGPanoTags((offset, length) async {
    final bytes = await read(offset, length);
    if (offset == 0) {
      head = bytes;
    }
    return bytes;
  }, 0);
  return probeStereoPhotoHead(
    head,
    name: name,
    width: width,
    height: height,
    isSphere: gpano != null && isEquirectangularGPano(gpano),
  );
}

/// Key of [asset] in the results of [FlatStereoService]: its id on the server and its checksum, which change together
/// with the file, else its id on the device and the time it last changed
String flatStereoKey(BaseAsset asset) {
  final remoteId = asset.remoteId;
  if (remoteId != null) {
    return 'r:$remoteId:${asset.checksum ?? ''}';
  }
  return 'l:${asset.localId ?? asset.id}:${asset.updatedAt.millisecondsSinceEpoch}';
}

/// Tells which photos of the library hold two eyes side by side (see [detect]). What it found lasts as long as the
/// app, in memory: a candidate costs one read of its head per session.
class FlatStereoService {
  FlatStereoService({
    required this._localFile,
    required this._serverReader,
    this.maxEntries = 2000,
    this.timeout = const Duration(seconds: 15),
  });

  /// The copy on the device of the asset with this local id, null when there is none
  final Future<File?> Function(String localId) _localFile;

  /// Reads the original on the server of the asset with this remote id, null without a server
  final ByteRangeReader? Function(String remoteId) _serverReader;

  /// Past this many photos, the ones read first are forgotten
  final int maxEntries;

  /// Longest wait for the head of a photo
  final Duration timeout;

  // What was found per photo (see flatStereoKey), the latest last, flat photos included
  final _results = <String, FlatStereoPhoto?>{};
  final _pending = <String, Future<FlatStereoPhoto?>>{};

  /// Whether [asset] may hold two eyes side by side, so that its file is read: a photo whose name or frame makes it a
  /// candidate (see [isStereoPhotoCandidate])
  static bool isCandidate(BaseAsset asset) =>
      asset.isImage && isStereoPhotoCandidate(name: asset.name, width: asset.width, height: asset.height);

  /// What an earlier [detect] found for [asset], without reading anything: null when it is flat or unknown
  FlatStereoPhoto? cached(BaseAsset asset) => _results[flatStereoKey(asset)];

  /// What makes [asset] a photo of two eyes side by side, null when it is none or when its file could not be read (it
  /// is read again next time). Read from its copy on the device when there is one, else from the original on the
  /// server, its head only. Never throws.
  Future<FlatStereoPhoto?> detect(BaseAsset asset) async {
    if (!isCandidate(asset)) {
      return null;
    }
    final key = flatStereoKey(asset);
    if (_results.containsKey(key)) {
      return _results[key];
    }
    final pending = _pending[key] ??= _read(asset, key);
    try {
      return await pending;
    } finally {
      unawaited(_pending.remove(key));
    }
  }

  Future<FlatStereoPhoto?> _read(BaseAsset asset, String key) async {
    try {
      final read = await _readPhoto(asset);
      if (read == null) {
        return null;
      }
      final found = read.$1;
      if (found != null) {
        _log.info('${asset.name} holds two eyes side by side: $found');
      }
      _remember(key, found);
      return found;
    } catch (error, stackTrace) {
      _log.warning('Could not tell whether ${asset.name} holds two eyes side by side', error, stackTrace);
      return null;
    }
  }

  // In a record so that "read, flat" and "could not read" (null) stay apart
  Future<(FlatStereoPhoto?,)?> _readPhoto(BaseAsset asset) async {
    final localId = asset.localId;
    if (localId != null) {
      File? file;
      try {
        file = await _localFile(localId);
      } catch (error) {
        _log.fine('Copy on the device of ${asset.name} not found: $error');
      }
      if (file != null) {
        try {
          return (await _probeFile(file, asset),);
        } catch (error) {
          _log.fine('Copy on the device of ${asset.name} unreadable, reading the server copy: $error');
        }
      }
    }
    final remoteId = asset.remoteId;
    final read = remoteId == null ? null : _serverReader(remoteId);
    if (read == null) {
      return null;
    }
    try {
      return (
        await probeStereoPhoto(read, name: asset.name, width: asset.width, height: asset.height).timeout(timeout),
      );
    } catch (error) {
      _log.info('Could not read the head of ${asset.name} on the server: $error');
      return null;
    }
  }

  Future<FlatStereoPhoto?> _probeFile(File file, BaseAsset asset) async {
    final handle = await file.open();
    try {
      return await probeStereoPhoto(
        (offset, length) async {
          await handle.setPosition(offset);
          return handle.read(length);
        },
        name: asset.name,
        width: asset.width,
        height: asset.height,
      ).timeout(timeout);
    } finally {
      await handle.close();
    }
  }

  void _remember(String key, FlatStereoPhoto? found) {
    // Removed first, so that the photo goes last, as the latest
    _results
      ..remove(key)
      ..[key] = found;
    while (_results.length > maxEntries) {
      _results.remove(_results.keys.first);
    }
  }
}
