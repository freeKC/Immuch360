// Export and import of the settings (issue 16): what this install holds is gathered into a SettingsFileContent, and a
// file's content is written back, with a report of what was restored and what was not. What goes in the file, and
// what stays on the device, is decided here (portableStoreKeys, the excluded settings) and told in
// docs/immuch360/user-guide.md ("Keep your settings in a file").

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/settings_file/settings_file.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/local_album.service.dart';
import 'package:immich_mobile/domain/services/settings_file/settings_file_crypto.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/auth.provider.dart';
import 'package:immich_mobile/providers/backup/backup_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/services/widget.service.dart';
import 'package:immich_mobile/utils/provider_utils.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart';

final _log = Logger('SettingsFile');

/// Which part of the file a report line is about
enum SettingsFileSection { account, server, settings, sources, backupAlbums, pairing }

enum SettingsFileOutcome {
  restored,

  /// Not restored, see [SettingsFileSkipReason]
  skipped,

  /// Kept to apply later: backup albums before the device's albums are listed
  waiting,
}

enum SettingsFileSkipReason {
  /// The account: this install is signed in to a server; sign out first to use the file's
  signedIn,

  /// A network setting of another server than the one this install uses
  otherServer,

  /// A source with this id or this address is here already (merge)
  alreadyHere,

  /// A setting or a source type a later build wrote
  unknownToThisBuild,

  /// A value that does not read
  unreadable,

  /// A backup album not found on this device
  notOnThisDevice,

  /// The account: the server no longer accepts the session of the file (signed out there, or expired)
  sessionRefused,
}

/// How the session of a restored account went when the app put it to the server, as at a start with a saved token
enum SettingsFileSignInResult {
  /// The server accepted the session and named its user
  signedIn,

  /// The server answered that the session is no longer valid: the address is kept, the token is not
  refused,

  /// No answer from the server (offline, another network): the account is kept and the app signs in when it answers
  unreachable,
}

class SettingsFileSignIn {
  const SettingsFileSignIn(this.result, {this.name, this.email});

  final SettingsFileSignInResult result;

  /// The user the server named, when signed in
  final String? name;
  final String? email;
}

/// What a check of the session against the server gave
enum SettingsFileSessionCheck { valid, refused, unreachable }

/// The server side of a restored account, behind an interface for the tests: what the start of the app does with a
/// saved token (splash screen, auth guard), and what a sign in sets that a token written in the Store alone does not
abstract interface class SettingsFileServerLink {
  /// Points the API client at [address] (resolved first from what the user typed when [resolve]) and gives [token]
  /// to the HTTP clients of the app, which carry the session as a cookie that only a sign in or this sets
  Future<void> connect(String address, {required bool resolve, required String token});

  /// Asks the server whether the session is valid
  Future<SettingsFileSessionCheck> check();

  /// Loads the user of the session into the app (current user, device id, the auth state); null when the server did
  /// not give it
  Future<({String name, String email})?> loadUser(String token);

  /// Forgets a session the server refused: the token, the user and the session cookies; the addresses stay
  Future<void> forget();
}

class _AppServerLink implements SettingsFileServerLink {
  const _AppServerLink(this._ref);

  final Ref _ref;

  static const _timeout = Duration(seconds: 12);

  ApiService get _api => _ref.read(apiServiceProvider);

  Future<void> _giveToken(String token) async {
    await NetworkRepository.setHeaders(ApiService.getNativeHeaders(), ApiService.getServerUrls(), token: token);
    _api.apiClient.client = NetworkRepository.client;
  }

  @override
  Future<void> connect(String address, {required bool resolve, required String token}) async {
    // The custom headers (a proxy in front of the server) before the first request
    await _giveToken(token);
    if (resolve) {
      await _api.resolveAndSetEndpoint(address).timeout(_timeout);
    } else {
      _api.setEndpoint(address);
    }
    await _api.setDeviceInfoHeader();
    // Again with the address in use, which may be another host than the one stored
    await _giveToken(token);
    invalidateApiRepositoryProviders(_ref.invalidate);
  }

