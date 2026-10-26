// The yes the user gives once for a network folder before any 3D photo is written next to its originals
// (design-final 2026-10-26, section 2.5; spec 6.1: no automatic write is tried on a remote source). Without it, nothing
// is written nor tried there, not even the check of the folder: the conversion dialog asks "Save 3D photos in the
// folders of this network folder?". The yes is kept in desktop_ai.json (networkRootsAllowed): for a root of the
// library by its id, for a file opened with the program by its volume. The settings list them and take one back.
//
// Ids and volume keys are those of volume_id.dart: "net-//nas/photos" for the share, "net-//nas/photos:/2024" for a
// root in it. A yes covers its own root and the folders under it; a yes for a volume covers every folder of it.

import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';

/// Whether the yes given for [allowed] (a root id or a volume key) covers [key] (a root id, or a folder named as a root
/// would be, see VolumeIdentity.rootId)
bool consentCovers(String allowed, String key) =>
    key == allowed || rootContains(allowed, key) || key.startsWith('$allowed:/');

/// Whether one of [allowed] covers [key]
bool consentGiven(Iterable<String> allowed, String key) => allowed.any((given) => consentCovers(given, key));

/// The network folders the user allowed, kept in desktop_ai.json
class NetworkRootConsent {
  NetworkRootConsent({DesktopAiSettingsStore? store}) : _store = store ?? DesktopAiSettingsStore.instance;

  final DesktopAiSettingsStore _store;

  /// The roots and volumes allowed, in the order the user allowed them
  Future<List<String>> allowed() async => (await _store.read()).networkRootsAllowed;

  /// Whether a 3D photo may be written in the folder [key]
  Future<bool> isAllowed(String key) async => consentGiven(await allowed(), key);

  /// "Yes, for this network folder": kept for [key], a root id or a volume key. The settings kept.
  Future<DesktopAiSettings> allow(String key) => _store.update(
    (settings) => settings.networkRootsAllowed.contains(key)
        ? settings
        : settings.copyWith(networkRootsAllowed: List.unmodifiable([...settings.networkRootsAllowed, key])),
  );

  /// Takes back the yes given for [key]; the next conversion asks again. The settings kept.
  Future<DesktopAiSettings> withdraw(String key) => _store.update(
    (settings) => settings.copyWith(
      networkRootsAllowed: List.unmodifiable(settings.networkRootsAllowed.where((given) => given != key)),
    ),
  );
}
