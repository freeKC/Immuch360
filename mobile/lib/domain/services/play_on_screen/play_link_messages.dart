// The messages of "Play on the TV" (play_link_protocol.dart): what the phone asks the screen, and the state the screen
// tells back. The play message names the item on the screen's own access to the same source, never a token: the
// Plex machine identifier of the server and the rating key of a film (build 51, unchanged), an Immich asset id with
// the phone's user id, a share's identity with a path, a Jellyfin or Emby item (build 52, [PlayTarget]). A build 51
// screen answers "invalid" to a kind it does not know: the phone then asks to update it.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';

/// What the screen does now
enum ScreenPlayPhase {
  /// Nothing from a phone plays
  idle('idle'),

  /// The Quest asks its user before it plays
  asking('asking'),

  /// The film opens: the server is asked, the player loads
  opening('opening'),
  playing('playing'),
  paused('paused'),
  buffering('buffering'),
  ended('ended'),

  /// A photo is on the screen (build 52: never told to a phone that sent a film)
  showing('showing'),

  /// It did not play: [ScreenPlayState.reason] tells why
  failed('failed');

  const ScreenPlayPhase(this.wire);
  final String wire;

  static ScreenPlayPhase fromWire(Object? value) =>
      ScreenPlayPhase.values.where((phase) => phase.wire == value).firstOrNull ?? ScreenPlayPhase.idle;
}

/// Why a play did not happen, as the phone says it in one sentence
enum ScreenPlayReason {
  /// The screen has no Plex source of that machine identifier: "Add (server) to (screen)"
  noSuchServer('noSuchServer'),

  /// The screen's token for that server is refused
  tokenRefused('tokenRefused'),

  /// The server does not answer the screen
  unreachable('unreachable'),

  /// The server does not know that item
  notFound('notFound'),

  /// The user of the screen said Not now
  declined('declined'),

  /// The screen is busy (a dialog of its own, a sign in)
  busy('busy'),

  /// Anything else
  failed('failed'),

  /// The screen is not signed in to an Immich server
  notSignedIn('notSignedIn'),

  /// The screen's Immich server says the asset is not for its account, at an address the phone uses too
  otherAccount('otherAccount'),

  /// The screen's Immich server does not know the asset, and the phone uses another address
  otherServer('otherServer'),

  /// The screen's account may not see the asset (a shared album or a partner it does not have)
  notVisible('notVisible'),

  /// The asset is in a locked folder: a screen never opens one
  locked('locked'),

  /// The screen has no source of that identity (a share, a Jellyfin or Emby server)
  noSuchSource('noSuchSource');

  const ScreenPlayReason(this.wire);
  final String wire;

  static ScreenPlayReason? fromWire(Object? value) =>
      ScreenPlayReason.values.where((reason) => reason.wire == value).firstOrNull;
}

/// The kind of a track
enum PlayTrackKind {
  audio('audio'),
  subtitle('subtitle');

  const PlayTrackKind(this.wire);
  final String wire;

  static PlayTrackKind? fromWire(Object? value) => switch (value) {
    'audio' => PlayTrackKind.audio,
    'subtitle' => PlayTrackKind.subtitle,
    _ => null,
  };
}

/// A track of the film as the screen's player lists it
class PlayTrack {
  const PlayTrack({required this.kind, required this.id, required this.label, this.language, this.selected = false});

  final PlayTrackKind kind;

  /// The id of the screen's player, sent back as is to choose it
  final String id;
  final String label;
  final String? language;
  final bool selected;

  Map<String, Object?> toJson() => {
    'kind': kind.wire,
    'id': id,
    'label': label,
    if (language != null) 'lang': language,
    'sel': selected,
  };

