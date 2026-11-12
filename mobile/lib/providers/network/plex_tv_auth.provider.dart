// What the optional "Sign in with Plex" of the Plex server page uses to reach plex.tv and to open its page in the
// browser. Providers so that the tests replace the network and the browser.

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_tv_auth.dart';
import 'package:url_launcher/url_launcher.dart';

/// The requests to plex.tv, see [PlexTvAuth]
final plexTvAuthProvider = Provider<PlexTvAuth>((ref) => PlexTvAuth());

/// Opens the auth page of plex.tv in the browser of the device; true when something opened
final plexTvOpenBrowserProvider = Provider<Future<bool> Function(Uri url)>(
  (ref) =>
      (url) => launchUrl(url, mode: LaunchMode.externalApplication),
);
