// The logins of this run, in memory only, so that a camera is not logged in to twice in a row: a C200 refuses a new
// login while its previous session lives (Tapo design 2.4 step 7), and every refusal counts towards a lockout. "Test the
// camera" leaves its session here, and the connection the camera page opens after the save takes it over. A session is
// kept until the camera forgets it (its expiry), and dropped as soon as the camera refuses it.
//
// The cache also tells which hosts a login reached through the pinned certificate of their camera in this run: the
// media port (8800) of a host is only opened after such a login, since its Digest exchange travels in clear and could
// be guessed offline by whoever answers in the camera's place.
//
// It also remembers the refusals of this run (a wrong password, a lockout): the camera page asks the camera from
// several places at once (its details, its days, the pictures of the clips), and each new login with a refused password
// would count towards a lockout. A remembered refusal is told again without asking the camera, until the user asks
// again ("Test the camera", Retry) or the address or the password changes.

import 'package:immich_mobile/domain/models/tapo_camera_info.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_crypto.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_login.dart';

/// A login of this run: its session and what it learned about the camera
class TapoCachedLogin {
  const TapoCachedLogin({required this.session, required this.info});

  final TapoSession session;
  final TapoCameraInfo info;
}

class TapoSessionCache {
  TapoSessionCache();

  /// The cache of the app
  static final instance = TapoSessionCache();

  final Map<String, TapoCachedLogin> _logins = {};

  /// Host (lower case) to the certificate a login went through
  final Map<String, String> _verified = {};

  /// The refusals by the key of their login, with when they were told
  final Map<String, ({TapoCameraException error, DateTime at})> _refusals = {};

  /// The source, the address and the password (as a digest, so that the key holds no password) of a login: a new
  /// address or a new password needs a new login
  static String _key(String sourceId, String host, String password) =>
      '$sourceId|${host.trim().toLowerCase()}|${sha256Hex(password)}';

  /// The live login of [sourceId] at [host] with [password], null when there is none or it expired
  TapoCachedLogin? get(String sourceId, String host, String password) {
    final key = _key(sourceId, host, password);
    final login = _logins[key];
    if (login == null) {
      return null;
    }
    if (login.session.isExpired) {
      _logins.remove(key);
      return null;
    }
    return login;
  }

  void put(String sourceId, String host, String password, TapoCachedLogin login) =>
      _logins[_key(sourceId, host, password)] = login;

  /// Forgets [session] once the camera refused it; a newer login of the same camera stays
  void drop(TapoSession session) => _logins.removeWhere((_, login) => identical(login.session, session));

  /// Forgets every login and refusal of [sourceId] (the camera was removed)
  void forget(String sourceId) {
    _logins.removeWhere((key, _) => key.startsWith('$sourceId|'));
    forgetRefusals(sourceId);
  }

  /// Remembers that the camera refused [password] (wrongPassword) or is locked, see the header
  void refuse(String sourceId, String host, String password, TapoCameraException error, {DateTime? now}) =>
      _refusals[_key(sourceId, host, password)] = (error: error, at: now ?? DateTime.now());

  /// The refusal remembered for [sourceId] at [host] with [password], null when there is none. A lockout tells the
  /// minutes left from when the camera told it, and no minutes once they are over: the camera is not asked again on
  /// its own even then.
  TapoCameraException? refusal(String sourceId, String host, String password, {DateTime? now}) {
    final refused = _refusals[_key(sourceId, host, password)];
    if (refused == null) {
      return null;
    }
    final error = refused.error;
    final minutes = error.lockedMinutes;
    if (error.kind != TapoErrorKind.locked || minutes == null) {
      return error;
    }
    final elapsed = (now ?? DateTime.now()).difference(refused.at).inSeconds;
    final left = (minutes * 60 - elapsed + 59) ~/ 60;
    return TapoCameraException(TapoErrorKind.locked, code: error.code, lockedMinutes: left > 0 ? left : null);
  }

  /// Forgets the refusals of [sourceId]: the user asks the camera again
  void forgetRefusals(String sourceId) => _refusals.removeWhere((key, _) => key.startsWith('$sourceId|'));

  /// Remembers that a login reached [host] through the certificate [certificateSha256], pinned for its camera
  void markVerified(String host, String certificateSha256) =>
      _verified[host.trim().toLowerCase()] = certificateSha256.toLowerCase();

  /// Whether a login reached [host] through [certificateSha256] in this run
  bool isVerified(String host, String? certificateSha256) {
    final seen = _verified[host.trim().toLowerCase()];
    return seen != null && certificateSha256 != null && seen == certificateSha256.toLowerCase();
  }

  /// Everything, for the tests
  void clear() {
    _logins.clear();
    _verified.clear();
    _refusals.clear();
  }
}
