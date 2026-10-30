// "Make 3D (AI)" on the photos of a share opened in the app (SMB, WebDAV, DLNA, Plex), on a computer (FreeKC, 30
// October 2026: "Make 3D (AI)" works on a photo of a share as on a library photo). The conversion dialog opens on the
// files of the share: it copies each photo once into the cache through the media bridge (ShareFileSource), shows its
// name and its size while it does, with Cancel, and reads the facts of the photo from that copy with the probes of a
// file of this computer: the frame and our XMP as the scan of the library reads them (readMediaMetadataSync), the 360°
// rules of the scan (probeLocalPanoramaFile), two eyes by name, frame or our XMP as the viewer reads them, an Apple
// spatial photo, and the GPano crop. The plan then gives the four types of a library photo, with their reasons, and the
// job of each photo reads the copy the dialog made.
//
// The photo of a share has no asset in the app: the plan sees it through shareConversionAsset, which holds only what
// the rules of the plan read (its name, its kind, its frame), never a photo of the timeline, so nothing of the
// library, the server or the viewer is asked about it.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/creator/existing_version_finder.dart';
import 'package:immich_mobile/desktop/ai/creator/share_file_source.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/ui/conversion_dialog.dart';
import 'package:immich_mobile/desktop/ai/ui/conversions_panel.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/library_index.dart';
import 'package:immich_mobile/desktop/library/library_metadata.dart';
import 'package:immich_mobile/domain/models/apple_spatial.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/view_rotation.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/domain/services/apple_spatial/heic_stereo_probe.dart';
import 'package:immich_mobile/domain/services/local_panorama.service.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart' show ByteRangeReader;
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart' show readGPanoFile;
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('ShareConversion');

/// Makes the source of a photo of a share: its copy through the media bridge, as the pages of the shares read it;
/// replaced in tests
final shareConversionSourceProvider = Provider<ShareFileSource Function(NetworkEntry entry)>((ref) {
  final connections = ref.watch(networkConnectionsProvider);
  final client = ref.watch(networkBridgeClientProvider);
  return (entry) => ShareFileSource(
    entry: entry,
    url: () => connections.mediaUrl(entry.sourceId, entry.path),
    fetch: (url) => client.send(http.Request('GET', url)),
  );
});

/// What the dialog reads of the copy of a photo of a share: its frame as it is shown, its facts, and the fields its
/// version keeps from it
class ShareCopyFacts {
  const ShareCopyFacts({this.width, this.height, required this.facts, this.exif = const ImmersiveExif()});

  final int? width;
  final int? height;
  final ConversionPhotoFacts facts;
  final ImmersiveExif exif;
}

/// Reads the facts of [entry] from its [copy], the photo shown with [quarterTurns] by the page of its share
typedef ShareCopyFactsReader = Future<ShareCopyFacts> Function(NetworkEntry entry, String copy, {int quarterTurns});

final shareCopyFactsReaderProvider = Provider<ShareCopyFactsReader>(
  (ref) =>
      (entry, copy, {quarterTurns = 0}) => readShareCopyFacts(entry, copy, quarterTurns: quarterTurns),
);

