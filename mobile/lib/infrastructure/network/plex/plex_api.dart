// The answers of a Plex Media Server that the app reads, as JSON (Accept: application/json). Plain Dart without I/O,
// so that a large listing can be parsed in another isolate. Plex puts folder like elements in MediaContainer.Directory
// and media in MediaContainer.Metadata, but which array an element lands in varies by endpoint (the folder view puts
// its folders and its items in Metadata), so both arrays are read, in order, and each element is classified by what
// it holds: a file per Media Part, a folder for a listing key, anything else left out.
//
// What the answers hold of the account (user name, account token, the titles and the server paths of the library) is
// read for the few fields named below and never kept, logged or written anywhere else.

import 'dart:io' show InternetAddress, InternetAddressType;

import 'package:immich_mobile/infrastructure/network/entry_names.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_direct.dart';

/// Who answers at an address, from /identity (no token needed)
class PlexIdentity {
  const PlexIdentity({required this.machineIdentifier, this.version, this.claimed});

  /// 40 hex digits, the id of the server for its whole life (the discoveryId of its source)
  final String machineIdentifier;
  final String? version;

  /// Whether the server belongs to a Plex account, which a plex.direct certificate needs
  final bool? claimed;

  /// The first 8 digits, enough to tell two servers apart on the page
  String get shortId => machineIdentifier.length > 8 ? machineIdentifier.substring(0, 8) : machineIdentifier;
}

/// The identity of the server, null when [json] is not one
PlexIdentity? parsePlexIdentity(Object? json) {
  final container = _container(json);
  final id = container?['machineIdentifier'];
  if (id is! String || id.isEmpty) {
    return null;
  }
  final version = container!['version'];
  final claimed = container['claimed'];
  return PlexIdentity(
    machineIdentifier: id,
    version: version is String && version.isNotEmpty ? version : null,
    claimed: claimed is bool ? claimed : (claimed is num ? claimed != 0 : null),
  );
}

/// The name the owner gave the server, from GET / (with the token); null when it has none
String? parsePlexServerName(Object? json) {
  final name = _container(json)?['friendlyName'];
  return name is String && name.trim().isNotEmpty ? name.trim() : null;
}

/// The kinds of library the app shows: photos, movies (also "other videos"), shows. Music is left out.
const plexShownSectionTypes = {'photo', 'movie', 'show'};

/// A library of the server, from /library/sections
class PlexSection {
  const PlexSection({required this.key, required this.title, required this.type});

  /// The id of the section in /library/sections/{key}/...
  final String key;
  final String title;

  /// photo, movie or show
  final String type;

  bool get isPhoto => type == 'photo';
}

/// The sections of /library/sections whose media the app shows, in server order
List<PlexSection> parsePlexSections(Object? json) {
  final sections = <PlexSection>[];
  for (final element in _elements(json)) {
    final key = _string(element['key']);
    final type = element['type'];
    if (key == null || type is! String || !plexShownSectionTypes.contains(type)) {
      continue;
    }
    sections.add(PlexSection(key: key, title: _string(element['title']) ?? key, type: type));
  }
  return sections;
}

/// The folder names of [sections] at the root of the share: their titles, made safe for a path and unique without
/// case ("Photos (2)"), in server order
List<({PlexSection item, String name})> plexSectionEntryNames(List<PlexSection> sections) =>
    uniqueEntryNames(sections, (section) => safeEntryName(section.title), (_) => true);

/// One element of a listing the app keeps, see [parsePlexListing]
sealed class PlexListItem {
  const PlexListItem();

  /// The name of the entry before it is made unique in its folder
  String get name;
}

/// A folder of a listing: what to ask for to list it
class PlexFolderItem extends PlexListItem {
  const PlexFolderItem({required this.key, required this.title});

  /// The request path of its listing, absolute ("/library/sections/1/folder?parent=101") or relative to the listing
  /// it came from
  final String key;
  final String title;

  @override
  String get name => safeEntryName(title);
}

/// One file of a listing: one Part of a Media of an item (a movie in two files, or in two versions, gives two)
class PlexFileItem extends PlexListItem {
  const PlexFileItem({
    required this.partKey,
    required this.fileName,
    this.partId,
    this.size,
    this.addedAt,
    this.mimeType,
    this.width,
    this.height,
    this.durationMs,
    this.thumb,
    this.ratingKey,
  });

  /// The request path of the bytes of the file (/library/parts/{id}/{changestamp}/file.{ext})
  final String partKey;

  /// The last segment of the file's path on the server (the name on the disk); else the title and the container
  final String fileName;
  final int? partId;
  final int? size;

  /// When the item was added to the library. Not updatedAt: it moves with every metadata refresh, and the "sent before"
  /// marks of the uploads are keyed by size and date.
  final DateTime? addedAt;
  final String? mimeType;
  final int? width;
  final int? height;
  final int? durationMs;