  @override
  Future<SettingsFileSessionCheck> check() async {
    try {
      final response = await _api.authenticationApi.validateAccessToken().timeout(_timeout);
      return response?.authStatus == true ? SettingsFileSessionCheck.valid : SettingsFileSessionCheck.refused;
    } on ApiException catch (error) {
      return error.code == HttpStatus.unauthorized
          ? SettingsFileSessionCheck.refused
          : SettingsFileSessionCheck.unreachable;
    } catch (error) {
      _log.info('The server of the settings file did not answer: ${error.runtimeType}');
      return SettingsFileSessionCheck.unreachable;
    }
  }

  @override
  Future<({String name, String email})?> loadUser(String token) async {
    final auth = _ref.read(authProvider.notifier);
    if (!await auth.saveAuthInfo(accessToken: token)) {
      return null;
    }
    final state = _ref.read(authProvider);
    return (name: state.name, email: state.userEmail);
  }

  @override
  Future<void> forget() async {
    final store = _ref.read(storeServiceProvider);
    await store.delete(StoreKey.accessToken);
    await store.delete(StoreKey.currentUser);
    await networkApi.clearCookies();
    // saveAuthInfo hands the token to the home screen widgets before it loads the user
    try {
      await _ref.read(widgetServiceProvider).clearCredentials();
    } catch (error) {
      _log.info('The widgets could not forget the session: ${error.runtimeType}');
    }
  }
}

final settingsFileServerLinkProvider = Provider<SettingsFileServerLink>(_AppServerLink.new);

class SettingsFileReportItem {
  const SettingsFileReportItem(this.section, this.label, this.outcome, [this.reason]);

  final SettingsFileSection section;

  /// What it is about: the server address, a source name, an album name, a setting's name, or a count of settings
  final String label;
  final SettingsFileOutcome outcome;
  final SettingsFileSkipReason? reason;

  @override
  String toString() => '${section.name} $label ${outcome.name}${reason == null ? '' : ' ${reason!.name}'}';
}

class SettingsFileReport {
  const SettingsFileReport(this.items, {this.accountRestored = false, this.signIn});

  final List<SettingsFileReportItem> items;

  /// The session of the file's server was put in place: the app starts again from its start screen to resume it
  final bool accountRestored;

  /// What the server said of the file's session, when the file put one in place
  final SettingsFileSignIn? signIn;

  Iterable<SettingsFileReportItem> where(SettingsFileOutcome outcome) => items.where((i) => i.outcome == outcome);
}

/// The albums of this device, behind an interface for the tests
abstract interface class SettingsFileAlbums {
  Future<List<LocalAlbum>> all();

  Future<void> setChoice(LocalAlbum album, BackupSelection selection);
}

class _DeviceAlbums implements SettingsFileAlbums {
  const _DeviceAlbums(this._service);

  final LocalAlbumService _service;

  @override
  Future<List<LocalAlbum>> all() => _service.getAll();

  @override
  Future<void> setChoice(LocalAlbum album, BackupSelection selection) =>
      _service.update(album.copyWith(backupSelection: selection));
}

final settingsFileAlbumsProvider = Provider<SettingsFileAlbums>(
  (ref) => _DeviceAlbums(LocalAlbumService(ref.watch(driftProvider).localAlbumRepository)),
);

final settingsFileServiceProvider = Provider<SettingsFileService>(SettingsFileService.new);

class SettingsFileService {
  SettingsFileService(this._ref);

  final Ref _ref;

