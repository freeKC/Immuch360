import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/platform/desktop_apis.dart';
import 'package:immich_mobile/domain/services/background_worker.service.dart';
import 'package:immich_mobile/platform/connectivity_api.g.dart';
import 'package:immich_mobile/platform/local_image_api.g.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:immich_mobile/platform/network_api.g.dart';
import 'package:immich_mobile/platform/permission_api.g.dart';
import 'package:immich_mobile/platform/remote_image_api.g.dart';
import 'package:immich_mobile/platform/spatial_video_api.g.dart';
import 'package:immich_mobile/platform/spherical_video_api.g.dart';
import 'package:immich_mobile/platform/video_decoder_api.g.dart';

// Each API comes from PlatformApis: the generated class on the phones, its desktop implementation on the computers

final backgroundWorkerFgServiceProvider = Provider((_) => BackgroundWorkerFgService(PlatformApis.backgroundWorkerFg()));

final backgroundWorkerLockServiceProvider = Provider<BackgroundWorkerLockService>(
  (_) => BackgroundWorkerLockService(PlatformApis.backgroundWorkerLock()),
);

final nativeSyncApiProvider = Provider<NativeSyncApi>((_) => PlatformApis.nativeSync());

final permissionApiProvider = Provider<PermissionApi>((_) => PlatformApis.permission());

final connectivityApiProvider = Provider<ConnectivityApi>((_) => PlatformApis.connectivity());

final sphericalVideoApiProvider = Provider<SphericalVideoApi>((_) => PlatformApis.sphericalVideo());

final spatialVideoApiProvider = Provider<SpatialVideoApi>((_) => PlatformApis.spatialVideo());

final videoDecoderApiProvider = Provider<VideoDecoderApi>((_) => PlatformApis.videoDecoder());

final LocalImageApi localImageApi = PlatformApis.localImage();

final RemoteImageApi remoteImageApi = PlatformApis.remoteImage();

final NetworkApi networkApi = PlatformApis.network();
