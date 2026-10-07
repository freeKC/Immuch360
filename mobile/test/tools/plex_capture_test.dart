// Captures the answers of a real Plex Media Server for the fixtures of test/fixtures/plex, sanitised, outside the
// repository. Skipped unless IMMUCH_PLEX_CAPTURE=1, IMMUCH_PLEX_URL and IMMUCH_PLEX_TOKEN are set (IMMUCH_PLEX_LOCAL,
// host:port, is used instead of the URL when given). Writes to IMMUCH_PLEX_CAPTURE_OUT, /tmp/plex-capture by default.
//
// Sanitised: the token, the hash, the machine identifier, the addresses, the user name, the titles and names, the
// Location paths and the folders of Part.file (its extension kept) are replaced; keys, types, sizes, dimensions and
// durations are kept. A file is not written when a value of the environment is still in it. The developer reads the
// result before copying anything into the repository.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_api.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_client.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_direct.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_pairing.dart';

const _syntheticHash = '0123456789abcdef0123456789abcdef';
const _syntheticMachine = '0000000000000000000000000000000000000001';

/// Keys whose text is a name given by someone: replaced by a made up one
const _nameKeys = {
  'title', 'title1', 'title2', 'librarySectionTitle', 'summary', 'tagline', 'studio', 'originalTitle', 'titleSort', //
  'slug', 'friendlyName', 'username', 'email', 'name', 'label', 'alt', 'grandparentTitle', 'parentTitle',
  'contentRating', 'myPlexUsername', 'tag', 'filename',
};

/// The settings of /:/prefs kept, with what they say of the address outside home
const _keptSettings = {
  'ManualPortMappingMode', 'ManualPortMappingPort', 'customConnections', 'GdmEnabled', 'secureConnections', //
  'LastAutomaticMappedPort', 'FriendlyName',
};

class _Sanitiser {
  _Sanitiser(this.secrets);

  /// Values that must not stay anywhere
  final List<String> secrets;
  var _names = 0;
  var _files = 0;

  Object? clean(Object? value, [String? key]) {
    if (value is Map) {
      if (key == 'MediaContainer' && value['Setting'] is List) {
        return {
          ...{for (final e in value.entries) '${e.key}': e.key == 'Setting' ? null : clean(e.value, '${e.key}')},
          'Setting': [
            for (final setting in value['Setting'] as List)
              if (setting is Map && _keptSettings.contains(setting['id'])) _setting(setting),
          ],
        };
      }
      return {for (final e in value.entries) '${e.key}': clean(e.value, '${e.key}')};
    }
    if (value is List) {
      return [for (final element in value) clean(element, key)];
    }
    if (value is! String) {
      return value;
    }
    switch (key) {
      case 'machineIdentifier':
        return _syntheticMachine;
      case 'authToken' || 'token' || 'accessToken':
        return 'TEST-ACCOUNT-TOKEN-0000';
      case 'publicAddress':
        return '203.0.113.7';
      case 'privateAddress':
        return '192.0.2.20';
      case 'uuid' || 'librarySectionUUID':
        return '00000000-0000-0000-0000-000000000000';
      case 'file':
        final name = value.split(RegExp(r'[/\\]')).last;
        final dot = name.lastIndexOf('.');
        return '/data/library/file-${++_files}${dot > 0 ? name.substring(dot) : ''}';
      case 'path':
        return '/data/library-${++_names}';
      case 'guid':
        return 'plex://item/${++_names}';
    }
    if (key != null && _nameKeys.contains(key)) {
      return value.isEmpty ? value : 'Name ${++_names}';
    }
    var text = value;
    for (final secret in secrets) {
      text = text.replaceAll(secret, 'x');
    }
    return text;
  }

  /// A setting of /:/prefs: its value replaced when it is text (a name, the custom server addresses)
  Map<String, Object?> _setting(Map<Object?, Object?> setting) {
    final cleaned = {for (final e in setting.entries) '${e.key}': clean(e.value, '${e.key}')};
    final value = setting['value'];
    if (value is String && value.isNotEmpty) {
      cleaned['value'] = setting['id'] == 'FriendlyName'
          ? 'Test Plex'
          : 'https://203-0-113-9.$_syntheticHash.plex.direct:443';
    }
    return cleaned;
  }