  /// The values of the Store the user chose and that mean the same on another device: viewer choices per photo (the
  /// keys are server ids, or source ids that the import keeps), the DJI obstacle settings, Play from a phone, haptics,
  /// read only mode, advanced troubleshooting. Never the ids of this install (X-Plex-Client-Identifier, phone share
  /// id), the caches, what the app learned (Plex addresses, DJI live picture seen), the rating state, nor
  /// manageLocalMediaAndroid, which needs a permission the user grants by hand.
  static const portableStoreKeys = <StoreKey>[
    StoreKey.advancedTroubleshooting,
    StoreKey.enableHapticFeedback,
    StoreKey.readonlyModeEnabled,
    StoreKey.spatialLayoutOverrides,
    StoreKey.forcedPanoramaAssets,
    StoreKey.sphereCoverageOverrides,
    StoreKey.viewRotations,
    StoreKey.djiObstacleSoundOff,
    StoreKey.djiObstacleFarCm,
    StoreKey.djiObstacleNearCm,
    StoreKey.djiObstacleSideTest,
    StoreKey.djiObstacleSideOff,
    StoreKey.djiObstacleRingOff,
    StoreKey.djiObstacleHapticOff,
    StoreKey.djiObstacleNumbersOff,
    StoreKey.djiHeadsetLowestDelayOff,
    StoreKey.djiObstacleShapeFrame,
    StoreKey.playFromPhoneOff,
    StoreKey.playFromPhoneAsk,
  ];

  /// The big screens this phone signed in, and the name and signer of this big screen: no token, but they name
  /// sessions of the account, so they travel with it (accounts level)
  static const pairingStoreKeys = <StoreKey>[
    StoreKey.pairedScreens,
    StoreKey.pairingScreenLabel,
    StoreKey.pairingSignedInBy,
  ];

  /// Settings never written: a state of this install
  static const localSettings = <SettingsKey>{SettingsKey.featureMessageSeenRelease};

  /// The settings of the connection to the server: applied only when this install has no server yet or the file's
  /// server is this install's, and never reset by a replace that keeps the current account
  static const serverSettings = <SettingsKey>{
    SettingsKey.networkAutoEndpointSwitching,
    SettingsKey.networkExternalEndpointList,
    SettingsKey.networkCustomHeaders,
    SettingsKey.networkPreferredWifiName,
    SettingsKey.networkLocalEndpoint,
  };

  StoreService get _store => _ref.read(storeServiceProvider);

  SettingsRepository get _settings => _ref.read(settingsProvider);

  NetworkSourcesNotifier get _sources => _ref.read(networkSourcesProvider.notifier);

  /// Whether this install is signed in to an Immich server
  bool get isSignedIn => (_store.tryGet(StoreKey.accessToken) ?? '').isNotEmpty;

  /// Everything this install would put in an accounts level file; [SettingsFileContent.withoutSecrets] makes the
  /// settings level from it
  Future<SettingsFileContent> collect() async {
    final store = _store;
    final serverUrl = store.tryGet(StoreKey.serverUrl);
    final server = serverUrl == null || serverUrl.isEmpty
        ? null
        : SettingsFileServer(
            url: serverUrl,
            endpoint: store.tryGet(StoreKey.serverEndpoint),
            accessToken: store.tryGet(StoreKey.accessToken),
          );

    final config = _settings.appConfig;
    final settings = <String, String?>{};
    for (final key in SettingsKey.values) {
      if (localSettings.contains(key)) {
        continue;
      }
      final value = config.read(key);
      if (value == defaultConfig.read(key)) {
        continue;
      }
      try {
        settings[key.name] = value == null ? null : key.encode(value);
      } catch (error) {
        _log.warning('A setting could not be written to the settings file: ${key.name}');
      }
    }

    final values = <String, Object?>{
      for (final key in portableStoreKeys)
        if (store.tryGet<dynamic>(key) case final Object value) key.name: value,
    };
    final pairing = <String, Object?>{
      for (final key in pairingStoreKeys)
        if (store.tryGet<dynamic>(key) case final Object value) key.name: value,
    };

    final sources = _ref.read(networkSourcesProvider);
    final secrets = <String, SettingsFileSourceSecrets>{};
    for (final source in sources) {
      final secret = SettingsFileSourceSecrets(
        password: await _sources.readPassword(source.id),
        cameraPassword: source.type == NetworkSourceType.tapo ? await _sources.readCameraPassword(source.id) : null,
      );
      if (!secret.isEmpty) {
        secrets[source.id] = secret;
      }
    }

    final albums = <SettingsFileBackupAlbum>[];
    try {
      for (final album in await _ref.read(settingsFileAlbumsProvider).all()) {
        final choice = switch (album.backupSelection) {
          BackupSelection.selected => SettingsFileAlbumChoice.selected,
          BackupSelection.excluded => SettingsFileAlbumChoice.excluded,
          BackupSelection.none => null,
        };
        if (choice != null) {
          albums.add(SettingsFileBackupAlbum(id: album.id, name: album.name, choice: choice));
        }
      }
    } catch (error) {
      _log.warning('The backup albums could not be read for the settings file: $error');
    }
    // Albums waiting for the device's first scan are this install's choices too
    albums.addAll(_pendingAlbums().albums.where((p) => albums.every((a) => a.id != p.id)));

    return SettingsFileContent(
      server: server,
      settings: settings,
      store: values,
      sources: [for (final source in sources) source.toJson()],
      sourceSecrets: secrets,
      backupAlbums: albums,
      pairing: pairing,
    );
  }

