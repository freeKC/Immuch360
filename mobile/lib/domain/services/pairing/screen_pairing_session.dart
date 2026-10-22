// The big screen's side of "Sign in with your phone", without any network: the codes it shows, the hellos it
// accepts, and the single use of each code. The listener (pairing_server.dart) hands it what arrives and sends back
// what it answers; the panel shows what [ScreenPairingSession.state] tells.
//
// The rules (design 5, "Rules on the screen"):
// - a code lives [codeLifetime], then a new one replaces it and the old one is dead at once;
// - at most [maxHellos] hellos per code (two phones of a family scanning at once), each with its own keys;
// - after a valid hello the code stops rotating for up to [holdAfterHello], while the phone asks its user;
// - the first sealed message that decrypts uses the code up, and so does the first one that does not;
// - the browser page may get the password wrong [maxPasswordTries] times per code;
// - after [idleCodes] codes without any hello, the session pauses: no more listening until "Show a new code".
//
// S, the code and the keys live in memory only, and never go to the logs.

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';

/// What the panel shows
enum ScreenPairingPhase {
  /// A code is shown, nobody scanned it yet
  waiting,

  /// A phone said hello: its user is asked to confirm
  confirmOnPhone,

  /// The session or the credentials arrived: the screen signs in
  signingIn,

  /// Signed in: the listener stops
  signedIn,

  /// No hello for [ScreenPairingSession.idleCodes] codes: nothing listens until the user asks for a new code
  paused,

  /// Stopped by its owner
  stopped,
}

/// Why the current code replaced the previous one before its time, for a line under it
enum ScreenPairingNotice {
  none,

  /// A message did not decrypt: wrong code, or another device
  tooManyAttempts,

  /// The phone's server could not be reached from here
  serverUnreachable,

  /// The token or the credentials were refused
  signInFailed,
}

/// The code the screen shows now
class ScreenPairingCode {
  ScreenPairingCode._({
    required this.id,
    required this.secret,
    required this.code,
    required this.startedAt,
    required this.expiresAt,
  });

  /// Not secret: in the URL and the DNS-SD record
  final String id;

  /// S, in the QR code only
  final Uint8List secret;

  /// C, on the screen only
  final String code;
  final DateTime startedAt;
  DateTime expiresAt;
  final List<ScreenHello> hellos = [];
  bool _used = false;
  bool _busy = false;
  int _passwordFailures = 0;

  bool get isUsed => _used;

  @override
  String toString() => 'ScreenPairingCode(used: $_used, hellos: ${hellos.length})';
}

/// One hello a code accepted: the keys shared with that phone (or browser page)
class ScreenHello {
  ScreenHello({required this.mode, required this.client, required this.channel, required this.at});

  final PairingMode mode;
  final PairingClient client;
  final PairingChannel channel;
  final DateTime at;

  String get handle => channel.handle;
}

/// What the panel shows of the session
class ScreenPairingState {
  const ScreenPairingState({required this.phase, this.code, this.notice = ScreenPairingNotice.none, this.noticeDetail});

  final ScreenPairingPhase phase;

  /// The code shown, null while paused or stopped
  final ScreenPairingCode? code;
  final ScreenPairingNotice notice;

  /// The server that could not be reached, for [ScreenPairingNotice.serverUnreachable]
  final String? noticeDetail;

  @override
  String toString() => 'ScreenPairingState($phase, $notice)';
}

/// The answer to a hello
sealed class HelloOutcome {
  const HelloOutcome();
}

class HelloAccepted extends HelloOutcome {
  const HelloAccepted(this.response);

  /// {v, pk, d, confirm}: the screen's key, its device bytes and the proof that it knows the secret
  final Map<String, Object> response;
}

/// 410: unknown, expired or used code
class HelloGone extends HelloOutcome {
  const HelloGone({required this.used});
  final bool used;
}

/// 429: [ScreenPairingSession.maxHellos] already
class HelloThrottled extends HelloOutcome {
  const HelloThrottled();
}

/// 400: not a hello of this protocol
class HelloInvalid extends HelloOutcome {
  const HelloInvalid();
}

/// What a sealed message of a phone or browser page turned into
sealed class SealedOutcome {
  const SealedOutcome();
}

/// It decrypted: [message] is the plain JSON, [hello] seals the answer
class SealedOpened extends SealedOutcome {
  const SealedOpened(this.hello, this.message);
  final ScreenHello hello;
  final Map<String, Object?> message;
}

/// 410: unknown, expired or used code
class SealedGone extends SealedOutcome {
  const SealedGone({required this.used});
  final bool used;
}

/// 400: it did not decrypt, the code is used up
class SealedRejected extends SealedOutcome {
  const SealedRejected();
}

/// 409: another message of this code is being handled
class SealedBusy extends SealedOutcome {
  const SealedBusy();
}