  /// The secrets still in [text], by index (never by value)
  List<int> leaks(String text) => [
    for (final (index, secret) in secrets.indexed)
      if (text.contains(secret)) index,
  ];
}

void main() {
  final environment = Platform.environment;
  final url = environment['IMMUCH_PLEX_URL'] ?? '';
  final token = environment['IMMUCH_PLEX_TOKEN'] ?? '';
  final local = environment['IMMUCH_PLEX_LOCAL'] ?? '';
  final out = Directory(environment['IMMUCH_PLEX_CAPTURE_OUT'] ?? '/tmp/plex-capture');
  final enabled = environment['IMMUCH_PLEX_CAPTURE'] == '1' && url.isNotEmpty && token.isNotEmpty;

  test('captures the answers of the server, sanitised, outside the repository', () async {
    expect(out.absolute.path.contains('/idtr/'), isFalse, reason: 'never into the repository');
    final pairing = PlexPairing();
    final public = parsePlexAddress(url);
    var server = await pairing.lookUp(public);
    if (local.isNotEmpty) {
      server = await pairing.lookUp(parsePlexAddress(local), knownHash: server.hash);
    }
    final base = plexDirectUri(server.address, server.port, server.hash);
    final client = PlexClient(
      IOClient(pinnedPlexHttpClient(server.hash)),
      token: token,
      clientIdentifier: await plexClientIdentifier(),
    );
    addTearDown(client.close);
    final account = await client.getJson(base.resolve('/myplex/account'), (json) => json);
    final secrets = {
      token,
      server.hash,
      server.machineIdentifier,
      server.address.address,
      server.address.address.replaceAll('.', '-'),
      public.host,
      public.host.replaceAll('.', '-'),
      if (account is Map && account['MyPlex'] is Map) ...[
        for (final key in ['username', 'email', 'publicAddress', 'privateAddress', 'authToken'])
          if ((account['MyPlex'] as Map)[key] case final String value when value.length >= 4) value,
      ],
    }.where((value) => value.length >= 4).toList();
    final sanitiser = _Sanitiser(secrets);
    await out.create(recursive: true);
    var written = 0;

    Future<void> save(String name, Object? json) async {
      final text = const JsonEncoder.withIndent('  ').convert(sanitiser.clean(json));
      final leaks = sanitiser.leaks(text);
      if (leaks.isNotEmpty) {
        fail('$name still holds ${leaks.length} value(s) of the environment: not written');
      }
      await File('${out.path}/$name').writeAsString('$text\n');
      written++;
    }

    Future<Object?> get(String path, {int? start, int? size, bool withToken = true}) => client.getJson(
      base.resolve(path),
      (json) => json,
      withToken: withToken,
      headers: {
        if (start != null) 'x-plex-container-start': '$start',
        if (size != null) 'x-plex-container-size': '$size',
      },
    );

    await save('identity.json', await get('/identity', withToken: false));
    await save('server_root.json', await get('/'));
    final sectionsJson = await get('/library/sections');
    await save('sections.json', sectionsJson);
    await save('account.json', account);
    await save('prefs.json', await get('/:/prefs'));
    final sections = parsePlexSections(sectionsJson);
    final browsable = sections.where((s) => !s.isPhoto).firstOrNull;
    if (browsable != null) {
      final root = await get('/library/sections/${browsable.key}/folder', start: 0, size: 200);
      await save('folder_root.json', root);
      final child = parsePlexListing(root).items.whereType<PlexFolderItem>().firstOrNull;
      if (child != null) {
        await save('folder_child_page1.json', await get(child.key, start: 0, size: 2));
        await save('folder_child_page2.json', await get(child.key, start: 2, size: 2));
      }
    }
    final photos = sections.where((s) => s.isPhoto).firstOrNull;
    if (photos != null) {
      final all = await get('/library/sections/${photos.key}/all', start: 0, size: 50);
      await save('photo_all.json', all);
      final album = parsePlexListing(all).items.whereType<PlexFolderItem>().firstOrNull;
      if (album != null) {
        await save('album_children.json', await get(album.key, start: 0, size: 50));
      }
    }
    stdout.writeln('plex capture: $written files written, photo section ${photos != null}');
    expect(written, greaterThanOrEqualTo(5));
  }, skip: enabled ? false : 'needs IMMUCH_PLEX_CAPTURE=1, IMMUCH_PLEX_URL and IMMUCH_PLEX_TOKEN');
}
