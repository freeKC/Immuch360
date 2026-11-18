// What the Jellyfin page asks of a server before a source exists: its public information, its users, a sign in by
// password or Quick Connect, a sign out. A provider so that the page tests replace the network.

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/io_client.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_api.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_client.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_routes.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_client.dart' show plexAppVersion;

/// A server at a base URL, as the page met it: its information once read
typedef JellyfinTarget = ({Uri base, JellyfinPublicInfo info});

/// The requests of the Jellyfin page, each on a client of its own (the page sends a few requests only)
class JellyfinConnector {
  const JellyfinConnector();

  Future<JellyfinClient> _client(
    Uri base,
    JellyfinProduct product,
    String? version,
    String sourceId, {
    String? token,
  }) async => JellyfinClient(
    IOClient(),
    routes: JellyfinRoutes(base, product, version),
    deviceId: await deviceIdOf(sourceId),
    token: token,
    appVersion: await plexAppVersion(),
  );

  /// The DeviceId of the requests for the source [sourceId] (see jellyfinDeviceIdOf)
  Future<String> deviceIdOf(String sourceId) async => jellyfinDeviceIdOf(await jellyfinInstallId(), sourceId);

  Future<T> _with<T>(JellyfinClient client, Future<T> Function(JellyfinClient client) action) async {
    try {
      return await action(client);
    } catch (error) {
      throw jellyfinErrorOf(error);
    } finally {
      client.close();
    }
  }

  /// The public information at [base]; setupNotDone when the server's setup is not done
  Future<JellyfinPublicInfo> publicInfo(Uri base, String sourceId) async {
    final info = await _with(await _client(base, JellyfinProduct.jellyfin, null, sourceId), (c) => c.publicInfo());
    if (info.startupWizardCompleted == false) {
      throw JellyfinException.of(JellyfinFailure.setupNotDone);
    }
    return info;
  }

  Future<List<JellyfinPublicUser>> publicUsers(JellyfinTarget target, String sourceId) async =>
      _with(await _client(target.base, target.info.product, target.info.version, sourceId), (c) => c.publicUsers());

  Future<JellyfinSignIn> signIn(JellyfinTarget target, String sourceId, String user, String password) async => _with(
    await _client(target.base, target.info.product, target.info.version, sourceId),
    (c) => c.signIn(user, password),
  );

  Future<bool> quickConnectEnabled(JellyfinTarget target, String sourceId) async => _with(
    await _client(target.base, target.info.product, target.info.version, sourceId),
    (c) => c.quickConnectEnabled(),
  );

  Future<JellyfinQuickConnect> quickConnectStart(JellyfinTarget target, String sourceId) async => _with(
    await _client(target.base, target.info.product, target.info.version, sourceId),
    (c) => c.quickConnectInitiate(),
  );

  Future<bool> quickConnectApproved(JellyfinTarget target, String sourceId, String secret) async => _with(
    await _client(target.base, target.info.product, target.info.version, sourceId),
    (c) => c.quickConnectApproved(secret),
  );

  Future<JellyfinSignIn> quickConnectSignIn(JellyfinTarget target, String sourceId, String secret) async => _with(
    await _client(target.base, target.info.product, target.info.version, sourceId),
    (c) => c.quickConnectSignIn(secret),
  );

  /// Ends the session of [token] on the server, best effort: a failure is logged by the client and dropped
  Future<void> signOut(JellyfinTarget target, String sourceId, String token) async {
    final client = await _client(target.base, target.info.product, target.info.version, sourceId, token: token);
    try {
      await client.logout();
    } finally {
      client.close();
    }
  }

  /// The page of the web client where a signed in user approves a Quick Connect code
  Uri quickConnectPage(JellyfinTarget target) =>
      JellyfinRoutes(target.base, target.info.product, target.info.version).quickConnectPage();
}

final jellyfinConnectorProvider = Provider<JellyfinConnector>((ref) => const JellyfinConnector());
