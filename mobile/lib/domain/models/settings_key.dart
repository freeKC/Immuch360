import 'package:flutter/material.dart';
import 'package:immich_mobile/constants/colors.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_pair_requests.dart';
import 'package:immich_mobile/domain/models/log.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/models/value_codec.dart';
import 'package:immich_mobile/providers/album/album_sort_by_options.provider.dart';
import 'package:immich_mobile/utils/semver.dart';

enum SettingsKey<T> {
  // Theme
  themePrimaryColor<ImmichColorPreset>(codec: EnumCodec(ImmichColorPreset.values)),
  themeMode<ThemeMode>(codec: EnumCodec(ThemeMode.values)),
  themeDynamic<bool>(),
  themeColorfulInterface<bool>(),

  // Image
  imagePreferRemote<bool>(),
  imageLoadOriginal<bool>(),

  // Viewer
  viewerLoopVideo<bool>(),
  // The Looping setting of a TV, see ViewerConfig.loopVideoOnTv
  viewerLoopVideoOnTv<bool>(),
  viewerLoadOriginalVideo<bool>(),
  viewerAutoPlayVideo<bool>(),
  viewerTapToNavigate<bool>(),
  viewerSpatial25d<bool>(),
  // The right thumbstick of the Meta Quest immersive viewer turns the other way, see ViewerConfig.reverseThumbstickTurn
  viewerReverseThumbstickTurn<bool>(),
  // The flat 3D media told by their file name in the Meta Quest immersive viewer, see ViewerConfig.flat3dByName
  viewerFlat3dByName<bool>(),
  // The compositor layer and its filters on the flat screens of the Meta Quest immersive viewer, see
  // ViewerConfig.sharpFlatScreens
  viewerSharpFlatScreens<bool>(),
  // Null until the user picks a source: viewerLoadOriginalVideo tells it until then, see ViewerConfig.videoSource
  viewerVideoSource<VideoSourcePolicy?>(codec: EnumCodec<VideoSourcePolicy>(VideoSourcePolicy.values)),

  // Network
  networkAutoEndpointSwitching<bool>(),
  networkExternalEndpointList<List<String>>(codec: ListCodec(PrimitiveCodec.string)),
  networkCustomHeaders<Map<String, String>>(codec: MapCodec(PrimitiveCodec.string, PrimitiveCodec.string)),
  networkPreferredWifiName<String?>(),
  networkLocalEndpoint<String?>(),

  // Album
  albumSortMode<AlbumSortMode>(codec: EnumCodec(AlbumSortMode.values)),
  albumIsReverse<bool>(),
  albumIsGrid<bool>(),

  // Backup
  backupEnabled<bool>(),
  backupUseCellularForVideos<bool>(),
  backupUseCellularForPhotos<bool>(),
  backupRequireCharging<bool>(),
  backupTriggerDelay<int>(),
  backupSyncAlbums<bool>(),

  // Timeline
  timelineTilesPerRow<int>(),
  timelineGroupAssetsBy<GroupAssetsBy>(codec: EnumCodec(GroupAssetsBy.values)),
  timelineStorageIndicator<bool>(),

  // Log
  logLevel<LogLevel>(codec: EnumCodec(LogLevel.values)),

  // TV
  tvLayout<TvLayoutMode>(codec: EnumCodec(TvLayoutMode.values)),

  // Map
  mapShowFavoriteOnly<bool>(),
  mapRelativeDate<int>(),
  mapCustomFrom<DateTime?>(),
  mapCustomTo<DateTime?>(),
  mapIncludeArchived<bool>(),
  mapThemeMode<ThemeMode>(codec: EnumCodec(ThemeMode.values)),
  mapWithPartners<bool>(),

  // Cleanup
  cleanupKeepFavorites<bool>(),
  cleanupKeepMediaType<AssetKeepType>(codec: EnumCodec(AssetKeepType.values)),
  cleanupKeepAlbumIds<List<String>>(codec: ListCodec(PrimitiveCodec.string)),
  cleanupCutoffDaysAgo<int>(),
  cleanupDefaultsInitialized<bool>(),

  // Share
  shareFileType<ShareAssetType>(codec: EnumCodec(ShareAssetType.values)),

  // Slideshow
  slideshowRepeat<bool>(),
  slideshowDuration<int>(),
  slideshowLook<SlideshowLook>(codec: EnumCodec(SlideshowLook.values)),
  slideshowDirection<SlideshowDirection>(codec: EnumCodec(SlideshowDirection.values)),

  // Feature message
  featureMessageSeenRelease<SemVer>(codec: SemVerCodec()),

  // Uploads from the shares and the drone page: send the spheres of drones with an XMP sidecar that makes the server
  // show them as 360° (see NetworkUploadOptions.tagSpheres)
  uploadTagSpheres<bool>(),

  // Settings, Advanced, "DJI drones (experimental)", on by default: the DJI drone page of the Network shares (Android
  // phones)
  djiImportEnabled<bool>(),

  // Settings, Advanced, "DJI link diagnostics (experimental)", on by default: the DJI link page that reads a DJI
  // remote controller plugged in as a USB accessory (Android phones and the Meta Quest build, not the TV layout)
  djiLinkEnabled<bool>(),

  // The AI features (relief estimated by AI), experimental and on by default, see AiImmersiveConfig
  aiImmersiveEnabled<bool>(),
  // "AI relief on Quest 2 and Quest Pro (untested)", off by default
  aiImmersiveOlderHeadsets<bool>(),
  // How the immersive viewer of the Meta Quest first shows an AI relief: stereo by default, 2.5D (experimental) when
  // "Open AI reliefs in 2.5D" is on, see AiImmersiveConfig.questMode
  aiReliefQuestMode<ReliefViewMode>(codec: EnumCodec(ReliefViewMode.values));

  final ValueCodec<T>? _codecOverride;

  const SettingsKey({ValueCodec<T>? codec}) : _codecOverride = codec;

  ValueCodec<T> get _codec => _codecOverride ?? ValueCodec.forType(T);

  String encode(T value) => _codec.encode(value);

  T decode(String raw) => _codec.decode(raw);
}