  static PlayTrack? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final kind = PlayTrackKind.fromWire(json['kind']);
    final id = _shortText(json['id'], 64);
    if (kind == null || id == null) {
      return null;
    }
    return PlayTrack(
      kind: kind,
      id: id,
      label: _shortText(json['label'], 80) ?? id,
      language: _shortText(json['lang'], 16),
      selected: json['sel'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PlayTrack &&
      other.kind == kind &&
      other.id == id &&
      other.label == label &&
      other.language == language &&
      other.selected == selected;

  @override
  int get hashCode => Object.hash(kind, id, label, language, selected);
}

/// A choice of track the phone sends with a play: matched by language on the screen, since the ids of the two
/// players differ. [off] for subtitles off.
class PlayTrackChoice {
  const PlayTrackChoice({this.language, this.off = false});

  final String? language;
  final bool off;

  Map<String, Object?> toJson() => {if (language != null) 'lang': language, if (off) 'off': true};

  static PlayTrackChoice? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final language = _shortText(json['lang'], 16);
    final off = json['off'] == true;
    return language == null && !off ? null : PlayTrackChoice(language: language, off: off);
  }
}

/// Whether an item is a video or a photo: a photo has no position, the screen shows it until the next one or Stop
enum PlayMedia {
  video('video'),
  photo('photo');

  const PlayMedia(this.wire);
  final String wire;

  static PlayMedia? fromWire(Object? value) => PlayMedia.values.where((media) => media.wire == value).firstOrNull;
}

/// How the picture of an item is laid out, for the screen's matching viewer: flat, a whole sphere, a half sphere, two
/// eyes side by side or over and under
enum PlayProjection {
  flat('none'),
  equirect('equirect'),
  vr180('vr180'),
  sbs('sbs'),
  ou('ou');

  const PlayProjection(this.wire);
  final String wire;

  bool get isSphere => this == PlayProjection.equirect || this == PlayProjection.vr180;

  static PlayProjection fromWire(Object? value) =>
      PlayProjection.values.where((projection) => projection.wire == value).firstOrNull ?? PlayProjection.flat;
}

/// The kinds of source a play names its item in
enum PlayKind {
  plex('plex'),
  immich('immich'),
  share('share'),
  mediaServer('mediaServer');

  const PlayKind(this.wire);
  final String wire;
}

/// The protocols of a share a play may name
enum PlayShareType {
  smb('smb'),
  webdav('webdav'),
  dlna('dlna');

  const PlayShareType(this.wire);
  final String wire;

  static PlayShareType? fromWire(Object? value) => PlayShareType.values.where((type) => type.wire == value).firstOrNull;
}

/// The media servers a play may name an item of, besides Plex
enum PlayMediaServerType {
  jellyfin('jellyfin'),
  emby('emby');

  const PlayMediaServerType(this.wire);
  final String wire;

  static PlayMediaServerType? fromWire(Object? value) =>
      PlayMediaServerType.values.where((type) => type.wire == value).firstOrNull;
}

final _uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
final _machineId = RegExp(r'^[0-9a-zA-Z]{8,64}$');

/// What a play names: the item in a source the screen reaches with its own access, never a credential. The fields
/// sit at the top level of the play message, beside "kind", as the Plex play of build 51 has them: none may be called
/// "type", the command's own key.
sealed class PlayTarget {
  const PlayTarget();

  PlayKind get kind;

  /// Which server or source the item is of, as the state tells it back ("server")
  String get serverKey;

  /// The item in it, as the state tells it back ("itemKey")
  String get itemKey;

  PlayMedia get media => PlayMedia.video;
  PlayProjection get projection => PlayProjection.flat;

  Map<String, Object?> toJson();

  /// The target of a play message; null for anything this build does not take, or takes with a field out of bounds
  static PlayTarget? fromJson(Map<String, Object?> json) => switch (json['kind']) {
    'plex' => PlexPlayTarget._fromJson(json),
    'immich' => ImmichPlayTarget._fromJson(json),
    'share' => SharePlayTarget._fromJson(json),
    'mediaServer' => MediaServerPlayTarget._fromJson(json),
    _ => null,
  };
}

/// A film of a Plex server: its machine identifier and the rating key
class PlexPlayTarget extends PlayTarget {
  const PlexPlayTarget({required this.server, required this.item});

  final String server;
  final String item;

  @override
  PlayKind get kind => PlayKind.plex;

  @override
  String get serverKey => server;

  @override
  String get itemKey => item;

  @override
  Map<String, Object?> toJson() => {'kind': 'plex', 'server': server, 'item': item};

