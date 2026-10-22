// The big screen's side of "Sign in with your phone", without any network: the codes it shows, the hellos it
// accepts, and the single use of each code. The listener (pairing_server.dart) hands it what arrives and sends back
// what it answers; the panel shows what [ScreenPairingSession.state] tells.
//
// The rules (design 5, "Rules on the screen"):
// - a code shows for [quietLifetime], then a new one replaces it and the old one is dead at once;
// - once a phone said hello, the code stays until [codeLifetime] after it showed, so that its user has time to
//   confirm, and never longer: nothing of a code is taken past that deadline, whatever arrives;
// - at most [maxHellos] hellos per code (two phones of a family scanning at once), each with its own keys;
// - the first sealed message that decrypts uses the code up, and so does the first message of a hello that does not
//   decrypt; a message that names no hello of the code is refused and changes nothing;
// - the browser page may get the password (or the server address) wrong [maxPasswordTries] times per code;
// - after [idleCodes] codes that no phone sent anything to, the session pauses: no more listening until "Show a new
//   code" (a hello alone does not count, so that a device that only says hello cannot keep the screen listening).
//
// Each hello of a phone gets a check number, from its keys: the panel shows it, and the phone asks its user to check
// that the screen shows the number the phone shows.
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

  /// No phone used the last [ScreenPairingSession.idleCodes] codes: nothing listens until the user asks for a new code
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
    required this.deadline,
    required this.expiresAt,
  });

  /// Not secret: in the URL and the DNS-SD record
  final String id;

  /// S, in the QR code only
  final Uint8List secret;

  /// C, on the screen only
  final String code;
  final DateTime startedAt;

  /// [ScreenPairingSession.codeLifetime] after it showed: nothing of this code is taken from then on
  final DateTime deadline;

  /// When the next code replaces it: [ScreenPairingSession.quietLifetime] after it showed, [deadline] once a phone
  /// said hello. Never later than [deadline].
  DateTime expiresAt;
  final List<ScreenHello> hellos = [];
  bool _used = false;
  bool _busy = false;

  /// A message of one of its hellos came: the code was used, for the pause
  bool _answered = false;
  int _passwordFailures = 0;

  bool get isUsed => _used;

  @override
  String toString() => 'ScreenPairingCode(used: $_used, hellos: ${hellos.length})';
}

/// One hello a code accepted: the keys shared with that phone (or browser page)
class ScreenHello {
  ScreenHello({required this.mode, required this.client, required this.channel, required this.at, required this.check});

  final PairingMode mode;
  final PairingClient client;
  final PairingChannel channel;
  final DateTime at;

  /// The six digits the panel shows for this hello, and the phone too (pairingCheckNumber)
  final String check;

  /// Cancelled by its phone: nothing more of it is taken
  bool cancelled = false;

  String get handle => channel.handle;

  @override
  String toString() => 'ScreenHello(${client.wire}, cancelled: $cancelled)';
}

/// What the panel shows of the session
class ScreenPairingState {
  const ScreenPairingState({
    required this.phase,
    this.code,
    this.notice = ScreenPairingNotice.none,
    this.noticeDetail,
    this.checks = const [],
  });

  final ScreenPairingPhase phase;

  /// The code shown, null while paused or stopped
  final ScreenPairingCode? code;
  final ScreenPairingNotice notice;

  /// The server that could not be reached, for [ScreenPairingNotice.serverUnreachable]
  final String? noticeDetail;

  /// The check numbers of the phones that said hello to the code and wait for their user, oldest first: more than
  /// one tells that another device is signing in too
  final List<String> checks;

  @override
  String toString() => 'ScreenPairingState($phase, $notice, ${checks.length} phones)';
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

/// 400: it names no hello of this code (or one of the other client, or a cancelled one): refused, the code stays
class SealedUnknown extends SealedOutcome {
  const SealedUnknown();
}

/// The phone of [hello] cancelled: its check number goes from the panel, the code stays for another phone
class SealedCancelled extends SealedOutcome {
  const SealedCancelled(this.hello);
  final ScreenHello hello;
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

typedef _HelloKeys = ({Uint8List screenKey, Uint8List transcript, PairingKeys keys, Uint8List confirm, String check});

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
  final check = pairingCheckNumber(confirmKey: keys.confirm, transcript: transcript);
  return (screenKey: screen.publicKey, transcript: transcript, keys: keys, confirm: confirm, check: check);
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

  /// The longest a code is taken: two minutes after it showed
  static const codeLifetime = Duration(seconds: 120);

  /// How long a code shows while no phone said hello; the rest of [codeLifetime] is for the user of a phone that
  /// said hello at the last moment to confirm
  static const quietLifetime = Duration(seconds: 90);
  static const maxHellos = 3;
  static const maxPasswordTries = 3;

  /// Codes in a row that no phone sent anything to before the session pauses: about 10 minutes
  static const idleCodes = 7;

  final Uint8List _device;
  final DateTime Function() _clock;
  final Random _random;
  final PairingCompute _compute;

