// SHA-1 of the files of the folder library, the checksum the Immich server deduplicates uploads by, computed by the
// operating system. A folder of 360° footage runs to 100 GB per hour of an Insta360 X4, and package:crypto gave 14 to
// 15 MB/s on a development PC against 164 MB/s for "openssl sha1" on the same machine: one hour of footage would take
// almost two hours to hash in Dart. So the digest comes from the system's own library through dart:ffi, without a plugin:
//  - Windows: CNG in bcrypt.dll (BCryptOpenAlgorithmProvider, BCryptCreateHash, BCryptHashData, BCryptFinishHash);
//  - Linux: libcrypto's EVP digest functions (OpenSSL 3 or 1.1);
//  - macOS: CommonCrypto in libSystem (CC_SHA1_Init, CC_SHA1_Update, CC_SHA1_Final).
// package:crypto stays as the fallback when none of them loads. The file is read in 1 MiB chunks straight into a
// native buffer, which the digest reads without a copy.
//
// The file is read through a SharedFileReader (shared_file.dart): while a 4 GB video was hashed, Explorer could not
// rename, move or delete it or its folder through dart:io's way of opening files on Windows.
//
// The result is base64, as the phones give it (MessageDigest SHA-1 then Base64.NO_WRAP on Android).

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:ffi/ffi.dart';
import 'package:immich_mobile/desktop/library/shared_file.dart';

/// Bytes read at once while hashing
const sha1ChunkLength = 1024 * 1024;

/// A running SHA-1 over native memory
abstract class Sha1Digest {
  void update(Pointer<Uint8> data, int length);

  /// The 20 bytes of the digest; the digest cannot be used afterwards
  Uint8List finish();

  /// Releases the digest without finishing it (an error or a cancel)
  void discard();
}

/// Makes digests; one per isolate, since the native handles are not shared between isolates
abstract class Sha1Engine {
  /// "cng", "libcrypto", "commoncrypto" or "dart"
  String get name;

  Sha1Digest start();

  /// Releases what the engine holds (the CNG algorithm provider); no digest may be started afterwards
  void close();

  /// The engine of the operating system, or package:crypto when no system library loads, kept for the isolate
  static Sha1Engine system() => _system ??= open();

  static Sha1Engine? _system;

  /// A new engine of the operating system, for an isolate that ends after its work and closes it
  static Sha1Engine open() => _loadSystemEngine() ?? const DartSha1Engine();

  static Sha1Engine? _loadSystemEngine() {
    try {
      if (Platform.isWindows) {
        return CngSha1Engine();
      }
      if (Platform.isLinux) {
        return LibcryptoSha1Engine.load();
      }
      if (Platform.isMacOS) {
        return CommonCryptoSha1Engine();
      }
    } on Object {
      // ArgumentError of a missing library or symbol: the Dart fallback
    }
    return null;
  }
}

/// SHA-1 of the file at [path] in base64. [isCancelled] is asked between chunks; a cancel throws [Sha1Cancelled].
String sha1OfFile(String path, {Sha1Engine? engine, bool Function()? isCancelled}) {
  final file = SharedFileReader.open(path);
  final buffer = malloc<Uint8>(sha1ChunkLength);
  try {
    final digest = (engine ?? Sha1Engine.system()).start();
    var finished = false;
    try {
      while (true) {
        if (isCancelled?.call() ?? false) {
          throw const Sha1Cancelled();
        }
        final read = file.readInto(buffer, sha1ChunkLength);
        if (read <= 0) {
          break;
        }
        digest.update(buffer, read);
      }
      finished = true;
      return base64.encode(digest.finish());
    } finally {
      if (!finished) {
        digest.discard();
      }
    }
  } finally {
    malloc.free(buffer);
    file.close();
  }
}

/// Thrown by [sha1OfFile] when asked to stop
class Sha1Cancelled implements Exception {
  const Sha1Cancelled();
}

// --- package:crypto --------------------------------------------------------------------------------------------------