  /// The file to save or share: [level] settings in clear, accounts encrypted with [passphrase]
  Future<String> buildFile({
    required SettingsFileLevel level,
    required SettingsFileOrigin origin,
    String? passphrase,
    DateTime? now,
  }) async {
    final content = await collect();
    final createdAt = (now ?? DateTime.now()).toUtc();
    if (level == SettingsFileLevel.settings) {
      return SettingsFile(
        origin: origin,
        createdAt: createdAt,
        level: level,
        content: content.withoutSecrets(),
      ).encode();
    }
    if (passphrase == null || passphrase.length < settingsFileMinPassphraseLength) {
      throw ArgumentError('A passphrase of $settingsFileMinPassphraseLength characters or more is needed');
    }
    final file = await sealSettingsFile(content: content, passphrase: passphrase, origin: origin, createdAt: createdAt);
    return file.encode();
  }

  /// Writes [content] into this install. Merge adds the file's sources and settings and keeps this install's;
  /// replace removes this install's sources, settings and album choices first. The account is put in place only when
  /// this install is signed in to no server.
  Future<SettingsFileReport> restore(SettingsFileContent content, SettingsFileRestoreMode mode) async {
    final items = <SettingsFileReportItem>[];
    final replace = mode == SettingsFileRestoreMode.replace;

    // The server first: whether the network settings belong to it depends on it
    final currentUrl = _store.tryGet(StoreKey.serverUrl);
    final signedIn = isSignedIn;
    final server = content.server;
    var accountRestored = false;
    var sameServer =
        currentUrl == null || currentUrl.isEmpty || (server != null && _sameAddress(server.url, currentUrl));
    if (server != null) {
      if (server.hasAccount) {
        if (signedIn) {
          items.add(
            SettingsFileReportItem(
              SettingsFileSection.account,
              server.url,
              SettingsFileOutcome.skipped,
              SettingsFileSkipReason.signedIn,
            ),
          );
        } else {
          await _store.put(StoreKey.serverUrl, server.url);
          if (server.endpoint != null) {
            await _store.put(StoreKey.serverEndpoint, server.endpoint!);
          }
          await _store.put(StoreKey.accessToken, server.accessToken!);
          accountRestored = true;
          sameServer = true;
          // Its line comes once the server said what it thinks of the session, below
        }
      } else if (!signedIn) {
        // No account in the file: the addresses fill in the sign in form (getServerUrl reads the endpoint), as after a
        // sign out, which keeps them too
        await _store.put(StoreKey.serverUrl, server.url);
        if (server.endpoint != null) {
          await _store.put(StoreKey.serverEndpoint, server.endpoint!);
        }
        sameServer = true;
        items.add(SettingsFileReportItem(SettingsFileSection.server, server.url, SettingsFileOutcome.restored));
      } else if (!sameServer) {
        items.add(
          SettingsFileReportItem(
            SettingsFileSection.server,
            server.url,
            SettingsFileOutcome.skipped,
            SettingsFileSkipReason.signedIn,
          ),
        );
      }
    }

    items.addAll(await _restoreSettings(content, replace: replace, serverSettingsApply: sameServer));
    items.addAll(await _restoreStore(content, replace: replace));
    SettingsFileSignIn? signIn;
    if (accountRestored) {
      items.addAll(await _restorePairing(content));
      // The settings first: the proxy headers, the local address and this screen's name go with the first request
      signIn = await _signIn(server!);
      if (signIn.result == SettingsFileSignInResult.refused) {
        accountRestored = false;
        items.insert(
          0,
          SettingsFileReportItem(
            SettingsFileSection.account,
            server.url,
            SettingsFileOutcome.skipped,
            SettingsFileSkipReason.sessionRefused,
          ),
        );
        items.insert(0, SettingsFileReportItem(SettingsFileSection.server, server.url, SettingsFileOutcome.restored));
      } else {
        items.insert(0, SettingsFileReportItem(SettingsFileSection.account, server.url, SettingsFileOutcome.restored));
      }
    }
    items.addAll(await _restoreSources(content, replace: replace));
    items.addAll(await _restoreAlbums(content.backupAlbums, replace: replace));

    return SettingsFileReport(List.unmodifiable(items), accountRestored: accountRestored, signIn: signIn);
  }

