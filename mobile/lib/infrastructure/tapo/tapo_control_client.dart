// The control API of one camera (Tapo design 2.5 and 3.7): its details, the state of its memory card, the days that
// have recordings and the clips of a day. One request at a time, through the session of [TapoLogin]; a session the
// camera refused is replaced by exactly one new login, never in a loop (logins count towards a lockout). A refused
// password or a lockout is remembered in [TapoSessionCache] and told again without asking the camera, until the user
// asks again. The answers are kept a while, as the camera limits repeated requests (-40109).
//
// A camera is only logged in to through its pinned certificate; without a pin yet, only "Test the camera" logs in
// (trust on first use, at the user's press), and any other caller gets the certificate shown, for the user to accept.
//
// Only read methods leave the app: [tapoReadMethods] is checked before anything is sent. No method that changes the
// camera exists in this code, least of all the one that sets its local control, which would overwrite the camera's
// PAKE verifier (P§6.4).

import 'dart:async';

import 'package:immich_mobile/domain/models/tapo_camera_info.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_crypto.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_https.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_login.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_session_cache.dart';
import 'package:logging/logging.dart';
import 'package:timezone/timezone.dart' as tz;

final _log = Logger('TapoControl');

/// The methods this app sends to a camera: all of them only read
const tapoReadMethods = {
  'getDeviceInfo',
  'getSdCardStatus',
  'getTimezone',
  'getClockStatus',
  'getAppComponentList',
  'searchDateWithVideo',
  'searchVideoWithUTC',
  'searchVideoOfDay',
  'getUserID',
  'searchDetectionList',
};

/// The player_id of the listings and downloads of a camera: stable per camera, derived from the id of its source so
/// that nothing is stored for it (Tapo design 3.1)
String tapoPlayerId(String sourceId) => sha256Hex('immuch360-tapo-player:$sourceId').substring(0, 32).toUpperCase();

/// The kind of a clip from its video_type (Tapo design 2.5): 1 continuous, 2 motion, 6 person, 7 baby crying, 8
/// vehicle, 9 pet, 33 animal; the other events (tamper, line crossing, area intrusion...) are events without a word
TapoClipKind tapoClipKind(int videoType) => switch (videoType) {
  1 => TapoClipKind.continuous,
  2 => TapoClipKind.motion,
  6 => TapoClipKind.person,
  7 => TapoClipKind.babyCry,
  8 => TapoClipKind.vehicle,
  9 => TapoClipKind.pet,
  33 => TapoClipKind.animal,
  _ => TapoClipKind.other,
};

/// "yyyy-mm-dd" of a date
String tapoDayOf(int year, int month, int day) =>
    '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';

/// The year, month and day of "yyyy-mm-dd", null when [day] is not one
({int year, int month, int day})? tapoParseDay(String day) {
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(day);
  if (match == null) {
    return null;
  }
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final date = int.parse(match.group(3)!);
  final check = DateTime.utc(year, month, date);
  if (check.year != year || check.month != month || check.day != date) {
    return null;
  }
  return (year: year, month: month, day: date);
}

/// The time zone of a camera, for the bounds of its days: its zone_id when the time zone data knows it, else the
/// standard offset it tells ("UTC+01:00", no daylight saving time), else the zone of this device
class TapoZone {
  TapoZone._(this._location, this._offset);

  factory TapoZone.of(String? zoneId, {String? offsetText}) {
    if (zoneId != null && zoneId.isNotEmpty) {
      try {
        return TapoZone._(tz.getLocation(zoneId), null);
      } catch (error) {
        _log.fine('Time zone $zoneId unknown here: $error');
      }
    }
    final match = RegExp(r'^(?:UTC|GMT)([+-])(\d{1,2}):?(\d{2})?$').firstMatch(offsetText?.trim() ?? '');
    if (match != null) {
      final minutes = int.parse(match.group(2)!) * 60 + int.parse(match.group(3) ?? '0');
      return TapoZone._(null, Duration(minutes: match.group(1) == '-' ? -minutes : minutes));
    }
    return TapoZone._(null, null);
  }