/// Runs the crypto of a hello, which takes tens of milliseconds of pure Dart on a TV: in an isolate in the app
/// (Isolate.run), in place in the tests. [work] is a top-level function, so that nothing else goes to the isolate.
typedef PairingCompute = Future<R> Function<A, R>(R Function(A argument) work, A argument);

Future<R> _inline<A, R>(R Function(A argument) work, A argument) async => work(argument);

typedef _HelloInput = ({
  String id,
  PairingMode mode,
  PairingClient client,
  Uint8List phoneKey,
  Uint8List secret,
  Uint8List device,
});

typedef _HelloKeys = ({Uint8List screenKey, Uint8List transcript, PairingKeys keys, Uint8List confirm});

/// The hello's keys and proof, with a new key pair of the screen
_HelloKeys? _computeHello(_HelloInput input) {
  final screen = PairingKeyPair.generate();
  final shared = screen.agree(input.phoneKey);
  if (shared == null) {
    return null;
  }
  final transcript = pairingTranscript(
    id: input.id,
    mode: input.mode,
    client: input.client,
    phoneKey: input.phoneKey,
    screenKey: screen.publicKey,
  );
  final keys = derivePairingKeys(shared: shared, secret: input.secret, transcript: transcript);
  final confirm = pairingConfirm(confirmKey: keys.confirm, transcript: transcript, device: input.device);
  return (screenKey: screen.publicKey, transcript: transcript, keys: keys, confirm: confirm);
}

/// See the top of this file
class ScreenPairingSession {
  ScreenPairingSession({
    required Map<String, String> device,
    DateTime Function()? clock,
    Random? random,
    PairingCompute? compute,
  }) : _device = pairingDeviceBytes(device),
       _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure(),
       _compute = compute ?? _inline;

  static const codeLifetime = Duration(seconds: 120);
  static const holdAfterHello = Duration(seconds: 60);
  static const maxHellos = 3;
  static const maxPasswordTries = 3;

  /// Codes in a row without a hello before the session pauses: 10 minutes
  static const idleCodes = 5;

  final Uint8List _device;
  final DateTime Function() _clock;
  final Random _random;
  final PairingCompute _compute;

  final _states = StreamController<ScreenPairingState>.broadcast();
  ScreenPairingState _state = const ScreenPairingState(phase: ScreenPairingPhase.stopped);
  Timer? _timer;
  int _codesWithoutHello = 0;

  ScreenPairingState get state => _state;

  /// Every change of [state]
  Stream<ScreenPairingState> get states => _states.stream;

  ScreenPairingCode? get currentCode => _state.code;

  /// Shows a first code, or a new one after a pause
  void start() {
    _codesWithoutHello = 0;
    _rotate(ScreenPairingNotice.none);
  }

  /// No code any more: every later message gets 410
  void stop() {
    _timer?.cancel();
    _timer = null;
    _set(const ScreenPairingState(phase: ScreenPairingPhase.stopped));
  }

  Future<void> dispose() async {
    stop();
    await _states.close();
  }

  void _set(ScreenPairingState state) {
    _state = state;
    if (!_states.isClosed) {
      _states.add(state);
    }
  }

  ScreenPairingCode _newCode() {
    final now = _clock();
    return ScreenPairingCode._(
      id: pairingBase64(pairingRandomBytes(pairingIdBytes, _random)),
      secret: pairingRandomBytes(pairingSecretBytes, _random),
      code: newPairingCode(_random),
      startedAt: now,
      expiresAt: now.add(codeLifetime),
    );
  }

  /// A new code in place of the current one, which is dead at once
  void _rotate(ScreenPairingNotice notice, {String? detail}) {
    _timer?.cancel();
    final code = _newCode();
    _set(ScreenPairingState(phase: ScreenPairingPhase.waiting, code: code, notice: notice, noticeDetail: detail));
    _schedule(code);
  }

  void _schedule(ScreenPairingCode code) {
    _timer?.cancel();
    final left = code.expiresAt.difference(_clock());
    _timer = Timer(left.isNegative ? Duration.zero : left, () => _expire(code));
  }

  void _expire(ScreenPairingCode code) {
    if (!identical(_state.code, code)) {
      return;
    }
    // Held by a hello that came late, or a sign in under way: the code waits for its end
    if (code._busy) {
      code.expiresAt = _clock().add(const Duration(seconds: 5));
      _schedule(code);
      return;
    }
    if (code.hellos.isEmpty) {
      _codesWithoutHello++;
    }
    if (_codesWithoutHello >= idleCodes) {
      _timer = null;
      _set(const ScreenPairingState(phase: ScreenPairingPhase.paused));
      return;
    }
    _rotate(ScreenPairingNotice.none);
  }

  /// The code [id] names, when it is the current one and alive
  ScreenPairingCode? _alive(String id) {
    final code = _state.code;
    if (code == null || code.id != id || !_clock().isBefore(code.expiresAt)) {
      return null;
    }
    return code;
  }

