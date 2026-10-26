// What happens when the name of a 3D photo is taken (spec 6.4; design-final 2026-10-26, section 2.5), as chosen in the
// conversion dialog and kept in desktop_ai.json: keep both (the default, "name (1)"), replace, or skip. Replace only
// ever takes the place of a file that carries our XMP and a DerivativeId, read again just before the rename: a photo
// of the user, the 3D photo of another tool, or one of ours without an id is never replaced, both are kept instead.
// Nor is the original of the job, whatever it carries. Pure rules: SafeWriter reads the files and acts.

import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/files/saved_files.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';

/// How much of the head of a file is read for its XMP, as the scan and the panorama viewer read GPano
const versionHeadLength = 128 * 1024;

/// The name of the 3D photo of [originalName] on a computer: "salon_3D_LRF_Full_SBS.jpg", made safe for Windows
String sbsTargetName(String originalName) => safeFileName(sbsFileNameFor(originalName));

/// Whether [head], the first bytes of a file, show a 3D photo of ours that may be replaced: our XMP, with a
/// DerivativeId
bool isReplaceableVersion(Uint8List head) {
  final id = StereoPhotoXmp.findIn(head)?.derivativeId;
  return id != null && id.trim().isNotEmpty;
}

/// What becomes of a 3D photo whose name may be taken
enum CollisionAction {
  /// Written under its name, or under the first free "name (n)" when it is taken
  newName,

  /// Written in place of the existing file, a 3D photo of ours
  replace,

  /// Not written: the existing file stays
  skip,
}

/// What [whenExists] does with a name that is [taken] by a file whose first bytes are [head] (null when they could not
/// be read). [isOriginal] when that file is the original of the job, which is never replaced.
CollisionAction collisionAction({
  required AiWhenExists whenExists,
  required bool taken,
  Uint8List? head,
  bool isOriginal = false,
}) {
  if (!taken) {
    return CollisionAction.newName;
  }
  return switch (whenExists) {
    AiWhenExists.keepBoth => CollisionAction.newName,
    AiWhenExists.skip => CollisionAction.skip,
    AiWhenExists.replace =>
      !isOriginal && head != null && isReplaceableVersion(head) ? CollisionAction.replace : CollisionAction.newName,
  };
}