  /// Puts the session of the file to its server, as the start of the app does with a saved token: the API client
  /// pointed at the server, the token given to the HTTP clients (a token in the Store alone is not sent: the session
  /// travels as a cookie that a sign in sets), the session checked, the user loaded. The address the old install
  /// used first, then the one the user typed, resolved again (the old one may be a local address of another network).
  Future<SettingsFileSignIn> _signIn(SettingsFileServer server) async {
    final link = _ref.read(settingsFileServerLinkProvider);
    final token = server.accessToken!;
    final candidates = <(String, bool)>[
      if (server.endpoint != null) (server.endpoint!, false),
      if (server.endpoint == null || !_sameAddress(server.endpoint!, server.url)) (server.url, true),
    ];
    var check = SettingsFileSessionCheck.unreachable;
    for (final (address, resolve) in candidates) {
      try {
        await link.connect(address, resolve: resolve, token: token);
      } catch (error) {
        _log.info('The server of the settings file is not reachable at one of its addresses: ${error.runtimeType}');
        continue;
      }
      check = await link.check();
      if (check != SettingsFileSessionCheck.unreachable) {
        break;
      }
    }

    if (check == SettingsFileSessionCheck.valid) {
      final user = await link.loadUser(token);
      if (user != null) {
        return SettingsFileSignIn(SettingsFileSignInResult.signedIn, name: user.name, email: user.email);
      }
      // Valid a moment ago, then no user: asked again, so a session ended in between is not kept
      check = await link.check();
      if (check == SettingsFileSessionCheck.valid) {
        // The start of the app loads the user again
        check = SettingsFileSessionCheck.unreachable;
      }
    }

    switch (check) {
      case SettingsFileSessionCheck.refused:
        _log.info('The server refused the session of the settings file');
        await link.forget();
        // The sign in form fills its address from the endpoint
        if ((_store.tryGet(StoreKey.serverEndpoint) ?? '').isEmpty) {
          await _store.put(StoreKey.serverEndpoint, server.url);
        }
        return const SettingsFileSignIn(SettingsFileSignInResult.refused);
      case SettingsFileSessionCheck.unreachable:
      case SettingsFileSessionCheck.valid:
        return const SettingsFileSignIn(SettingsFileSignInResult.unreachable);
    }
  }