  final _states = StreamController<ScreenPairingState>.broadcast();
  ScreenPairingState _state = const ScreenPairingState(phase: ScreenPairingPhase.stopped);
  Timer? _timer;
  int _codesWithoutUse = 0;

  ScreenPairingState get state => _state;

  /// Every change of [state]
  Stream<ScreenPairingState> get states => _states.stream;

  ScreenPairingCode? get currentCode => _state.code;

  /// Shows a first code, or a new one after a pause
  void start() {
    _codesWithoutUse = 0;
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
      deadline: now.add(codeLifetime),
      expiresAt: now.add(quietLifetime),
    );
  }

  /// The check numbers of the phones that wait for their user
  static List<String> _checks(ScreenPairingCode code) => [
    for (final hello in code.hellos)
      if (hello.client == PairingClient.app && !hello.cancelled) hello.check,
  ];

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
    if (_clock().isBefore(code.expiresAt)) {
      _schedule(code);
      return;
    }
    // A sign in under way: the code takes nothing more (see _alive) and waits for its end
    if (code._busy) {
      _timer = Timer(const Duration(seconds: 1), () => _expire(code));
      return;
    }
    if (!code._answered) {
      _codesWithoutUse++;
    }
    if (_codesWithoutUse >= idleCodes) {
      _timer = null;
      _set(const ScreenPairingState(phase: ScreenPairingPhase.paused));
      return;
    }
    _rotate(ScreenPairingNotice.none);
  }

  /// The code [id] names, when it is the current one and alive: never past its deadline
  ScreenPairingCode? _alive(String id) {
    final code = _state.code;
    final now = _clock();
    if (code == null || code.id != id || !now.isBefore(code.expiresAt) || !now.isBefore(code.deadline)) {
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
    if (code.hellos.length >= maxHellos || code._busy) {
      return const HelloThrottled();
    }
    final first = code.hellos.isEmpty;
    code.hellos.add(
      ScreenHello(
        mode: parsedMode,
        client: parsedClient,
        at: _clock(),
        check: computed.check,
        channel: PairingChannel(
          transcript: computed.transcript,
          keys: computed.keys,
          sends: PairingDirection.down,
          random: _random,
        ),
      ),
    );
    // The first hello gives its user the rest of the two minutes, once: later ones never move the deadline
    if (first) {
      code.expiresAt = code.deadline;
      _schedule(code);
    }
    final phase = _state.phase == ScreenPairingPhase.waiting ? ScreenPairingPhase.confirmOnPhone : _state.phase;
    _set(ScreenPairingState(phase: phase, code: code, checks: _checks(code)));
    return HelloAccepted({
      'v': pairingProtocolVersion,
      'pk': pairingBase64(computed.screenKey),
      'd': pairingBase64(_device),
      'confirm': pairingBase64(computed.confirm),
    });
  }

  /// POST /p/{id}/session or /p/{id}/login: opens [envelope] with the hello it names. One that names no hello is
  /// refused and changes nothing; one that does not decrypt uses the code up; a cancel of the phone frees its hello;
  /// one that decrypts holds the code until [finish] says how the sign in went.
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
      if (candidate.handle == handle && candidate.client == client && !candidate.cancelled) {
        hello = candidate;
      }
    }
    // No hello of this code: whoever sent it never shared a key with the screen, and cannot use the code up
    if (hello == null) {
      return const SealedUnknown();
    }
    code._answered = true;
    _codesWithoutUse = 0;
    final message = hello.channel.open(envelope);
    if (message == null || message['v'] != pairingProtocolVersion) {
      code._used = true;
      _rotate(ScreenPairingNotice.tooManyAttempts);
      return const SealedRejected();
    }
    if (client == PairingClient.app && message['cancel'] == true) {
      hello.cancelled = true;
      final checks = _checks(code);
      final waiting = checks.isEmpty && code.hellos.every((other) => other.cancelled);
      _set(
        ScreenPairingState(
          phase: waiting ? ScreenPairingPhase.waiting : ScreenPairingPhase.confirmOnPhone,
          code: code,
          checks: checks,
        ),
      );
      return SealedCancelled(hello);
    }
    code._busy = true;
    _set(ScreenPairingState(phase: ScreenPairingPhase.signingIn, code: code, checks: _checks(code)));
    return SealedOpened(hello, message);
  }

  /// How the sign in of the message [open] gave went. [signedIn] ends the session; a [retry] of the browser page (a
  /// wrong password, a server that does not answer) keeps the code for another try, up to [maxPasswordTries] and as
  /// long as the code lives; anything else uses the code up and shows a new one with [notice]. Gives the tries left
  /// for a [retry], else null.
  int? finish({
    required String id,
    required bool signedIn,
    bool retry = false,
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
    if (retry) {
      code._passwordFailures++;
      final left = maxPasswordTries - code._passwordFailures;
      if (left > 0 && identical(_alive(id), code)) {
        _set(ScreenPairingState(phase: ScreenPairingPhase.confirmOnPhone, code: code, checks: _checks(code)));
        return left;
      }
    }
    code._used = true;
    _rotate(notice, detail: detail);
    return retry ? 0 : null;
  }
}
