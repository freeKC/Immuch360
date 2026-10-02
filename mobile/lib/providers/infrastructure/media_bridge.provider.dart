import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/media_bridge.service.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';

/// The local HTTP bridge the players read the network shares through, one for the life of the app. It listens once
/// [MediaBridge.start] was called (safe to call before each use) and keeps the shares registered on it.
final mediaBridgeProvider = Provider<MediaBridge>((ref) {
  final bridge = LocalMediaBridge();
  ref.onDispose(() => unawaited(bridge.stop()));
  return bridge;
});