  Future<List<SettingsFileReportItem>> _restoreSettings(
    SettingsFileContent content, {
    required bool replace,
    required bool serverSettingsApply,
  }) async {
    final items = <SettingsFileReportItem>[];
    final settings = _settings;
    final written = <SettingsKey>{};
    var restored = 0;
    var otherServer = 0;
    for (final MapEntry(key: name, :value) in content.settings.entries) {
      final key = SettingsKey.values.where((k) => k.name == name).firstOrNull;
      if (key == null) {
        items.add(
          SettingsFileReportItem(
            SettingsFileSection.settings,
            name,
            SettingsFileOutcome.skipped,
            SettingsFileSkipReason.unknownToThisBuild,
          ),
        );
        continue;
      }
      if (localSettings.contains(key)) {
        continue;
      }
      if (serverSettings.contains(key) && !serverSettingsApply) {
        otherServer++;
        continue;
      }
      try {
        final decoded = value == null ? null : key.decode(value);
        await settings.write(key, decoded);
        written.add(key);
        restored++;
      } catch (error) {
        _log.warning('A setting of the settings file does not read: $name');
        items.add(
          SettingsFileReportItem(
            SettingsFileSection.settings,
            name,
            SettingsFileOutcome.skipped,
            SettingsFileSkipReason.unreadable,
          ),
        );
      }
    }
    if (replace) {
      // Back to the default: what this install set and the file does not hold. The connection settings stay unless
      // they belong to the file's server
      final reset = SettingsKey.values.where(
        (key) =>
            !written.contains(key) &&
            !localSettings.contains(key) &&
            (serverSettingsApply || !serverSettings.contains(key)) &&
            settings.appConfig.read(key) != defaultConfig.read(key),
      );
      await settings.clear(reset.toList());
    }
    items.insert(0, SettingsFileReportItem(SettingsFileSection.settings, '$restored', SettingsFileOutcome.restored));
    if (otherServer > 0) {
      items.add(
        SettingsFileReportItem(
          SettingsFileSection.settings,
          '$otherServer',
          SettingsFileOutcome.skipped,
          SettingsFileSkipReason.otherServer,
        ),
      );
    }
    return items;
  }

  Future<List<SettingsFileReportItem>> _restoreStore(SettingsFileContent content, {required bool replace}) async {
    final items = <SettingsFileReportItem>[];
    final store = _store;
    for (final key in portableStoreKeys) {
      final value = content.store[key.name];
      if (value == null) {
        if (replace && store.tryGet<dynamic>(key) != null) {
          await store.delete(key);
        }
        continue;
      }
      if (!await _putTyped(key, value)) {
        items.add(
          SettingsFileReportItem(
            SettingsFileSection.settings,
            key.name,
            SettingsFileOutcome.skipped,
            SettingsFileSkipReason.unreadable,
          ),
        );
      }
    }
    for (final name in content.store.keys) {
      if (portableStoreKeys.every((key) => key.name != name)) {
        items.add(
          SettingsFileReportItem(
            SettingsFileSection.settings,
            name,
            SettingsFileOutcome.skipped,
            SettingsFileSkipReason.unknownToThisBuild,
          ),
        );
      }
    }
    return items;
  }

  Future<List<SettingsFileReportItem>> _restorePairing(SettingsFileContent content) async {
    var restored = 0;
    for (final key in pairingStoreKeys) {
      final value = content.pairing[key.name];
      if (value != null && await _putTyped(key, value)) {
        restored++;
      }
    }
    return [
      if (restored > 0) SettingsFileReportItem(SettingsFileSection.pairing, '$restored', SettingsFileOutcome.restored),
    ];
  }