  final tz.Location? _location;
  final Duration? _offset;

  /// The instant the local day [year]-[month]-[day] starts, in UTC (a day of a daylight saving time change lasts 23 or
  /// 25 hours)
  DateTime startOfDay(int year, int month, int day) {
    final location = _location;
    if (location != null) {
      return tz.TZDateTime(location, year, month, day).toUtc();
    }
    final offset = _offset;
    if (offset != null) {
      return DateTime.utc(year, month, day).subtract(offset);
    }
    return DateTime(year, month, day).toUtc();
  }

  /// The local time of [instant] in the zone: a DateTime marked UTC whose fields are the local ones, so that nothing
  /// converts it again
  DateTime local(DateTime instant) {
    final utc = instant.toUtc();
    final offset = offsetAt(utc);
    final shifted = utc.add(offset);
    return DateTime.utc(
      shifted.year,
      shifted.month,
      shifted.day,
      shifted.hour,
      shifted.minute,
      shifted.second,
      shifted.millisecond,
    );
  }

  /// The offset from UTC of the zone at [instant]
  Duration offsetAt(DateTime instant) {
    final location = _location;
    if (location != null) {
      return tz.TZDateTime.from(instant.toUtc(), location).timeZoneOffset;
    }
    return _offset ?? instant.toLocal().timeZoneOffset;
  }

  /// "yyyy-mm-dd" of [instant] in the zone
  String dayOf(DateTime instant) {
    final local = this.local(instant);
    return tapoDayOf(local.year, local.month, local.day);
  }
}

/// The control API of one camera, see the header
class TapoControlClient {
  TapoControlClient({
    required this.sourceId,
    required this.host,
    required this._password,
    TapoCameraInfo known = const TapoCameraInfo(),
    TapoTransport Function(String host, String? pinnedSha256)? transport,
    TapoLogin Function(TapoTransport transport)? login,
    TapoSessionCache? cache,
    DateTime Function()? clock,
    this.trustFirstCertificate = false,
    TapoCertificateReader? certificateReader,
  }) : _info = known,
       _makeTransport = transport ?? ((host, pin) => TapoHttpsTransport(host, pinnedSha256: pin)),
       _makeLogin = login ?? TapoLogin.new,
       _cache = cache ?? TapoSessionCache.instance,
       _clock = clock ?? DateTime.now,
       _readCertificate = certificateReader ?? readTapoCertificate;

  final String sourceId;
  final String host;
  final String _password;

  /// Whether a camera without a pinned certificate may be logged in to, the certificate it shows being pinned then:
  /// only "Test the camera" does it, at the user's press
  final bool trustFirstCertificate;
  final TapoCertificateReader _readCertificate;
  final TapoTransport Function(String host, String? pinnedSha256) _makeTransport;
  final TapoLogin Function(TapoTransport transport) _makeLogin;
  final TapoSessionCache _cache;
  final DateTime Function() _clock;
  final _serial = TapoSerial();

  TapoCameraInfo _info;
  TapoTransport? _transport;
  TapoSession? _session;
  bool _closed = false;

  final Map<String, ({DateTime at, Future<Object?> value})> _answers = {};

  /// What this connection knows of the camera: what was stored, and what its logins and answers taught since
  TapoCameraInfo get info => _info;

  /// Whether a login reached the camera through its pinned certificate in this run, see [TapoSessionCache.isVerified]
  bool get isVerified => _cache.isVerified(host, _info.certificateSha256);

  /// Logs in when there is no live session yet (or takes the one "Test the camera" left), without any request
  Future<void> ensureLoggedIn() => _serial.run(() async {
    try {
      await _sessionNow();
    } on TapoNetworkException {
      throw TapoCameraException(TapoErrorKind.unreachable, detail: host);
    }
  });

  /// Forgets a refused password or a lockout remembered for this camera: the user asks the camera again ("Test the
  /// camera", Retry), which may cost one more refused attempt
  void forgetRefusals() => _cache.forgetRefusals(sourceId);

