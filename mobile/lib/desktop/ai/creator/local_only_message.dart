// "Saved on this computer only" at the end of a 3D photo written to a folder that is not on the network
// (design-final 2026-10-26, section 2.5; spec 6.5: a result kept on the disk of the computer is not seen by the other
// devices on their own). The second sentence gives the ways to the Quest: a network folder (a NAS), or Share this
// computer, which only Windows has (computer_share.dart); on Linux and macOS it names the network folder alone.

import 'package:immich_mobile/desktop/network/computer_share.dart';
import 'package:immich_mobile/generated/translations.g.dart';

/// The message after a 3D photo saved to a folder that [isNetwork] or not, null for a network folder. [computerShare]
/// tells whether this computer can share its folders (Windows); this computer by default.
String? localOnlyMessage(Translations t, {required bool isNetwork, bool? computerShare}) {
  if (isNetwork) {
    return null;
  }
  return computerShare ?? computerShareAvailable
      ? t.ai_immersive_saved_local_only
      : t.ai_immersive_saved_local_only_no_share;
}
