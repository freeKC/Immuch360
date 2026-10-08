// Where the app gets each platform API. On Android and iOS every factory returns the class pigeon generated, a new
// one per call as before; on Windows, macOS and Linux it returns the desktop implementation, a Dart class that
// implements the generated one, so that a changed pigeon signature upstream breaks the desktop build on the day of
// the merge rather than at run time. The choice reads defaultTargetPlatform (CurrentPlatform), which tests can
// override and which release builds fold to a constant.

import 'package:immich_mobile/desktop/library/folder_library_sync_api.dart';
import 'package:immich_mobile/desktop/platform/desktop_background_worker_api.dart';
import 'package:immich_mobile/desktop/platform/desktop_connectivity_api.dart';
import 'package:immich_mobile/desktop/platform/desktop_local_image_api.dart';
import 'package:immich_mobile/desktop/platform/desktop_network_api.dart';
import 'package:immich_mobile/desktop/platform/desktop_permission_api.dart';
import 'package:immich_mobile/desktop/platform/desktop_remote_image_api.dart';
import 'package:immich_mobile/desktop/platform/desktop_share_files_api.dart';
import 'package:immich_mobile/desktop/platform/desktop_spatial_video_api.dart';
import 'package:immich_mobile/desktop/platform/desktop_spherical_video_api.dart';
import 'package:immich_mobile/desktop/platform/desktop_video_decoder_api.dart';
import 'package:immich_mobile/desktop/platform/desktop_video_thumbnail_api.dart';
import 'package:immich_mobile/desktop/platform/desktop_view_intent_api.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/platform/background_worker_api.g.dart';
import 'package:immich_mobile/platform/background_worker_lock_api.g.dart';
import 'package:immich_mobile/platform/connectivity_api.g.dart';
import 'package:immich_mobile/platform/local_image_api.g.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:immich_mobile/platform/network_api.g.dart';
import 'package:immich_mobile/platform/permission_api.g.dart';
import 'package:immich_mobile/platform/phone_share_api.g.dart';
import 'package:immich_mobile/platform/remote_image_api.g.dart';
import 'package:immich_mobile/platform/spatial_video_api.g.dart';
import 'package:immich_mobile/platform/spherical_video_api.g.dart';
import 'package:immich_mobile/platform/video_decoder_api.g.dart';
import 'package:immich_mobile/platform/video_thumbnail_api.g.dart';
import 'package:immich_mobile/platform/view_intent_api.g.dart';

abstract final class PlatformApis {
  // The desktop implementations that hold state (the folder library, the client certificate) are kept once, as the
  // native side keeps one host object per API
  static FolderLibrarySyncApi? _nativeSync;
  static DesktopNetworkApi? _network;
  static DesktopLocalImageApi? _localImage;
  static DesktopRemoteImageApi? _remoteImage;
  static DesktopShareFilesApi? _shareFiles;

  static NativeSyncApi nativeSync() =>
      CurrentPlatform.isDesktop ? _nativeSync ??= FolderLibrarySyncApi() : NativeSyncApi();

  static PermissionApi permission() => CurrentPlatform.isDesktop ? DesktopPermissionApi() : PermissionApi();

  static ConnectivityApi connectivity() => CurrentPlatform.isDesktop ? DesktopConnectivityApi() : ConnectivityApi();

  static BackgroundWorkerFgHostApi backgroundWorkerFg() =>
      CurrentPlatform.isDesktop ? DesktopBackgroundWorkerFgHostApi() : BackgroundWorkerFgHostApi();

  static BackgroundWorkerBgHostApi backgroundWorkerBg() =>
      CurrentPlatform.isDesktop ? DesktopBackgroundWorkerBgHostApi() : BackgroundWorkerBgHostApi();

  static BackgroundWorkerLockApi backgroundWorkerLock() =>
      CurrentPlatform.isDesktop ? DesktopBackgroundWorkerLockApi() : BackgroundWorkerLockApi();

  static SphericalVideoApi sphericalVideo() =>
      CurrentPlatform.isDesktop ? DesktopSphericalVideoApi() : SphericalVideoApi();

  static SpatialVideoApi spatialVideo() => CurrentPlatform.isDesktop ? DesktopSpatialVideoApi() : SpatialVideoApi();

  static VideoDecoderApi videoDecoder() => CurrentPlatform.isDesktop ? DesktopVideoDecoderApi() : VideoDecoderApi();

  static VideoThumbnailApi videoThumbnail() =>
      CurrentPlatform.isDesktop ? DesktopVideoThumbnailApi() : VideoThumbnailApi();

  static LocalImageApi localImage() =>
      CurrentPlatform.isDesktop ? _localImage ??= DesktopLocalImageApi() : LocalImageApi();

  static RemoteImageApi remoteImage() =>
      CurrentPlatform.isDesktop ? _remoteImage ??= DesktopRemoteImageApi() : RemoteImageApi();

  static NetworkApi network() => CurrentPlatform.isDesktop ? _network ??= DesktopNetworkApi() : NetworkApi();

  /// "Share this phone on the network" on the phones, "Share this computer on the network" on the computers
  static PhoneShareApi phoneShare() =>
      CurrentPlatform.isDesktop ? _shareFiles ??= DesktopShareFilesApi() : PhoneShareApi();

  static ViewIntentHostApi viewIntent() => CurrentPlatform.isDesktop ? DesktopViewIntentHostApi() : ViewIntentHostApi();
}
