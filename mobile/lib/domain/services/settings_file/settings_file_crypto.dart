// The encryption of an accounts level settings file: AES-256-GCM under a key derived from the passphrase by Argon2id
// (RFC 9106), both from pointycastle (MIT), which the app already uses for the pairing, the Play on links and the Tapo
// cameras. The derivation takes about 0.2 s on a computer and runs in an isolate, so the screen keeps moving.

import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/settings_file/settings_file.dart';
import 'package:pointycastle/export.dart';

/// The shortest passphrase the export accepts
const settingsFileMinPassphraseLength = 8;

/// Seals [content] in a new accounts level file. [kdf] and [nonce] are for the tests; a random salt and nonce
/// otherwise.
Future<SettingsFile> sealSettingsFile({
  required SettingsFileContent content,
  required String passphrase,
  required SettingsFileOrigin origin,
  required DateTime createdAt,
  SettingsFileKdf? kdf,
  List<int>? nonce,
}) async {
  final usedKdf = kdf ?? SettingsFileKdf(salt: _randomBytes(16));
  final usedNonce = nonce ?? _randomBytes(12);
  final key = await deriveSettingsFileKey(passphrase, usedKdf);
  final plaintext = utf8.encode(jsonEncode(content.toJson()));
  final aad = SettingsFile.associatedData(SettingsFile.currentVersion, SettingsFileLevel.accounts, createdAt);
  final ciphertext = _gcm(true, key, usedNonce, aad, plaintext);
  return SettingsFile(
    origin: origin,
    createdAt: createdAt,
    level: SettingsFileLevel.accounts,
    sealed: SettingsFileSealed(kdf: usedKdf, nonce: usedNonce, ciphertext: ciphertext),
  );
}

/// The content of [file]: as it is for a settings level file, decrypted with [passphrase] for an accounts level one.
/// Throws [SettingsFileException] with [SettingsFileError.wrongPassphrase] when the passphrase (or the header) does
/// not match, [SettingsFileError.damaged] when the decrypted content does not read.
Future<SettingsFileContent> openSettingsFile(SettingsFile file, {String? passphrase}) async {
  final content = file.content;
  if (content != null) {
    return content;
  }
  final sealed = file.sealed!;
  if (passphrase == null || passphrase.isEmpty) {
    throw const SettingsFileException(SettingsFileError.wrongPassphrase);
  }
  final key = await deriveSettingsFileKey(passphrase, sealed.kdf);
  final aad = SettingsFile.associatedData(file.version, file.level, file.createdAt);
  final List<int> plaintext;
  try {
    plaintext = _gcm(false, key, sealed.nonce, aad, sealed.ciphertext);
  } on InvalidCipherTextException {
    throw const SettingsFileException(SettingsFileError.wrongPassphrase);
  } on ArgumentError {
    throw const SettingsFileException(SettingsFileError.wrongPassphrase);
  }
  final Object? json;
  try {
    json = jsonDecode(utf8.decode(plaintext));
  } on FormatException {
    throw const SettingsFileException(SettingsFileError.damaged, 'decrypted content');
  }
  return SettingsFileContent.fromJson(json);
}

/// The 32 byte key of [passphrase] (its UTF-8 bytes, as typed) under [kdf], computed in an isolate
Future<Uint8List> deriveSettingsFileKey(String passphrase, SettingsFileKdf kdf) {
  final salt = Uint8List.fromList(kdf.salt);
  final memory = kdf.memoryKiB;
  final iterations = kdf.iterations;
  final lanes = kdf.parallelism;
  return Isolate.run(() => deriveSettingsFileKeySync(passphrase, salt, memory, iterations, lanes));
}

/// The derivation itself, for [deriveSettingsFileKey] and the tests
Uint8List deriveSettingsFileKeySync(String passphrase, Uint8List salt, int memoryKiB, int iterations, int lanes) {
  final generator = Argon2BytesGenerator()
    ..init(
      Argon2Parameters(
        Argon2Parameters.ARGON2_id,
        salt,
        desiredKeyLength: 32,
        iterations: iterations,
        memory: memoryKiB,
        lanes: lanes,
        version: Argon2Parameters.ARGON2_VERSION_13,
      ),
    );
  final key = Uint8List(32);
  generator.deriveKey(Uint8List.fromList(utf8.encode(passphrase)), 0, key, 0);
  return key;
}

Uint8List _gcm(bool encrypt, Uint8List key, List<int> nonce, List<int> aad, List<int> input) {
  final cipher = GCMBlockCipher(AESEngine())
    ..init(encrypt, AEADParameters(KeyParameter(key), 128, Uint8List.fromList(nonce), Uint8List.fromList(aad)));
  return cipher.process(Uint8List.fromList(input));
}

Uint8List _randomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
}