  /// Puts [value] under [key] when it has the key's type; false otherwise
  Future<bool> _putTyped(StoreKey key, Object value) async {
    final store = _store;
    switch (key.type) {
      case const (bool) when value is bool:
        await store.put(key as StoreKey<bool>, value);
      case const (int) when value is int:
        await store.put(key as StoreKey<int>, value);
      case const (String) when value is String:
        await store.put(key as StoreKey<String>, value);
      default:
        return false;
    }
    return true;
  }

  Future<List<SettingsFileReportItem>> _restoreSources(SettingsFileContent content, {required bool replace}) async {
    final items = <SettingsFileReportItem>[];
    final notifier = _sources;
    if (replace) {
      for (final source in [..._ref.read(networkSourcesProvider)]) {
        await notifier.remove(source.id);
      }
    }
    for (final json in content.sources) {
      final source = NetworkSource.fromJson(json);
      final name = switch (json['name']) {
        final String name => name,
        _ => '?',
      };
      if (source == null) {
        items.add(
          SettingsFileReportItem(
            SettingsFileSection.sources,
            name,
            SettingsFileOutcome.skipped,
            SettingsFileSkipReason.unknownToThisBuild,
          ),
        );
        continue;
      }
      final current = _ref.read(networkSourcesProvider);
      if (current.any((s) => s.id == source.id || _sameSource(s, source))) {
        items.add(
          SettingsFileReportItem(
            SettingsFileSection.sources,
            source.name,
            SettingsFileOutcome.skipped,
            SettingsFileSkipReason.alreadyHere,
          ),
        );
        continue;
      }
      final secrets = content.sourceSecrets[source.id];
      try {
        await notifier.add(source, password: secrets?.password, cameraPassword: secrets?.cameraPassword);
        items.add(SettingsFileReportItem(SettingsFileSection.sources, source.name, SettingsFileOutcome.restored));
      } catch (error) {
        _log.warning('A source of the settings file could not be added: $error');
        items.add(
          SettingsFileReportItem(
            SettingsFileSection.sources,
            source.name,
            SettingsFileOutcome.skipped,
            SettingsFileSkipReason.unreadable,
          ),
        );
      }
    }
    return items;
  }

  /// Applies [albums] to this device's albums now when they are listed, or keeps them for the next scan
  Future<List<SettingsFileReportItem>> _restoreAlbums(
    List<SettingsFileBackupAlbum> albums, {
    required bool replace,
  }) async {
    if (albums.isEmpty) {
      return const [];
    }
    final List<LocalAlbum> device;
    try {
      device = await _ref.read(settingsFileAlbumsProvider).all();
    } catch (error) {
      _log.warning('The albums of the device could not be read: $error');
      return [await _keepPending(albums, replace)];
    }
    if (device.isEmpty) {
      // A new install before its first scan of the device
      return [await _keepPending(albums, replace)];
    }
    return _applyAlbums(albums, device, replace: replace);
  }

  Future<SettingsFileReportItem> _keepPending(List<SettingsFileBackupAlbum> albums, bool replace) async {
    await _store.put(
      StoreKey.pendingBackupAlbums,
      jsonEncode({
        'replace': replace,
        'albums': [for (final album in albums) album.toJson()],
      }),
    );
    return SettingsFileReportItem(SettingsFileSection.backupAlbums, '${albums.length}', SettingsFileOutcome.waiting);
  }

  Future<List<SettingsFileReportItem>> _applyAlbums(
    List<SettingsFileBackupAlbum> albums,
    List<LocalAlbum> device, {
    required bool replace,
  }) async {
    final items = <SettingsFileReportItem>[];
    final api = _ref.read(settingsFileAlbumsProvider);
    final matched = <String>{};
    for (final album in albums) {
      final target = _match(album, device, matched);
      if (target == null) {
        items.add(
          SettingsFileReportItem(
            SettingsFileSection.backupAlbums,
            album.name,
            SettingsFileOutcome.skipped,
            SettingsFileSkipReason.notOnThisDevice,
          ),
        );
        continue;
      }
      matched.add(target.id);
      final selection = album.choice == SettingsFileAlbumChoice.selected
          ? BackupSelection.selected
          : BackupSelection.excluded;
      if (target.backupSelection != selection) {
        await api.setChoice(target, selection);
      }
      items.add(SettingsFileReportItem(SettingsFileSection.backupAlbums, target.name, SettingsFileOutcome.restored));
    }
    if (replace) {
      for (final album in device) {
        if (!matched.contains(album.id) && album.backupSelection != BackupSelection.none) {
          await api.setChoice(album, BackupSelection.none);
        }
      }
    }
    _ref.invalidate(backupAlbumProvider);
    return items;
  }

