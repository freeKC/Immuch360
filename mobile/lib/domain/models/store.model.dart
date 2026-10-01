import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:immich_mobile/domain/models/user.model.dart';

part 'store.model.freezed.dart';

/// Key for each possible value in the `Store`.
/// Defines the data type for each value
enum StoreKey<T> {
  version<int>._(0),
  currentUser<UserDto>._(2),
  deviceId<String>._(4),
  serverUrl<String>._(10),
  accessToken<String>._(11),
  serverEndpoint<String>._(12),
  advancedTroubleshooting<bool>._(114),
  enableHapticFeedback<bool>._(126),

  manageLocalMediaAndroid<bool>._(137),
  // Read-only Mode settings
  readonlyModeEnabled<bool>._(138),

  syncMigrationStatus<String>._(1013),

  // Keys of this fork start at 5000, away from the ranges upstream uses (0 to 16, 100 to 141, 1000 to 1013)
  /// Stereo layout the user picked in the Spatial 2.5D player, per asset: a JSON map from the asset id (the server
  /// id when there is one, else the id on the device) to a SpatialStereoLayout name
  spatialLayoutOverrides<String>._(5000),

  /// Assets the user chose to view as 360° although the server does not flag them: a JSON list of asset keys, the
  /// same as for the stereo layouts above, the latest choice last
  forcedPanoramaAssets<String>._(5001),

  /// Coverage of the sphere the user picked in a 360° viewer, per asset: a JSON map from the asset key, the same as
  /// for the stereo layouts above, to a SphereCoverage name ("full" or "half"), the latest choice last
  sphereCoverageOverrides<String>._(5002),

  // Legacy keys that have been migrated to the new metadata store
  legacyBackupRequireCharging<bool>._(7),
  legacyBackupTriggerDelay<int>._(8),
  legacySyncAlbums<bool>._(131),
  legacyEnableBackup<bool>._(1003),
  legacyUseWifiForUploadVideos<bool>._(1004),
  legacyUseWifiForUploadPhotos<bool>._(1005),
  legacySelectedAlbumSortOrder<int>._(113),
  legacySelectedAlbumSortReverse<bool>._(123),
  legacyAlbumGridView<bool>._(140),
  legacyAutoEndpointSwitching<bool>._(132),
  legacyPreferredWifiName<String>._(133),
  legacyLocalEndpoint<String>._(134),
  legacyExternalEndpointList<String>._(135),
  legacyCustomHeaders<String>._(127),
  legacyLoopVideo<bool>._(117),
  legacyLoadOriginalVideo<bool>._(136),
  legacyAutoPlayVideo<bool>._(139),
  legacyTapToNavigate<bool>._(141),
  legacyPreferRemoteImage<bool>._(116),
  legacyLoadOriginal<bool>._(101),
  legacyPrimaryColor<String>._(128),
  legacyDynamicTheme<bool>._(129),
  legacyColorfulInterface<bool>._(130),
  legacyThemeMode<String>._(102),
  legacyCleanupKeepFavorites<bool>._(1008),
  legacyCleanupKeepMediaType<int>._(1009),
  legacyCleanupKeepAlbumIds<String>._(1010),
  legacyCleanupCutoffDaysAgo<int>._(1011),
  legacyCleanupDefaultsInitialized<bool>._(1012),
  legacyTilesPerRow<int>._(103),
  legacyGroupAssetsBy<int>._(105),
  legacyStorageIndicator<bool>._(109),
  legacyMapRelativeDate<int>._(119),
  legacyMapShowFavoriteOnly<bool>._(118),
  legacyMapIncludeArchived<bool>._(121),
  legacyMapThemeMode<int>._(124),
  legacyMapwithPartners<bool>._(125),
  legacyLogLevel<int>._(115);

  const StoreKey._(this.id);
  final int id;
  Type get type => T;
}

@freezed
abstract class StoreDto<T> with _$StoreDto<T> {
  const factory StoreDto(StoreKey<T> key, T? value) = _StoreDto<T>;
}
