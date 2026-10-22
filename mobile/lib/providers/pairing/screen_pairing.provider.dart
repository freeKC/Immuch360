// "Sign in with your phone" on a big screen (a TV, the Quest window, a computer): the listener and its announcement,
// for as long as the pairing panel shows (pairing_panel.widget.dart). It starts when the panel shows, and stops when
// the panel goes, when the app goes to the background or its window is hidden, when the codes pause (no phone for 10
// minutes) and once a phone signed the screen in. On a computer it follows the public network rule of the share of
// the computer: no listening on a network Windows calls public.

import 'dart:async';
import 'dart:isolate';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/network/interface_rank.dart';
import 'package:immich_mobile/desktop/network/windows_dns_sd.dart';
import 'package:immich_mobile/desktop/platform/desktop_device.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/pairing/screen_pairing_session.dart';
import 'package:immich_mobile/domain/services/pairing/screen_sign_in.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/network/pairing/pairing_server.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/phone_share.provider.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';

final _log = Logger('ScreenPairing');

/// A debug build may put another address in its code, for two emulators that reach each other only through the host
/// (`--dart-define=IMMUCH_PAIRING_ADVERTISE=10.0.2.2:18361`); a release build ignores it
const _debugAdvertise = String.fromEnvironment('IMMUCH_PAIRING_ADVERTISE');

/// Why the panel shows no code
enum ScreenPairingProblem {
  none,

  /// No address on a local network
  noNetwork,

  /// Windows: every network of the computer is marked public
  publicNetwork,

  /// The listener could not start
  failed,
}

/// What the panel shows
@immutable
class ScreenPairingView {
  const ScreenPairingView({
    this.phase = ScreenPairingPhase.stopped,
    this.kind = PairingScreenKind.tv,
    this.qrText,
    this.code,
    this.typedUrl,
    this.startedAt,
    this.expiresAt,
    this.notice = ScreenPairingNotice.none,
    this.noticeDetail,
    this.problem = ScreenPairingProblem.none,
    this.port,
    this.signedIn,
  });

  final ScreenPairingPhase phase;
  final PairingScreenKind kind;

  /// The text of the QR code; secret, never logged
  final String? qrText;

  /// The short code, in two groups of five; secret, never logged
  final String? code;

  /// `http://<address>:<port>/p`, for a browser typed by hand
  final String? typedUrl;
  final DateTime? startedAt;
  final DateTime? expiresAt;
  final ScreenPairingNotice notice;
  final String? noticeDetail;
  final ScreenPairingProblem problem;
  final int? port;

  /// Who signed the screen in, once it is
  final ScreenSignedIn? signedIn;

  ScreenPairingView copyWith({
    ScreenPairingPhase? phase,
    ScreenPairingProblem? problem,
    int? port,
    ScreenSignedIn? signedIn,
  }) => ScreenPairingView(
    phase: phase ?? this.phase,
    kind: kind,
    qrText: qrText,
    code: code,
    typedUrl: typedUrl,
    startedAt: startedAt,
    expiresAt: expiresAt,
    notice: notice,
    noticeDetail: noticeDetail,
    problem: problem ?? this.problem,
    port: port ?? this.port,
    signedIn: signedIn ?? this.signedIn,
  );

  @override
  String toString() => 'ScreenPairingView($phase, $problem)';
}

/// Announces a service of the given type; gives what stops the announcement
typedef PairingAdvertise =
    Future<Future<void> Function()> Function(String name, int port, Map<String, String> attributes);

/// What the pairing of a big screen needs from the device, replaced by fakes in the tests
class ScreenPairingEnvironment {
  const ScreenPairingEnvironment({
    required this.localAddresses,
    required this.publicNetworkOnly,
    required this.advertise,
    required this.networkChanges,
    required this.lifecycle,
    required this.deviceName,
    required this.kind,
    required this.os,
    required this.appVersion,
    required this.page,
    this.compute,
    this.advertisedAddress,
    this.preferredPort = pairingDefaultPort,
  });

  /// The addresses the listener serves and shows, the first one in the code
  final Future<List<String>> Function() localAddresses;

