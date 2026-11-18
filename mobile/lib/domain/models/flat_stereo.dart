// Flat 3D media: a photo or a video for a screen, not for a sphere, that holds one image per eye side by side or one
// above the other. Nothing the server indexes tells them apart from regular media, so the immersive viewer of the Meta
// Quest goes by the words of the file name, as 3D players and converters write them, and shows them on a flat screen
// in front of the user: a video on the flat video screen, a photo of two eyes one above the other on the stereo quad
// (see stackedPhotoFormatOf). The viewer gets them as the flat3d JSON (see Flat3dRequest).

import 'dart:convert';

import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';

/// How a flat 3D media packs its eyes, with the name the immersive viewer reads ([wire])
enum FlatStereoFormat {
  /// Side by side, each eye with the aspect of half the frame (3840x1080 for two 16:9 eyes)
  sbs('sbs'),

  /// Side by side, each eye squeezed to half its width (1920x1080 for two 16:9 eyes)
  halfSbs('halfSbs'),

  /// One above the other, left eye on top, each eye with the aspect of half the frame
  tb('tb'),

  /// One above the other, each eye squeezed to half its height
  halfTb('halfTb');

  const FlatStereoFormat(this.wire);

  /// The value of "format" in the flat3d JSON (see [Flat3dRequest])
  final String wire;

  /// One eye above the other
  bool get isStacked => this == tb || this == halfTb;

  /// The format of [wire], null for a value this build does not know
  static FlatStereoFormat? fromWire(Object? wire) {
    for (final format in values) {
      if (format.wire == wire) {
        return format;
      }
    }
    return null;
  }
}

// The words of the file names, split on dots, underscores, dashes and spaces. "Half-SBS" splits into two words, of
// which "half" squeezes the eyes of the other one, and so does "h" right before it ("H-OU").
const _sideBySideWords = {'sbs', 'fsbs', 'fullsbs', 'lr', '3dsbs', 'sidebyside', '3dh'};
const _halfSideBySideWords = {'hsbs', 'halfsbs'};
const _topBottomWords = {'tb', 'ou', 'fou', 'ftb', 'tab', 'overunder', 'topbottom', '3dou', '3dv'};
const _halfTopBottomWords = {'htb', 'hou', 'htab', 'halfou', 'halftb'};
const _packingWords = {..._sideBySideWords, ..._halfSideBySideWords, ..._topBottomWords, ..._halfTopBottomWords};

// Short words that are everyday words or tags of their own too: "ou" is "or" in French and Portuguese, "tab" a tab,
// "TB" a terabyte, "LR" a low resolution proxy. They count as 3D words only at the end of a name of several words
// (street_TB, movie OU) or next to a 3D word (Movie.3D.OU.Remux, Full-OU, H-TB); "Paris ou Lyon.mp4" and
// "Screen recording tab 2.mp4" stay regular media.
const _shortWords = {'ou', 'tab', 'tb', 'lr'};

// "fou" ends French names ("Le fou.jpg", "Un vent fou.mp4"): it counts only next to a 3D word (Movie.3D.FOU)
const _wordsNextToStereoOnly = {'fou'};

// The words next to which a short word is a 3D word
const _stereoContextWords = {'3d', 'half', 'full', 'h'};

// Words of 360° and VR180 media, which the viewer shows on a sphere whatever their 3D words say
const _sphereWords = {'360', '180', 'vr', 'vr180', 'vr360', '180x180', '360x180', 'equirect', 'equirectangular'};

final _wordSeparators = RegExp(r'[._\- ]+');