  /// The album of the device for [album]: the same id, else the only one with its name
  static LocalAlbum? _match(SettingsFileBackupAlbum album, List<LocalAlbum> device, Set<String> taken) {
    final byId = device.where((a) => a.id == album.id && !taken.contains(a.id)).firstOrNull;
    if (byId != null) {
      return byId;
    }
    final byName = device.where((a) => a.name == album.name && !taken.contains(a.id)).toList();
    return byName.length == 1 ? byName.single : null;
  }

  ({bool replace, List<SettingsFileBackupAlbum> albums}) _pendingAlbums() {
    final raw = _store.tryGet(StoreKey.pendingBackupAlbums);
    if (raw == null) {
      return (replace: false, albums: const []);
    }
    try {
      final json = jsonDecode(raw);
      if (json case {'albums': final List<Object?> albums}) {
        return (
          replace: json['replace'] == true,
          albums: [for (final album in albums) ?SettingsFileBackupAlbum.fromJson(album)],
        );
      }
    } on FormatException {
      // Dropped below
    }
    return (replace: false, albums: const []);
  }

  /// After a scan of the device: the backup album choices a settings file restored before the albums were listed.
  /// Nothing while the device lists no album yet; once it does, the choices are applied (those of albums not on this
  /// device are dropped) and the key is removed.
  Future<void> applyPendingBackupAlbums() async {
    try {
      if (_store.tryGet(StoreKey.pendingBackupAlbums) == null) {
        return;
      }
    } catch (error) {
      // No Store in this isolate: the main one applies them
      return;
    }
    final pending = _pendingAlbums();
    try {
      final device = await _ref.read(settingsFileAlbumsProvider).all();
      if (device.isEmpty && pending.albums.isNotEmpty) {
        return;
      }
      final items = await _applyAlbums(pending.albums, device, replace: pending.replace);
      final missed = items.where((i) => i.outcome == SettingsFileOutcome.skipped).length;
      _log.info('Backup albums of a settings file applied: ${items.length - missed}, not on this device: $missed');
    } catch (error) {
      _log.warning('The backup albums of a settings file could not be applied: $error');
      return;
    }
    await _store.delete(StoreKey.pendingBackupAlbums);
  }

  /// The same share or server reached the same way: the type, the address, the port and the share
  static bool _sameSource(NetworkSource a, NetworkSource b) {
    if (a.type != b.type) {
      return false;
    }
    if (a.discoveryId != null && a.discoveryId == b.discoveryId) {
      return true;
    }
    return a.host.toLowerCase() == b.host.toLowerCase() &&
        a.host.isNotEmpty &&
        a.port == b.port &&
        a.share == b.share &&
        a.rootPath == b.rootPath &&
        a.username == b.username;
  }

  static bool _sameAddress(String a, String b) {
    String normal(String url) {
      final uri = Uri.tryParse(url.trim());
      if (uri == null) {
        return url.trim().toLowerCase();
      }
      var path = uri.path;
      while (path.endsWith('/')) {
        path = path.substring(0, path.length - 1);
      }
      if (path.endsWith('/api')) {
        path = path.substring(0, path.length - 4);
      }
      return '${uri.scheme}://${uri.host.toLowerCase()}:${uri.hasPort ? uri.port : ''}$path';
    }

    return normal(stripUserInfo(a)) == normal(stripUserInfo(b));
  }
}