  /// The request path of the picture the server keeps of the item, for its photo transcoder
  final String? thumb;
  final String? ratingKey;

  @override
  String get name => safeEntryName(fileName);
}

/// One page of a listing
class PlexListingPage {
  const PlexListingPage({required this.items, required this.count, required this.offset, this.totalSize});

  final List<PlexListItem> items;

  /// The elements the page held, those left out included: what the next page starts after
  final int count;
  final int offset;

  /// Null when the server does not tell; the pages then go on while full
  final int? totalSize;
}

/// One page of a folder view, an album list or an album's children
PlexListingPage parsePlexListing(Object? json) {
  final container = _container(json);
  final elements = _elements(json);
  final items = <PlexListItem>[];
  for (final element in elements) {
    final parts = _partsOf(element);
    if (parts.isNotEmpty) {
      items.addAll(parts);
      continue;
    }
    final key = _string(element['key']);
    if (key != null && _isListingKey(key)) {
      items.add(PlexFolderItem(key: key, title: _string(element['title']) ?? ''));
    }
  }
  final offset = container?['offset'];
  final total = container?['totalSize'];
  return PlexListingPage(
    items: items,
    count: elements.length,
    offset: offset is int ? offset : 0,
    totalSize: total is int && total >= 0 ? total : null,
  );
}

/// The keys of what lists more: a folder of the folder view, the children of an album. An item without media
/// (/library/metadata/{id}) is no folder.
bool _isListingKey(String key) {
  final path = key.split('?').first;
  return path.endsWith('/folder') || path.endsWith('/children');
}

List<PlexFileItem> _partsOf(Map<String, Object?> element) {
  final medias = element['Media'];
  if (medias is! List) {
    return const [];
  }
  final title = _string(element['title']) ?? '';
  final added = element['addedAt'];
  final addedAt = added is int && added > 0 ? DateTime.fromMillisecondsSinceEpoch(added * 1000, isUtc: true) : null;
  final files = <PlexFileItem>[];
  for (final media in medias.whereType<Map>()) {
    final parts = media['Part'];
    if (parts is! List) {
      continue;
    }
    for (final part in parts.whereType<Map>()) {
      final key = _string(part['key']);
      if (key == null) {
        continue;
      }
      final container = _string(part['container']) ?? _string(media['container']);
      final fileName = _baseName(_string(part['file'])) ?? _titleName(title, container);
      if (fileName == null) {
        continue;
      }
      files.add(
        PlexFileItem(
          partKey: key,
          fileName: fileName,
          partId: _int(part['id']),
          size: _int(part['size']),
          addedAt: addedAt,
          mimeType: _mimeTypes[container?.toLowerCase()],
          width: _int(media['width']),
          height: _int(media['height']),
          durationMs: _int(part['duration']) ?? _int(media['duration']),
          thumb: _string(element['thumb']),
          ratingKey: _string(element['ratingKey']),
        ),
      );
    }
  }
  return files;
}

/// The last segment of a server path, "/" or "\" separated (a server on Windows)
String? _baseName(String? path) {
  if (path == null) {
    return null;
  }
  final name = path.split(RegExp(r'[/\\]')).last.trim();
  return name.isEmpty ? null : name;
}

String? _titleName(String title, String? container) {
  if (title.trim().isEmpty || container == null) {
    return null;
  }
  return '${title.trim()}.${_extensions[container.toLowerCase()] ?? container.toLowerCase()}';
}

/// Plex container names that are no file extension
const _extensions = {'jpeg': 'jpg', 'mpegts': 'ts', 'matroska': 'mkv'};

/// The content types of the containers Plex names, for the players; the extension decides for the others
const _mimeTypes = {
  'jpeg': 'image/jpeg',
  'jpg': 'image/jpeg',
  'png': 'image/png',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'heic': 'image/heic',
  'heif': 'image/heic',
  'tiff': 'image/tiff',
  'bmp': 'image/bmp',
  'mp4': 'video/mp4',
  'm4v': 'video/mp4',
  'mov': 'video/quicktime',
  'mkv': 'video/x-matroska',
  'webm': 'video/webm',
  'avi': 'video/x-msvideo',
  'mpegts': 'video/mp2t',
  '3gp': 'video/3gpp',
};

/// What /myplex/account tells of the address outside home. The answer also holds the user name and an account token,
/// which are not read.
class PlexAccountAddress {
  const PlexAccountAddress({this.publicAddress, this.publicPort, this.mappingState});

  final String? publicAddress;
  final int? publicPort;

  /// "mapped", "unknown", "failed"...: whether the server could open its port on the router
  final String? mappingState;
}

