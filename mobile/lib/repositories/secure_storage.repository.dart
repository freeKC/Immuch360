import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/platform/linux_secret_storage.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';

final secureStorageRepositoryProvider = Provider(
  (ref) => const SecureStorageRepository(SecureStorageRepository.storage),
);

class SecureStorageRepository {
  final FlutterSecureStorage _secureStorage;

  const SecureStorageRepository(this._secureStorage);

  /// The plugin as the app uses it. Only the macOS options differ from the plugin's defaults, so Android, iOS, Windows
  /// and Linux keep their secrets where they always were.
  static const storage = FlutterSecureStorage(mOptions: macOsOptions);

  /// Immuch360 Desktop on macOS keeps its secrets in the login keychain of the user (the file based keychain), not in
  /// the data protection keychain that flutter_secure_storage 9 picks by default: that one is open only to an app
  /// signed by a team with a keychain access group in its entitlements, and refuses the builds of the CI, which are
  /// signed for the computer that runs them only, with errSecMissingEntitlement (-34018). So the server token and the
  /// share passwords could not be saved. A build signed with a Developer ID and a keychain access group may move to
  /// the data protection keychain with --dart-define=IMMUCH360_MACOS_DATA_PROTECTION_KEYCHAIN=true; the secrets the
  /// login keychain holds are not moved, so the user signs in again once.
  ///
  /// After an update macOS may ask for the user's password before the new build reads an item the old one saved: a
  /// build signed for the computer only is another program for the keychain. "Always Allow" keeps the answer until
  /// the next update.
  static const macOsOptions = MacOsOptions(
    useDataProtectionKeyChain: bool.fromEnvironment('IMMUCH360_MACOS_DATA_PROTECTION_KEYCHAIN'),
  );

  /// A secret kept on this device only: out of iCloud and of the device to device backups, and readable once the
  /// device was unlocked after its start, so that a playback or a fetch going on while the phone locks can connect
  /// again. Android keeps every secret out of the backups already (allowBackup is false).
  static const _deviceOnly = IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device);

  /// The plugin; on Linux behind the store of the session (lib/desktop/platform/linux_secret_storage.dart), which uses
  /// the keyring when one answers and the memory of the session otherwise, in every isolate
  FlutterSecureStorage get _storage {
    if (CurrentPlatform.isLinux) {
      LinuxSecretStorage.install();
    }
    return _secureStorage;
  }

  Future<String?> read(String key) {
    return _storage.read(key: key);
  }

  /// [deviceOnly]: see [_deviceOnly]
  Future<void> write(String key, String value, {bool deviceOnly = false}) {
    if (deviceOnly) {
      return _storage.write(key: key, value: value, iOptions: _deviceOnly);
    }
    return _storage.write(key: key, value: value);
  }

  /// [deviceOnly] must be what the key was written with: the iOS delete of the plugin (flutter_secure_storage 9.2.4,
  /// FlutterSecureStorage.swift) looks for the item with that accessibility, so an item written with one accessibility
  /// and deleted with another stays in the Keychain
  Future<void> delete(String key, {bool deviceOnly = false}) {
    if (deviceOnly) {
      return _storage.delete(key: key, iOptions: _deviceOnly);
    }
    return _storage.delete(key: key);
  }
}