  Future<TapoSession> _sessionNow() async {
    if (_closed) {
      throw TapoCameraException(TapoErrorKind.unreachable, detail: host);
    }
    final current = _session;
    if (current != null && !current.isExpired) {
      return current;
    }
    _session = null;
    final cached = _cache.get(sourceId, host, _password);
    if (cached != null) {
      _session = cached.session;
      _learn(cached.info);
      return cached.session;
    }
    // Every other call of the page (its details, its days, each picture) would log in again with a refused password
    final refused = _cache.refusal(sourceId, host, _password, now: _clock());
    if (refused != null) {
      throw refused;
    }
    if (_info.certificateSha256 == null && !trustFirstCertificate) {
      // Whoever answers at the address now would be trusted silently: the user is shown the certificate instead, and
      // nothing is sent before they accept it
      final seen = await _readCertificate(host);
      if (seen == null) {
        throw const TapoNetworkException('TLS');
      }
      throw TapoCameraException(TapoErrorKind.certificateChanged, certificateSha256: seen);
    }
    final transport = _transport ??= _makeTransport(host, _info.certificateSha256);
    final TapoLoginResult result;
    try {
      result = await _makeLogin(transport).login(_password, known: _info);
    } on TapoCameraException catch (error) {
      if (error.kind == TapoErrorKind.wrongPassword || error.kind == TapoErrorKind.locked) {
        _cache.refuse(sourceId, host, _password, error, now: _clock());
      }
      rethrow;
    }
    final certificate = transport.certificateSha256 ?? _info.certificateSha256;
    _info = _info.copyWith(
      protocol: result.protocol,
      passcode: result.passcode,
      userName: result.userName,
      certificateSha256: certificate,
    );
    if (certificate != null) {
      _cache.markVerified(host, certificate);
    }
    _cache.put(sourceId, host, _password, TapoCachedLogin(session: result.session, info: _info));
    _session = result.session;
    _log.info('Logged in to a camera (${result.protocol.name})');
    return result.session;
  }

  /// What the cached login learned that this connection did not know yet
  void _learn(TapoCameraInfo learned) {
    _info = _info.copyWith(
      protocol: learned.protocol,
      passcode: learned.passcode,
      userName: learned.userName,
      certificateSha256: _info.certificateSha256 ?? learned.certificateSha256,
      model: learned.model,
      firmware: learned.firmware,
      zoneId: learned.zoneId,
    );
  }

  void _forget(TapoSession? session) {
    if (session == null) {
      return;
    }
    _cache.drop(session);
    if (identical(_session, session)) {
      _session = null;
    }
  }

  /// Sends [requests] in one multipleRequest and gives back the answers in order, each `{method, result,
  /// error_code}`. Throws an [ArgumentError] for a method that is not a read method, before anything is sent.
  Future<List<Map<String, Object?>>> call(List<({String method, Map<String, Object?> params})> requests) {
    for (final request in requests) {
      if (!tapoReadMethods.contains(request.method)) {
        throw ArgumentError.value(request.method, 'method', 'Not a read method of the camera');
      }
    }
    final payload = [
      for (final request in requests) {'method': request.method, 'params': request.params},
    ];
    return _serial.run(() async {
      for (var attempt = 0; ; attempt++) {
        TapoSession? session;
        try {
          session = await _sessionNow();
          final answer = await session.multiple(payload);
          final code = _int(answer['error_code']);
          if (code != null && code != 0) {
            throw TapoCameraException(TapoErrorKind.unsupported, code: code, detail: 'multipleRequest');
          }
          final responses = _map(answer['result'])?['responses'];
          return [
            if (responses is List)
              for (final response in responses) ?_map(response),
          ];
        } on TapoSessionRefused catch (error) {
          _forget(session);
          // Exactly one new login, and only for what one new login may cure
          if (attempt > 0 || !error.isSessionLost) {
            throw TapoCameraException(TapoErrorKind.unsupported, code: error.code, detail: 'request refused');
          }
          _log.fine('The camera ended the session (${error.code}): one new login');
        } on TapoNetworkException catch (error) {
          _forget(session);
          if (attempt > 0) {
            throw TapoCameraException(TapoErrorKind.unreachable, detail: host);
          }
          _log.fine('The camera did not answer (${error.detail}): trying once more');
        } on TapoCameraException {
          _forget(session);
          rethrow;
        }
      }
    });
  }

