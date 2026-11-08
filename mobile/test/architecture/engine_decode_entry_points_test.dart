// The ways encoded bytes reach the engine's image decoders in the app, read in its sources. On Android the engine
// hands any format it has no codec of its own for to Android's decoder at its full size, which aborts the app on an
// OutOfMemoryError (crash M1 of the Meta Quest store, 8 November 2026): every encoded image goes through the probe
// first (ImageRequest for the loaders of the app, decodeEncodedBytes and the Guarded image providers for the others).
// A new NetworkImage, FileImage, Image.memory or direct decode outside the places listed here fails this test, so that
// a new viewer that forgets the probe breaks the build instead of a headset.

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
};

/// The places allowed to use them, with how many times and why
const _allowed = <String, Map<String, int>>{
  // After the probe: on Android only the formats of the engine's own codecs get there
  'lib/infrastructure/loaders/image_request.dart': {'ImageDescriptor.encoded': 1},
  // The guard itself: the engine's route of decodeEncodedBytes and decodeEncodedFile
  'lib/presentation/widgets/images/guarded_image.dart': {'instantiateImageCodec': 2, 'ImmutableBuffer.fromFilePath': 1},
  // The decoder handed to the loadImage of a provider of the app (thumbnails, previews: ImageRequest)
  'lib/presentation/widgets/images/progressive_image.widget.dart': {'instantiateImageCodec': 1},
  // RemoteImageRequest.load, whose encoded answers go through the probe in ImageRequest
  'lib/presentation/widgets/asset_viewer/immersive_viewer.dart': {'instantiateImageCodec': 1},
  'lib/presentation/widgets/asset_viewer/panorama_viewer.widget.dart': {'instantiateImageCodec': 1},
};

// The computers keep the engine for every buffer: their engines have no fallback decoder of that kind
const _desktop = 'lib/desktop/';

const _generated = ['.g.dart', '.freezed.dart', '.drift.dart', '.gr.dart', '.steps.dart', '.mocks.dart'];

/// The uses of each entry point in each file of lib, comment lines left out
Map<String, Map<String, int>> _uses() {
  final uses = <String, Map<String, int>>{};
  final files = Directory('lib').listSync(recursive: true).whereType<File>();
  for (final file in files.where((file) => file.path.endsWith('.dart'))) {
    final path = file.path.replaceAll(r'\', '/');
    if (path.startsWith(_desktop) || _generated.any(path.endsWith)) {
      continue;
    }
    for (final line in file.readAsLinesSync()) {
      if (line.trimLeft().startsWith('//')) {
        continue;
      }
      for (final MapEntry(key: name, value: pattern) in _entryPoints.entries) {
        final count = pattern.allMatches(line).length;
        if (count > 0) {
          final counts = uses.putIfAbsent(path, () => {});
          counts[name] = (counts[name] ?? 0) + count;
        }
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
    expect(_uses()['lib/infrastructure/loaders/image_request.dart'], {'ImageDescriptor.encoded': 1});
  });
}