/// Guesses how a flat 3D photo or video named [fileName] packs its eyes, null for a regular media or a 360° one:
/// - hsbs, halfsbs, or half with sbs, for squeezed eyes side by side; htb, hou, halfou, or half with tb or ou, for
///   squeezed eyes stacked; h right before such a word squeezes them too (H-SBS, H-OU);
/// - sbs, lr, 3dh, ... for full eyes side by side; tb, ou, tab, 3dv, ... for full eyes stacked. Many videos say sbs or
///   ou for squeezed eyes as well: for a video of [width] x [height], eyes narrower than square side by side
///   (1920x1080) or wider than 2.5:1 stacked (1920x1080) are taken as squeezed. Photos keep their eyes as they are:
///   a converter writes the squeezed ones with a word of their own, and two portrait photos side by side are common.
///
/// An explicit full word (fsbs, fullsbs, or full next to a side by side word: _3D_LRF_Full_SBS) keeps two full eyes
/// side by side whatever the frame: the 3D video a computer makes of a portrait phone clip is 2160 x 1920, eyes
/// narrower than square that the squeeze rule would stretch to twice their width. [declaredSideBySide] is for a caller
/// that read the file's st3d box saying left and right: a name that says nothing of 3D then gets two full eyes side by
/// side too (the words win over the box when there are some).
///
/// The short words ou, tab, tb and lr count at the end of a name of several words or next to 3d, half, full or h, and
/// fou only next to one of those: "Paris ou Lyon.jpg" and "Le fou.jpg" are regular photos. The words of 360° and VR180
/// media (360, 180, vr, vr180, ...) make it no flat media at all.
FlatStereoFormat? guessFlatStereoFormat({
  required String? fileName,
  int? width,
  int? height,
  bool isVideo = false,
  bool declaredSideBySide = false,
}) {
  if (fileName == null || fileName.isEmpty) {
    return null;
  }
  final parts = _nameParts(fileName);
  final words = {
    for (final (index, word) in parts.indexed)
      if (_countsAsStereoWord(parts, index)) word,
  };
  if (words.any(_sphereWords.contains)) {
    return null;
  }
  // "Half-SBS", "H-OU": squeezed eyes
  var half = words.contains('half');
  for (var i = 0; i + 1 < parts.length && !half; i++) {
    half = parts[i] == 'h' && _packingWords.contains(parts[i + 1]);
  }
  if (words.any(_halfSideBySideWords.contains)) {
    return FlatStereoFormat.halfSbs;
  }
  if (words.any(_halfTopBottomWords.contains)) {
    return FlatStereoFormat.halfTb;
  }
  final known = width != null && height != null && width > 0 && height > 0;
  if (words.any(_sideBySideWords.contains)) {
    final squeezed = half || (isVideo && known && !_saysFull(parts) && width / 2 / height < 1.0);
    return squeezed ? FlatStereoFormat.halfSbs : FlatStereoFormat.sbs;
  }
  if (words.any(_topBottomWords.contains)) {
    final squeezed = half || (isVideo && known && width / (height / 2) > 2.5);
    return squeezed ? FlatStereoFormat.halfTb : FlatStereoFormat.tb;
  }
  return declaredSideBySide ? FlatStereoFormat.sbs : null;
}

/// Whether the name [fileName] says two full eyes side by side in so many words: fsbs, fullsbs, or full right before
/// or after a side by side word (_3D_LRF_Full_SBS, SBS.Full); never with half or for stacked eyes
bool flatStereoFullSaid(String? fileName) {
  if (fileName == null || fileName.isEmpty) {
    return false;
  }
  final parts = _nameParts(fileName);
  return !parts.contains('half') && _saysFull(parts);
}

bool _saysFull(List<String> parts) {
  for (final (index, word) in parts.indexed) {
    if (word == 'fsbs' || word == 'fullsbs') {
      return true;
    }
    if (word == 'full') {
      final before = index > 0 && _sideBySideWords.contains(parts[index - 1]);
      final after = index + 1 < parts.length && _sideBySideWords.contains(parts[index + 1]);
      if (before || after) {
        return true;
      }
    }
  }
  return false;
}

/// The words of [fileName] without its extension, in lower case
List<String> _nameParts(String fileName) {
  final dot = fileName.lastIndexOf('.');
  final stem = dot > 0 ? fileName.substring(0, dot) : fileName;
  return stem.toLowerCase().split(_wordSeparators).where((word) => word.isNotEmpty).toList();
}

/// Whether the word at [index] of the words of a name, [parts], counts: any word but the short ones, which count at
/// the end of a name of several words or next to a 3D word ("fou" only next to a 3D word)
bool _countsAsStereoWord(List<String> parts, int index) {
  final word = parts[index];
  final short = _shortWords.contains(word);
  if (!short && !_wordsNextToStereoOnly.contains(word)) {
    return true;
  }
  final nextToStereo =
      (index > 0 && _stereoContextWords.contains(parts[index - 1])) ||
      (index + 1 < parts.length && _stereoContextWords.contains(parts[index + 1]));
  return nextToStereo || (short && index > 0 && index == parts.length - 1);
}

