// The client of the Wikipedia block of the film page, one for the life of the app: its pause after a 429 holds for
// every page, and its answers are kept in the support folder of the app. A future, since the version of the app that
// its User-Agent names comes from an asynchronous call; the tests override it with a client of a fake network.

import 'dart:io';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/io_client.dart';
import 'package:immich_mobile/infrastructure/wikipedia/wikipedia_film_cache.dart';
import 'package:immich_mobile/infrastructure/wikipedia/wikipedia_film_client.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The folder of the support folder of the app that holds the Wikipedia cache
const wikipediaCacheFolderName = 'wikipedia';

/// Finds the Wikipedia lead of a film, see [WikipediaFilmClient]
final wikipediaFilmClientProvider = FutureProvider<WikipediaFilmClient>((ref) async {
  // Closed with the provider, even when it goes before the version is known
  final http = IOClient();
  WikipediaFilmClient? built;
  var disposed = false;
  ref.onDispose(() {
    disposed = true;
    final current = built;
    if (current == null) {
      http.close();
    } else {
      current.close();
    }
  });
  final client = WikipediaFilmClient(
    client: http,
    userAgent: WikipediaFilmClient.userAgentFor(await _appVersion()),
    cache: FileWikipediaFilmCache.deferred(
      () async => Directory(p.join((await getApplicationSupportDirectory()).path, wikipediaCacheFolderName)),
    ),
  );
  built = client;
  if (disposed) {
    // Every call of a client closed this way gives null
    client.close();
  }
  return client;
});

/// The version of the app for the User-Agent, null when the platform does not tell (the tests)
Future<String?> _appVersion() async {
  try {
    return (await PackageInfo.fromPlatform().timeout(const Duration(seconds: 1))).version;
  } catch (_) {
    return null;
  }
}
