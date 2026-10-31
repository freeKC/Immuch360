// The folders of this device chosen in the system picker of Android (ACTION_OPEN_DOCUMENT_TREE, through
// DocumentTreeApi), browsed as the shares are: every subfolder, the photos and videos, the splats on a Meta Quest. A
// folder is known by its tree URI and the read grant Android keeps for it; its source lives in memory among the import
// sources, never in the stored list of the shares (see DeviceFoldersNotifier).

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:immich_mobile/domain/models/network_source.dart';

/// The authority of the storage of the device, its cards and its USB drives (ExternalStorageProvider)
const _externalStorage = 'com.android.externalstorage.documents';

/// The id of the source of the folder [treeUri]: the same in every session, apart from the one the DJI drone page
/// gives the same folder (ImportSourcesNotifier.idFor), and under NetworkEntry.importSourcePrefix, so that it is read
/// without a password and never stored with the shares
String deviceFolderSourceId(String treeUri) =>
    '${NetworkEntry.importSourcePrefix}folder-${sha1.convert(utf8.encode(treeUri)).toString().substring(0, 16)}';

/// The source the browser reads the folder [treeUri] through, under its [folderName]; [kind] says where it is
/// ("internal", "usb", "mtp", "other", see TreePick.kind)
NetworkSource deviceFolderSource({required String treeUri, required String folderName, required String kind}) =>
    NetworkSource(
      id: deviceFolderSourceId(treeUri),
      type: NetworkSourceType.deviceFolder,
      name: folderName,
      host: kind,
      share: treeUri,
    );

/// Where the folder [treeUri] is on its volume ("Download/Immuch360-splats", "" for a whole volume), read from the
/// document id of a folder of the storage, a card or a USB drive ("primary:Download/Immuch360-splats"); null when the
/// provider does not tell (a device in File transfer mode numbers its folders)
String? deviceFolderPath(String treeUri) {
  final uri = Uri.tryParse(treeUri);
  if (uri == null || uri.authority != _externalStorage) {
    return null;
  }
  final segments = uri.pathSegments;
  final tree = segments.indexOf('tree');
  if (tree < 0 || tree + 1 >= segments.length) {
    return null;
  }
  final documentId = segments[tree + 1];
  final colon = documentId.indexOf(':');
  return colon < 0 ? null : documentId.substring(colon + 1);
}