  static PlexPlayTarget? _fromJson(Map<String, Object?> json) {
    final server = json['server'];
    final item = json['item'];
    if (server is! String ||
        !_machineId.hasMatch(server) ||
        item is! String ||
        !RegExp(r'^[0-9]{1,12}$').hasMatch(item)) {
      return null;
    }
    return PlexPlayTarget(server: server.toLowerCase(), item: item);
  }
}

/// A photo or a video of an Immich server: the asset id, the phone's user id and the hashes of the addresses the phone
/// reaches its server at ([immichEndpointHash]). The screen asks its own server, with its own session, and that
/// server decides what it may see; the hashes only choose the sentence of a refusal ("another server" or "another
/// account"), the screen comparing them with the hashes of its own addresses: the phone's addresses (an outside host
/// name, the home network's) never go to the screen.
class ImmichPlayTarget extends PlayTarget {
  const ImmichPlayTarget({
    required this.asset,
    required this.user,
    this.endpointHashes = const [],
    this.media = PlayMedia.video,
    this.projection = PlayProjection.flat,
  });

  static const maxEndpoints = 4;

  final String asset;
  final String user;

  /// [immichEndpointHash] of each address, 4 at most
  final List<String> endpointHashes;
  @override
  final PlayMedia media;
  @override
  final PlayProjection projection;

  @override
  PlayKind get kind => PlayKind.immich;

  @override
  String get serverKey => 'immich';

  @override
  String get itemKey => asset;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'immich',
    'asset': asset,
    'user': user,
    if (endpointHashes.isNotEmpty) 'endpointHashes': endpointHashes,
    'media': media.wire,
    if (projection != PlayProjection.flat) 'projection': projection.wire,
  };

  static ImmichPlayTarget? _fromJson(Map<String, Object?> json) {
    final asset = json['asset'];
    final user = json['user'];
    final hashes = json['endpointHashes'];
    final media = PlayMedia.fromWire(json['media']);
    if (asset is! String || !_uuid.hasMatch(asset) || user is! String || !_uuid.hasMatch(user) || media == null) {
      return null;
    }
    if (hashes != null && (hashes is! List || hashes.length > maxEndpoints)) {
      return null;
    }
    final endpointHashes = <String>[];
    for (final hash in (hashes as List?) ?? const []) {
      if (hash is! String || !_endpointHash.hasMatch(hash)) {
        return null;
      }
      endpointHashes.add(hash);
    }
    return ImmichPlayTarget(
      asset: asset.toLowerCase(),
      user: user.toLowerCase(),
      endpointHashes: endpointHashes,
      media: media,
      projection: PlayProjection.fromWire(json['projection']),
    );
  }
}

final _endpointHash = RegExp(r'^[0-9a-f]{32}$');

/// What a play gives of an Immich server's address: the first 16 bytes of the SHA-256 of [normaliseImmichEndpoint] of
/// it, in lower case hex; null for an address that does not normalise
String? immichEndpointHash(String endpoint) {
  final normalised = normaliseImmichEndpoint(endpoint);
  if (normalised == null) {
    return null;
  }
  final digest = sha256.convert(utf8.encode(normalised)).bytes;
  return digest.take(16).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

/// An Immich server's address the way two devices can compare it: scheme and host in lower case, the port only when it
/// is not the scheme's, the path without "/api" nor a trailing slash. Null for anything that is not http or https.
String? normaliseImmichEndpoint(String endpoint) {
  final uri = Uri.tryParse(endpoint.trim());
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
    return null;
  }
  var path = uri.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  if (path.toLowerCase().endsWith('/api')) {
    path = path.substring(0, path.length - 4);
  }
  final port = uri.hasPort && uri.port != (uri.scheme == 'https' ? 443 : 80) ? ':${uri.port}' : '';
  return '${uri.scheme}://${uri.host.toLowerCase()}$port$path';
}

/// A file of a share (SMB, WebDAV, DLNA): the share's identity and the path from its root. The identity is the
/// DLNA server's UDN, else "host[:port]/share" as both devices write it (network_source.dart).
class SharePlayTarget extends PlayTarget {
  const SharePlayTarget({
    required this.type,
    required this.source,
    required this.path,
    this.media = PlayMedia.video,
    this.projection = PlayProjection.flat,
  });

  final PlayShareType type;
  final String source;
  final String path;
  @override
  final PlayMedia media;
  @override
  final PlayProjection projection;

  @override
  PlayKind get kind => PlayKind.share;

