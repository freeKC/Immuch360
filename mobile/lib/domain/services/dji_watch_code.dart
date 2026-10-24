// The text of the QR code a TV's Drone page shows (p2/design-tv-2026-10-24.md, 2.4): the code the TV made itself, for
// the phone's "Add a TV" to scan. Not a link: a camera app shows it as text, and the app acts on it only from the
// scanner of the Send panel. Strict: the prefix exactly, version 1, then the 10 symbols of the pairing alphabet.

import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';

/// The prefix of the text, then the version
const djiWatchQrPrefix = 'IMMUCH360-WATCH:';
const djiWatchQrVersion = 1;

/// The text of the QR code of a TV whose own code is [code]
String buildDjiWatchQrText(String code) => '$djiWatchQrPrefix$djiWatchQrVersion:$code';

/// What a scanned text is, for "Add a TV"
sealed class DjiWatchScan {
  const DjiWatchScan();
}

/// The code of a TV's Drone page
class DjiWatchCode extends DjiWatchScan {
  const DjiWatchCode(this.code);

  final String code;
}

/// The code of "Sign in with your phone": it signs a TV in, it does not let it watch
class DjiWatchSignInCode extends DjiWatchScan {
  const DjiWatchSignInCode();
}

/// Anything else
class DjiWatchNotACode extends DjiWatchScan {
  const DjiWatchNotACode();
}

/// Reads a scanned text: a TV's code only in the exact form of [buildDjiWatchQrText], trimmed; the sign in code of a
/// screen is told apart so that the phone says where it goes
DjiWatchScan parseDjiWatchQrText(String text) {
  final trimmed = text.trim();
  if (trimmed.length > 512) {
    return const DjiWatchNotACode();
  }
  final match = RegExp(r'^IMMUCH360-WATCH:([0-9]+):([A-Z0-9]{10})$').firstMatch(trimmed);
  if (match != null) {
    final code = match.group(2)!;
    if (match.group(1) == '$djiWatchQrVersion' && normalizePairingCode(code) == code) {
      return DjiWatchCode(code);
    }
    return const DjiWatchNotACode();
  }
  return switch (parsePairingText(trimmed)) {
    PairingTarget() || WebOsPairingLink() => const DjiWatchSignInCode(),
    _ => const DjiWatchNotACode(),
  };
}
