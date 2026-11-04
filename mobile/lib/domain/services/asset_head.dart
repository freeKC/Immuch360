// The head of the file of a photo of the library, for the probes that look for a packet of ours in it: the 3D scenes
// (ScenePhotoService) and the splat photos (SplatPhotoService). From the copy on the device when there is one, else
// from the original on the server, by a range request (a server that ignores the range is read from the start and cut
// after the bytes asked for, see httpRangeReader).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:logging/logging.dart';

/// The first [length] bytes of the file of [asset], null when they could not be read: from its copy on the device
/// ([localFile] of its local id) when there is one, else from its original on the server ([serverReader] of its remote
/// id), each read given [timeout]. [log] says what failed, at fine and info levels.
Future<Uint8List?> readAssetHead(
  BaseAsset asset, {
  required Future<File?> Function(String localId) localFile,
  required ByteRangeReader? Function(String remoteId) serverReader,
  required int length,
  required Duration timeout,
  required Logger log,
}) async {
  final localId = asset.localId;
  if (localId != null) {
    File? file;
    try {
      file = await localFile(localId);
    } catch (error) {
      log.fine('Copy on the device of ${asset.name} not found: $error');
    }
    if (file != null) {
      try {
        final handle = await file.open();
        try {
          return await handle.read(length).timeout(timeout);
        } finally {
          await handle.close();
        }
      } catch (error) {
        log.fine('Copy on the device of ${asset.name} unreadable, reading the server copy: $error');
      }
    }
  }
  final remoteId = asset.remoteId;
  final read = remoteId == null ? null : serverReader(remoteId);
  if (read == null) {
    return null;
  }
  try {
    return await read(0, length).timeout(timeout);
  } catch (error) {
    log.info('Could not read the head of ${asset.name} on the server: $error');
    return null;
  }
}