  @override
  String get serverKey => '${type.wire}:$source';

  @override
  String get itemKey => path.length > 64 ? path.substring(path.length - 64) : path;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'share',
    'protocol': type.wire,
    'source': source,
    'path': path,
    'media': media.wire,
    if (projection != PlayProjection.flat) 'projection': projection.wire,
  };

  static SharePlayTarget? _fromJson(Map<String, Object?> json) {
    final type = PlayShareType.fromWire(json['protocol']);
    final source = json['source'];
    final path = json['path'];
    final media = PlayMedia.fromWire(json['media']);
    if (type == null || media == null || source is! String || source.isEmpty || source.length > 300) {
      return null;
    }
    if (source.contains(RegExp(r'[\s@?#\\]')) || source.contains('..')) {
      return null;
    }
    if (path is! String || !isSafePlayPath(path)) {
      return null;
    }
    return SharePlayTarget(
      type: type,
      source: source,
      path: path,
      media: media,
      projection: PlayProjection.fromWire(json['projection']),
    );
  }
}

/// Whether [path] is a path from a share's root a screen may open: absolute, no "." nor ".." segment, no backslash, no
/// control character, 1024 characters at most
bool isSafePlayPath(String path) {
  if (path.isEmpty || path.length > 1024 || !path.startsWith('/') || path.contains('\\')) {
    return false;
  }
  if (path.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
    return false;
  }
  return path.split('/').every((segment) => segment != '.' && segment != '..');
}

/// An item of a Jellyfin or Emby server: the server's id and the item's
class MediaServerPlayTarget extends PlayTarget {
  const MediaServerPlayTarget({
    required this.type,
    required this.server,
    required this.item,
    this.media = PlayMedia.video,
  });

  final PlayMediaServerType type;
  final String server;
  final String item;
  @override
  final PlayMedia media;

  @override
  PlayKind get kind => PlayKind.mediaServer;

  @override
  String get serverKey => server;

  @override
  String get itemKey => item;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'mediaServer',
    'product': type.wire,
    'server': server,
    'item': item,
    'media': media.wire,
  };

  static MediaServerPlayTarget? _fromJson(Map<String, Object?> json) {
    final type = PlayMediaServerType.fromWire(json['product']);
    final server = json['server'];
    final item = json['item'];
    final media = PlayMedia.fromWire(json['media']);
    final id = RegExp(r'^[0-9a-zA-Z-]{1,64}$');
    if (type == null || media == null || server is! String || !id.hasMatch(server) || item is! String) {
      return null;
    }
    if (!id.hasMatch(item)) {
      return null;
    }
    return MediaServerPlayTarget(type: type, server: server.toLowerCase(), item: item, media: media);
  }
}

/// What to play: an item ([target]) by the screen's own access to its source, the texts of the screen's prompt, where
/// to start and the tracks
class PlayItem {
  /// A film of a Plex server: the play message of build 51, byte for byte
  const PlayItem({
    required this._server,
    required this._item,
    this.serverName,
    this.title,
    this.offsetMs = 0,
    this.audio,
    this.subtitle,
  }) : _target = null;

  /// Any other item
  const PlayItem.of(PlayTarget target, {this.serverName, this.title, this.offsetMs = 0, this.audio, this.subtitle})
    : _target = target,
      _server = null,
      _item = null;

  final String? _server;
  final String? _item;
  final PlayTarget? _target;

  PlayTarget get target => _target ?? PlexPlayTarget(server: _server!, item: _item!);

  /// The machine identifier of the Plex server (the source's discoveryId), or what stands for the source of another
  /// kind in the state
  String get server => _server ?? _target!.serverKey;

  /// Its rating key, or the item of another kind
  String get item => _item ?? _target!.itemKey;

  PlayKind get kind => target.kind;
  PlayMedia get media => target.media;

  /// For the screen's texts only: "Add (server)", the toast. Never logged.
  final String? serverName;
  final String? title;
  final int offsetMs;
  final PlayTrackChoice? audio;
  final PlayTrackChoice? subtitle;

  Map<String, Object?> toJson() => {
    ...target.toJson(),
    if (serverName != null) 'serverName': serverName,
    if (title != null) 'title': title,
    'offsetMs': offsetMs,
    if (audio != null) 'audio': audio!.toJson(),
    if (subtitle != null) 'subtitle': subtitle!.toJson(),
  };