/// The fallback, and the reference of the tests
class DartSha1Engine implements Sha1Engine {
  const DartSha1Engine();

  @override
  String get name => 'dart';

  @override
  Sha1Digest start() => _DartSha1Digest();

  @override
  void close() {}
}

class _DartSha1Digest implements Sha1Digest {
  _DartSha1Digest() {
    _input = crypto.sha1.startChunkedConversion(_output);
  }

  final _output = AccumulatorSink<crypto.Digest>();
  late final ByteConversionSink _input;

  @override
  void update(Pointer<Uint8> data, int length) => _input.add(Uint8List.fromList(data.asTypedList(length)));

  @override
  Uint8List finish() {
    _input.close();
    _output.close();
    return Uint8List.fromList(_output.events.single.bytes);
  }

  @override
  void discard() {
    _input.close();
    _output.close();
  }
}

/// Collects what a chunked conversion gives
class AccumulatorSink<T> implements Sink<T> {
  final events = <T>[];

  @override
  void add(T event) => events.add(event);

  @override
  void close() {}
}

// --- Windows CNG -----------------------------------------------------------------------------------------------------

typedef _OpenAlgorithmNative = Int32 Function(Pointer<Pointer<Void>>, Pointer<Utf16>, Pointer<Utf16>, Uint32);
typedef _OpenAlgorithm = int Function(Pointer<Pointer<Void>>, Pointer<Utf16>, Pointer<Utf16>, int);
typedef _CreateHashNative =
    Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>, Pointer<Uint8>, Uint32, Pointer<Uint8>, Uint32, Uint32);
typedef _CreateHash =
    int Function(Pointer<Void>, Pointer<Pointer<Void>>, Pointer<Uint8>, int, Pointer<Uint8>, int, int);
typedef _HashDataNative = Int32 Function(Pointer<Void>, Pointer<Uint8>, Uint32, Uint32);
typedef _HashData = int Function(Pointer<Void>, Pointer<Uint8>, int, int);
typedef _FinishHashNative = Int32 Function(Pointer<Void>, Pointer<Uint8>, Uint32, Uint32);
typedef _FinishHash = int Function(Pointer<Void>, Pointer<Uint8>, int, int);
typedef _DestroyHashNative = Int32 Function(Pointer<Void>);
typedef _DestroyHash = int Function(Pointer<Void>);
typedef _CloseAlgorithmNative = Int32 Function(Pointer<Void>, Uint32);
typedef _CloseAlgorithm = int Function(Pointer<Void>, int);

/// SHA-1 by Windows CNG. The algorithm provider is opened once, which is the costly part, and kept for the isolate;
/// each file gets its own hash object, whose memory CNG allocates itself (a null buffer, Windows 7 and later).
class CngSha1Engine implements Sha1Engine {
  CngSha1Engine() {
    final bcrypt = DynamicLibrary.open('bcrypt.dll');
    final open = bcrypt.lookupFunction<_OpenAlgorithmNative, _OpenAlgorithm>('BCryptOpenAlgorithmProvider');
    _createHash = bcrypt.lookupFunction<_CreateHashNative, _CreateHash>('BCryptCreateHash');
    _hashData = bcrypt.lookupFunction<_HashDataNative, _HashData>('BCryptHashData');
    _finishHash = bcrypt.lookupFunction<_FinishHashNative, _FinishHash>('BCryptFinishHash');
    _destroyHash = bcrypt.lookupFunction<_DestroyHashNative, _DestroyHash>('BCryptDestroyHash');
    _closeAlgorithm = bcrypt.lookupFunction<_CloseAlgorithmNative, _CloseAlgorithm>('BCryptCloseAlgorithmProvider');
    _algorithm = using((arena) {
      final handle = arena<Pointer<Void>>();
      final status = open(handle, 'SHA1'.toNativeUtf16(allocator: arena), nullptr, 0);
      if (status != 0) {
        throw ArgumentError('BCryptOpenAlgorithmProvider failed: 0x${status.toUnsigned(32).toRadixString(16)}');
      }
      return handle.value;
    });
  }

