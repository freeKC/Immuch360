import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'secret_file_store.dart';

/// DATA_BLOB of wincrypt.h
final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;

  external Pointer<Uint8> pbData;
}

typedef _CryptProtectDataNative =
    Int32 Function(
      Pointer<_DataBlob> dataIn,
      Pointer<Utf16> description,
      Pointer<_DataBlob> entropy,
      Pointer<Void> reserved,
      Pointer<Void> prompt,
      Uint32 flags,
      Pointer<_DataBlob> dataOut,
    );
typedef _CryptProtectData =
    int Function(
      Pointer<_DataBlob> dataIn,
      Pointer<Utf16> description,
      Pointer<_DataBlob> entropy,
      Pointer<Void> reserved,
      Pointer<Void> prompt,
      int flags,
      Pointer<_DataBlob> dataOut,
    );

typedef _CryptUnprotectDataNative =
    Int32 Function(
      Pointer<_DataBlob> dataIn,
      Pointer<Pointer<Utf16>> description,
      Pointer<_DataBlob> entropy,
      Pointer<Void> reserved,
      Pointer<Void> prompt,
      Uint32 flags,
      Pointer<_DataBlob> dataOut,
    );
typedef _CryptUnprotectData =
    int Function(
      Pointer<_DataBlob> dataIn,
      Pointer<Pointer<Utf16>> description,
      Pointer<_DataBlob> entropy,
      Pointer<Void> reserved,
      Pointer<Void> prompt,
      int flags,
      Pointer<_DataBlob> dataOut,
    );

typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void> memory);
typedef _LocalFree = Pointer<Void> Function(Pointer<Void> memory);

/// Seals with the Windows Data Protection API: only the same Windows account, on this computer or one its roaming
/// profile reaches, can open the bytes again. The entropy ties them to this app as well, so that another program of
/// the same account calling CryptUnprotectData on the file without it gets nothing.
class DpapiCipher implements SecretCipher {
  const DpapiCipher();

  /// CRYPTPROTECT_UI_FORBIDDEN: never a dialog, the store runs without the user
  static const _uiForbidden = 0x1;

  static final _entropy = utf8.encode('Immuch360 Desktop secure storage');

  static final _crypt32 = DynamicLibrary.open('crypt32.dll');
  static final _kernel32 = DynamicLibrary.open('kernel32.dll');
  static final _protect = _crypt32.lookupFunction<_CryptProtectDataNative, _CryptProtectData>('CryptProtectData');
  static final _unprotect = _crypt32.lookupFunction<_CryptUnprotectDataNative, _CryptUnprotectData>(
    'CryptUnprotectData',
  );
  static final _localFree = _kernel32.lookupFunction<_LocalFreeNative, _LocalFree>('LocalFree');

  @override
  Uint8List protect(Uint8List plain) => _run(plain, (input, entropy, output) {
    return _protect(input, nullptr, entropy, nullptr, nullptr, _uiForbidden, output);
  }, 'CryptProtectData');

  @override
  Uint8List unprotect(Uint8List sealed) => _run(sealed, (input, entropy, output) {
    return _unprotect(input, nullptr, entropy, nullptr, nullptr, _uiForbidden, output);
  }, 'CryptUnprotectData');

  static Uint8List _run(
    Uint8List bytes,
    int Function(Pointer<_DataBlob> input, Pointer<_DataBlob> entropy, Pointer<_DataBlob> output) call,
    String name,
  ) {
    final arena = Arena(calloc);
    try {
      final input = _blob(arena, bytes);
      final entropy = _blob(arena, _entropy);
      final output = arena<_DataBlob>();
      if (call(input, entropy, output) == 0) {
        throw StateError('$name failed');
      }
      try {
        // Copied out of the system's buffer, which LocalFree releases
        return Uint8List.fromList(output.ref.pbData.asTypedList(output.ref.cbData));
      } finally {
        _localFree(output.ref.pbData.cast());
      }
    } finally {
      arena.releaseAll();
    }
  }

  static Pointer<_DataBlob> _blob(Arena arena, List<int> bytes) {
    final data = arena<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    data.asTypedList(bytes.length).setAll(0, bytes);
    final blob = arena<_DataBlob>();
    blob.ref
      ..cbData = bytes.length
      ..pbData = data;
    return blob;
  }
}