/// The address fields of /myplex/account (under MyPlex; under MediaContainer in older versions), null when [json]
/// has neither
PlexAccountAddress? parsePlexAccount(Object? json) {
  final account = json is Map ? (json['MyPlex'] ?? json['MediaContainer']) : null;
  if (account is! Map) {
    return null;
  }
  return PlexAccountAddress(
    publicAddress: _string(account['publicAddress']),
    publicPort: _int(account['publicPort']),
    mappingState: _string(account['mappingState']),
  );
}

/// What /:/prefs tells of the address outside home: the port forwarded by hand, and an address of [hash] among the
/// custom server addresses the owner gave
class PlexPrefsAddress {
  const PlexPrefsAddress({this.manualPort, this.customHost, this.customPort});

  /// ManualPortMappingPort when ManualPortMappingMode is on: the public port
  final int? manualPort;

  /// From a `https://<ipv4-dashes>.<hash>.plex.direct:<port>` address of customConnections
  final String? customHost;
  final int? customPort;
}

PlexPrefsAddress parsePlexPrefs(Object? json, String hash) {
  final settings = <String, Object?>{};
  for (final element in _elements(json, array: 'Setting')) {
    final id = element['id'];
    if (id is String) {
      settings[id] = element['value'];
    }
  }
  // A bool in the answers of 1.42, a number or a string in other versions
  final mode = settings['ManualPortMappingMode'];
  final manual = mode == true || mode == 1 || mode == '1' || mode == 'true';
  final port = _int(settings['ManualPortMappingPort']);
  String? customHost;
  int? customPort;
  final custom = settings['customConnections'];
  if (custom is String) {
    for (final text in custom.split(',')) {
      final uri = Uri.tryParse(text.trim());
      final target = uri == null || !uri.isScheme('https') ? null : parsePlexDirectHost(uri.host.toLowerCase());
      if (target != null && target.hash == hash && uri!.hasPort) {
        customHost = target.address.address;
        customPort = uri.port;
        break;
      }
    }
  }
  return PlexPrefsAddress(
    manualPort: manual && _isPort(port) ? port : null,
    customHost: customHost,
    customPort: customPort,
  );
}

/// The address outside home the server tells: the public IPv4 address of /myplex/account with its public port (or
/// the port forwarded by hand), else a plex.direct address of the custom server addresses. Null when neither gives a
/// public IPv4 address and a port.
({String host, int port, String? mapping})? plexPublicAddressOf(PlexAccountAddress? account, PlexPrefsAddress? prefs) {
  final address = account?.publicAddress;
  final port = _isPort(account?.publicPort) ? account!.publicPort : prefs?.manualPort;
  if (address != null && isPublicIPv4(address) && _isPort(port)) {
    return (host: address, port: port!, mapping: account?.mappingState);
  }
  final customHost = prefs?.customHost;
  final customPort = prefs?.customPort;
  if (customHost != null && isPublicIPv4(customHost) && _isPort(customPort)) {
    return (host: customHost, port: customPort!, mapping: account?.mappingState);
  }
  return null;
}

/// An IPv4 address reachable from the internet: not private, loopback, link local, shared by a carrier (100.64/10),
/// multicast, reserved or 0/8
bool isPublicIPv4(String text) {
  final address = InternetAddress.tryParse(text);
  if (address == null || address.type != InternetAddressType.IPv4) {
    return false;
  }
  final b = address.rawAddress;
  return !(b[0] == 0 ||
      b[0] == 10 ||
      b[0] == 127 ||
      (b[0] == 100 && b[1] >= 64 && b[1] < 128) ||
      (b[0] == 169 && b[1] == 254) ||
      (b[0] == 172 && b[1] >= 16 && b[1] < 32) ||
      (b[0] == 192 && b[1] == 168) ||
      b[0] >= 224);
}

bool _isPort(int? port) => port != null && port > 0 && port < 65536;

Map<String, Object?>? _container(Object? json) {
  final container = json is Map ? json['MediaContainer'] : null;
  return container is Map ? container.cast<String, Object?>() : null;
}

/// The elements of both arrays of the container, Directory first, in order
List<Map<String, Object?>> _elements(Object? json, {String? array}) {
  final container = _container(json);
  if (container == null) {
    return const [];
  }
  return [
    for (final name in array == null ? const ['Directory', 'Metadata'] : [array])
      if (container[name] case final List list)
        for (final element in list)
          if (element is Map) element.cast<String, Object?>(),
  ];
}

String? _string(Object? value) => switch (value) {
  final String text when text.isNotEmpty => text,
  final num number => '$number',
  _ => null,
};

int? _int(Object? value) => switch (value) {
  final int number => number,
  final double number when number.isFinite => number.round(),
  final String text => int.tryParse(text),
  _ => null,
};