/// The facts of [entry] read from its [copy] with the probes of a file of this computer (see the top of this file).
/// [quarterTurns] are those the page of its share shows it with; [linux], no decoder of HEIF there, so no spatial
/// probe either. What cannot be read stays as for a flat photo: the job reads the copy again.
Future<ShareCopyFacts> readShareCopyFacts(NetworkEntry entry, String copy, {int quarterTurns = 0, bool? linux}) async {
  final name = entry.name;
  final metadata = readMediaMetadataSync(copy, LibraryMediaKind.image);
  final width = metadata.displayWidth ?? entry.width;
  final height = metadata.displayHeight ?? entry.height;
  LocalPanoramaProbe? probe;
  try {
    probe = await probeLocalPanoramaFile(copy, isVideo: false, width: width, height: height);
  } on Object catch (error) {
    _log.fine('The copy of $name could not be read for a 360° projection: $error');
  }
  final isPanorama = probe?.isPanorama ?? false;
  final version = indexedVersionOf(metadata.immersive);
  var isStereo =
      (version != null && versionHoldsTwoEyes(version)) ||
      decideStereoPhoto(name: name, width: width, height: height) != null;
  // Two eyes side by side that only our XMP or the frame of another tool tells, read as the viewer reads them
  if (!isStereo && !isPanorama && isStereoPhotoCandidate(name: name, width: width, height: height)) {
    final head = await readFileHead(copy);
    isStereo = head != null && probeStereoPhotoHead(head, name: name, width: width, height: height) != null;
  }
  var isSpatial = false;
  if (isHeifName(name) && !(linux ?? Platform.isLinux)) {
    try {
      isSpatial = await probeHeicStereoPair(_fileReader(copy)) != null;
    } on Object catch (error) {
      _log.fine('The copy of $name could not be read for a spatial photo: $error');
    }
  }
  var partialSphere = false;
  if (isPanorama || isEquirectFrame(width, height)) {
    try {
      final crop = (await readGPanoFile(File(copy)))?.crop;
      partialSphere = crop != null && isPartialSphere(crop);
    } on Object catch (error) {
      _log.fine('The copy of $name could not be read for its GPano crop: $error');
    }
  }
  final date = metadata.takenAt ?? entry.modified;
  return ShareCopyFacts(
    width: width,
    height: height,
    facts: ConversionPhotoFacts(
      isPanorama: isPanorama,
      isRaw360: probe?.raw360 ?? false,
      isStereo: isStereo,
      version: version,
      isSpatial: isSpatial,
      quarterTurns: normalizeQuarterTurns(quarterTurns),
      partialSphere: partialSphere,
    ),
    exif: date == null ? const ImmersiveExif() : conversionExifOf(name, date),
  );
}

/// Reads the file at [path] by ranges, for the probes that take a reader
ByteRangeReader _fileReader(String path) => (offset, length) async {
  final file = await File(path).open();
  try {
    await file.setPosition(offset);
    return await file.read(length);
  } finally {
    await file.close();
  }
};

/// The photo of a share at [entry] as the plan sees it, of [width] x [height] pixels as its copy tells (else as its
/// share listed): its name, its kind, its frame and its date, nothing else. Its id names the share and the path, so
/// that it is never taken for a photo of the library.
LocalAsset shareConversionAsset(NetworkEntry entry, {int? width, int? height}) {
  final date = entry.modified ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  return LocalAsset(
    id: 'share:${entry.sourceId}:${entry.path}',
    name: entry.name,
    type: entry.isVideo
        ? AssetType.video
        : entry.isImage
        ? AssetType.image
        : AssetType.other,
    createdAt: date,
    updatedAt: date,
    width: width ?? entry.width,
    height: height ?? entry.height,
    playbackStyle: entry.isVideo ? AssetPlaybackStyle.video : AssetPlaybackStyle.image,
    isEdited: false,
  );
}

/// Opens the conversion dialog on [entries], files of one share, on the type [kind] when it takes one of them; once
/// photos were handed to the queue, the panel of the conversions shows
Future<void> openShareConversionDialog(BuildContext context, List<NetworkEntry> entries, {ConversionKind? kind}) async {
  // The page that opened the dialog may be gone when it closes: the panel opens from the navigator
  final navigator = Navigator.of(context, rootNavigator: true);
  final launched = await showDialog<bool>(
    context: context,
    builder: (context) => ConversionDialog(shareFiles: entries, kind: kind),
  );
  if (launched != true) {
    return;
  }
  final overlay = navigator.mounted ? navigator.overlay : null;
  if (overlay != null && overlay.mounted) {
    await showConversionsPanel(overlay.context);
  }
}