  /// The result of one [method]; throws a [TapoCameraException] when the camera refused it
  Future<Map<String, Object?>> _one(String method, Map<String, Object?> params) async {
    final answers = await call([(method: method, params: params)]);
    return _resultOf(answers, method);
  }

  static Map<String, Object?> _resultOf(List<Map<String, Object?>> answers, String method) {
    final answer = answers.where((answer) => answer['method'] == method).firstOrNull ?? answers.firstOrNull;
    if (answer == null) {
      throw TapoCameraException(TapoErrorKind.unsupported, detail: method);
    }
    final code = _int(answer['error_code']);
    if (code != null && code != 0) {
      throw TapoCameraException(TapoErrorKind.unsupported, code: code, detail: method);
    }
    return _map(answer['result']) ?? const {};
  }

  /// [compute] once per [ttl] for [key]; [refresh] asks again. A failure is not kept.
  Future<T> _kept<T>(String key, Duration ttl, bool refresh, Future<T> Function() compute) {
    final now = _clock();
    final kept = _answers[key];
    if (!refresh && kept != null && now.difference(kept.at) < ttl) {
      return kept.value.then((value) => value as T);
    }
    final value = compute();
    _answers[key] = (at: now, value: value);
    unawaited(
      value.then<void>(
        (_) {},
        onError: (Object _) {
          if (identical(_answers[key]?.value, value)) {
            _answers.remove(key);
          }
        },
      ),
    );
    return value;
  }

  static const _deviceInfoRequest = (
    method: 'getDeviceInfo',
    params: <String, Object?>{
      'device_info': {
        'name': ['basic_info'],
      },
    },
  );
  static const _timezoneRequest = (
    method: 'getTimezone',
    params: <String, Object?>{
      'system': {
        'name': ['basic'],
      },
    },
  );
  static const _cardRequest = (
    method: 'getSdCardStatus',
    params: <String, Object?>{
      'harddisk_manage': {
        'table': ['hd_info'],
      },
    },
  );
  static const _componentsRequest = (
    method: 'getAppComponentList',
    params: <String, Object?>{
      'app_component': {'name': 'app_component_list'},
    },
  );

  /// The camera's name, model, firmware, MAC address and time zone
  Future<TapoCameraDetails> details({bool refresh = false}) =>
      _kept('details', const Duration(minutes: 10), refresh, () async {
        final answers = await call([_deviceInfoRequest, _timezoneRequest]);
        return _takeDetails(answers);
      });

  TapoCameraDetails _takeDetails(List<Map<String, Object?>> answers) {
    final basic = _map(_map(_resultOf(answers, 'getDeviceInfo')['device_info'])?['basic_info']) ?? const {};
    String? zoneId;
    String? offsetText;
    try {
      final timezone = _map(_map(_resultOf(answers, 'getTimezone')['system'])?['basic']);
      zoneId = _text(timezone?['zone_id']);
      offsetText = _text(timezone?['timezone']);
    } on TapoCameraException catch (error) {
      _log.fine('No time zone from the camera: $error');
    }
    final details = TapoCameraDetails(
      alias: _text(basic['device_alias']) ?? '',
      model: _text(basic['device_model']) ?? '',
      firmware: _text(basic['sw_version']) ?? '',
      mac: (_text(basic['mac']) ?? '').replaceAll(':', '-').toLowerCase(),
      zoneId: zoneId,
    );
    _offsetText = offsetText;
    _info = _info.copyWith(
      model: details.model.isEmpty ? null : details.model,
      firmware: details.firmware.isEmpty ? null : details.firmware,
      zoneId: zoneId,
    );
    return details;
  }

  /// The standard offset the camera told with its zone, for a zone the time zone data does not know
  String? _offsetText;

