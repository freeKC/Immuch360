// The ways encoded bytes reach the engine's image decoders in the app, read in its sources. On Android the engine
// hands any format it has no codec of its own for to Android's decoder at its full size, which aborts the app on an
// OutOfMemoryError (crash M1 of the Meta Quest store, 8 November 2026): every encoded image goes through the probe
// first (ImageRequest for the loaders of the app, decodeEncodedBytes and the Guarded image providers for the others).
// A new NetworkImage, FileImage, Image.memory or direct decode outside the places listed here fails this test, so that
// a new viewer that forgets the probe breaks the build instead of a headset. A direct decode includes the decoder an
// image provider gets in loadImage, called on a buffer of the bytes (decode(buffer, ...) on
// ImmutableBuffer.fromUint8List), the way the thumbnails of the shares reached the engine before the probe.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The direct ways into the engine's decoders of encoded bytes
final _entryPoints = <String, RegExp>{
  'NetworkImage': RegExp(r'\bNetworkImage\('),
  'FileImage': RegExp(r'\bFileImage\('),
  'MemoryImage': RegExp(r'\bMemoryImage\('),
  'Image.memory': RegExp(r'\bImage\.memory\('),
  'Image.file': RegExp(r'\bImage\.file\('),
  'Image.network': RegExp(r'\bImage\.network\('),
  'ImmutableBuffer.fromFilePath': RegExp(r'\bImmutableBuffer\.fromFilePath\b'),
  'ImageDescriptor.encoded': RegExp(r'\bImageDescriptor\.encoded\b'),
  'instantiateImageCodec': RegExp(r'\binstantiateImageCodec'),
  'decodeImageFromList': RegExp(r'\bdecodeImageFromList\b'),
  'ImmutableBuffer.fromUint8List': RegExp(r'\bImmutableBuffer\.fromUint8List\b'),
  // The decoder of loadImage (ImageDecoderCallback) on a buffer, the buffer on the same line or the next one
  'decode(buffer': RegExp(r'(?<![.\w])decode\(\s*buffer\b'),
};

/// The places allowed to use them, with how many times and why
const _allowed = <String, Map<String, int>>{
  // After the probe: on Android only the formats of the engine's own codecs get there (ImageDescriptor.encoded and one
  // ImmutableBuffer of encoded bytes); the two other buffers hold the raw pixels of a TIFF decoded in Dart and of a
  // native decode, which ImageDescriptor.raw reads without any decoder
  'lib/infrastructure/loaders/image_request.dart': {'ImageDescriptor.encoded': 1, 'ImmutableBuffer.fromUint8List': 3},
  // The guard itself: the engine's route of decodeEncodedBytes and decodeEncodedFile (a buffer of encoded bytes after
  // the probe, the decoder on it twice), and the raw pixels of a native decode
  'lib/presentation/widgets/images/guarded_image.dart': {
    'instantiateImageCodec': 2,
    'ImmutableBuffer.fromFilePath': 1,
    'ImmutableBuffer.fromUint8List': 2,
    'decode(buffer': 2,
  },
  // NetworkVideoThumbnailImage: the JPEG the app's own video thumbnailer writes (Bitmap.compress on Android), never a
  // file of a share, so always a format of the engine's own codecs
  'lib/presentation/widgets/network/network_media_tile.widget.dart': {
    'ImmutableBuffer.fromUint8List': 1,
    'decode(buffer': 1,
  },
  // The raw pixels the Rust core decoded from a JPEG XL (the core route of the computers), which ImageDescriptor.raw
  // reads without any decoder
  'lib/infrastructure/loaders/core_image_decoder.dart': {'ImmutableBuffer.fromUint8List': 1},
  // The decoder handed to the loadImage of a provider of the app (thumbnails, previews: ImageRequest)
  'lib/presentation/widgets/images/progressive_image.widget.dart': {'instantiateImageCodec': 1},
  // RemoteImageRequest.load, whose encoded answers go through the probe in ImageRequest
  'lib/presentation/widgets/asset_viewer/immersive_viewer.dart': {'instantiateImageCodec': 1},
  'lib/presentation/widgets/asset_viewer/panorama_viewer.widget.dart': {'instantiateImageCodec': 1},
};

// The computers keep the engine for every buffer: their engines have no fallback decoder of that kind
const _desktop = 'lib/desktop/';

const _generated = ['.g.dart', '.freezed.dart', '.drift.dart', '.gr.dart', '.steps.dart', '.mocks.dart'];

/// The uses of each entry point in each file of lib, comment lines left out; a call may span two lines
Map<String, Map<String, int>> _uses() {
  final uses = <String, Map<String, int>>{};
  final files = Directory('lib').listSync(recursive: true).whereType<File>();
  for (final file in files.where((file) => file.path.endsWith('.dart'))) {
    final path = file.path.replaceAll(r'\', '/');
    if (path.startsWith(_desktop) || _generated.any(path.endsWith)) {
      continue;
    }
    final code = file.readAsLinesSync().where((line) => !line.trimLeft().startsWith('//')).join('\n');
    for (final MapEntry(key: name, value: pattern) in _entryPoints.entries) {
      final count = pattern.allMatches(code).length;
      if (count > 0) {
        uses.putIfAbsent(path, () => {})[name] = count;
      }
    }
  }
  return uses;
}

void main() {
  test('no encoded image reaches the engine but through the probe', () {
    final uses = _uses();
    int allowed(String path, String name) => _allowed[path]?[name] ?? 0;
    final unexpected = [
      for (final MapEntry(key: path, value: counts) in uses.entries)
        for (final MapEntry(key: name, value: count) in counts.entries)
          if (count > allowed(path, name)) '$path: $name $count time(s), ${allowed(path, name)} allowed',
    ];

    expect(
      unexpected,
      isEmpty,
      reason:
          'Decode an encoded image with decodeEncodedBytes, decodeEncodedFile, GuardedMemoryImage, GuardedFileImage or '
          'GuardedNetworkImage (lib/presentation/widgets/images/guarded_image.dart), or through an ImageRequest, so '
          'that on Android no format the engine has no codec for reaches its fallback decoder',
    );
  });

  test('the scan reads the sources', () {
    final uses = _uses();
    expect(uses['lib/infrastructure/loaders/image_request.dart'], {
      'ImageDescriptor.encoded': 1,
      'ImmutableBuffer.fromUint8List': 3,
    });
    // The decoder of loadImage called with its buffer on the next line
    expect(uses['lib/presentation/widgets/network/network_media_tile.widget.dart'], {
      'ImmutableBuffer.fromUint8List': 1,
      'decode(buffer': 1,
    });
  });

  test('the decoder of a provider on a buffer is an entry point, on one line or two, and no other decode is', () {
    int count(String code) => _entryPoints['decode(buffer']!.allMatches(code).length;
    expect(count('return decode(buffer, getTargetSize: size);'), 1);
    expect(count('return await decode(\n        buffer,\n        getTargetSize: size,'), 1);
    expect(count('final value = codec.decode(buffer);'), 0);
    expect(count('json.decode(raw); utf8.decode(bytes); decode(raw);'), 0);
    expect(count('decodeBuffer(buffer)'), 0);
  });
}
