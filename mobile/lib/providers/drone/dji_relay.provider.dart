// DJI link, stage 2b: the phone relays the drone's picture and flight values to Immuch360 on a headset of the same
// local network, and the headset receives them. Receive only toward the remote: the native relay takes a hello, pings
// and a bye from a headset and nothing else, and nothing on either device can move the aircraft.
//
// Sending (a phone): the code (the pairing alphabet, made by newPairingCode, kept in the secure storage until "New
// code"), the native relay with its foreground service, the announcement under the app's own pairing type with
// kind=drone (no third service type), the addresses with the port for a typed connection, and the screen kept on
// while the page is in front and sending, since Android keeps the Wi-Fi in its low latency mode only for an app in
// front with the screen on.
//
// Receiving (a headset, or a phone that receives): the phones announced with kind=drone on private IPv4 addresses, the
// code typed once per phone and remembered for its install id, the native receiver, and the fallback to the address
// the announcement gives after three failed attempts.

import 'dart:async';
import 'dart:io';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/network/network_discovery_probes.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/network/phone_share.provider.dart';
import 'package:immich_mobile/providers/permission.provider.dart';
import 'package:immich_mobile/services/secure_storage.service.dart';
import 'package:logging/logging.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

final _log = Logger('DjiRelay');

/// The port the relay tries first: 8360 is the phone share, 8361 the pairing
const djiRelayDefaultPort = 8362;

/// The code of this phone in the secure storage
const djiRelayCodeKey = 'dji_relay_code';

/// The code remembered on a headset for the phone of install id [phoneId]
String djiRelayRememberedCodeKey(String phoneId) => 'dji_relay_code.$phoneId';

/// The TXT record of a sending phone, under the pairing type: pairing protocol 1, relay protocol 1, kind drone
Map<String, String> djiRelayAttributes(String installId) => {'v': '1', 'kind': 'drone', 'rv': '1', 'id': installId};

/// A phone that sends, found on the network
class DjiRelayPhone {
  const DjiRelayPhone({required this.name, required this.host, required this.port, this.id});

  final String name;
  final String host;
  final int port;

  /// The install id of the phone, which its remembered code is kept for
  final String? id;

  String get address => '$host:$port';
}

/// One address of this phone on the local network; [hotspot] when it is the phone's own hotspot
class DjiRelayAddress {
  const DjiRelayAddress(this.address, {this.hotspot = false});

  final String address;
  final bool hotspot;
}

/// The phones announced under the pairing type that are sending phones: kind=drone, on a private IPv4 address. The
/// screens waiting to be signed in (kind tv, headset, computer) are not listed.
Future<DjiRelayPhone?> djiRelayPhoneOf(MdnsService service, Future<String?> Function(String host) lookup) async {
  if (service.attributes['kind'] != 'drone') {
    return null;
  }
  final host = isPrivatePairingIPv4(service.host) ? service.host : await lookup(service.host);
  if (host == null || !isPrivatePairingIPv4(host)) {
    return null;
  }
  final id = service.attributes['id'];
  return DjiRelayPhone(
    name: cleanPairingText(service.name),
    host: host,
    port: service.port,
    id: id != null && RegExp(r'^[0-9a-f]{16}$').hasMatch(id) ? id : null,
  );
}

/// The address typed on a headset ("192.168.1.23:8362", "192.168.1.23"), 8362 when no port is written; null when the
/// host is not a private IPv4 address written the plain way
({String host, int port})? parseDjiRelayAddress(String typed) {
  final text = typed.trim();
  final match = RegExp(r'^([0-9.]+)(?::([0-9]{1,5}))?$').firstMatch(text);
  if (match == null) {
    return null;
  }
  final host = match.group(1)!;
  final port = match.group(2) == null ? djiRelayDefaultPort : int.parse(match.group(2)!);
  if (!isPrivatePairingIPv4(host) || port < 1 || port > 65535) {
    return null;
  }
  return (host: host, port: port);
}