  /// The state of the memory card
  Future<TapoCardStatus> cardStatus({bool refresh = false}) =>
      _kept('card', const Duration(seconds: 30), refresh, () async {
        final result = await _one(_cardRequest.method, _cardRequest.params);
        return _parseCard(result);
      });

  static TapoCardStatus _parseCard(Map<String, Object?> result) {
    final disks = _unwrap(_map(result['harddisk_manage'])?['hd_info']);
    if (disks.isEmpty) {
      return const TapoCardStatus(state: TapoCardState.absent, status: '');
    }
    final disk = disks.first;
    final status = _text(disk['status']) ?? '';
    int? bytes(String key) {
      final text = _text(disk[key]);
      return text == null ? null : int.tryParse(text.replaceAll(RegExp(r'[Bb]$'), ''));
    }

    final total = bytes('total_space_accurate') ?? bytes('video_total_space_accurate');
    final free = bytes('free_space_accurate') ?? bytes('video_free_space_accurate');
    final oldest = _int(disk['record_start_time']);
    return TapoCardStatus(
      state: switch (status.toLowerCase()) {
        'normal' => TapoCardState.normal,
        '' || 'offline' || 'none' || 'unplugged' => TapoCardState.absent,
        _ => TapoCardState.other,
      },
      status: status,
      totalBytes: total,
      usedBytes: total != null && free != null && free <= total ? total - free : null,
      oldestRecording: oldest != null && oldest > 0
          ? DateTime.fromMillisecondsSinceEpoch(oldest * 1000, isUtc: true)
          : null,
    );
  }

  /// "Test the camera": the details, the card, the zone and the components in one request
  Future<({TapoCameraDetails details, TapoCardStatus card})> check() async {
    final answers = await call([_deviceInfoRequest, _timezoneRequest, _cardRequest, _componentsRequest]);
    final details = _takeDetails(answers);
    final card = _parseCard(_resultOf(answers, _cardRequest.method));
    final now = _clock();
    _answers['details'] = (at: now, value: Future.value(details));
    _answers['card'] = (at: now, value: Future.value(card));
    try {
      final components = _parseComponents(_resultOf(answers, _componentsRequest.method));
      _answers['components'] = (at: now, value: Future.value(components));
    } on TapoCameraException catch (error) {
      _log.fine('No component list from the camera: $error');
    }
    return (details: details, card: card);
  }

  /// The versions of the modules of the camera ("playback" tells which listing it takes)
  Future<Map<String, int>> components() => _kept('components', const Duration(hours: 1), false, () async {
    final result = await _one(_componentsRequest.method, _componentsRequest.params);
    return _parseComponents(result);
  });

  static Map<String, int> _parseComponents(Map<String, Object?> result) {
    final list = _map(result['app_component'])?['app_component_list'];
    return {
      if (list is List)
        for (final item in list)
          if (_map(item) case final item? when item['name'] is String && _int(item['version']) != null)
            item['name']! as String: _int(item['version'])!,
    };
  }

  /// The zone of the camera's days (see [TapoZone]); asks the camera once when no zone is known yet
  Future<TapoZone> zone() async {
    if (_info.zoneId == null && _offsetText == null) {
      try {
        await details();
      } on TapoCameraException catch (error) {
        _log.fine('The time zone of the camera is not known, the device zone is used: $error');
      }
    }
    return TapoZone.of(_info.zoneId, offsetText: _offsetText);
  }