  late final Pointer<Void> _algorithm;
  late final _CreateHash _createHash;
  late final _HashData _hashData;
  late final _FinishHash _finishHash;
  late final _DestroyHash _destroyHash;
  late final _CloseAlgorithm _closeAlgorithm;

  @override
  String get name => 'cng';

  @override
  void close() => _closeAlgorithm(_algorithm, 0);

  @override
  Sha1Digest start() {
    final handle = calloc<Pointer<Void>>();
    try {
      final status = _createHash(_algorithm, handle, nullptr, 0, nullptr, 0, 0);
      if (status != 0) {
        throw StateError('BCryptCreateHash failed: 0x${status.toUnsigned(32).toRadixString(16)}');
      }
      return _CngDigest(this, handle.value);
    } finally {
      calloc.free(handle);
    }
  }
}

class _CngDigest implements Sha1Digest {
  const _CngDigest(this._engine, this._hash);

  final CngSha1Engine _engine;
  final Pointer<Void> _hash;

  @override
  void update(Pointer<Uint8> data, int length) {
    final status = _engine._hashData(_hash, data, length, 0);
    if (status != 0) {
      throw StateError('BCryptHashData failed: 0x${status.toUnsigned(32).toRadixString(16)}');
    }
  }

  @override
  Uint8List finish() {
    final output = malloc<Uint8>(20);
    try {
      final status = _engine._finishHash(_hash, output, 20, 0);
      if (status != 0) {
        throw StateError('BCryptFinishHash failed: 0x${status.toUnsigned(32).toRadixString(16)}');
      }
      return Uint8List.fromList(output.asTypedList(20));
    } finally {
      malloc.free(output);
      _engine._destroyHash(_hash);
    }
  }

  @override
  void discard() => _engine._destroyHash(_hash);
}

// --- Linux libcrypto -------------------------------------------------------------------------------------------------

typedef _CtxNewNative = Pointer<Void> Function();
typedef _CtxFreeNative = Void Function(Pointer<Void>);
typedef _CtxFree = void Function(Pointer<Void>);
typedef _Sha1MdNative = Pointer<Void> Function();
typedef _DigestInitNative = Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef _DigestInit = int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef _DigestUpdateNative = Int32 Function(Pointer<Void>, Pointer<Uint8>, Size);
typedef _DigestUpdate = int Function(Pointer<Void>, Pointer<Uint8>, int);
typedef _DigestFinalNative = Int32 Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint32>);
typedef _DigestFinal = int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint32>);

/// SHA-1 by OpenSSL's libcrypto, through its EVP functions, which OpenSSL 1.1 and 3 both export
class LibcryptoSha1Engine implements Sha1Engine {
  LibcryptoSha1Engine._(DynamicLibrary library)
    : _newContext = library.lookupFunction<_CtxNewNative, _CtxNewNative>('EVP_MD_CTX_new'),
      _freeContext = library.lookupFunction<_CtxFreeNative, _CtxFree>('EVP_MD_CTX_free'),
      _sha1 = library.lookupFunction<_Sha1MdNative, _Sha1MdNative>('EVP_sha1'),
      _init = library.lookupFunction<_DigestInitNative, _DigestInit>('EVP_DigestInit_ex'),
      _update = library.lookupFunction<_DigestUpdateNative, _DigestUpdate>('EVP_DigestUpdate'),
      _final = library.lookupFunction<_DigestFinalNative, _DigestFinal>('EVP_DigestFinal_ex');

  /// The first libcrypto that loads: OpenSSL 3, 1.1, then the development link
  factory LibcryptoSha1Engine.load() {
    for (final name in const ['libcrypto.so.3', 'libcrypto.so.1.1', 'libcrypto.so']) {
      try {
        return LibcryptoSha1Engine._(DynamicLibrary.open(name));
      } on ArgumentError {
        continue;
      }
    }
    throw ArgumentError('No libcrypto');
  }