/// The addresses of this phone with the interface names, the hotspot ones labelled
Future<List<DjiRelayAddress>> djiRelayLocalAddresses() async {
  try {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    final named = [
      for (final interface in interfaces)
        for (final address in interface.addresses) (interface.name, address),
    ];
    final ordered = phoneShareAddressesOf(named);
    bool isHotspot(String address) => named.any(
      (entry) =>
          entry.$2.address == address &&
          const ['ap', 'swlan', 'softap'].any((prefix) => entry.$1.toLowerCase().startsWith(prefix)),
    );
    return [for (final address in ordered) DjiRelayAddress(address, hotspot: isHotspot(address))];
  } catch (error) {
    _log.fine('No network interface: $error');
    return const [];
  }
}

typedef DjiRelayAdvertise =
    Future<Future<void> Function()> Function(String name, int port, Map<String, String> attributes);

/// What the relay needs from the device, replaced by fakes in the tests
class DjiRelayEnvironment {
  const DjiRelayEnvironment({
    required this.advertise,
    required this.browse,
    required this.lookup,
    required this.localAddresses,
    required this.deviceName,
    required this.installId,
    required this.readSecret,
    required this.writeSecret,
    required this.deleteSecret,
    required this.keepScreenOn,
    required this.askNotifications,
    this.newCode = newPairingCode,
  });

  final DjiRelayAdvertise advertise;

  /// The services of the pairing type until the future completes
  final Stream<MdnsService> Function(Future<void> until) browse;
  final Future<String?> Function(String host) lookup;
  final Future<List<DjiRelayAddress>> Function() localAddresses;
  final Future<String> Function() deviceName;
  final Future<String> Function() installId;
  final Future<String?> Function(String key) readSecret;
  final Future<void> Function(String key, String value) writeSecret;
  final Future<void> Function(String key) deleteSecret;
  final Future<void> Function(bool on) keepScreenOn;
  final Future<void> Function() askNotifications;
  final String Function() newCode;
}

final djiRelayEnvironmentProvider = Provider<DjiRelayEnvironment>((ref) {
  return DjiRelayEnvironment(
    advertise: (name, port, attributes) => bonsoirAdvertise(name, port, attributes, type: pairingServiceType),
    browse: (until) => bonsoirBrowse(pairingServiceType, until),
    lookup: lookupIPv4,
    localAddresses: djiRelayLocalAddresses,
    deviceName: phoneShareDeviceName,
    installId: () => phoneShareInstallId(ref.read(storeServiceProvider)),
    // Kept on this device only: a code is never carried to another device by a backup
    readSecret: (key) => ref.read(secureStorageServiceProvider).read(key),
    writeSecret: (key, value) => ref.read(secureStorageServiceProvider).write(key, value, deviceOnly: true),
    deleteSecret: (key) => ref.read(secureStorageServiceProvider).delete(key, deviceOnly: true),
    keepScreenOn: (on) => on ? WakelockPlus.enable() : WakelockPlus.disable(),
    askNotifications: () async {
      await ref.read(notificationPermissionProvider.notifier).requestNotificationPermission();
    },
  );
});

class DjiRelayState {
  const DjiRelayState({
    this.sending = false,
    this.starting = false,
    this.code,
    this.port,
    this.addresses = const [],
    this.keepScreenOn = true,
    this.startFailed = false,
    this.announced = false,
    this.phones = const [],
    this.rememberedCodes = const {},
    this.connectError,
    this.target,
    this.flightViewFailed = false,
  });

  /// "Send to a headset" is on
  final bool sending;
  final bool starting;

  /// The code of this phone, shown in two groups of five
  final String? code;
  final int? port;
  final List<DjiRelayAddress> addresses;

  /// "Keep this screen on while sending", on by default
  final bool keepScreenOn;
  final bool startFailed;

  /// The announcement runs: a headset can find the phone without a typed address
  final bool announced;

  /// The sending phones found on the network
  final List<DjiRelayPhone> phones;

  /// The codes remembered for the phones found, by install id
  final Map<String, String> rememberedCodes;

  /// Why the last connect was refused here: badCode, badHost, busy or sending
  final String? connectError;

  /// The phone this device receives from, or tries to
  final DjiRelayPhone? target;
  final bool flightViewFailed;

