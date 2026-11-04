// What the desktop player is given for the VideoSource the viewer or the network page loads (design 2.2, "Sources"):
// - a file of this computer: its path, as libmpv opens it;
// - a media bridge URL (the shares, the Tapo recordings): as it is;
// - a video of the Immich server: the bridge URL of ImmichServerFileSystem, registered on the app's bridge on first
//   use, so that the session token, the custom headers and the server's address stay in Dart;
// - an AV2 video (.ivf, .obu) of this computer or of a share: the y4m its companion serves on 127.0.0.1
//   (av2_playback.dart), which mpv opens as a file of a share, its units read by the app from the file or through the
//   share's file system behind the bridge URL; an .ivf or .obu that holds another codec goes to libmpv as it is.
// Anything else is refused rather than handed to libmpv with its headers.

import 'dart:io';

import 'package:immich_mobile/desktop/network/immich_server_file_system.dart';
import 'package:immich_mobile/desktop/video/av2_playback.dart';
import 'package:immich_mobile/domain/services/media_bridge.service.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:native_video_player/native_video_player.dart';

/// The bridges the server file system was registered on
final _registered = Expando<ImmichServerFileSystem>('ImmichServerFileSystem');

/// The path or the URL libmpv opens for [source]. [serverEndpoint] is the API address of the server the app uses;
/// [serverFileSystem] makes the file system registered on [bridge] for its videos, once per bridge. [av2] serves the
/// AV2 videos; without it they go to libmpv as they are (which plays none of them).
Future<String> resolveDesktopVideoSource(
  VideoSource source, {
  required MediaBridge bridge,
  required String? serverEndpoint,
  required ImmichServerFileSystem Function() serverFileSystem,
  Av2Playbacks? av2,
}) async {
  final path = source.path;
  switch (source.type) {
    case VideoSourceType.file || VideoSourceType.asset:
      final file = path.startsWith('file:') ? Uri.parse(path).toFilePath() : path;
      if (av2 != null && isAv2VideoPath(file)) {
        return _av2(av2, Av2Bytes.file(file), file);
      }
      return file;
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
          final share = bridge is LocalMediaBridge && av2 != null && isAv2VideoPath(uri.path)
              ? bridge.fileOf(uri)
              : null;
          if (share != null) {
            return _av2(av2!, Av2Bytes.share(share.fileSystem, share.path), path);
          }
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

/// The URL of the companion serving [bytes], or [asIs] for a file that holds another codec than AV2
Future<String> _av2(Av2Playbacks av2, Av2Bytes bytes, String asIs) async {
  try {
    return await av2.open(bytes);
  } on Av2NotAv2 {
    // An IVF of AV1 or VP9 (aomenc, vpxenc): libmpv opens it, where its build has the demuxer
    return asIs;
  }
}

bool _isLoopback(Uri uri) {
  final host = uri.host;
  if (host == 'localhost') {
    return true;
  }
  return InternetAddress.tryParse(host)?.isLoopback ?? false;
}
