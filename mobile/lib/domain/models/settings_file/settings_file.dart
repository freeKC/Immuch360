// The settings file (issue 16): what one install of the app writes so that another install, or the same device after
// a reinstall, gets its servers, sources, settings and backup albums back. One JSON file, versioned, with a header in
// clear naming the app and the date. Two levels: "settings" holds no secret and stays readable; "accounts" adds the
// session of the Immich server and the passwords of the sources, and the whole content is then encrypted with a key
// derived from a passphrase the user types (see settings_file_crypto.dart). The user guide tells what each level holds
// and why some values never leave the device (docs/immuch360/user-guide.md, "Keep your settings in a file").

import 'dart:convert';

/// What a file holds: the settings only, or the settings with the accounts and the passwords (encrypted)
enum SettingsFileLevel { settings, accounts }

/// Merge keeps what this install has and adds the file's; replace puts the file's sources, settings and album choices
/// in place of this install's
enum SettingsFileRestoreMode { merge, replace }

/// Why a file cannot be read
enum SettingsFileError {
  /// Not JSON, or JSON of something else
  notASettingsFile,

  /// Written by a later build with a format this build does not know: update the app
  newerVersion,

  /// A settings file whose content is cut or changed
  damaged,

  /// The passphrase does not open the file (or its header was changed, which the encryption checks too)
  wrongPassphrase,
}

class SettingsFileException implements Exception {
  const SettingsFileException(this.error, [this.detail]);

  final SettingsFileError error;
  final String? detail;

  @override
  String toString() => 'SettingsFileException(${error.name}${detail == null ? '' : ': $detail'})';
}

/// The app that wrote the file, shown in the preview
class SettingsFileOrigin {
  const SettingsFileOrigin({required this.appVersion, this.build = '', this.platform = ''});

  final String appVersion;
  final String build;

  /// android, ios, windows, macos or linux
  final String platform;

  Map<String, Object?> toJson() => {'name': 'Immuch360', 'version': appVersion, 'build': build, 'platform': platform};

  static SettingsFileOrigin fromJson(Object? json) {
    if (json is! Map) {
      return const SettingsFileOrigin(appVersion: '');
    }
    String text(String key) => json[key] is String ? json[key] as String : (json[key]?.toString() ?? '');
    return SettingsFileOrigin(appVersion: text('version'), build: text('build'), platform: text('platform'));
  }
}

/// The Immich server: its addresses always, the session token at the accounts level only
class SettingsFileServer {
  const SettingsFileServer({required this.url, this.endpoint, this.accessToken});

  /// What the user typed (StoreKey.serverUrl)
  final String url;

  /// The API address found from it (StoreKey.serverEndpoint), null when unknown
  final String? endpoint;

  /// The session of the old install (StoreKey.accessToken), accounts level only
  final String? accessToken;

  bool get hasAccount => accessToken != null && accessToken!.isNotEmpty;

  Map<String, Object?> toJson() => {'url': url, 'endpoint': ?endpoint, 'accessToken': ?accessToken};

  static SettingsFileServer? fromJson(Object? json) {
    if (json is! Map || json['url'] is! String || (json['url'] as String).isEmpty) {
      return null;
    }
    final endpoint = json['endpoint'];
    final token = json['accessToken'];
    return SettingsFileServer(
      url: json['url'] as String,
      endpoint: endpoint is String && endpoint.isNotEmpty ? endpoint : null,
      accessToken: token is String && token.isNotEmpty ? token : null,
    );
  }

  SettingsFileServer withoutSecrets() =>
      SettingsFileServer(url: stripUserInfo(url), endpoint: endpoint == null ? null : stripUserInfo(endpoint!));
}

/// The passwords of one source: SMB and WebDAV password, Plex token, TP-Link password, the account password of a
/// camera of another brand; the camera account password of a Tapo camera, the stream addresses of a camera of another
/// brand (their path may hold a token)
class SettingsFileSourceSecrets {
  const SettingsFileSourceSecrets({this.password, this.cameraPassword});

  final String? password;
  final String? cameraPassword;

  bool get isEmpty => (password == null || password!.isEmpty) && (cameraPassword == null || cameraPassword!.isEmpty);

  Map<String, Object?> toJson() => {'password': ?password, 'cameraPassword': ?cameraPassword};