  DjiRelayState copyWith({
    bool? sending,
    bool? starting,
    String? code,
    int? port,
    List<DjiRelayAddress>? addresses,
    bool? keepScreenOn,
    bool? startFailed,
    bool? announced,
    List<DjiRelayPhone>? phones,
    Map<String, String>? rememberedCodes,
    String? connectError,
    DjiRelayPhone? target,
    bool? flightViewFailed,
    bool clearPort = false,
    bool clearConnectError = false,
    bool clearTarget = false,
  }) => DjiRelayState(
    sending: sending ?? this.sending,
    starting: starting ?? this.starting,
    code: code ?? this.code,
    port: clearPort ? null : (port ?? this.port),
    addresses: addresses ?? this.addresses,
    keepScreenOn: keepScreenOn ?? this.keepScreenOn,
    startFailed: startFailed ?? this.startFailed,
    announced: announced ?? this.announced,
    phones: phones ?? this.phones,
    rememberedCodes: rememberedCodes ?? this.rememberedCodes,
    connectError: clearConnectError ? null : (connectError ?? this.connectError),
    target: clearTarget ? null : (target ?? this.target),
    flightViewFailed: flightViewFailed ?? this.flightViewFailed,
  );
}

class DjiRelayNotifier extends Notifier<DjiRelayState> {
  DjiRelayEnvironment get _environment => ref.read(djiRelayEnvironmentProvider);
  DjiLinkApi get _api => ref.read(djiLinkApiProvider);

  Future<void> Function()? _stopAnnouncing;
  Completer<void>? _browsing;
  StreamSubscription<MdnsService>? _discovery;
  bool _pageVisible = false;
  int _headsets = -1;
  bool _fallbackTried = false;

  /// Bumped by every start and stop, so that a start overtaken by a stop undoes what it made
  int _generation = 0;

  @override
  DjiRelayState build() => const DjiRelayState();

  /// The page of the phone opened: the code it would send with, read from the secure storage
  Future<void> loadCode() async {
    try {
      final stored = await _environment.readSecret(djiRelayCodeKey);
      if (stored != null && normalizePairingCode(stored) == stored) {
        state = state.copyWith(code: stored);
      }
    } catch (error) {
      _log.fine('No relay code: $error');
    }
  }

  Future<String> _codeToSend() async {
    final current = state.code;
    if (current != null) {
      return current;
    }
    final made = _environment.newCode();
    try {
      await _environment.writeSecret(djiRelayCodeKey, made);
    } catch (error) {
      _log.fine('The relay code was not kept: $error');
    }
    state = state.copyWith(code: made);
    return made;
  }

  /// Whether a start or a connect may go on after an await: the page that asked for it is still shown. A page that
  /// closed meanwhile has stopped the link already, and nothing would stop a relay or a receiver started after it.
  bool _stillWanted(int generation) => generation == _generation && _pageVisible;

  /// "Send to a headset" on: the relay listens, the service keeps it alive, the phone is announced
  Future<void> startSending() async {
    if (state.sending || state.starting) {
      return;
    }
    final generation = ++_generation;
    state = state.copyWith(starting: true, startFailed: false);
    // The notification of the service, without waiting for the answer: the relay works without it
    unawaited(_environment.askNotifications().catchError((Object error) => _log.fine('Notifications: $error')));
    final code = await _codeToSend();
    if (!_stillWanted(generation)) {
      _abandonStart(generation);
      return;
    }
    final deviceName = await _environment.deviceName();
    if (!_stillWanted(generation)) {
      _abandonStart(generation);
      return;
    }
    String? installId;
    try {
      installId = await _environment.installId();
    } catch (error) {
      _log.fine('No install id: $error');
    }
    if (!_stillWanted(generation)) {
      _abandonStart(generation);
      return;
    }
    final t = StaticTranslations.instance;
    int port;
    try {
      port = await _api.startRelay(
        DjiRelayStart(
          code: code,
          phoneName: deviceName,
          phoneId: installId,
          notificationTitle: t.dji_link_relay_notification_title,
          notificationText: t.dji_link_relay_notification_text(count: 0),
          stopLabel: t.dji_link_relay_notification_stop,
          channelName: t.dji_link_relay_channel,
        ),
      );
    } catch (error) {
      _log.warning('The relay did not start: $error');
      port = 0;
    }
    if (generation != _generation) {
      return;
    }
    if (port <= 0) {
      state = state.copyWith(starting: false, sending: false, startFailed: true);
      return;
    }
    _headsets = 0;
    state = state.copyWith(starting: false, sending: true, port: port);
    final addresses = await _environment.localAddresses();
    if (generation != _generation) {
      return;
    }
    state = state.copyWith(addresses: addresses);
    await _applyScreen();
    if (installId != null) {
      try {
        final stop = await _environment.advertise(
          phoneShareServiceName(deviceName),
          port,
          djiRelayAttributes(installId),
        );
        if (generation != _generation) {
          await stop();
          return;
        }
        _stopAnnouncing = stop;
        state = state.copyWith(announced: true);
      } catch (error) {
        // No multicast here: a headset types the address the page shows
        _log.info('The phone could not be announced: $error');
      }
    }
  }

