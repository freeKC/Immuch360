// The AV2 decoder of the tests: the entries of the catalogue with a size, a sum and the files of an archive of their
// own (made like those of the run 41463914157 of lot AD2 for Windows), and without them, as a version that does not
// offer the decoder has it (store/m2/av2-2026-11-02/plan-2026-11-02.md, section 3).

import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';

final _sum = 'ab' * 32;

/// [entry] with a size, a sum and its files
AiComponent completeAv2Decoder(AiComponent entry, {int size = 790281, int program = 1628160}) => AiComponent(
  id: entry.id,
  name: entry.name,
  version: entry.version,
  kind: entry.kind,
  platforms: entry.platforms,
  assetName: entry.assetName,
  installPath: entry.installPath,
  size: size,
  sha256: _sum,
  compression: entry.compression,
  licence: entry.licence,
  licenceUrl: entry.licenceUrl,
  features: entry.features,
  releaseTag: entry.releaseTag,
  releaseRepository: entry.releaseRepository,
  archiveFiles: [
    AiArchiveFile(
      path: entry.id.contains('windows') ? 'immuch360-av2.exe' : 'immuch360-av2',
      size: program,
      sha256: _sum,
      executable: true,
    ),
    AiArchiveFile(path: 'licenses/dav2d-COPYING.txt', size: 1316, sha256: _sum),
    AiArchiveFile(path: 'licenses/AOM-PATENTS.txt', size: 5302, sha256: _sum),
  ],
);

/// The catalogue of the app with the three entries of the AV2 decoder complete
final av2CompleteCatalogue = [
  for (final component in aiComponents)
    component.features.contains(AiFeature.av2Video) ? completeAv2Decoder(component) : component,
];

/// The complete entry for Windows x64
final av2WindowsComplete = av2CompleteCatalogue.firstWhere((component) => component.id == 'av2-decoder-windows-x64');

/// [entry] without its size, its sum and its files, as the catalogue of a version that does not offer the decoder has
/// it
AiComponent incompleteAv2Decoder(AiComponent entry) => AiComponent(
  id: entry.id,
  name: entry.name,
  version: entry.version,
  kind: entry.kind,
  platforms: entry.platforms,
  assetName: entry.assetName,
  installPath: entry.installPath,
  size: null,
  sha256: null,
  compression: entry.compression,
  licence: entry.licence,
  licenceUrl: entry.licenceUrl,
  features: entry.features,
  releaseTag: entry.releaseTag,
  releaseRepository: entry.releaseRepository,
);

/// The catalogue of the app with the three entries of the AV2 decoder without sums: a version that does not offer it
final av2IncompleteCatalogue = [
  for (final component in aiComponents)
    component.features.contains(AiFeature.av2Video) ? incompleteAv2Decoder(component) : component,
];
