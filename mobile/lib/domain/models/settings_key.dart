import 'package:flutter/material.dart';
import 'package:immich_mobile/constants/colors.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/ai_immersive/relief_strength.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_pair_requests.dart';
import 'package:immich_mobile/domain/models/film_player_preference.dart';
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
  // "Remember where I stopped" and its threshold in minutes, see ViewerConfig.resumeVideos and WatchRule
  viewerResumeVideos<bool>(),
  viewerResumeMinMinutes<int>(),
  viewerLoadOriginalVideo<bool>(),
  viewerAutoPlayVideo<bool>(),
  viewerTapToNavigate<bool>(),
  // The date and time of a photo at the bottom left with the controls on a TV, see ViewerConfig.tvShowDateTime
  viewerTvShowDateTime<bool>(),
  viewerSpatial25d<bool>(),
  // The stabilisation of the raw 360° videos with the motion track of their camera, see ViewerConfig.stabilizeVideos
  viewerStabilizeVideos<bool>(),
  // The right thumbstick of the Meta Quest immersive viewer turns the other way, see ViewerConfig.reverseThumbstickTurn
  viewerReverseThumbstickTurn<bool>(),
  // The flat 3D media told by their file name in the Meta Quest immersive viewer, see ViewerConfig.flat3dByName
  viewerFlat3dByName<bool>(),
  // The compositor layer and its filters on the flat screens of the Meta Quest immersive viewer, see
  // ViewerConfig.sharpFlatScreens
  viewerSharpFlatScreens<bool>(),
  // The Gaussian splat files of other tools on a Meta Quest 3 or 3S, see ViewerConfig.gaussianSplats and largeSplats
  viewerGaussianSplats<bool>(),
  viewerLargeSplats<bool>(),
  // The dedicated graphics chip of a Windows computer with two, for the splat viewer: ViewerConfig.highPerformanceGpu
  viewerHighPerformanceGpu<bool>(),
  // Every gaussian of a splat on a computer whose graphics chip shares its memory: ViewerConfig.keepAllGaussians
  viewerKeepAllGaussians<bool>(),
  // The 3D sign in the photo of a splat scene saved to Immich: ViewerConfig.markSplatPhotos
  viewerMarkSplatPhotos<bool>(),
  // The AV2 videos of the computers, decoded by the processor, see ViewerConfig.av2Videos
  viewerAv2Videos<bool>(),
  // Null until the user picks a source: viewerLoadOriginalVideo tells it until then, see ViewerConfig.videoSource
  viewerVideoSource<VideoSourcePolicy?>(codec: EnumCodec<VideoSourcePolicy>(VideoSourcePolicy.values)),
  // The Wikipedia block of the film page of a Plex film, see ViewerConfig.filmWikipedia
  viewerFilmWikipedia<bool>(),
  // The player of a Plex film and the server's conversion of what the device cannot play, see ViewerConfig.filmPlayer
  // and ViewerConfig.plexConversion
  viewerFilmPlayer<FilmPlayerPreference>(codec: EnumCodec(FilmPlayerPreference.values)),
  viewerPlexConversion<bool>(),

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
  timelineSmoothScrubbing<bool>(),

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
  aiReliefQuestMode<ReliefViewMode>(codec: EnumCodec(ReliefViewMode.values)),
  // "Relief strength" of the AI reliefs of the Meta Quest: Normal by default, the parallax of every earlier version,
  // see AiImmersiveConfig.questStrength
  aiReliefStrength<ReliefStrength>(codec: EnumCodec(ReliefStrength.values)),

  // Settings, Advanced, "Kiosk mode (experimental)" of the Meta Quest, see KioskConfig: the switch, on by default; the
  // media the app opens at its start (KioskMedia.encode, none by default: the app starts as usual); the end card text
  kioskEnabled<bool>(),
  kioskMedia<String?>(),
  kioskEndText<String?>();

  final ValueCodec<T>? _codecOverride;

  const SettingsKey({ValueCodec<T>? codec}) : _codecOverride = codec;

  ValueCodec<T> get _codec => _codecOverride ?? ValueCodec.forType(T);

  String encode(T value) => _codec.encode(value);

  T decode(String raw) => _codec.decode(raw);
}