  static PlayItem? fromJson(Map<String, Object?> json) {
    final target = PlayTarget.fromJson(json);
    if (target == null) {
      return null;
    }
    final offset = json['offsetMs'];
    final serverName = _shortText(json['serverName'], 64);
    final title = _shortText(json['title'], 160);
    final offsetMs = offset is int && offset > 0 && offset < const Duration(days: 2).inMilliseconds ? offset : 0;
    final audio = PlayTrackChoice.fromJson(json['audio']);
    final subtitle = PlayTrackChoice.fromJson(json['subtitle']);
    if (target is PlexPlayTarget) {
      return PlayItem(
        server: target.server,
        item: target.item,
        serverName: serverName,
        title: title,
        offsetMs: offsetMs,
        audio: audio,
        subtitle: subtitle,
      );
    }
    return PlayItem.of(
      target,
      serverName: serverName,
      title: title,
      offsetMs: offsetMs,
      audio: audio,
      subtitle: subtitle,
    );
  }

  @override
  String toString() => 'PlayItem(${kind.wire})';
}

/// What the screen tells of its playback, numbered: the phone's long poll asks for a state after the one it has
class ScreenPlayState {
  const ScreenPlayState({
    this.seq = 0,
    this.phase = ScreenPlayPhase.idle,
    this.positionMs = 0,
    this.durationMs,
    this.server,
    this.item,
    this.itemKey,
    this.media,
    this.title,
    this.tracks = const [],
    this.reason,
    this.from,
    this.fromId,
  });

  final int seq;
  final ScreenPlayPhase phase;
  final int positionMs;
  final int? durationMs;
  final String? server;

  /// The rating key of a Plex film, 16 characters at most (what a build 51 phone reads)
  final String? item;

  /// The item of any kind, 64 characters at most (an Immich asset id is 36)
  final String? itemKey;

  /// A photo or a video; null from a build 51 screen (a film)
  final PlayMedia? media;
  final String? title;
  final List<PlayTrack> tracks;
  final ScreenPlayReason? reason;

  /// The name of the phone that asked for what plays
  final String? from;

  /// The install id of that phone, kept on the screen: never sent ([toJson])
  final String? fromId;

  bool get isActive =>
      phase == ScreenPlayPhase.opening ||
      phase == ScreenPlayPhase.playing ||
      phase == ScreenPlayPhase.paused ||
      phase == ScreenPlayPhase.buffering ||
      phase == ScreenPlayPhase.showing;

  /// The item, whichever build told it
  String? get key => itemKey ?? item;

  ScreenPlayState next({
    ScreenPlayPhase? phase,
    int? positionMs,
    int? durationMs,
    String? server,
    String? item,
    String? itemKey,
    PlayMedia? media,
    String? title,
    List<PlayTrack>? tracks,
    ScreenPlayReason? reason,
    bool clearReason = false,
    String? from,
    String? fromId,
  }) => ScreenPlayState(
    seq: seq + 1,
    phase: phase ?? this.phase,
    positionMs: positionMs ?? this.positionMs,
    durationMs: durationMs ?? this.durationMs,
    server: server ?? this.server,
    item: item ?? this.item,
    itemKey: itemKey ?? this.itemKey,
    media: media ?? this.media,
    title: title ?? this.title,
    tracks: tracks ?? this.tracks,
    reason: clearReason ? null : (reason ?? this.reason),
    from: from ?? this.from,
    fromId: fromId ?? this.fromId,
  );

  /// What another phone than the one that played reads: the phase and who played, never what
  ScreenPlayState withoutItem() => ScreenPlayState(seq: seq, phase: phase, from: from, fromId: fromId);

  /// Whether [other] says the same, its number apart
  bool sameAs(ScreenPlayState other) =>
      other.phase == phase &&
      other.positionMs == positionMs &&
      other.durationMs == durationMs &&
      other.server == server &&
      other.item == item &&
      other.itemKey == itemKey &&
      other.media == media &&
      other.title == title &&
      other.reason == reason &&
      other.from == from &&
      other.fromId == fromId &&
      _sameTracks(other.tracks, tracks);

