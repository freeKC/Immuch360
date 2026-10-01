// Spatial 2.5D: stereoscopic videos played on a phone with depth, through a native player that follows the head of
// the user with the front camera. Like for 360° media, nothing the server indexes tells a stereoscopic video apart,
// so the player gets a guess from the frame shape and the file name, and the user can pick another layout in the
// player. That choice is remembered for the asset, on the device only.

import 'dart:convert';

import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/spatial_video_api.g.dart';

export 'package:immich_mobile/platform/spatial_video_api.g.dart' show SpatialProjection, SpatialStereoLayout;

// File name words that mark a stereoscopic video, as players and rippers write them. "3D-SBS" or "Half-OU" split into
// two words, of which the second one is enough.
const _sideBySideWords = {'sbs', 'hsbs', 'fsbs', 'lr', '3dsbs', 'halfsbs', 'fullsbs', 'sidebyside'};
const _sideBySideSwappedWords = {'rl'};
const _topBottomWords = {'ou', 'hou', 'fou', 'tb', 'htb', 'ftb', 'tab', 'htab', 'overunder', 'topbottom', '3dou'};

/// Guesses how the eyes of a stereoscopic video of [width] x [height] pixels named [fileName] are laid out, in that
/// order:
/// - the frame shape. For a 360° video ([projection] equirectangular), the guess of the 360° viewers (see
///   [guessStereoLayout]): a square frame holds two eyes stacked, a 4:1 frame two eyes side by side. For a flat video,
///   a frame about twice as wide as a regular one (ratio 3.2 to 3.9, for example 3840x1080) holds two full eyes side
///   by side, and a frame a little taller than wide (ratio above 0.8, up to 0.95, for example 1920x2160) two full
///   eyes stacked. Portrait 4:5 videos (ratio 0.8) are left out.
/// - the words of the file name, split on dots, underscores, dashes and spaces, in any case: sbs, hsbs, lr, ... for
///   side by side, ou, hou, tb, tab, overunder, ... for top and bottom, rl for side by side with the right eye first.
///   Half width or half height files look like any 16:9 video and only their name tells.
/// - else [SpatialStereoLayout.auto]: the player uses what the file declares (its st3d box), then the frame shape.
///
/// [declaredStereo] is for a caller that knows the file declares its layout: the player then reads it, which beats
/// any guess, so this returns [SpatialStereoLayout.auto].
SpatialStereoLayout guessSpatialLayout({
  int? width,
  int? height,
  String? fileName,
  SpatialProjection projection = SpatialProjection.flat,
  bool declaredStereo = false,
}) {
  if (declaredStereo) {
    return SpatialStereoLayout.auto;
  }
  if (projection == SpatialProjection.equirectangular) {
    final layout = spatialLayoutOf(guessStereoLayout(width: width, height: height));
    if (layout != SpatialStereoLayout.auto) {
      return layout;
    }
  } else if (width != null && height != null && width > 0 && height > 0) {
    final aspectRatio = width / height;
    if (aspectRatio >= 3.2 && aspectRatio <= 3.9) {
      return SpatialStereoLayout.sideBySide;
    }
    if (aspectRatio > 0.8 && aspectRatio <= 0.95) {
      return SpatialStereoLayout.topBottom;
    }
  }

  final words = (fileName ?? '').toLowerCase().split(RegExp(r'[._\- ]+')).toSet();
  if (words.any(_sideBySideWords.contains)) {
    return SpatialStereoLayout.sideBySide;
  }
  if (words.any(_topBottomWords.contains)) {
    return SpatialStereoLayout.topBottom;
  }
  if (words.any(_sideBySideSwappedWords.contains)) {
    return SpatialStereoLayout.sideBySideSwapped;
  }
  return SpatialStereoLayout.auto;
}

/// The Spatial layout matching a layout of the 360° viewers. Mono becomes [SpatialStereoLayout.auto]: the 360° guess
/// says mono for any frame it does not recognise, and the player may still find a layout in the file.
SpatialStereoLayout spatialLayoutOf(StereoLayout layout) => switch (layout) {
  StereoLayout.topBottom => SpatialStereoLayout.topBottom,
  StereoLayout.leftRight => SpatialStereoLayout.sideBySide,
  StereoLayout.mono => SpatialStereoLayout.auto,
};

/// Key of [asset] in the remembered layouts: the server id when there is one, so that the copy on the device and the
/// one on the server share it, else the id on the device.
String spatialLayoutKey(BaseAsset asset) => asset.remoteId ?? asset.id;

/// Reads the remembered layouts from their JSON form, a map from asset key to layout name. Unknown names and a
/// damaged value are skipped: the guess then applies.
Map<String, SpatialStereoLayout> decodeSpatialLayouts(String? json) {
  if (json == null || json.isEmpty) {
    return {};
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return {};
  }
  if (decoded is! Map) {
    return {};
  }
  final layouts = <String, SpatialStereoLayout>{};
  for (final MapEntry(:key, :value) in decoded.entries) {
    final layout = SpatialStereoLayout.values.where((layout) => layout.name == value).firstOrNull;
    if (key is String && layout != null) {
      layouts[key] = layout;
    }
  }
  return layouts;
}

/// The JSON form of [layouts], see [decodeSpatialLayouts]. Names rather than indexes, so that the stored value
/// survives a change in the order of the enum.
String encodeSpatialLayouts(Map<String, SpatialStereoLayout> layouts) =>
    jsonEncode({for (final MapEntry(:key, :value) in layouts.entries) key: value.name});

/// Translated labels of the Spatial 2.5D player, under the keys it reads. It falls back to its English texts for a
/// missing key.
Map<String, String> spatialLabels(Translations t) => {
  'spatial': t.spatial_2_5d,
  'normal': t.spatial_normal,
  'layout': t.spatial_layout,
  'layoutAuto': t.spatial_layout_auto,
  'layoutSideBySide': t.spatial_layout_side_by_side,
  'layoutTopBottom': t.spatial_layout_top_bottom,
  'layoutSideBySideSwapped': t.spatial_layout_side_by_side_swapped,
  'layoutTopBottomSwapped': t.spatial_layout_top_bottom_swapped,
  'layoutNone': t.spatial_layout_none,
  'recenter': t.spatial_recenter,
  'trackingLost': t.spatial_tracking_lost,
  'cameraDenied': t.spatial_camera_denied,
  'unavailable': t.spatial_unavailable,
  'sensitivity': t.spatial_sensitivity,
  'close': t.close,
  'error': t.errors.unable_to_play_video,
};