  static SettingsFileSourceSecrets fromJson(Object? json) {
    if (json is! Map) {
      return const SettingsFileSourceSecrets();
    }
    final password = json['password'];
    final cameraPassword = json['cameraPassword'];
    return SettingsFileSourceSecrets(
      password: password is String && password.isNotEmpty ? password : null,
      cameraPassword: cameraPassword is String && cameraPassword.isNotEmpty ? cameraPassword : null,
    );
  }
}

/// selected or excluded: an album left as it is (none) is not written
enum SettingsFileAlbumChoice { selected, excluded }

/// A backup choice for an album of the device, found again by its id (the same on the same device, and for the
/// folders of Android, whose id comes from their path) or by its name
class SettingsFileBackupAlbum {
  const SettingsFileBackupAlbum({required this.id, required this.name, required this.choice});

  final String id;
  final String name;
  final SettingsFileAlbumChoice choice;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'selection': choice.name};

  static SettingsFileBackupAlbum? fromJson(Object? json) {
    if (json is! Map || json['id'] is! String || json['name'] is! String) {
      return null;
    }
    final choice = SettingsFileAlbumChoice.values.where((c) => c.name == json['selection']).firstOrNull;
    if (choice == null) {
      return null;
    }
    return SettingsFileBackupAlbum(id: json['id'] as String, name: json['name'] as String, choice: choice);
  }
}

/// What a file carries, once read (and opened when it is encrypted)
class SettingsFileContent {
  const SettingsFileContent({
    this.server,
    this.settings = const {},
    this.store = const {},
    this.sources = const [],
    this.sourceSecrets = const {},
    this.backupAlbums = const [],
    this.pairing = const {},
  });

  final SettingsFileServer? server;

  /// The app settings, by SettingsKey name, as the settings table stores them (null for a value set to nothing)
  final Map<String, String?> settings;

  /// The values of the Store the user chose (see SettingsFileService.portableStoreKeys), by StoreKey name
  final Map<String, Object?> store;

  /// The network sources as the app stores them (NetworkSource.toJson), never with a password
  final List<Map<String, Object?>> sources;

  /// The passwords of the sources, by source id: accounts level only
  final Map<String, SettingsFileSourceSecrets> sourceSecrets;

  final List<SettingsFileBackupAlbum> backupAlbums;

  /// The big screens this phone signed in, and the name of this big screen, by StoreKey name: accounts level only
  final Map<String, Object?> pairing;

  /// Whether anything in it needs the accounts level
  bool get hasSecrets =>
      (server?.hasAccount ?? false) ||
      sourceSecrets.values.any((secrets) => !secrets.isEmpty) ||
      settings.containsKey(secretSettingName) ||
      pairing.isNotEmpty;

  /// The proxy headers often carry an access token: accounts level only
  static const secretSettingName = 'networkCustomHeaders';

  /// The same content without anything secret, for the settings level: no token, no password, no proxy header, no
  /// user and password in an address, no pairing
  SettingsFileContent withoutSecrets() => SettingsFileContent(
    server: server?.withoutSecrets(),
    settings: {
      for (final entry in settings.entries)
        if (entry.key != secretSettingName) entry.key: _settingWithoutSecrets(entry.key, entry.value),
    },
    store: store,
    sources: sources,
    backupAlbums: backupAlbums,
  );

  Map<String, Object?> toJson() => {
    if (server != null) 'server': server!.toJson(),
    'settings': settings,
    'store': store,
    'sources': sources,
    if (sourceSecrets.isNotEmpty)
      'sourceSecrets': {for (final entry in sourceSecrets.entries) entry.key: entry.value.toJson()},
    'backupAlbums': [for (final album in backupAlbums) album.toJson()],
    if (pairing.isNotEmpty) 'pairing': pairing,
  };