  static bool _sameTracks(List<PlayTrack> a, List<PlayTrack> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  Map<String, Object?> toJson() => {
    'seq': seq,
    'phase': phase.wire,
    'positionMs': positionMs,
    if (durationMs != null) 'durationMs': durationMs,
    if (server != null) 'server': server,
    if (item != null) 'item': item,
    if (itemKey != null) 'itemKey': itemKey,
    if (media != null) 'media': media!.wire,
    if (title != null) 'title': title,
    if (tracks.isNotEmpty) 'tracks': [for (final track in tracks) track.toJson()],
    if (reason != null) 'reason': reason!.wire,
    if (from != null) 'from': from,
  };

  static ScreenPlayState fromJson(Object? json) {
    if (json is! Map) {
      return const ScreenPlayState();
    }
    final seq = json['seq'];
    final position = json['positionMs'];
    final duration = json['durationMs'];
    final tracks = json['tracks'];
    return ScreenPlayState(
      seq: seq is int && seq >= 0 ? seq : 0,
      phase: ScreenPlayPhase.fromWire(json['phase']),
      positionMs: position is int && position >= 0 ? position : 0,
      durationMs: duration is int && duration > 0 ? duration : null,
      server: _shortText(json['server'], 64),
      item: _shortText(json['item'], 16),
      itemKey: _shortText(json['itemKey'], 64),
      media: PlayMedia.fromWire(json['media']),
      title: _shortText(json['title'], 160),
      tracks: [
        if (tracks is List)
          for (final track in tracks.take(64)) ?PlayTrack.fromJson(track),
      ],
      reason: ScreenPlayReason.fromWire(json['reason']),
      from: _shortText(json['from'], 64),
    );
  }

  @override
  String toString() => 'ScreenPlayState($seq, ${phase.wire}${reason == null ? '' : ', ${reason!.wire}'})';
}

/// The Plex source a phone hands over with "Add (server) to (screen)": what the screen needs to connect, the token
/// apart (it travels beside it, under the keys of the handover)
class HandedPlexServer {
  const HandedPlexServer({
    required this.name,
    required this.machineIdentifier,
    required this.hash,
    required this.host,
    this.port,
    this.publicHost,
    this.publicPort,
    this.rootPath = '/',
  });

  final String name;
  final String machineIdentifier;

  /// The plex.direct hash its certificate is pinned to
  final String hash;

  /// The address at home ("" when the phone paired it from outside)
  final String host;
  final int? port;
  final String? publicHost;
  final int? publicPort;
  final String rootPath;

  Map<String, Object?> toJson() => {
    'name': name,
    'machineIdentifier': machineIdentifier,
    'hash': hash,
    'host': host,
    if (port != null) 'port': port,
    if (publicHost != null) 'publicHost': publicHost,
    if (publicPort != null) 'publicPort': publicPort,
    'rootPath': rootPath,
  };

  static HandedPlexServer? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final name = _shortText(json['name'], 64);
    final id = json['machineIdentifier'];
    final hash = json['hash'];
    final host = json['host'];
    final port = json['port'];
    final publicPort = json['publicPort'];
    final rootPath = json['rootPath'];
    if (name == null ||
        id is! String ||
        !RegExp(r'^[0-9a-zA-Z]{8,64}$').hasMatch(id) ||
        hash is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(hash) ||
        host is! String ||
        host.length > 253 ||
        (host.isNotEmpty && !RegExp(r'^[0-9A-Za-z.:-]+$').hasMatch(host))) {
      return null;
    }
    return HandedPlexServer(
      name: name,
      machineIdentifier: id.toLowerCase(),
      hash: hash,
      host: host,
      port: port is int && port > 0 && port < 65536 ? port : null,
      publicHost: _shortText(json['publicHost'], 253),
      publicPort: publicPort is int && publicPort > 0 && publicPort < 65536 ? publicPort : null,
      rootPath: rootPath is String && rootPath.startsWith('/') && rootPath.length < 512 ? rootPath : '/',
    );
  }

  @override
  String toString() => 'HandedPlexServer';
}

String? _shortText(Object? value, int max) {
  if (value is! String) {
    return null;
  }
  final text = cleanPairingText(value);
  if (text.isEmpty) {
    return null;
  }
  return text.length > max ? text.substring(0, max).trimRight() : text;
}