  /// Whether the device has local addresses, all of them on networks Windows marks as public
  final Future<bool> Function() publicNetworkOnly;
  final PairingAdvertise advertise;
  final Stream<void> Function() networkChanges;
  final Stream<AppLifecycleState> Function() lifecycle;
  final Future<String> Function() deviceName;
  final Future<PairingScreenKind> Function() kind;

  /// "Android", "Windows", "Linux" or "macOS"
  final String os;
  final Future<String> Function() appVersion;

  /// The files and texts of the browser page
  final Future<PairingPage> Function() page;
  final PairingCompute? compute;

  /// host:port to put in the code instead of the device's own (debug builds, two emulators)
  final String? advertisedAddress;
  final int preferredPort;
}

Future<R> _isolateCompute<A, R>(R Function(A argument) work, A argument) => Isolate.run(() => work(argument));

/// The texts of the browser page in the language of the app, by key; {provider} is left for the page to fill
Map<String, String> pairingPageTexts(Translations t) => {
  'pairing_web_title_tv': t.pairing_web_title_tv,
  'pairing_web_title_headset': t.pairing_web_title_headset,
  'pairing_web_title_computer': t.pairing_web_title_computer,
  'pairing_web_intro': t.pairing_web_intro,
  'pairing_web_code': t.pairing_web_code,
  'pairing_web_connect': t.pairing_web_connect,
  'pairing_web_connecting': t.pairing_web_connecting,
  'pairing_web_done': t.pairing_web_done,
  'pairing_web_open_app': t.pairing_web_open_app,
  'pairing_web_get_app': t.pairing_web_get_app,
  'pairing_web_oauth': t.pairing_web_oauth(provider: '{provider}'),
  'pairing_web_bad_credentials': t.pairing_web_bad_credentials,
  'pairing_web_lost': t.pairing_web_lost,
  'pairing_web_prefer_app': t.pairing_web_prefer_app,
  'pairing_web_expired': t.pairing_web_expired,
  'pairing_web_wrong_code': t.pairing_web_wrong_code,
  'pairing_web_unreachable': t.pairing_web_unreachable,
  'pairing_web_server_unreachable': t.pairing_web_server_unreachable,
  'pairing_web_paused': t.pairing_web_paused,
  'server_info_box_server_url': t.server_info_box_server_url,
  'email': t.email,
  'password': t.password,
};

Future<PairingPage> _loadPage() async {
  Future<Uint8List> load(String name) async => (await rootBundle.load('assets/pairing/$name')).buffer.asUint8List();
  return PairingPage(
    html: await load('index.html'),
    script: await load('app.js'),
    style: await load('app.css'),
    texts: pairingPageTexts(StaticTranslations.instance),
  );
}

Future<bool> _desktopPublicNetworkOnly() async {
  try {
    final candidates = await desktopShareCandidates();
    return candidates.isNotEmpty && candidates.every(isLeftOutAsPublic);
  } catch (_) {
    return false;
  }
}

final screenPairingEnvironmentProvider = Provider<ScreenPairingEnvironment>((ref) {
  return ScreenPairingEnvironment(
    // A computer listens only where it is shared: not on WSL, VPN or public networks (interface_rank.dart)
    localAddresses: CurrentPlatform.isDesktop ? desktopShareLocalAddresses : phoneShareLocalAddresses,
    publicNetworkOnly: CurrentPlatform.isWindows ? _desktopPublicNetworkOnly : () async => false,
    // bonsoir_windows crashes the app; Windows announces through dnsapi (lib/desktop/network/windows_dns_sd.dart)
    advertise: CurrentPlatform.isWindows
        ? (name, port, attributes) => windowsShareAdvertise(name, port, attributes, type: pairingServiceType)
        : (name, port, attributes) => bonsoirAdvertise(name, port, attributes, type: pairingServiceType),
    networkChanges: () => Connectivity().onConnectivityChanged.map<void>((_) {}),
    lifecycle: appLifecycleStates,
    deviceName: CurrentPlatform.isDesktop ? desktopShareDeviceName : phoneShareDeviceName,
    kind: () async {
      if (CurrentPlatform.isDesktop) {
        return PairingScreenKind.computer;
      }
      final headset = await ref.read(isHorizonOsProvider.future).catchError((Object _) => false);
      return headset ? PairingScreenKind.headset : PairingScreenKind.tv;
    },
    os: CurrentPlatform.isDesktop ? desktopDeviceType() : 'Android',
    appVersion: () async => (await PackageInfo.fromPlatform()).version,
    page: _loadPage,
    compute: _isolateCompute,
    advertisedAddress: kDebugMode && _debugAdvertise.isNotEmpty ? _debugAdvertise : null,
  );
});

