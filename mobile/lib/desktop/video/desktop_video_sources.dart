// What the desktop player is given for the VideoSource the viewer or the network page loads (design 2.2, "Sources"):
// - a file of this computer: its path, as libmpv opens it;
// - a media bridge URL (the shares, the Tapo recordings): as it is;
// - a video of the Immich server: the bridge URL of ImmichServerFileSystem, registered on the app's bridge on first
//   use, so that the session token, the custom headers and the server's address stay in Dart.
// Anything else is refused rather than handed to libmpv with its headers.

import 'dart:io';

import 'package:immich_mobile/desktop/network/immich_server_file_system.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:native_video_player/native_video_player.dart';

/// The bridges the server file system was registered on
final _registered = Expando<ImmichServerFileSystem>('ImmichServerFileSystem');

/// The path or the URL libmpv opens for [source]. [serverEndpoint] is the API address of the server the app uses;
/// [serverFileSystem] makes the file system registered on [bridge] for its videos, once per bridge.
Future<String> resolveDesktopVideoSource(
  VideoSource source, {
  required MediaBridge bridge,
  required String? serverEndpoint,
  required ImmichServerFileSystem Function() serverFileSystem,
}) async {
  final path = source.path;
  switch (source.type) {
    case VideoSourceType.file || VideoSourceType.asset:
      return path.startsWith('file:') ? Uri.parse(path).toFilePath() : path;
    case VideoSourceType.network:
      final uri = Uri.tryParse(path);
      if (uri == null) {
        throw const FormatException('Not an address');
      }
      // The server first: one that runs on this computer has a loopback address too
      final serverPath = ImmichServerFileSystem.pathOf(path, serverEndpoint);
      if (serverPath == null) {
        if (_isLoopback(uri) && uri.userInfo.isEmpty && uri.scheme == 'http') {
          // Already a bridge URL: the shares hand those to every player
          return path;
        }
        throw UnsupportedError('Only the files of this computer, the shares and the server are played here');
      }
      if (_registered[bridge] == null) {
        final fileSystem = serverFileSystem();
        bridge.register(fileSystem);
        _registered[bridge] = fileSystem;
      }
      await bridge.start();
      return bridge.urlFor(ImmichServerFileSystem.sourceId, serverPath).toString();
  }
}

bool _isLoopback(Uri uri) {
  final host = uri.host;
  if (host == 'localhost') {
    return true;
  }
  return InternetAddress.tryParse(host)?.isLoopback ?? false;
}
