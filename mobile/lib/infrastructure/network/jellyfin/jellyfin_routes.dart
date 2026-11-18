// The routes of a Jellyfin or Emby server, per product and version. Jellyfin 10.9 (May 2024) moved the user scoped
// routes (/Users/{userId}/Items, /Users/{userId}/Views) to /Items?userId= and /UserViews?userId=, and its OpenAPI
// document of 12.4 lists the new ones only; Emby keeps the user scoped ones and has no /UserViews nor /Users/Me (404
// and 500 on the bench of release 49). Every URL is built here, under the base path of the server ("" or the
// "/jellyfin" of a reverse proxy).

import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_api.dart';

/// The version numbers of [version] ("12.4.0", "10.10.7", "4.10.2.0"), [0] when it does not read
List<int> jellyfinVersionNumbers(String? version) {
  final numbers = <int>[];
  for (final part in (version ?? '').split('.')) {
    final value = int.tryParse(part.trim());
    if (value == null) {
      break;
    }
    numbers.add(value);
  }
  return numbers.isEmpty ? const [0] : numbers;
}

/// Whether [version] is at least [major].[minor]
bool jellyfinVersionAtLeast(String? version, int major, int minor) {
  final numbers = jellyfinVersionNumbers(version);
  final first = numbers[0];
  final second = numbers.length > 1 ? numbers[1] : 0;
  return first > major || (first == major && second >= minor);
}

/// The URLs of one server: [base] is its scheme, host, port and base path
class JellyfinRoutes {
  JellyfinRoutes(Uri base, this.product, this.version) : base = _withoutTrailingSlash(base);

  final Uri base;
  final JellyfinProduct product;
  final String? version;

  /// Whether the items and views are under /Users/{userId}: Emby, and Jellyfin before 10.9
  bool get userScoped => product == JellyfinProduct.emby || !jellyfinVersionAtLeast(version, 10, 9);

  /// A word for the diagnostics line: which route table is in use
  String get tableName => userScoped ? 'items-v1' : 'items-v2';

  static Uri _withoutTrailingSlash(Uri base) {
    var path = base.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return _uriWithQuery(base, path, null);
  }

  Uri _at(String path, [Map<String, String?> query = const {}]) {
    final kept = {
      for (final entry in query.entries)
        if (entry.value != null) entry.key: entry.value!,
    };
    return base.replace(path: '${base.path}$path', queryParameters: kept.isEmpty ? null : kept);
  }

  static String _id(String id) => Uri.encodeComponent(id);

  Uri publicInfo() => _at('/System/Info/Public');
  Uri publicUsers() => _at('/Users/Public');
  Uri signIn() => _at('/Users/AuthenticateByName');
  Uri logout() => _at('/Sessions/Logout');

  Uri quickConnectEnabled() => _at('/QuickConnect/Enabled');
  Uri quickConnectInitiate() => _at('/QuickConnect/Initiate');
  Uri quickConnectState(String secret) => _at('/QuickConnect/Connect', {'secret': secret});
  Uri quickConnectSignIn() => _at('/Users/AuthenticateWithQuickConnect');

  /// The web page where a signed in user approves a Quick Connect code: the route "quickconnect" of the web client
  /// of 10.10 and 12.4 (bench of release 49)
  Uri quickConnectPage() => base.replace(path: '${base.path}/web/', fragment: '/quickconnect');

  /// The signed in user: /Users/Me on Jellyfin, /Users/{id} on Emby (whose /Users/Me fails)
  Uri me(String userId) => product == JellyfinProduct.emby ? _at('/Users/${_id(userId)}') : _at('/Users/Me');

  Uri views(String userId) => userScoped ? _at('/Users/${_id(userId)}/Views') : _at('/UserViews', {'userId': userId});

  /// The fields the app reads of an item, beyond the defaults
  static const itemFields = 'MediaSources,Path,Overview,ProductionYear,SortName,Width,Height';

