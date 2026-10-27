// What happens when the name of a 3D photo is taken (spec 6.4; design-final 2026-10-26, section 2.5), as chosen in the
// conversion dialog and kept in desktop_ai.json: keep both (the default, "name (1)"), replace, or skip. Replace only
// ever takes the place of a 3D photo of ours made from the same original, read again just before the rename: our XMP,
// a DerivativeId, and the SourceSha1 of the original (else its SourceName and SourceSize, the rule of design-final
// 4.2). salon.jpg and salon.heic both give salon_3D_LRF_Full_SBS.jpg: the 3D photo of the one is never replaced by that
// of the other. A photo of the user, the 3D photo of another tool, or one of ours without an id is never replaced
// either, both are kept instead. Nor is the original of the job, whatever it carries. Pure rules: SafeWriter reads the
// files and acts.

import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/files/saved_files.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';

/// How much of the head of a file is read for its XMP, as the scan and the panorama viewer read GPano
const versionHeadLength = 128 * 1024;

const _sbsNameEnd = '$sbsFullNameSuffix$sbsFileExtension';

/// The name of the 3D photo of [originalName] on a computer: "salon_3D_LRF_Full_SBS.jpg", made safe for Windows. A
/// name too long is shortened before "_3D_LRF_Full_SBS.jpg", which always stays whole: SKYBOX, DeoVR and iw3 read it.
String sbsTargetName(String originalName) {
  var stem = fileStem(originalName);
  for (;;) {
    final name = safeFileName('$stem$_sbsNameEnd');
    if (name.endsWith(_sbsNameEnd) || stem.isEmpty) {
      return name;
    }
    // safeFileName cut the end of the name: the name of the original loses what was cut instead
    final over = '$stem$_sbsNameEnd'.length - name.length;
    var keep = stem.length - (over > 0 ? over : 1);
    if (keep > 0 && _isHighSurrogate(stem.codeUnitAt(keep - 1))) {
      // Never half of a character outside the basic plane
      keep--;
    }
    stem = stem.substring(0, keep < 0 ? 0 : keep);
  }
}

bool _isHighSurrogate(int unit) => unit >= 0xd800 && unit <= 0xdbff;

/// The original of a job, as the XMP of its 3D photos names it (design-final 4.2): its SHA-1 in base64, its name and
/// its size. [path] is the file on this computer, never replaced nor even read by the writer.
class OriginalIdentity {
  const OriginalIdentity({required this.name, required this.size, this.sha1, this.path});

  /// The original [source] of a job
  factory OriginalIdentity.of(ImmersiveSource source) =>
      OriginalIdentity(name: source.name, size: source.size, sha1: source.sha1, path: source.path);

  final String name;
  final int size;

  /// SourceSha1, null while it is not known
  final String? sha1;
  final String? path;

  /// Whether [xmp] is that of a 3D photo made from this original: the same SourceSha1 when both are known, else the
  /// same SourceName and SourceSize
  bool madeFrom(StereoPhotoXmp xmp) {
    final mine = sha1?.trim() ?? '';
    final theirs = xmp.sourceSha1?.trim() ?? '';
    if (mine.isNotEmpty && theirs.isNotEmpty) {
      return mine == theirs;
    }
    return xmp.sourceName == name && xmp.sourceSize == size;
  }

  @override
  String toString() => 'OriginalIdentity($name, $size, $sha1)';
}

/// Whether [head], the first bytes of a file, show a 3D photo of ours that may be replaced by a new one of [original]:
/// our XMP, with a DerivativeId, made from that same original
bool isReplaceableVersion(Uint8List head, {required OriginalIdentity original}) {
  final xmp = StereoPhotoXmp.findIn(head);
  final id = xmp?.derivativeId;
  return xmp != null && id != null && id.trim().isNotEmpty && original.madeFrom(xmp);
}

/// What becomes of a 3D photo whose name may be taken
enum CollisionAction {
  /// Written under its name, or under the first free "name (n)" when it is taken
  newName,

  /// Written in place of the existing file, a 3D photo of ours made from the same original
  replace,

  /// Not written: the existing file stays
  skip,
}

/// What [whenExists] does with a name that is [taken] by a file whose first bytes are [head] (null when they could not
/// be read), for a new 3D photo of [original] (null when it is not known: never a replace then). [isOriginal] when that
/// file is the original of the job, which is never replaced.
CollisionAction collisionAction({
  required AiWhenExists whenExists,
  required bool taken,
  Uint8List? head,
  OriginalIdentity? original,
  bool isOriginal = false,
}) {
  if (!taken) {
    return CollisionAction.newName;
  }
  return switch (whenExists) {
    AiWhenExists.keepBoth => CollisionAction.newName,
    AiWhenExists.skip => CollisionAction.skip,
    AiWhenExists.replace =>
      !isOriginal && head != null && original != null && isReplaceableVersion(head, original: original)
          ? CollisionAction.replace
          : CollisionAction.newName,
  };
}