  /// POST /p/{id}/hello
  Future<HelloOutcome> hello({
    required String id,
    required Object? mode,
    required Object? client,
    required Object? phoneKey,
  }) async {
    final parsedMode = PairingMode.fromWire(mode);
    final parsedClient = PairingClient.fromWire(client);
    final key = pairingDecodeBase64(phoneKey);
    final code = _alive(id);
    if (code == null) {
      return HelloGone(used: _state.code?.id == id && _state.code!.isUsed);
    }
    if (code.isUsed) {
      return const HelloGone(used: true);
    }
    if (parsedMode == null || parsedClient == null || key == null || key.length != 33) {
      return const HelloInvalid();
    }
    if (code.hellos.length >= maxHellos || code._busy) {
      return const HelloThrottled();
    }
    final secret = parsedMode == PairingMode.qr ? code.secret : Uint8List.fromList(code.code.codeUnits);
    final _HelloInput input = (
      id: id,
      mode: parsedMode,
      client: parsedClient,
      phoneKey: key,
      secret: secret,
      device: _device,
    );
    final computed = await _compute<_HelloInput, _HelloKeys?>(_computeHello, input);
    if (computed == null) {
      return const HelloInvalid();
    }
    // The code may have changed while the keys were computed
    if (!identical(_alive(id), code) || code.isUsed) {
      return HelloGone(used: code.isUsed);
    }
    if (code.hellos.length >= maxHellos) {
      return const HelloThrottled();
    }
    final now = _clock();
    code.hellos.add(
      ScreenHello(
        mode: parsedMode,
        client: parsedClient,
        at: now,
        channel: PairingChannel(
          transcript: computed.transcript,
          keys: computed.keys,
          sends: PairingDirection.down,
          random: _random,
        ),
      ),
    );
    _codesWithoutHello = 0;
    final held = now.add(holdAfterHello);
    if (held.isAfter(code.expiresAt)) {
      code.expiresAt = held;
      _schedule(code);
    }
    if (_state.phase == ScreenPairingPhase.waiting) {
      _set(ScreenPairingState(phase: ScreenPairingPhase.confirmOnPhone, code: code));
    }
    return HelloAccepted({
      'v': pairingProtocolVersion,
      'pk': pairingBase64(computed.screenKey),
      'd': pairingBase64(_device),
      'confirm': pairingBase64(computed.confirm),
    });
  }

  /// POST /p/{id}/session or /p/{id}/login: opens [envelope] with the hello it names. One that does not decrypt
  /// uses the code up; one that does holds the code until [finish] says how the sign in went.
  SealedOutcome open({required String id, required Map<String, Object?> envelope, required PairingClient client}) {
    final code = _alive(id);
    if (code == null) {
      return SealedGone(used: _state.code?.id == id && _state.code!.isUsed);
    }
    if (code.isUsed) {
      return const SealedGone(used: true);
    }
    if (code._busy) {
      return const SealedBusy();
    }
    final handle = envelope['h'];
    ScreenHello? hello;
    for (final candidate in code.hellos) {
      if (candidate.handle == handle && candidate.client == client) {
        hello = candidate;
      }
    }
    final message = hello?.channel.open(envelope);
    if (hello == null || message == null || message['v'] != pairingProtocolVersion) {
      code._used = true;
      _rotate(ScreenPairingNotice.tooManyAttempts);
      return const SealedRejected();
    }
    code._busy = true;
    _set(ScreenPairingState(phase: ScreenPairingPhase.signingIn, code: code));
    return SealedOpened(hello, message);
  }

  /// How the sign in of the message [open] gave went. [signedIn] ends the session; a wrong password of the browser
  /// page keeps the code for another try, up to [maxPasswordTries]; anything else uses the code up and shows a new
  /// one with [notice]. Gives the tries left for a wrong password, else null.
  int? finish({
    required String id,
    required bool signedIn,
    bool wrongPassword = false,
    ScreenPairingNotice notice = ScreenPairingNotice.signInFailed,
    String? detail,
  }) {
    final code = _state.code;
    if (code == null || code.id != id) {
      return null;
    }
    code._busy = false;
    if (signedIn) {
      code._used = true;
      _timer?.cancel();
      _timer = null;
      _set(ScreenPairingState(phase: ScreenPairingPhase.signedIn, code: code));
      return null;
    }
    if (wrongPassword) {
      code._passwordFailures++;
      final left = maxPasswordTries - code._passwordFailures;
      if (left > 0) {
        _set(ScreenPairingState(phase: ScreenPairingPhase.confirmOnPhone, code: code));
        return left;
      }
    }
    code._used = true;
    _rotate(notice, detail: detail);
    return wrongPassword ? 0 : null;
  }
}