  final Pointer<Void> Function() _newContext;
  final _CtxFree _freeContext;
  final Pointer<Void> Function() _sha1;
  final _DigestInit _init;
  final _DigestUpdate _update;
  final _DigestFinal _final;

  @override
  String get name => 'libcrypto';

  @override
  void close() {}

  @override
  Sha1Digest start() {
    final context = _newContext();
    if (context == nullptr) {
      throw StateError('EVP_MD_CTX_new failed');
    }
    if (_init(context, _sha1(), nullptr) != 1) {
      _freeContext(context);
      throw StateError('EVP_DigestInit_ex failed');
    }
    return _LibcryptoDigest(this, context);
  }
}

class _LibcryptoDigest implements Sha1Digest {
  const _LibcryptoDigest(this._engine, this._context);

  final LibcryptoSha1Engine _engine;
  final Pointer<Void> _context;

  @override
  void update(Pointer<Uint8> data, int length) {
    if (_engine._update(_context, data, length) != 1) {
      throw StateError('EVP_DigestUpdate failed');
    }
  }

  @override
  Uint8List finish() {
    final output = malloc<Uint8>(64);
    final length = malloc<Uint32>();
    try {
      if (_engine._final(_context, output, length) != 1 || length.value != 20) {
        throw StateError('EVP_DigestFinal_ex failed');
      }
      return Uint8List.fromList(output.asTypedList(20));
    } finally {
      malloc
        ..free(output)
        ..free(length);
      _engine._freeContext(_context);
    }
  }

  @override
  void discard() => _engine._freeContext(_context);
}

// --- macOS CommonCrypto ----------------------------------------------------------------------------------------------

typedef _CcInitNative = Int32 Function(Pointer<Uint8>);
typedef _CcInit = int Function(Pointer<Uint8>);
typedef _CcUpdateNative = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Uint32);
typedef _CcUpdate = int Function(Pointer<Uint8>, Pointer<Uint8>, int);
typedef _CcFinalNative = Pointer<Uint8> Function(Pointer<Uint8>, Pointer<Uint8>);

// CC_SHA1_CTX is 96 bytes (five state words, two counters, sixteen data words, one int); more is harmless
const _ccContextLength = 128;

/// SHA-1 by CommonCrypto, part of libSystem, which every macOS process has loaded
class CommonCryptoSha1Engine implements Sha1Engine {
  CommonCryptoSha1Engine() : this._(DynamicLibrary.process());

  CommonCryptoSha1Engine._(DynamicLibrary library)
    : _init = library.lookupFunction<_CcInitNative, _CcInit>('CC_SHA1_Init'),
      _update = library.lookupFunction<_CcUpdateNative, _CcUpdate>('CC_SHA1_Update'),
      _final = library.lookupFunction<_CcFinalNative, _CcFinalNative>('CC_SHA1_Final');

  final _CcInit _init;
  final _CcUpdate _update;
  final Pointer<Uint8> Function(Pointer<Uint8>, Pointer<Uint8>) _final;

  @override
  String get name => 'commoncrypto';

  @override
  void close() {}

  @override
  Sha1Digest start() {
    final context = calloc<Uint8>(_ccContextLength);
    _init(context);
    return _CommonCryptoDigest(this, context);
  }
}

class _CommonCryptoDigest implements Sha1Digest {
  const _CommonCryptoDigest(this._engine, this._context);

  final CommonCryptoSha1Engine _engine;
  final Pointer<Uint8> _context;

  @override
  void update(Pointer<Uint8> data, int length) => _engine._update(_context, data, length);

  @override
  Uint8List finish() {
    final output = malloc<Uint8>(20);
    try {
      _engine._final(output, _context);
      return Uint8List.fromList(output.asTypedList(20));
    } finally {
      malloc.free(output);
      calloc.free(_context);
    }
  }

  @override
  void discard() => calloc.free(_context);
}