/// See the top of this file
class ScreenPairingController extends Notifier<ScreenPairingView> {
  late ScreenPairingEnvironment _environment;
  ScreenSignInActions? _actions;
  ScreenPairingSession? _session;
  PairingServer? _server;
  ScreenSignIn? _signIn;
  Future<void> Function()? _stopAdvertising;
  StreamSubscription<ScreenPairingState>? _states;
  StreamSubscription<AppLifecycleState>? _lifecycle;
  StreamSubscription<void>? _network;
  String? _address;
  int _shown = 0;
  bool _background = false;

  /// Bumped by every start and stop, so that a start overtaken by a stop undoes what it made
  int _generation = 0;

  @override
  ScreenPairingView build() {
    _environment = ref.read(screenPairingEnvironmentProvider);
    ref.onDispose(() {
      _generation++;
      unawaited(_bringDown());
      unawaited(_lifecycle?.cancel());
    });
    return const ScreenPairingView();
  }

  /// The panel shows: listen until it goes. [actions] signs the screen in with what arrives.
  Future<void> show(ScreenSignInActions actions) async {
    _actions = actions;
    _shown++;
    if (_shown == 1) {
      await _lifecycle?.cancel();
      _lifecycle = _environment.lifecycle().listen(_onLifecycle);
    }
    if (_server == null && !_background) {
      await _start();
    }
  }

  /// The panel goes
  Future<void> hide() async {
    _shown = _shown > 0 ? _shown - 1 : 0;
    if (_shown == 0) {
      await _lifecycle?.cancel();
      _lifecycle = null;
      _generation++;
      await _bringDown();
      if (state.phase != ScreenPairingPhase.signedIn) {
        state = ScreenPairingView(kind: state.kind);
      }
    }
  }

  /// "Show a new code", after the codes paused or a problem
  Future<void> showNewCode() async {
    final session = _session;
    if (session != null && _server != null) {
      session.start();
      return;
    }
    await _start();
  }

  void _onLifecycle(AppLifecycleState lifecycle) {
    switch (lifecycle) {
      case AppLifecycleState.paused || AppLifecycleState.hidden || AppLifecycleState.detached:
        if (!_background) {
          _background = true;
          _generation++;
          unawaited(_bringDown().then((_) => state = ScreenPairingView(kind: state.kind)));
        }
      case AppLifecycleState.resumed:
        if (_background) {
          _background = false;
          if (_shown > 0 && state.phase != ScreenPairingPhase.signedIn) {
            unawaited(_start());
          }
        }
      case AppLifecycleState.inactive:
        break;
    }
  }

  Future<void> _start() async {
    final generation = ++_generation;
    await _bringDown();
    final actions = _actions;
    if (actions == null) {
      return;
    }
    try {
      final kind = await _environment.kind();
      final addresses = await _environment.localAddresses();
      if (generation != _generation) {
        return;
      }
      if (addresses.isEmpty) {
        final public = await _environment.publicNetworkOnly();
        state = ScreenPairingView(
          kind: kind,
          problem: public ? ScreenPairingProblem.publicNetwork : ScreenPairingProblem.noNetwork,
        );
        _watchNetwork(generation);
        return;
      }
      var label = Store.tryGet(StoreKey.pairingScreenLabel);
      if (label == null || label.trim().isEmpty) {
        label = (await _environment.deviceName()).trim();
        await Store.put(StoreKey.pairingScreenLabel, label);
      }
      final device = {'label': label, 'kind': kind.wire, 'os': _environment.os, 'app': await _environment.appVersion()};
      final session = ScreenPairingSession(device: device, compute: _environment.compute);
      final signIn = ScreenSignIn(actions);
      final server = PairingServer(
        session: session,
        signIn: signIn,
        page: await _environment.page(),
        device: device,
        servedAddresses: _environment.localAddresses,
        preferredPort: _environment.preferredPort,
      );
      final port = await server.start();
      if (generation != _generation) {
        await server.stop();
        await session.dispose();
        return;
      }
      _session = session;
      _server = server;
      _signIn = signIn;
      _address = addresses.first;
      state = ScreenPairingView(kind: kind, port: port);
      _states = session.states.listen((sessionState) => _onSession(sessionState, kind, port));
      session.start();
      _watchNetwork(generation);
      try {
        _stopAdvertising = await _environment.advertise(phoneShareServiceName(label), port, {
          'v': '$pairingProtocolVersion',
          'kind': kind.wire,
        });
        if (generation != _generation) {
          await _stopAdvertising?.call();
          _stopAdvertising = null;
        }
      } catch (error) {
        // The code and the typed address work without it; only Enter a code lists the screens it finds
        _log.info('Pairing: not announced on the network: ${error.runtimeType}');
      }
    } catch (error) {
      _log.warning('Pairing: the listener did not start: ${error.runtimeType}');
      if (generation == _generation) {
        state = ScreenPairingView(kind: state.kind, problem: ScreenPairingProblem.failed);
      }
    }
  }