  /// A start the page left before the relay was asked for: nothing was started, the switch is off again
  void _abandonStart(int generation) {
    _log.info('The page closed before the relay started: not started');
    if (generation == _generation) {
      state = state.copyWith(starting: false, sending: false);
    }
  }

  /// "Send to a headset" off: a bye to every headset, the announcement and the service stop
  Future<void> stopSending() async {
    _generation += 1;
    try {
      await _api.stopRelay();
    } catch (error) {
      _log.fine('The relay did not stop cleanly: $error');
    }
    await _afterStop();
  }

  /// Stop in the notification: the native side stopped the relay already
  Future<void> onStopRequested() async {
    _generation += 1;
    await _afterStop();
  }

  Future<void> _afterStop() async {
    final stop = _stopAnnouncing;
    _stopAnnouncing = null;
    if (stop != null) {
      try {
        await stop();
      } catch (error) {
        _log.fine('The announcement did not stop cleanly: $error');
      }
    }
    _headsets = -1;
    state = state.copyWith(sending: false, starting: false, announced: false, clearPort: true);
    await _applyScreen();
  }

  /// "New code": every headset is told and must prove the new one
  Future<void> newCode() async {
    final made = _environment.newCode();
    try {
      await _environment.writeSecret(djiRelayCodeKey, made);
    } catch (error) {
      _log.fine('The relay code was not kept: $error');
    }
    state = state.copyWith(code: made);
    if (state.sending) {
      try {
        await _api.setRelayCode(made);
      } catch (error) {
        _log.fine('The new code did not reach the relay: $error');
      }
    }
  }

  Future<void> setKeepScreenOn(bool on) async {
    state = state.copyWith(keepScreenOn: on);
    await _applyScreen();
  }

  /// The page is in front or not: the screen is kept on only while it is and sends
  Future<void> setPageVisible(bool visible) async {
    _pageVisible = visible;
    await _applyScreen();
  }

  Future<void> _applyScreen() async {
    try {
      await _environment.keepScreenOn(state.sending && state.keepScreenOn && _pageVisible);
    } catch (error) {
      _log.fine('The screen setting did not apply: $error');
    }
  }

  // Receiving

  /// Looks for sending phones for as long as the receive section shows
  void startBrowsing() {
    if (_browsing != null) {
      return;
    }
    final until = Completer<void>();
    _browsing = until;
    state = state.copyWith(phones: const []);
    _discovery = _environment
        .browse(until.future)
        .listen((service) => unawaited(_found(service)), onError: (Object error) => _log.fine('Browse: $error'));
  }

  void stopBrowsing() {
    final until = _browsing;
    _browsing = null;
    if (until != null && !until.isCompleted) {
      until.complete();
    }
    unawaited(_discovery?.cancel());
    _discovery = null;
  }

  Future<void> _found(MdnsService service) async {
    final phone = await djiRelayPhoneOf(service, _environment.lookup);
    if (phone == null || _browsing == null) {
      return;
    }
    if (state.phones.any((other) => other.address == phone.address && other.id == phone.id)) {
      return;
    }
    final phones = [...state.phones.where((other) => other.id == null || other.id != phone.id), phone];
    state = state.copyWith(phones: phones);
    final id = phone.id;
    if (id != null && !state.rememberedCodes.containsKey(id)) {
      try {
        final code = await _environment.readSecret(djiRelayRememberedCodeKey(id));
        if (code != null && normalizePairingCode(code) == code) {
          state = state.copyWith(rememberedCodes: {...state.rememberedCodes, id: code});
        }
      } catch (error) {
        _log.fine('No remembered code: $error');
      }
    }
  }

