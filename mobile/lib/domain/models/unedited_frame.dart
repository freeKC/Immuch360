// The frame of a photo as its file holds it, upright, before any edit of the server. The server rewrites the width and
// the height of an asset it edits (a quarter turn swaps them, a crop shrinks them), while the 360°, 180° and 3D views
// show the unedited file: their guesses of the layout and the coverage, and the rules that tell a photo may be 360°,
// read this frame, never the edited one.

import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';

/// A width and a height in pixels, each null when unknown
typedef AssetFrame = ({int? width, int? height});

/// The frame of a photo upright before the edits of the server: [width] x [height], the size of the asset, while it
/// carries no edit ([isEdited] false); else the size the exif read in its file, [exifWidth] x [exifHeight], swapped
/// when the exif orientation turns it a quarter ([exifFlipped]), as the server sizes an asset before any edit; else
/// unknown.
AssetFrame uneditedFrame({
  required int? width,
  required int? height,
  required bool isEdited,
  int? exifWidth,
  int? exifHeight,
  bool exifFlipped = false,
}) {
  if (!isEdited) {
    return (width: width, height: height);
  }
  if (exifWidth == null || exifHeight == null || exifWidth <= 0 || exifHeight <= 0) {
    return (width: null, height: null);
  }
  return exifFlipped ? (width: exifHeight, height: exifWidth) : (width: exifWidth, height: exifHeight);
}

/// Whether the server rewrote the size of [asset] with an edit: only an asset of the server carries edits, a file of
/// the device is read as it is
bool hasEditedFrame(BaseAsset asset) => asset is RemoteAsset && asset.isEdited;

/// [uneditedFrame] of [asset], whose exif is [exif] (needed only when [hasEditedFrame])
AssetFrame uneditedFrameOf(BaseAsset asset, ExifInfo? exif) => uneditedFrame(
  width: asset.width,
  height: asset.height,
  isEdited: hasEditedFrame(asset),
  exifWidth: exif?.width,
  exifHeight: exif?.height,
  exifFlipped: exif?.isFlipped ?? false,
);

/// Whether [frame] is known: a width and a height above 0
bool isKnownFrame(AssetFrame frame) => (frame.width ?? 0) > 0 && (frame.height ?? 0) > 0;