/// [guessFlatStereoFormat] for [asset], null for anything but a photo or a video
FlatStereoFormat? flatStereoFormatOf(BaseAsset asset) => asset.isImage || asset.isVideo
    ? guessFlatStereoFormat(fileName: asset.name, width: asset.width, height: asset.height, isVideo: asset.isVideo)
    : null;

/// [guessFlatStereoFormat] for [asset] when it is a video, null for anything else: what puts a video on the flat video
/// screen of the immersive viewer
FlatStereoFormat? flatStereoVideoFormatOf(BaseAsset asset) => asset.isVideo ? flatStereoFormatOf(asset) : null;

/// The packing of a photo named [name] that the file name puts on the stereo quad: two eyes one above the other (tb,
/// ou, htb, Half-OU, 3dv...). A photo whose name says its eyes are side by side keeps the rule of the stereo photo
/// probe (decideStereoPhoto, which reads our XMP first, then the name and the frame, and serves the computers too): the
/// 3D photos a computer makes (_3D_LRF_Full_SBS) and the side by side files of other tools go on the quad as before.
/// Null for any other photo, and for a 360° or VR180 name.
FlatStereoFormat? stackedPhotoFormatOf(String name) {
  final format = guessFlatStereoFormat(fileName: name);
  return format != null && format.isStacked ? format : null;
}

/// The kind and the version of the flat3d JSON, see [Flat3dRequest]
const flat3dKind = 'flat3d';
const flat3dVersion = 1;

/// What the immersive viewer of the Meta Quest is asked for a flat 3D media told by its file name: the flat3d JSON of
/// the stereoPair parameter of ImmersiveApi.open (FlatStereoSpec on the side of the viewer), frozen in
/// test/fixtures/ai_immersive/flat3d_contract_v1.json. A photo goes on the stereo quad, a video on the flat video
/// screen in front of the user. A viewer that does not know the request shows the photo flat, and the video on the
/// sphere.
///
/// [fullSaid] (written as "full": true, side by side only) tells the viewer that the name or the st3d box said two full
/// eyes, which it then keeps whatever the frame: without it, the viewer squeezes eyes narrower than square as
/// guessFlatStereoFormat does once the frame size is known. A viewer that does not know the key squeezes them as before.
class Flat3dRequest {
  const Flat3dRequest(this.format, {bool fullSaid = false}) : fullSaid = fullSaid && format == FlatStereoFormat.sbs;

  /// The request for a video named [fileName] packed as [format]: full said by its words (see [flatStereoFullSaid]),
  /// or by its st3d box ([declaredSideBySide]) when the name says nothing of 3D
  factory Flat3dRequest.ofName(FlatStereoFormat format, String? fileName, {bool declaredSideBySide = false}) {
    final silent = guessFlatStereoFormat(fileName: fileName) == null;
    return Flat3dRequest(format, fullSaid: flatStereoFullSaid(fileName) || (declaredSideBySide && silent));
  }

  /// How the frame packs the eyes
  final FlatStereoFormat format;

  /// Whether the eyes are full by the name or the file's box, see the class
  final bool fullSaid;

  Map<String, Object> toJson() => {
    'kind': flat3dKind,
    'version': flat3dVersion,
    'format': format.wire,
    if (fullSaid) 'full': true,
  };

  /// The stereoPair JSON of ImmersiveApi.open
  String toJsonString() => jsonEncode(toJson());

  /// The request [json] holds, null for another kind or version or a format this build does not know
  static Flat3dRequest? fromJson(Object? json) {
    if (json is! Map || json['kind'] != flat3dKind || json['version'] != flat3dVersion) {
      return null;
    }
    final format = FlatStereoFormat.fromWire(json['format']);
    return format == null ? null : Flat3dRequest(format, fullSaid: json['full'] == true);
  }

  @override
  bool operator ==(Object other) => other is Flat3dRequest && other.format == format && other.fullSaid == fullSaid;

  @override
  int get hashCode => Object.hash(format, fullSaid);

  @override
  String toString() => 'Flat3dRequest(${format.wire}${fullSaid ? ', full' : ''})';
}
