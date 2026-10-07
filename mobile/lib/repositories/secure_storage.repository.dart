import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

final secureStorageRepositoryProvider = Provider((ref) => const SecureStorageRepository(FlutterSecureStorage()));

class SecureStorageRepository {
  final FlutterSecureStorage _secureStorage;

  const SecureStorageRepository(this._secureStorage);

  /// A secret kept on this device only: out of iCloud and of the device to device backups, and readable once the
  /// device was unlocked after its start, so that a playback or a fetch going on while the phone locks can connect
  /// again. Android keeps every secret out of the backups already (allowBackup is false).
  static const _deviceOnly = IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device);

  Future<String?> read(String key) {
    return _secureStorage.read(key: key);
  }

  /// [deviceOnly]: see [_deviceOnly]
  Future<void> write(String key, String value, {bool deviceOnly = false}) {
    if (deviceOnly) {
      return _secureStorage.write(key: key, value: value, iOptions: _deviceOnly);
    }
    return _secureStorage.write(key: key, value: value);
  }

  /// [deviceOnly] must be what the key was written with: the iOS delete of the plugin (flutter_secure_storage 9.2.4,
  /// FlutterSecureStorage.swift) looks for the item with that accessibility, so an item written with one accessibility
  /// and deleted with another stays in the Keychain
  Future<void> delete(String key, {bool deviceOnly = false}) {
    if (deviceOnly) {
      return _secureStorage.delete(key: key, iOptions: _deviceOnly);
    }
    return _secureStorage.delete(key: key);
  }
}
