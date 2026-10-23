import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/media_bridge.service.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';

/// The local HTTP bridge the players read the network shares through, one for the life of the app. It listens once
/// [MediaBridge.start] was called (safe to call before each use) and keeps the shares registered on it. The players of
/// the computers (libmpv) read transport streams with 192 byte packets as they are; Media3 needs them as a 188 byte TS.
final mediaBridgeProvider = Provider<MediaBridge>((ref) {
  final bridge = LocalMediaBridge(convertM2ts: !CurrentPlatform.isDesktop);
  ref.onDispose(() => unawaited(bridge.stop()));
  return bridge;
});
