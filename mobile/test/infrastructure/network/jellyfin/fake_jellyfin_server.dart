// A small Jellyfin or Emby server on 127.0.0.1 for the tests of the Jellyfin client, built from the answers recorded on
// the release 49 bench (test/fixtures/jellyfin, jellyfin-10.10 and emby): the public information, the public users, a
// sign in with a password, Quick Connect, the user, the views, the items by parent (with paging), one item, the
// seasons, episodes and next up of a series, PlaybackInfo, the original files with or without Range support, the
// images, the HLS conversion (master, main playlist, segments), the playback reports and the sign out. Every answer
// but the public ones wants the token in the header of the product, as a real server does, and answers 401
// otherwise. Emby answers 404 to /UserViews and 500 to /Users/Me, as Emby 4.10 did on the bench.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_api.dart';

const jellyfinTestPassword = 'test-password';
const jellyfinTestToken = 'TEST-TOKEN-0000';

/// One request the server received
typedef JellyfinTestRequest = ({String method, String path, Map<String, String> query, Map<String, String> headers});

/// A fixture of [folder] (jellyfin, jellyfin-10.10, emby), decoded
Object? jellyfinFixture(String folder, String name) =>
    jsonDecode(File('test/fixtures/$folder/$name.json').readAsStringSync());

Map<String, Object?> _map(Object? value) => (value! as Map).cast<String, Object?>();

List<Map<String, Object?>> _items(Object? page) => [for (final item in _map(page)['Items']! as List) _map(item)];

class FakeJellyfinServer {
  FakeJellyfinServer._(this._server, this.folder, this.product, this.basePath);

  /// Starts a server answering as the bench server of [folder], under [basePath] ("" or "/jellyfin")
  static Future<FakeJellyfinServer> start({String folder = 'jellyfin', String basePath = ''}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final info = _map(jellyfinFixture(folder, 'system_info_public'));
    final fake = FakeJellyfinServer._(
      server,
      folder,
      info.containsKey('ProductName') ? JellyfinProduct.jellyfin : JellyfinProduct.emby,
      basePath,
    );
    fake._load();
    server.listen(fake._handle);
    return fake;
  }

