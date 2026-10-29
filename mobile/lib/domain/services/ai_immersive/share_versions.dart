// The versions of a photo of a network share, found among the files of its folder (design-final 2026-10-26, sections
// 3.8 and 4.2; design-final 2026-10-27, section 8.4, point 5): what "View the 3D version", "View the 3D scene" and "View
// the 360° version" open on the Meta Quest, the files a computer saved next to the original on a NAS (route 9.1 of the
// specification). A share gives no SHA-1 of its files, so the rule of derived_file_rule.dart goes by the folder, the
// name, and the SourceName and SourceSize of the XMP of the version. Only the neighbours whose name starts like a
// version (the suffixes of the four kinds) are read, the eight newest at most, the head of each (128 KiB): a folder
// without such a name costs no read at all. Each version is kept when the probe of its kind recognises it: the probe
// of the side by side photos for a 3D photo, our packet for a 3D scene, the 360° rules (an equirectangular GPano) for
// a panorama, and a frame of two eyes stacked besides for a 360° 3D panorama. Shared code: the Quest reads it, the
// computers have their own index.

import 'dart:typed_data';

import 'package:immich_mobile/domain/models/ai_immersive/derived_file_rule.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:logging/logging.dart';

final _log = Logger('ShareVersions');

/// How much of the head of a neighbour is read for its XMP: the window of the GPano tags, which the computers write
/// within
const shareVersionHeadLength = 128 * 1024;

/// A version of a photo of a share: its file, its kind, and what its head says
class ShareVersion {
  const ShareVersion({required this.entry, required this.kind, required this.xmp, this.photo});

  final NetworkEntry entry;

  /// A 3D photo, a 3D scene, a 360° panorama or a 360° 3D panorama; null for a kind of a newer format, which the probe
  /// of the side by side photos keeps so that the viewer can say it was made by a newer version
  final ImmersiveKind? kind;

  /// Our packet, as its kind reads it (SceneXmp, PanoramaXmp, StereoPanoramaXmp, StereoPhotoXmp): the request of a
  /// scene for the headset, the region of the photo in a panorama
  final ImmersiveXmp xmp;

  /// For a 3D photo, and a kind of a newer format, what the probe of the side by side photos found: the eyes and the
  /// request of the viewer; null for the other kinds
  final FlatStereoPhoto? photo;

  @override
  String toString() => 'ShareVersion(${entry.name}, ${kind?.name ?? 'newer kind'})';
}

/// The folder of the share path [path], "/" for a file at the root
String shareFolderOf(String path) {
  final slash = path.lastIndexOf('/');
  return slash <= 0 ? '/' : path.substring(0, slash);
}

/// The versions of [original] among [neighbours], the pictures of its folder (others are left out), of every kind, the
/// newest first. [readerOf] reads a neighbour; a neighbour that cannot be read is skipped, and so is one the probe of
/// its kind does not recognise. Empty when the size of the original is unknown: the rule needs it. Never throws.
Future<List<ShareVersion>> findShareVersions(
  NetworkEntry original,
  Iterable<NetworkEntry> neighbours, {
  required ByteRangeReader Function(NetworkEntry entry) readerOf,
}) async {
  final size = original.size;
  if (size == null || original.isDirectory) {
    return const [];
  }
  final folder = shareFolderOf(original.path);
  // The newest first before derivedNameCandidates keeps eight of them: with more versions than that, the newest are
  // read. Equal dates keep the order of the folder.
  final ordered = neighbours.indexed.toList()
    ..sort((a, b) {
      final byDate = _newestFirst(a.$2.modified, b.$2.modified);
      return byDate != 0 ? byDate : a.$1.compareTo(b.$1);
    });
  final files = {
    for (final (_, entry) in ordered)
      if (entry.isImage && entry.sourceId == original.sourceId && shareFolderOf(entry.path) == folder)
        entry.name: entry,
  };
  final names = derivedNameCandidates(original.name, files.keys);
  if (names.isEmpty) {
    return const [];
  }
  final rule = DerivedRuleOriginal(name: original.name, size: size, folder: folder);
  final versions = <ShareVersion>[];
  for (final name in names) {
    final entry = files[name]!;
    try {
      final head = await readerOf(entry)(0, shareVersionHeadLength);
      final xmp = holdsImmuch360Xmp(head) ? StereoPhotoXmp.findIn(head) : null;
      if (!isDerivedFrom(DerivedRuleCandidate(name: name, folder: folder, xmp: xmp), rule)) {
        _log.fine('$name is no version of ${original.name}');
        continue;
      }
      final version = await _probeVersion(entry, head);
      if (version == null) {
        _log.fine('$name is a version of ${original.name} its probe does not recognise');
        continue;
      }
      versions.add(version);
    } catch (error) {
      _log.info('Could not read $name for the versions of ${original.name}: $error');
    }
  }
  versions.sort((a, b) => _newestFirst(a.entry.modified, b.entry.modified));
  if (versions.isNotEmpty) {
    _log.info('${original.name} has ${versions.length} versions: ${versions.join(', ')}');
  }
  return versions;
}

/// [entry], a version of ours whose [head] was read, as the probe of its kind recognises it; null when it does not
Future<ShareVersion?> _probeVersion(NetworkEntry entry, Uint8List head) async {
  final xmp = ImmersiveXmp.findIn(head);
  switch (xmp) {
    case null:
      return null;
    case SceneXmp():
      // A scene of a newer format is kept: the viewer says why it shows it flat
      return ShareVersion(entry: entry, kind: ImmersiveKind.volumetricScene, xmp: xmp);
    case PanoramaXmp() || StereoPanoramaXmp():
      final gpano = await readGPanoTags((offset, length) async => _window(head, offset, length), head.length);
      if (gpano == null || !isEquirectangularGPano(gpano)) {
        return null;
      }
      if (xmp is PanoramaXmp) {
        return ShareVersion(entry: entry, kind: ImmersiveKind.panorama360, xmp: xmp);
      }
      final frame = frameOfHead(head);
      final stacked =
          frame != null && guessStereoLayout(width: frame.width, height: frame.height) == StereoLayout.topBottom;
      return stacked ? ShareVersion(entry: entry, kind: ImmersiveKind.stereoPanorama360, xmp: xmp) : null;
    default:
      final photo = probeStereoPhotoHead(head, name: entry.name, width: entry.width, height: entry.height);
      return photo == null ? null : ShareVersion(entry: entry, kind: xmp.kind, xmp: xmp, photo: photo);
  }
}

Uint8List _window(Uint8List bytes, int offset, int length) => offset >= bytes.length
    ? Uint8List(0)
    : Uint8List.sublistView(bytes, offset, (offset + length).clamp(0, bytes.length));

/// The newer of two dates first, a missing date last
int _newestFirst(DateTime? a, DateTime? b) {
  if (a == null || b == null) {
    return a == null ? (b == null ? 0 : 1) : -1;
  }
  return b.compareTo(a);
}