  /// Lenient: a missing or unreadable section is empty, so that a file of an older build (fewer sections) reads
  static SettingsFileContent fromJson(Object? json) {
    if (json is! Map) {
      throw const SettingsFileException(SettingsFileError.damaged, 'content');
    }
    final settings = json['settings'];
    final store = json['store'];
    final sources = json['sources'];
    final secrets = json['sourceSecrets'];
    final albums = json['backupAlbums'];
    final pairing = json['pairing'];
    return SettingsFileContent(
      server: SettingsFileServer.fromJson(json['server']),
      settings: {
        if (settings is Map)
          for (final entry in settings.entries)
            if (entry.key is String && (entry.value == null || entry.value is String))
              entry.key as String: entry.value as String?,
      },
      store: {
        if (store is Map)
          for (final entry in store.entries)
            if (entry.key is String) entry.key as String: entry.value,
      },
      sources: [
        if (sources is List)
          for (final source in sources)
            if (source is Map) {for (final entry in source.entries) entry.key.toString(): entry.value},
      ],
      sourceSecrets: {
        if (secrets is Map)
          for (final entry in secrets.entries)
            if (entry.key is String) entry.key as String: SettingsFileSourceSecrets.fromJson(entry.value),
      },
      backupAlbums: [
        if (albums is List)
          for (final album in albums) ?SettingsFileBackupAlbum.fromJson(album),
      ],
      pairing: {
        if (pairing is Map)
          for (final entry in pairing.entries)
            if (entry.key is String) entry.key as String: entry.value,
      },
    );
  }
}

/// The settings that hold addresses: the user and password a URL may carry are removed at the settings level
const _addressSettings = {'networkLocalEndpoint', 'networkExternalEndpointList'};

String? _settingWithoutSecrets(String name, String? value) {
  if (value == null || !_addressSettings.contains(name)) {
    return value;
  }
  if (name == 'networkLocalEndpoint') {
    return stripUserInfo(value);
  }
  // A list, stored as a JSON array of strings (ListCodec)
  try {
    final list = jsonDecode(value);
    if (list is List) {
      return jsonEncode([for (final item in list) item is String ? stripUserInfo(item) : item]);
    }
  } on FormatException {
    // Left as it is: not a list this build wrote
  }
  return value;
}

/// [url] without the user and password it may carry ("https://user:pass@host" to "https://host")
String stripUserInfo(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.userInfo.isEmpty) {
    return url;
  }
  return uri.replace(userInfo: '').toString();
}

/// The parameters of the key derivation, written in clear in the file so that a later build may raise them
class SettingsFileKdf {
  const SettingsFileKdf({
    required this.salt,
    this.memoryKiB = defaultMemoryKiB,
    this.iterations = defaultIterations,
    this.parallelism = 1,
  });

  /// RFC 9106 and the OWASP password storage sheet (2025): Argon2id, 19 MiB, two passes, one lane. About 0.2 s on a
  /// computer, about a second on a TV; little memory for the Quest and the TVs
  static const defaultMemoryKiB = 19456;
  static const defaultIterations = 2;

  /// Bounds a file may ask, so that a file made to exhaust the device is refused: 256 MiB, 10 passes, 4 lanes
  static const maxMemoryKiB = 262144;
  static const maxIterations = 10;
  static const maxParallelism = 4;

  final List<int> salt;
  final int memoryKiB;
  final int iterations;
  final int parallelism;

  Map<String, Object?> toJson() => {
    'name': 'argon2id',
    'memoryKiB': memoryKiB,
    'iterations': iterations,
    'parallelism': parallelism,
    'salt': base64.encode(salt),
  };

  static SettingsFileKdf fromJson(Object? json) {
    if (json is! Map || json['name'] != 'argon2id') {
      throw const SettingsFileException(SettingsFileError.damaged, 'kdf');
    }
    final memory = json['memoryKiB'];
    final iterations = json['iterations'];
    final parallelism = json['parallelism'];
    if (memory is! int ||
        iterations is! int ||
        parallelism is! int ||
        memory < 8 * parallelism ||
        memory > maxMemoryKiB ||
        iterations < 1 ||
        iterations > maxIterations ||
        parallelism < 1 ||
        parallelism > maxParallelism) {
      throw const SettingsFileException(SettingsFileError.damaged, 'kdf parameters');
    }
    return SettingsFileKdf(
      salt: _bytes(json['salt'], 'salt'),
      memoryKiB: memory,
      iterations: iterations,
      parallelism: parallelism,
    );
  }
}

/// The encrypted content of an accounts level file
class SettingsFileSealed {
  const SettingsFileSealed({required this.kdf, required this.nonce, required this.ciphertext});

  final SettingsFileKdf kdf;
  final List<int> nonce;

  /// The content as JSON in UTF-8, encrypted with AES-256-GCM, its 16 byte tag at the end
  final List<int> ciphertext;
}

/// A settings file: its header, and its content in clear (settings level) or sealed (accounts level)
class SettingsFile {
  const SettingsFile({
    required this.origin,
    required this.createdAt,
    required this.level,
    this.version = currentVersion,
    this.content,
    this.sealed,
  }) : assert((content == null) != (sealed == null));