  void _watchNetwork(int generation) {
    unawaited(_network?.cancel());
    _network = _environment.networkChanges().listen((_) async {
      if (generation != _generation) {
        return;
      }
      final addresses = await _environment.localAddresses();
      if (generation != _generation) {
        return;
      }
      if (_server == null) {
        // No network before: maybe one now
        if (addresses.isNotEmpty && _shown > 0 && !_background) {
          unawaited(_start());
        }
        return;
      }
      await _server?.refreshServedAddresses();
      if (addresses.isEmpty || addresses.first != _address) {
        // The address in the code changed: a new start shows a code with the new one
        unawaited(_start());
      }
    });
  }

  void _onSession(ScreenPairingState sessionState, PairingScreenKind kind, int port) {
    final code = sessionState.code;
    final (host, shownPort) = _advertised(port);
    if (sessionState.phase == ScreenPairingPhase.signedIn) {
      final signedIn = _signIn?.signedIn;
      _generation++;
      unawaited(_bringDown());
      state = ScreenPairingView(kind: kind, phase: ScreenPairingPhase.signedIn, signedIn: signedIn);
      return;
    }
    state = ScreenPairingView(
      phase: sessionState.phase,
      kind: kind,
      qrText: code == null || host == null
          ? null
          : buildPairingQrText(host: host, port: shownPort, id: code.id, secret: code.secret),
      code: code == null ? null : formatPairingCode(code.code),
      typedUrl: host == null ? null : buildPairingTypedUrl(host: host, port: shownPort),
      startedAt: code?.startedAt,
      expiresAt: code?.expiresAt,
      notice: sessionState.notice,
      noticeDetail: sessionState.noticeDetail,
      port: port,
    );
  }

  /// The address and port the code shows: the device's own, or the debug override
  (String?, int) _advertised(int port) {
    final override = _environment.advertisedAddress;
    if (override != null) {
      final parsed = parsePairingAddress(override);
      if (parsed != null) {
        return (parsed.host, parsed.port);
      }
    }
    final address = _address;
    return (address != null && isPrivatePairingIPv4(address) ? address : null, port);
  }

  Future<void> _bringDown() async {
    final session = _session;
    final server = _server;
    final stopAdvertising = _stopAdvertising;
    _session = null;
    _server = null;
    _stopAdvertising = null;
    unawaited(_states?.cancel());
    _states = null;
    unawaited(_network?.cancel());
    _network = null;
    try {
      await stopAdvertising?.call();
    } catch (error) {
      _log.fine('Pairing: the announcement did not stop: ${error.runtimeType}');
    }
    await server?.stop();
    session?.stop();
    await session?.dispose();
  }
}

final screenPairingProvider = NotifierProvider<ScreenPairingController, ScreenPairingView>(ScreenPairingController.new);

/// Whether this device is a big screen that a phone signs in: a TV (the remote control layout), the Quest window, a
/// computer. The phones and tablets scan the code instead.
final isBigScreenProvider = Provider.autoDispose<bool>((ref) {
  if (CurrentPlatform.isDesktop || ref.watch(tvModeProvider)) {
    return true;
  }
  return ref.watch(isHorizonOsProvider).value ?? false;
});
