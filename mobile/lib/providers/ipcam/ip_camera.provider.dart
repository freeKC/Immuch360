// What the pages of a camera of another brand read: the network service (search, ONVIF, stream test) and the secrets
// of a camera kept in the secure storage, its password and its stream addresses. Providers so that the tests of the
// pages give fakes.

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/ipcam/camera_address.dart';
import 'package:immich_mobile/infrastructure/ipcam/ip_camera_service.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';

final ipCameraServiceProvider = Provider<IpCameraService>((_) => IpCameraService());

/// The password of the account of the camera of a source id, null without one
final ipCameraPasswordProvider = FutureProvider.autoDispose.family<String?, String>((ref, sourceId) async {
  ref.watch(networkSourceProvider(sourceId));
  return ref.read(networkSourcesProvider.notifier).readPassword(sourceId);
});

/// The stream addresses of the camera of a source id, null when none is stored (a settings file restored without its
/// accounts)
final ipCameraStreamsProvider = FutureProvider.autoDispose.family<IpCameraStreams?, String>((ref, sourceId) async {
  ref.watch(networkSourceProvider(sourceId));
  return IpCameraStreams.decode(await ref.read(networkSourcesProvider.notifier).readCameraPassword(sourceId));
});