  /// The days with recordings, "yyyy-mm-dd" in the camera's zone, newest first, over the last 24 months. One request
  /// for the whole span; a camera with a full card refuses a wide span (-71105), then 31 days at a time.
  Future<List<String>> days({bool refresh = false}) => _kept('days', const Duration(seconds: 120), refresh, () async {
    final zone = await this.zone();
    final now = _clock();
    final today = zone.local(now);
    final end = DateTime.utc(today.year, today.month, today.day + 1);
    var start = DateTime.utc(today.year, today.month, today.day - 730);
    // The card holds nothing older than its oldest recording, when that is already known
    final card = _answers['card'];
    if (card != null) {
      // A failed card only loses the hint (the future holds a TapoCardStatus: catchError could not give null for it)
      final known = await card.value.then<Object?>((value) => value, onError: (Object _) => null);
      final oldest = (known as TapoCardStatus?)?.oldestRecording;
      if (oldest != null) {
        final local = zone.local(oldest);
        final first = DateTime.utc(local.year, local.month, local.day - 1);
        if (first.isAfter(start)) {
          start = first;
        }
      }
    }
    final found = <String>{};
    try {
      found.addAll(await _daysBetween(start, end));
    } on TapoCameraException catch (error) {
      if (error.code != -71105) {
        rethrow;
      }
      // Newest first, so that a failure late in the span loses the oldest days only
      for (var chunkEnd = end; !chunkEnd.isBefore(start); chunkEnd = chunkEnd.subtract(const Duration(days: 31))) {
        var chunkStart = chunkEnd.subtract(const Duration(days: 30));
        if (chunkStart.isBefore(start)) {
          chunkStart = start;
        }
        found.addAll(await _daysBetween(chunkStart, chunkEnd));
      }
    }
    return found.toList()..sort((a, b) => b.compareTo(a));
  });

  Future<List<String>> _daysBetween(DateTime start, DateTime end) async {
    String compact(DateTime day) => tapoDayOf(day.year, day.month, day.day).replaceAll('-', '');
    final result = await _one('searchDateWithVideo', {
      'playback': {
        'search_year_utility': {
          'channel': [0],
          'start_date': compact(start),
          'end_date': compact(end),
        },
      },
    });
    final days = <String>[];
    for (final item in _unwrap(_map(result['playback'])?['search_results'])) {
      final date = _text(item['date']);
      if (date != null && date.length == 8) {
        final day = '${date.substring(0, 4)}-${date.substring(4, 6)}-${date.substring(6, 8)}';
        if (tapoParseDay(day) != null) {
          days.add(day);
        }
      }
    }
    return days;
  }

  /// The clips of [day] ("yyyy-mm-dd" in the camera's zone), oldest first
  Future<List<TapoClip>> clips(String day, {bool refresh = false}) =>
      _kept('clips $day', const Duration(seconds: 20), refresh, () async {
        final date = tapoParseDay(day);
        if (date == null) {
          throw ArgumentError.value(day, 'day', 'Not a yyyy-mm-dd date');
        }
        final zone = await this.zone();
        final start = zone.startOfDay(date.year, date.month, date.day);
        final next = zone.startOfDay(date.year, date.month, date.day + 1);
        final startSeconds = start.millisecondsSinceEpoch ~/ 1000;
        final endSeconds = next.millisecondsSinceEpoch ~/ 1000 - 1;

        Map<String, int> components;
        try {
          components = await this.components();
        } on TapoCameraException catch (error) {
          _log.fine('No component list, the newest listing is tried: $error');
          components = const {};
        }
        final playback = components['playback'];
        List<Map<String, Object?>> items;
        if (playback == 1) {
          items = await _clipsOfDayLegacy(date);
        } else {
          try {
            items = playback != null && playback < 6
                ? await _clipsWithUtc(startSeconds, endSeconds, userId: await _userId())
                : await _clipsWithUtc(startSeconds, endSeconds);
          } on TapoCameraException catch (error) {
            // -71103: the listing wants the user id instead of the player id; -40106: no UTC listing at all
            if (error.code == -71103) {
              items = await _clipsWithUtc(startSeconds, endSeconds, userId: await _userId());
            } else if (error.code == -40106) {
              items = await _clipsOfDayLegacy(date);
            } else {
              rethrow;
            }
          }
        }
        final clips = <(int, int), TapoClip>{};
        for (final item in items) {
          final clipStart = _int(item['startTime']);
          final clipEnd = _int(item['endTime']);
          if (clipStart == null || clipEnd == null || clipEnd <= clipStart || clipStart < 0) {
            continue;
          }
          // A missing type is a motion, as in the official app
          final type = _int(item['video_type']) ?? _int(item['vedio_type']) ?? 2;
          clips[(clipStart, clipEnd)] = TapoClip(
            start: DateTime.fromMillisecondsSinceEpoch(clipStart * 1000, isUtc: true),
            end: DateTime.fromMillisecondsSinceEpoch(clipEnd * 1000, isUtc: true),
            videoType: type,
            kind: tapoClipKind(type),
            path: '/$day/$clipStart-$clipEnd.mov',
          );
        }
        return clips.values.toList()..sort((a, b) => a.start.compareTo(b.start));
      });

