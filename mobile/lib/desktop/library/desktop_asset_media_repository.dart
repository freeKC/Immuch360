import 'package:immich_mobile/repositories/asset_media.repository.dart';

/// The local media operations on the computers. The phone repository asks photo_manager, which has no Windows or
/// Linux implementation: the name of a file of the folder library is its asset name already, and the files of the
/// user are never deleted by the app until they can go to the system's trash.
class DesktopAssetMediaRepository extends AssetMediaRepository {
  const DesktopAssetMediaRepository(super.nativeSyncApi, super.storageRepository);

  /// Null: the callers fall back to the asset name, which is the file name on a computer
  @override
  Future<String?> getOriginalFilename(String id) async => null;

  /// Nothing is deleted on a computer
  @override
  Future<List<String>> deleteAll(List<String> ids, {bool trash = true}) async => const [];
}
