import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/repositories/secure_storage.repository.dart';

final secureStorageServiceProvider = Provider(
  (ref) => SecureStorageService(ref.watch(secureStorageRepositoryProvider)),
);

class SecureStorageService {
  final SecureStorageRepository _secureStorageRepository;

  const SecureStorageService(this._secureStorageRepository);

  /// [deviceOnly]: a secret kept on this device only, see SecureStorageRepository.write
  Future<void> write(String key, String value, {bool deviceOnly = false}) async {
    await _secureStorageRepository.write(key, value, deviceOnly: deviceOnly);
  }

  /// [deviceOnly] must be what the key was written with, see SecureStorageRepository.delete
  Future<void> delete(String key, {bool deviceOnly = false}) async {
    await _secureStorageRepository.delete(key, deviceOnly: deviceOnly);
  }

  Future<String?> read(String key) async {
    return _secureStorageRepository.read(key);
  }
}