  Uri items(
    String userId, {
    String? parentId,
    int? startIndex,
    int? limit,
    String? sortBy = 'SortName',
    String? includeItemTypes,
    bool recursive = false,
    String fields = itemFields,
  }) {
    final query = {
      'parentId': parentId,
      'startIndex': startIndex?.toString(),
      'limit': limit?.toString(),
      'sortBy': sortBy,
      'sortOrder': sortBy == null ? null : 'Ascending',
      'includeItemTypes': includeItemTypes,
      'recursive': recursive ? 'true' : null,
      'fields': fields,
      'enableTotalRecordCount': 'true',
    };
    return userScoped ? _at('/Users/${_id(userId)}/Items', query) : _at('/Items', {'userId': userId, ...query});
  }

  Uri item(String userId, String itemId) => userScoped
      ? _at('/Users/${_id(userId)}/Items/${_id(itemId)}', {'fields': itemFields})
      : _at('/Items/${_id(itemId)}', {'userId': userId, 'fields': itemFields});

  Uri seasons(String userId, String seriesId) =>
      _at('/Shows/${_id(seriesId)}/Seasons', {'userId': userId, 'fields': itemFields});

  Uri episodes(String userId, String seriesId, {String? seasonId}) =>
      _at('/Shows/${_id(seriesId)}/Episodes', {'userId': userId, 'seasonId': seasonId, 'fields': itemFields});

  Uri nextUp(String userId, String seriesId) =>
      _at('/Shows/NextUp', {'userId': userId, 'seriesId': seriesId, 'fields': itemFields, 'limit': '1'});

  Uri playbackInfo(String userId, String itemId) => _at('/Items/${_id(itemId)}/PlaybackInfo', {'userId': userId});

  /// The original file of a video, as it is on the disk (static: no conversion)
  Uri videoStream(String itemId, String mediaSourceId) =>
      _at('/Videos/${_id(itemId)}/stream', {'static': 'true', 'mediaSourceId': mediaSourceId});

  /// The original file of any item (a photo, a video without media source)
  Uri file(String itemId) => _at('/Items/${_id(itemId)}/File');

  Uri image(
    String itemId,
    String type, {
    int? fillWidth,
    int? fillHeight,
    int? maxWidth,
    int? maxHeight,
    String? tag,
  }) => _at('/Items/${_id(itemId)}/Images/$type', {
    'fillWidth': fillWidth?.toString(),
    'fillHeight': fillHeight?.toString(),
    'maxWidth': maxWidth?.toString(),
    'maxHeight': maxHeight?.toString(),
    'quality': '90',
    'tag': tag,
  });

  Uri playing() => _at('/Sessions/Playing');
  Uri playingProgress() => _at('/Sessions/Playing/Progress');
  Uri playingStopped() => _at('/Sessions/Playing/Stopped');

  /// [transcodingUrl] of PlaybackInfo resolved against the server, without the key it carries (ApiKey on 12.4,
  /// api_key on 10.10 and Emby): the token goes in the header, which the bench showed is enough
  Uri conversion(String transcodingUrl) {
    final resolved = transcodingUrl.startsWith('/')
        ? _uriWithQuery(base, '${base.path}${transcodingUrl.split('?').first}', _queryOf(transcodingUrl))
        : base.resolve(transcodingUrl);
    return withoutJellyfinKey(resolved);
  }

  static String? _queryOf(String url) {
    final question = url.indexOf('?');
    return question < 0 ? null : url.substring(question + 1);
  }
}

/// [uri] without its ApiKey or api_key query parameter, the other parameters in their order and as they were written
Uri withoutJellyfinKey(Uri uri) {
  final query = uri.query;
  if (query.isEmpty) {
    return uri;
  }
  final kept = query
      .split('&')
      .where((pair) {
        final name = Uri.decodeQueryComponent(pair.split('=').first).toLowerCase();
        return name != 'apikey' && name != 'api_key';
      })
      .join('&');
  return _uriWithQuery(uri, uri.path, kept.isEmpty ? null : kept);
}

/// [uri] with [path] and [query] (none when null), without fragment: Uri.replace keeps a query it is given null for
Uri _uriWithQuery(Uri uri, String path, String? query) =>
    Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null, path: path, query: query);