  static const formatName = 'immuch360-settings';

  /// 1: the first format (release 46)
  static const currentVersion = 1;

  /// The type of the file for the share sheet and the save dialogs
  static const mimeType = 'application/json';

  final int version;
  final SettingsFileOrigin origin;
  final DateTime createdAt;
  final SettingsFileLevel level;
  final SettingsFileContent? content;
  final SettingsFileSealed? sealed;

  bool get isEncrypted => sealed != null;

  /// The name to save it under: immuch360-settings-2026-11-11.json
  static String fileName(DateTime date) {
    String two(int value) => value.toString().padLeft(2, '0');
    return 'immuch360-settings-${date.year}-${two(date.month)}-${two(date.day)}.json';
  }

  /// What the encryption binds to the ciphertext: a changed header fails as a wrong passphrase does
  static List<int> associatedData(int version, SettingsFileLevel level, DateTime createdAt) =>
      utf8.encode('$formatName|$version|${level.name}|${createdAt.toUtc().toIso8601String()}');

  String encode() {
    final json = <String, Object?>{
      'format': formatName,
      'version': version,
      'app': origin.toJson(),
      'createdAt': createdAt.toUtc().toIso8601String(),
      'level': level.name,
      if (content != null) 'content': content!.toJson(),
      if (sealed != null) ...{
        'encryption': {'kdf': sealed!.kdf.toJson(), 'cipher': 'aes-256-gcm', 'nonce': base64.encode(sealed!.nonce)},
        'payload': base64.encode(sealed!.ciphertext),
      },
    };
    return const JsonEncoder.withIndent('  ').convert(json);
  }

  /// Whether [text] starts like a settings file, without reading it all (for a file shared to the app)
  static bool looksLikeSettingsFile(String text) => text.contains('"format"') && text.contains('"$formatName"');

  static SettingsFile parse(String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      throw const SettingsFileException(SettingsFileError.notASettingsFile);
    }
    if (json is! Map || json['format'] != formatName) {
      throw const SettingsFileException(SettingsFileError.notASettingsFile);
    }
    final version = json['version'];
    if (version is! int || version < 1) {
      throw const SettingsFileException(SettingsFileError.damaged, 'version');
    }
    if (version > currentVersion) {
      throw SettingsFileException(SettingsFileError.newerVersion, '$version');
    }
    final migrated = _migrate(json, version);
    final level = SettingsFileLevel.values.where((l) => l.name == migrated['level']).firstOrNull;
    final createdAt = switch (migrated['createdAt']) {
      final String text => DateTime.tryParse(text),
      _ => null,
    };
    if (level == null || createdAt == null) {
      throw const SettingsFileException(SettingsFileError.damaged, 'header');
    }
    final origin = SettingsFileOrigin.fromJson(migrated['app']);
    if (level == SettingsFileLevel.settings) {
      return SettingsFile(
        version: version,
        origin: origin,
        createdAt: createdAt,
        level: level,
        content: SettingsFileContent.fromJson(migrated['content']),
      );
    }
    final encryption = migrated['encryption'];
    if (encryption is! Map || encryption['cipher'] != 'aes-256-gcm') {
      throw const SettingsFileException(SettingsFileError.damaged, 'encryption');
    }
    final nonce = _bytes(encryption['nonce'], 'nonce');
    final ciphertext = _bytes(migrated['payload'], 'payload');
    if (nonce.length != 12 || ciphertext.length < 16) {
      throw const SettingsFileException(SettingsFileError.damaged, 'payload');
    }
    return SettingsFile(
      version: version,
      origin: origin,
      createdAt: createdAt,
      level: level,
      sealed: SettingsFileSealed(
        kdf: SettingsFileKdf.fromJson(encryption['kdf']),
        nonce: nonce,
        ciphertext: ciphertext,
      ),
    );
  }

  /// A file of an older format brought to the current one. Version 1 is the first: nothing to do yet. A later
  /// version adds its step here (rename a section, move a key), so that every file ever written still imports.
  static Map<Object?, Object?> _migrate(Map<Object?, Object?> json, int version) {
    return json;
  }
}

List<int> _bytes(Object? value, String what) {
  if (value is! String) {
    throw SettingsFileException(SettingsFileError.damaged, what);
  }
  try {
    return base64.decode(value);
  } on FormatException {
    throw SettingsFileException(SettingsFileError.damaged, what);
  }
}
