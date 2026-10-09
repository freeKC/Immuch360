import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Seals and opens the bytes of the store: DPAPI on Windows ([DpapiCipher]), anything reversible in the tests
abstract interface class SecretCipher {
  Uint8List protect(Uint8List plain);

  /// Throws when [sealed] cannot be opened (another account, damaged bytes)
  Uint8List unprotect(Uint8List sealed);
}

/// The secrets of the app in one sealed file of [directory]: a JSON map from the keys the app uses to their values.
///
/// Each operation reads the file again under an exclusive lock file, so that two isolates (or two windows of the app)
/// never write over each other's changes; the operations of one isolate also run one after the other.
class SecretFileStore {
  SecretFileStore({
    required Future<Directory> Function() directory,
    required SecretCipher cipher,
    DateTime Function()? clock,
  }) : _directory = directory,
       _cipher = cipher,
       _clock = clock ?? DateTime.now;

  static const fileName = 'secure_storage.dat';
  static const _lockName = 'secure_storage.lock';
  static const _version = 1;

  final Future<Directory> Function() _directory;
  final SecretCipher _cipher;
  final DateTime Function() _clock;

  Future<void> _queue = Future.value();

  Future<String?> read(String key) => _locked((values) async => values[key]);

  Future<bool> containsKey(String key) => _locked((values) async => values.containsKey(key));

  Future<Map<String, String>> readAll() => _locked((values) async => Map.of(values));

  Future<void> write(String key, String value) => _locked((values) async {
    if (values[key] == value) {
      return;
    }
    await _save({...values, key: value});
  });

  Future<void> delete(String key) => _locked((values) async {
    if (!values.containsKey(key)) {
      return;
    }
    await _save({...values}..remove(key));
  });

  Future<void> deleteAll() => _locked((values) async {
    final file = await _file();
    if (await file.exists()) {
      await file.delete();
    }
  });

  Future<File> _file() async => File(p.join((await _directory()).path, fileName));

  /// Runs [action] on the stored values, after the operations already asked in this isolate and under the lock file
  Future<T> _locked<T>(Future<T> Function(Map<String, String> values) action) {
    final result = _queue.then((_) async {
      final folder = await _directory();
      await folder.create(recursive: true);
      final lock = await File(p.join(folder.path, _lockName)).open(mode: FileMode.write);
      try {
        await lock.lock(FileLock.blockingExclusive);
        return await action(await _load());
      } finally {
        await lock.close();
      }
    });
    // The next operation waits for this one, whether it succeeds or not
    _queue = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Future<Map<String, String>> _load() async {
    final file = await _file();
    if (!await file.exists()) {
      return const {};
    }
    // A read error of the disk is not an empty store: the next write would lose every secret
    final sealed = await file.readAsBytes();
    try {
      return decode(_cipher.unprotect(sealed));
    } on Object {
      // Sealed by another account, or damaged: kept aside for a look, and the app starts again without secrets
      final aside = '${file.path}.unreadable-${_clock().millisecondsSinceEpoch}';
      await file.rename(aside);
      return const {};
    }
  }

  Future<void> _save(Map<String, String> values) async {
    final file = await _file();
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(_cipher.protect(encode(values)), flush: true);
    await temporary.rename(file.path);
  }

  /// The plain bytes of [values], before sealing
  static Uint8List encode(Map<String, String> values) =>
      utf8.encode(jsonEncode({'version': _version, 'values': values}));

  /// [values] from the plain bytes; throws on anything else
  static Map<String, String> decode(Uint8List plain) {
    final json = jsonDecode(utf8.decode(plain));
    if (json is! Map<String, dynamic> || json['version'] != _version || json['values'] is! Map<String, dynamic>) {
      throw const FormatException('Not a secure storage file');
    }
    return {
      for (final MapEntry(:key, :value) in (json['values'] as Map<String, dynamic>).entries) key: value as String,
    };
  }
}