  /// Connects to [phone] with the code as typed; the code is remembered for the phone's id once the connect started
  Future<void> connect(DjiRelayPhone phone, String typedCode) async {
    final code = normalizePairingCode(typedCode);
    if (code == null) {
      state = state.copyWith(connectError: 'badCode');
      return;
    }
    String? outcome;
    try {
      final headsetName = await _environment.deviceName();
      if (!_pageVisible) {
        // The page closed while the name was read: a receiver that no page shows is never started
        _log.info('The page closed before the receiver started: not started');
        return;
      }
      outcome = await _api.connectRelay(phone.host, phone.port, code, phone.id, headsetName);
    } catch (error) {
      _log.warning('The receiver did not start: $error');
      outcome = 'badHost';
    }
    if (outcome != null) {
      state = state.copyWith(connectError: outcome);
      return;
    }
    _fallbackTried = false;
    state = state.copyWith(target: phone, clearConnectError: true, flightViewFailed: false);
    final id = phone.id;
    if (id != null) {
      state = state.copyWith(rememberedCodes: {...state.rememberedCodes, id: code});
      try {
        await _environment.writeSecret(djiRelayRememberedCodeKey(id), code);
      } catch (error) {
        _log.fine('The code was not remembered: $error');
      }
    }
  }

  Future<void> disconnect() async {
    try {
      await _api.disconnectRelay();
    } catch (error) {
      _log.fine('The receiver did not stop cleanly: $error');
    }
    state = state.copyWith(clearTarget: true, clearConnectError: true);
  }

  /// The flight view of the Quest, with the texts of its panel
  Future<void> openFlightView(Map<String, String> labels) async {
    bool opened;
    try {
      opened = await _api.openFlightView(labels);
    } catch (error) {
      _log.warning('The flight view did not open: $error');
      opened = false;
    }
    state = state.copyWith(flightViewFailed: !opened);
  }

  /// Every snapshot of the link: the notification follows the number of headsets; a receiver that lost its phone
  /// three times in a row tries the address the announcement now gives for the same phone; a refused code is forgotten
  void onSnapshot(DjiLinkSnapshot snapshot) {
    final sending = snapshot.relaySending;
    if (state.sending && sending != null && sending.on && sending.headsets.length != _headsets) {
      _headsets = sending.headsets.length;
      final text = StaticTranslations.instance.dji_link_relay_notification_text(count: _headsets);
      unawaited(_api.updateRelayNotification(text).catchError((Object error) => _log.fine('Notification: $error')));
    }
    final receiving = snapshot.relayReceiving;
    final target = state.target;
    if (receiving == null || target == null) {
      return;
    }
    final id = target.id;
    if (receiving.state == DjiRelayReceiveState.wrongCode && id != null && state.rememberedCodes.containsKey(id)) {
      final codes = {...state.rememberedCodes}..remove(id);
      state = state.copyWith(rememberedCodes: codes);
      unawaited(_environment.deleteSecret(djiRelayRememberedCodeKey(id)).catchError((Object _) {}));
    }
    if (receiving.state == DjiRelayReceiveState.lost && receiving.failures >= 3 && id != null && !_fallbackTried) {
      final moved = state.phones.where((phone) => phone.id == id && phone.address != target.address).firstOrNull;
      final code = state.rememberedCodes[id];
      if (moved != null && code != null) {
        _fallbackTried = true;
        _log.info('The phone ${target.name} moved to ${moved.address}');
        unawaited(connect(moved, code));
      }
    }
  }
}

/// Kept for the life of the app: the relay goes on while the pilot leaves the page
final djiRelayProvider = NotifierProvider<DjiRelayNotifier, DjiRelayState>(
  DjiRelayNotifier.new,
  dependencies: [djiRelayEnvironmentProvider, djiLinkApiProvider],
);
