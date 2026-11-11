// The AV2 decoder of this computer as the screens show it (store/m2/av2-2026-11-02/plan-2026-11-02.md, sections 1.3 and
// 3): the entry of the catalogue for this computer (av2-decoder-windows-x64, -linux-x64, -macos-universal), whether
// this version of the app offers it (an entry with its size, its sum and its files: a release of
// github.com/immuch360/av2-companion since build 45, the prerelease av2-decoder-1 before), its state, and its sizes. It
// downloads, checks and installs as the AI components do (AiComponentsService: the SHA-256 always checked, the mirror
// of IMMUCH360_AI_COMPONENTS_MIRROR, the licences next to it), but its screens are those of the videos: the card of the
// player and the settings of the videos, never the tile of the AI components.

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/ui/ai_settings_section.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';

/// The entry of the AV2 decoder for [platform] in [catalogue], complete or not; null where there is none (the phones,
/// the Quest)
AiComponent? av2DecoderComponentFor(AiPlatform? platform, {List<AiComponent> catalogue = aiComponents}) {
  if (platform == null) {
    return null;
  }
  for (final component in catalogue) {
    if (component.features.contains(AiFeature.av2Video) && component.platforms.contains(platform)) {
      return component;
    }
  }
  return null;
}

/// The AV2 decoder of [platform] in the catalogue of [service]
class Av2Decoder {
  Av2Decoder(this.service, this.platform);

  final AiComponentsService service;
  final AiPlatform? platform;

  /// Its entry for this computer, complete or not
  late final AiComponent? component = av2DecoderComponentFor(platform, catalogue: service.catalogue);

  /// Whether this version offers it: an entry with its size, its sum and its files. Without one, nothing is ever
  /// downloaded (the builds before the decoder had a release of its own)
  bool get offered => component?.isComplete ?? false;

  /// Its state; not installed where there is no entry
  AiComponentStatus get status {
    final component = this.component;
    return component == null ? const AiComponentStatus(AiComponentState.notInstalled) : service.statusOf(component);
  }

  bool get isInstalled => status.state == AiComponentState.installed;

  bool get isDownloading => status.state == AiComponentState.downloading;

  /// What the download takes, from the catalogue; 0 without an entry
  int get downloadBytes => component == null ? 0 : AiComponentsService.downloadBytesOf([component!]);

  /// What it takes once installed (the files of its archive), from the catalogue; 0 without an entry
  int get diskBytes => component == null ? 0 : AiComponentsService.diskBytesOf([component!]);

  /// The version of the catalogue: the commit of dav2d and the build of the companion ("30140b5-1")
  String get version => component?.version ?? '';
}

/// The AV2 decoder of this computer; its screens listen to [Av2Decoder.service] for its state
final av2DecoderProvider = Provider<Av2Decoder>(
  (ref) => Av2Decoder(ref.watch(aiComponentsServiceProvider), ref.watch(aiPlatformProvider)),
);

/// Whether the AV2 decoder of this computer is installed, told again when it is installed or removed: the tiles of the
/// shares ask a frame of an AV2 video only then (before, its grab would give none, and the frame of a share is not
/// asked again for minutes)
final av2DecoderInstalledProvider = Provider<bool>((ref) {
  final decoder = ref.watch(av2DecoderProvider);
  void changed() => ref.state = decoder.isInstalled;
  decoder.service.addListener(changed);
  ref.onDispose(() => decoder.service.removeListener(changed));
  return decoder.isInstalled;
});