  /// The page size of the listings and the highest index the official app asks for
  static const _page = 100;
  static const _maxIndex = 12288;

  Future<List<Map<String, Object?>>> _clipsWithUtc(int start, int end, {int? userId}) async {
    final items = <Map<String, Object?>>[];
    for (var index = 0; index < _maxIndex; index += _page) {
      final result = await _one('searchVideoWithUTC', {
        'playback': {
          'search_video_with_utc': {
            'channel': 0,
            'start_time': start,
            'end_time': end,
            'start_index': index,
            'end_index': index + _page - 1,
            if (userId == null) 'player_id': tapoPlayerId(sourceId) else 'id': userId,
          },
        },
      });
      final playback = _map(result['playback']);
      final page = _unwrap(playback?['search_video_results']);
      items.addAll(page);
      if (page.isEmpty || _int(playback?['to_be_continued']) != 1) {
        break;
      }
    }
    return items;
  }

  Future<List<Map<String, Object?>>> _clipsOfDayLegacy(({int year, int month, int day}) date) async {
    final userId = await _userId();
    final items = <Map<String, Object?>>[];
    final compact = tapoDayOf(date.year, date.month, date.day).replaceAll('-', '');
    for (var index = 0; index < _maxIndex; index += _page) {
      final result = await _one('searchVideoOfDay', {
        'playback': {
          'search_video_utility': {
            'channel': 0,
            'date': compact,
            'start_index': index,
            'end_index': index + _page - 1,
            'id': userId,
          },
        },
      });
      final page = _unwrap(_map(result['playback'])?['search_video_results']);
      items.addAll(page);
      if (page.length < _page) {
        break;
      }
    }
    return items;
  }

  Future<int> _userId() => _kept('user id', const Duration(hours: 1), false, () async {
    final result = await _one('getUserID', {
      'system': {'get_user_id': 'null'},
    });
    final id = _int(result['user_id']);
    if (id == null) {
      throw const TapoCameraException(TapoErrorKind.unsupported, detail: 'getUserID');
    }
    return id;
  });

  /// Ends this connection. A session left in the cache keeps its transport, so that the next connection to the camera
  /// goes on with it instead of logging in again; an idle connection closes by itself after a few seconds.
  void close() {
    _closed = true;
    final session = _session;
    final keptInCache = session != null && identical(_cache.get(sourceId, host, _password)?.session, session);
    if (!keptInCache) {
      _transport?.close();
    }
    _transport = null;
    _session = null;
  }
}

/// The values of a list of single key maps (`[{"search_results_1": {...}}, ...]`), the shape of the camera's lists;
/// a list of plain maps is taken as it is
List<Map<String, Object?>> _unwrap(Object? items) {
  if (items is! List) {
    return const [];
  }
  final out = <Map<String, Object?>>[];
  for (final item in items) {
    final map = _map(item);
    if (map == null) {
      continue;
    }
    if (map.length == 1 && map.values.first is Map) {
      out.add(_map(map.values.first)!);
    } else {
      out.add(map);
    }
  }
  return out;
}

Map<String, Object?>? _map(Object? value) =>
    value is Map ? value.map((key, entry) => MapEntry('$key', entry as Object?)) : null;

int? _int(Object? value) => value is int ? value : (value is String ? int.tryParse(value.trim()) : null);

String? _text(Object? value) {
  if (value == null) {
    return null;
  }
  final text = '$value'.trim();
  return text.isEmpty ? null : text;
}
