// Flat 3D media: a photo or a video for a screen, not for a sphere, that holds one image per eye side by side or one
// above the other. Nothing the server indexes tells them apart from regular media, so the immersive viewer of the Meta
// Quest goes by the words of the file name, as 3D players and converters write them, and shows them on a flat screen
// in front of the user.

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

  /// The value of the flatFormat parameter of the immersive viewer
  final String wire;
}

// The words of the file names, split on dots, underscores, dashes and spaces. "Half-SBS" splits into two words, of
// which "half" squeezes the eyes of the other one.
const _sideBySideWords = {'sbs', 'fsbs', 'fullsbs', 'lr', '3dsbs', 'sidebyside', '3dh'};
const _halfSideBySideWords = {'hsbs', 'halfsbs'};
const _topBottomWords = {'tb', 'ou', 'fou', 'ftb', 'tab', 'overunder', 'topbottom', '3dou', '3dv'};
const _halfTopBottomWords = {'htb', 'hou', 'htab', 'halfou', 'halftb'};

// Words of 360° and VR180 media, which the viewer shows on a sphere whatever their 3D words say
const _sphereWords = {'360', '180', 'vr', 'vr180', 'vr360', '180x180', '360x180', 'equirect', 'equirectangular'};

final _wordSeparators = RegExp(r'[._\- ]+');

/// Guesses how a flat 3D photo or video named [fileName] packs its eyes, null for a regular media or a 360° one:
/// - hsbs, halfsbs, or half with sbs, for squeezed eyes side by side; htb, hou, halfou, or half with tb or ou, for
///   squeezed eyes stacked;
/// - sbs, lr, 3dh, ... for full eyes side by side; tb, ou, tab, 3dv, ... for full eyes stacked. Many videos say sbs or
///   ou for squeezed eyes as well: for a video of [width] x [height], eyes narrower than square side by side
///   (1920x1080) or wider than 2.5:1 stacked (1920x1080) are taken as squeezed. Photos keep their eyes as they are:
///   a converter writes the squeezed ones with a word of their own, and two portrait photos side by side are common.
///
/// The words of 360° and VR180 media (360, 180, vr, vr180, ...) make it no flat media at all.
FlatStereoFormat? guessFlatStereoFormat({required String? fileName, int? width, int? height, bool isVideo = false}) {
  if (fileName == null || fileName.isEmpty) {
    return null;
  }
  final dot = fileName.lastIndexOf('.');
  final stem = dot > 0 ? fileName.substring(0, dot) : fileName;
  final words = stem.toLowerCase().split(_wordSeparators).where((word) => word.isNotEmpty).toSet();
  if (words.any(_sphereWords.contains)) {
    return null;
  }
  final half = words.contains('half');
  if (words.any(_halfSideBySideWords.contains)) {
    return FlatStereoFormat.halfSbs;
  }
  if (words.any(_halfTopBottomWords.contains)) {
    return FlatStereoFormat.halfTb;
  }
  final known = width != null && height != null && width > 0 && height > 0;
  if (words.any(_sideBySideWords.contains)) {
    final squeezed = half || (isVideo && known && width / 2 / height < 1.0);
    return squeezed ? FlatStereoFormat.halfSbs : FlatStereoFormat.sbs;
  }
  if (words.any(_topBottomWords.contains)) {
    final squeezed = half || (isVideo && known && width / (height / 2) > 2.5);
    return squeezed ? FlatStereoFormat.halfTb : FlatStereoFormat.tb;
  }
  return null;
}

/// [guessFlatStereoFormat] for [asset], null for anything but a photo or a video
FlatStereoFormat? flatStereoFormatOf(BaseAsset asset) => asset.isImage || asset.isVideo
    ? guessFlatStereoFormat(fileName: asset.name, width: asset.width, height: asset.height, isVideo: asset.isVideo)
    : null;
