// What the page that adds a Plex server uses to reach it before it is saved. A provider so that the tests replace the
// network.

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_pairing.dart';

/// Looks a Plex server up and tests a token on it, see [PlexPairing]
final plexPairingProvider = Provider<PlexPairing>((ref) => PlexPairing());
