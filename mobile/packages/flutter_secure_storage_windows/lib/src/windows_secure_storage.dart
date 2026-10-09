import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:path_provider/path_provider.dart';

import 'dpapi.dart';
import 'secret_file_store.dart';

/// flutter_secure_storage on Windows for Immuch360 Desktop: the secrets in a DPAPI sealed file of the app's support
/// folder (see IMMUCH360-NOTE.md). Registered by Flutter on Windows as the plugin's Dart class.
class FlutterSecureStorageWindows extends FlutterSecureStoragePlatform {
  FlutterSecureStorageWindows({SecretFileStore? store})
    : _store = store ?? SecretFileStore(directory: getApplicationSupportDirectory, cipher: const DpapiCipher());

  final SecretFileStore _store;

  /// Called by the plugin registrant of a Windows build
  static void registerWith() {
    FlutterSecureStoragePlatform.instance = FlutterSecureStorageWindows();
  }

  @override
  Future<void> write({required String key, required String value, required Map<String, String> options}) =>
      _store.write(key, value);

  @override
  Future<String?> read({required String key, required Map<String, String> options}) => _store.read(key);

  @override
  Future<bool> containsKey({required String key, required Map<String, String> options}) => _store.containsKey(key);

  @override
  Future<void> delete({required String key, required Map<String, String> options}) => _store.delete(key);

  @override
  Future<Map<String, String>> readAll({required Map<String, String> options}) => _store.readAll();

  @override
  Future<void> deleteAll({required Map<String, String> options}) => _store.deleteAll();
}