  final HttpServer _server;
  final String folder;
  final JellyfinProduct product;
  final String basePath;

  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}$basePath');
  int get port => _server.port;

  late Map<String, Object?> publicInfo;
  late String serverId;
  late String userId;
  String userName = 'viewer';
  String password = jellyfinTestPassword;

  /// The tokens the server takes; a sign in adds [jellyfinTestToken]
  final Set<String> tokens = {jellyfinTestToken};

  bool quickConnectEnabled = true;

  /// Quick Connect requests by secret: their code and whether a user approved them
  final Map<String, ({String code, bool approved})> quickConnects = {};
  int _quickConnectCount = 0;

  /// Whether the original files answer a range with 206; false answers 200 with the whole file
  bool honourRanges = true;

  /// What the server answers to every request but the public ones, when set (a 500, a 401)
  int? failWith;

  /// The public users shown, empty by default as Jellyfin
  List<Map<String, Object?>> publicUsers = [];

  final List<JellyfinTestRequest> requests = [];

  /// The bodies of the playback reports received, with their kind (start, progress, stopped)
  final List<({String kind, Map<String, Object?> body})> reports = [];

  /// The conversions stopped by a report, by play session id
  final Set<String> logouts = {};

  late List<Map<String, Object?>> views;

  /// The items by id, and the children of each parent id in their order
  final Map<String, Map<String, Object?>> items = {};
  final Map<String, List<String>> children = {};

  /// The bytes of the original file of each item (made up, [fileSize] long by default)
  final Map<String, Uint8List> files = {};
  static const fileSize = 48 * 1024;

  Map<String, Object?>? _playbackInfo;

  /// The bodies of the PlaybackInfo requests, and the encodings stopped ("deviceId playSessionId")
  final List<Map<String, Object?>> playbackInfoBodies = [];
  final List<String> encodingsStopped = [];

  void _load() {
    publicInfo = _map(jellyfinFixture(folder, 'system_info_public'));
    serverId = publicInfo['Id']! as String;
    userId = _map(_map(jellyfinFixture(folder, 'authenticate_by_name'))['User'])['Id']! as String;
    views = _items(jellyfinFixture(folder, 'views'));
    for (final view in views) {
      items[view['Id']! as String] = view;
    }
    String idOf(String name) => views.firstWhere((v) => v['Name'] == name)['Id']! as String;
    void add(String parent, String fixture) {
      for (final item in _items(jellyfinFixture(folder, fixture))) {
        final id = item['Id']! as String;
        items[id] = item;
        (children[parent] ??= []).add(id);
      }
    }

    add(idOf('Films'), 'items_films');
    add(idOf('Shows'), 'items_series');
    add(idOf('Home'), 'items_home');
    add(idOf('Photos'), 'items_photos');
    final series = children[idOf('Shows')]!.first;
    add(series, 'seasons');
    final season = children[series]!.first;
    add(season, 'episodes');
    add(children[idOf('Home')]!.first, 'items_home_trip');
    add(children[idOf('Photos')]!.first, 'items_photos_2024');
    for (final item in items.values) {
      if (item['IsFolder'] != true) {
        setFile(item['Id']! as String, _pattern(item['Id']! as String, fileSize));
      }
    }
    _playbackInfo = _map(jellyfinFixture(folder, 'playback_info_conversion'));
  }

  static Uint8List _pattern(String seed, int length) {
    final bytes = Uint8List(length);
    final start = seed.codeUnits.fold(0, (a, b) => a + b);
    for (var i = 0; i < length; i++) {
      bytes[i] = (start + i * 31 + (i >> 8)) & 0xff;
    }
    return bytes;
  }

  /// Gives [id] the file [bytes], its media sources the size of it
  void setFile(String id, Uint8List bytes) {
    files[id] = bytes;
    final item = items[id];
    final sources = item?['MediaSources'];
    if (item != null && sources is List) {
      item['MediaSources'] = [
        for (final source in sources) {..._map(source), 'Size': bytes.length},
      ];
    }
  }

  /// Adds [count] films to the library [parentId], named "Film 0001" and on, after the others
  void addFilms(String parentId, int count) {
    final model = items[children[parentId]!.first]!;
    for (var n = 1; n <= count; n++) {
      final id = 'a${n.toRadixString(16).padLeft(31, '0')}';
      final source = _map((model['MediaSources']! as List).first);
      items[id] = {
        ...model,
        'Id': id,
        'Name': 'Film ${n.toString().padLeft(4, '0')}',
        'ProductionYear': 2000,
        'MediaSources': [
          {...source, 'Id': id, 'Path': '/media/films/Film $n/Film ${n.toString().padLeft(4, '0')}.mp4', 'Size': 1000},
        ],
      };
      (children[parentId] ??= []).add(id);
    }
  }

  /// The id of the view [name]
  String viewId(String name) => views.firstWhere((v) => v['Name'] == name)['Id']! as String;

  /// The id of the item named [name]
  String itemId(String name) => items.values.firstWhere((v) => v['Name'] == name)['Id']! as String;

  Future<void> close() => _server.close(force: true);

  bool _hasToken(HttpRequest request) {
    final emby = request.headers.value('x-emby-token');
    if (emby != null && tokens.contains(emby)) {
      return true;
    }
    final header = request.headers.value(product == JellyfinProduct.emby ? 'x-emby-authorization' : 'authorization');
    final token = RegExp(r'Token="([^"]*)"').firstMatch(header ?? '')?.group(1);
    return token != null && tokens.contains(token);
  }

  Future<void> _handle(HttpRequest request) async {
    final headers = <String, String>{};
    request.headers.forEach((name, values) => headers[name] = values.join(','));
    var path = request.uri.path;
    if (basePath.isNotEmpty) {
      if (!path.startsWith(basePath)) {
        return _send(request, 404, 'not under the base path');
      }
      path = path.substring(basePath.length);
    }
    requests.add((method: request.method, path: path, query: request.uri.queryParameters, headers: headers));
    final body = await utf8.decoder.bind(request).join();
    final query = request.uri.queryParameters;
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    final lower = path.toLowerCase();

    // Public routes
    if (path == '/System/Info/Public') {
      return _json(request, {...publicInfo, 'Id': serverId});
    }
    if (path == '/Users/Public') {
      return _json(request, publicUsers);
    }
    if (path == '/Users/AuthenticateByName' && request.method == 'POST') {
      final sent = jsonDecode(body) as Map;
      if (sent['Username'] != userName || sent['Pw'] != password) {
        return _send(request, 401, 'Error processing request.');
      }
      tokens.add(jellyfinTestToken);
      return _json(request, _signIn());
    }
    if (path == '/QuickConnect/Enabled' && product == JellyfinProduct.jellyfin) {
      return _json(request, quickConnectEnabled);
    }
    if (path == '/QuickConnect/Initiate' && request.method == 'POST' && product == JellyfinProduct.jellyfin) {
      if (!quickConnectEnabled) {
        return _send(request, 401, 'Quick connect is disabled');
      }
      _quickConnectCount++;
      final secret = 'secret-$_quickConnectCount';
      final code = (123456 + _quickConnectCount).toString();
      quickConnects[secret] = (code: code, approved: false);
      return _json(request, {'Secret': secret, 'Code': code, 'Authenticated': false});
    }
    if (path == '/QuickConnect/Connect' && product == JellyfinProduct.jellyfin) {
      final known = quickConnects[query['secret']];
      if (known == null) {
        return _send(request, 404, 'Unknown secret');
      }
      return _json(request, {'Secret': query['secret'], 'Code': known.code, 'Authenticated': known.approved});
    }
    if (path == '/Users/AuthenticateWithQuickConnect' && request.method == 'POST') {
      final secret = (jsonDecode(body) as Map)['Secret'];
      final known = quickConnects[secret];
      if (known == null || !known.approved) {
        return _send(request, 401, 'Not approved');
      }
      quickConnects.remove(secret);
      tokens.add(jellyfinTestToken);
      return _json(request, _signIn());
    }
    if (lower.startsWith('/web/')) {
      return _send(request, 200, '<html></html>');
    }

    // Everything else needs the token
    if (!_hasToken(request)) {
      return _send(request, 401, '');
    }
    final failure = failWith;
    if (failure != null) {
      return _send(request, failure, 'failing');
    }
    if (path == '/Sessions/Logout' && request.method == 'POST') {
      tokens.clear();
      return _send(request, 204, '');
    }
    if (path.startsWith('/Sessions/Playing') && request.method == 'POST') {
      final kind = switch (path) {
        '/Sessions/Playing' => 'start',
        '/Sessions/Playing/Progress' => 'progress',
        '/Sessions/Playing/Stopped' => 'stopped',
        _ => 'other',
      };
      final sent = _map(jsonDecode(body));
      reports.add((kind: kind, body: sent));
      if (kind == 'stopped') {
        logouts.add('${sent['PlaySessionId']}');
        final item = items[sent['ItemId']];
        if (item != null) {
          item['UserData'] = {..._map(item['UserData'] ?? {}), 'PlaybackPositionTicks': sent['PositionTicks']};
        }
      }
      return _send(request, 204, '');
    }
    if (path == '/Users/Me') {
      return product == JellyfinProduct.emby ? _send(request, 500, 'error') : _json(request, _user());
    }
    if (path == '/UserViews') {
      return product == JellyfinProduct.emby ? _send(request, 404, '') : _json(request, _page(views, query));
    }
    if (segments.length == 2 && segments[0] == 'Users' && segments[1] == userId) {
      return _json(request, _user());
    }
    if (segments.length == 3 && segments[0] == 'Users' && segments[2] == 'Views') {
      return _json(request, _page(views, query));
    }
    if (path == '/Items' || (segments.length == 3 && segments[0] == 'Users' && segments[2] == 'Items')) {
      return _json(request, _page(_childrenOf(query['parentId'], query['includeItemTypes']), query));
    }
    if (segments.length == 2 && segments[0] == 'Items' ||
        (segments.length == 4 && segments[0] == 'Users' && segments[2] == 'Items')) {
      final item = items[segments.last];
      return item == null ? _send(request, 404, '') : _json(request, item);
    }
    if (segments.length == 3 && segments[0] == 'Shows' && segments[2] == 'Seasons') {
      return _json(request, _page(_childrenOf(segments[1], null), query));
    }
    if (segments.length == 3 && segments[0] == 'Shows' && segments[2] == 'Episodes') {
      final season = query['seasonId'] ?? children[segments[1]]?.first;
      return _json(request, _page(_childrenOf(season, null), query));
    }
    if (path == '/Shows/NextUp') {
      final series = query['seriesId'];
      final season = children[series]?.first;
      final next = _childrenOf(season, null).where((e) => (_map(e['UserData'] ?? {})['Played']) != true).take(1);
      return _json(request, _page(next.toList(), query));
    }
    if (segments.length == 3 && segments[0] == 'Items' && segments[2] == 'PlaybackInfo') {
      playbackInfoBodies.add(_map(jsonDecode(body)));
      return _json(request, _playbackInfo);
    }
    if (path == '/Videos/ActiveEncodings' && request.method == 'DELETE') {
      encodingsStopped.add('${query['deviceId']} ${query['playSessionId']}');
      return _send(request, 204, '');
    }
    if (segments.length == 3 && segments[0] == 'Videos' && segments[2] == 'stream') {
      return _file(request, segments[1]);
    }
    if (segments.length == 3 && segments[0] == 'Items' && segments[2] == 'File') {
      return _file(request, segments[1]);
    }
    if (segments.length == 4 && segments[0] == 'Items' && segments[2] == 'Images') {
      final item = items[segments[1]];
      if (item == null) {
        return _send(request, 404, '');
      }
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType('image', 'jpeg')
        ..add([0xff, 0xd8, 0xff, 0xe0, ...utf8.encode('${query['fillWidth'] ?? query['maxWidth']}'), 0xff, 0xd9]);
      return request.response.close();
    }
    if (lower.startsWith('/videos/') && lower.endsWith('/master.m3u8')) {
      return _send(
        request,
        200,
        '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=4000000\nmain.m3u8?MediaSourceId=x\n',
        type: 'application/vnd.apple.mpegurl',
      );
    }
    if (lower.startsWith('/videos/') && lower.endsWith('/main.m3u8')) {
      return _send(
        request,
        200,
        '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nhls1/main/0.ts?x=1\n#EXTINF:6,\nhls1/main/1.ts?x=1\n#EXT-X-ENDLIST\n',
        type: 'application/vnd.apple.mpegurl',
      );
    }
    if (lower.startsWith('/videos/') && lower.endsWith('.ts')) {
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType('video', 'mp2t')
        ..add(List.filled(188 * 4, 0x47));
      return request.response.close();
    }
    return _send(request, 404, 'no route');
  }

  Map<String, Object?> _signIn() {
    final recorded = _map(jellyfinFixture(folder, 'authenticate_by_name'));
    return {...recorded, 'AccessToken': jellyfinTestToken, 'ServerId': serverId};
  }

  Map<String, Object?> _user() => _map(jellyfinFixture(folder, 'user'));

  List<Map<String, Object?>> _childrenOf(String? parentId, String? types) {
    final ids = children[parentId] ?? const [];
    final kinds = types?.split(',').toSet();
    return [
      for (final id in ids)
        if (kinds == null || kinds.contains(items[id]!['Type'])) items[id]!,
    ];
  }

  static Map<String, Object?> _page(List<Map<String, Object?>> all, Map<String, String> query) {
    final start = int.tryParse(query['startIndex'] ?? '') ?? 0;
    final limit = int.tryParse(query['limit'] ?? '') ?? all.length;
    return {'Items': all.skip(start).take(limit).toList(), 'TotalRecordCount': all.length, 'StartIndex': start};
  }

  Future<void> _file(HttpRequest request, String id) async {
    final bytes = files[id];
    if (bytes == null) {
      return _send(request, 404, '');
    }
    final range = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(request.headers.value('range') ?? '');
    final response = request.response..headers.contentType = ContentType('video', 'mp4');
    if (range == null || !honourRanges) {
      response
        ..statusCode = 200
        ..contentLength = bytes.length
        ..add(bytes);
      return response.close();
    }
    final start = int.parse(range[1]!);
    if (start >= bytes.length) {
      response.statusCode = 416;
      return response.close();
    }
    final end = range[2]!.isEmpty ? bytes.length - 1 : int.parse(range[2]!).clamp(start, bytes.length - 1);
    response
      ..statusCode = 206
      ..headers.set('content-range', 'bytes $start-$end/${bytes.length}')
      ..headers.set('accept-ranges', 'bytes')
      ..contentLength = end - start + 1
      ..add(bytes.sublist(start, end + 1));
    return response.close();
  }

  Future<void> _json(HttpRequest request, Object? value) {
    request.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(value));
    return request.response.close();
  }

  Future<void> _send(HttpRequest request, int status, String body, {String type = 'text/plain'}) {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.parse(type)
      ..write(body);
    return request.response.close();
  }

  /// Approves the Quick Connect request of [code], as a signed in user does on the web page
  bool approve(String code) {
    for (final entry in quickConnects.entries) {
      if (entry.value.code == code) {
        quickConnects[entry.key] = (code: code, approved: true);
        return true;
      }
    }
    return false;
  }

  /// The requests that carried a token
  Iterable<JellyfinTestRequest> get requestsWithToken => requests.where(
    (r) =>
        (r.headers['authorization'] ?? r.headers['x-emby-authorization'] ?? '').contains('Token=') ||
        r.headers.containsKey('x-emby-token'),
  );
}
