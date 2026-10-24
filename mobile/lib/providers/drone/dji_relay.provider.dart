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
// the announcement gives after three failed attempts. The watch page connects by itself, once per opening, to the last
// phone it received from when that phone is announced and its code remembered.
//
// A TV (p2/design-tv-2026-10-24.md, 2.3 to 2.6): it makes its own code once, in the pairing alphabet, kept on this
// device only, and shows it with a QR code; the pilot adds it on the phone, whose relay then welcomes a proof of that
// code as well as of its own. The TV tries its own code on the listed phones it has no code for, one try every 10 s
// while its page asks for it, 30 at most per opening: six wrong proofs a minute stay under the phone's limit of ten.
// The phone keeps the TVs it added (eight at most), on this device only, names each from its first connection, and
// removes them one by one. The wire does not change: a TV proves one code as a headset does, and sends a hello, pings
// and a bye only.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

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

/// The install id of the last phone a headset received from, for the connection the watch page makes by itself
const djiRelayLastPhoneKey = 'dji_relay_last_phone';

/// This TV's own code in the secure storage: made once, shown with its QR code for a phone to add
const djiWatchOwnCodeKey = 'dji_watch_own_code';

/// The install ids of the phones that welcomed this TV's own code, so that a new code forgets them
const djiWatchOwnCodePhonesKey = 'dji_watch_own_code_phones';

/// The TVs added on this phone, as JSON, in the secure storage
const djiRelayScreensKey = 'dji_relay_tv_codes';

/// A TV tries its own code on a listed phone at most this often while its page asks for it
const djiWatchTryEvery = Duration(seconds: 10);

/// The tries of a TV's own code per opening of its page: five minutes at one try every 10 s
const djiWatchOwnCodeTries = 30;

/// The TVs a phone keeps at most, as its relay does (RelayServer.MAX_SCREEN_CODES)
const djiRelayMaxScreens = 8;

/// A new opaque id for a TV added on this phone: 16 hexadecimal digits
String djiRelayNewScreenId([Random? random]) {
  final source = random ?? Random.secure();
  return List.generate(16, (_) => source.nextInt(16).toRadixString(16)).join();
}

int _nowMs() => DateTime.now().millisecondsSinceEpoch;

/// A TV added on this phone: an opaque id, the code the TV made and showed, when it was added, and its name once it
/// connected
class DjiRelayScreen {
  const DjiRelayScreen({required this.id, required this.code, required this.addedMs, this.name});

  final String id;
  final String code;
  final int addedMs;
  final String? name;

  DjiRelayScreen named(String name) => DjiRelayScreen(id: id, code: code, addedMs: addedMs, name: name);

  Map<String, Object?> toJson() => {'id': id, 'code': code, 'added': addedMs, if (name != null) 'name': name};

  /// Null for an entry that is not one of ours: it is dropped, never shown
  static DjiRelayScreen? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final id = json['id'];
    final code = json['code'];
    final added = json['added'];
    final name = json['name'];
    if (id is! String || id.isEmpty || id.length > 64 || code is! String || added is! int) {
      return null;
    }
    if (normalizePairingCode(code) != code) {
      return null;
    }
    return DjiRelayScreen(id: id, code: code, addedMs: added, name: name is String && name.isNotEmpty ? name : null);
  }
}

/// What "Add a TV" gave
enum DjiRelayAddScreen {
  added,

  /// This TV is in the list already
  already,

  /// Eight TVs already: one must be removed first
  full,

  /// Not a code of the pairing alphabet
  invalid,
}

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
    this.newScreenId = djiRelayNewScreenId,
    this.nowMs = _nowMs,
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

  /// The id of a TV added on this phone
  final String Function() newScreenId;

  /// The clock of the date a TV was added
  final int Function() nowMs;
}

final djiRelayEnvironmentProvider = Provider<DjiRelayEnvironment>((ref) {
  return DjiRelayEnvironment(
    advertise: (name, port, attributes) => bonsoirAdvertise(name, port, attributes, type: pairingServiceType),
    // With the phones that stop announcing themselves: a list left open for an hour drops them
    browse: (until) => bonsoirBrowse(pairingServiceType, until, lost: true),
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
    this.stoppedRemotely = false,
    this.phoneName,
    this.ownCode,
    this.screens = const [],
    this.usingOwnCode = false,
    this.ownCodeRefused = false,
    this.triesStopped = false,
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

  /// Sending stopped from the notification, or by itself after 10 minutes with nothing to send, since the last start
  final bool stoppedRemotely;

  /// The name of this phone as the headsets list it, once sending started
  final String? phoneName;

  /// A TV's own code, shown with its QR code for a phone to add; null on a headset and a phone
  final String? ownCode;

  /// The TVs added on this phone, each with its own code
  final List<DjiRelayScreen> screens;

  /// The connection under way proves this TV's own code, not a code typed for that phone
  final bool usingOwnCode;

  /// The phone refused this TV's own code: it does not know this TV yet
  final bool ownCodeRefused;

  /// The tries of the TV's own code reached [djiWatchOwnCodeTries] in this opening of the page
  final bool triesStopped;

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
    bool? stoppedRemotely,
    String? phoneName,
    String? ownCode,
    List<DjiRelayScreen>? screens,
    bool? usingOwnCode,
    bool? ownCodeRefused,
    bool? triesStopped,
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
    stoppedRemotely: stoppedRemotely ?? this.stoppedRemotely,
    phoneName: phoneName ?? this.phoneName,
    ownCode: ownCode ?? this.ownCode,
    screens: screens ?? this.screens,
    usingOwnCode: usingOwnCode ?? this.usingOwnCode,
    ownCodeRefused: ownCodeRefused ?? this.ownCodeRefused,
    triesStopped: triesStopped ?? this.triesStopped,
  );

  /// Whether a TV shows its code card: it has a code, and the phone refused it, or a try of it is under way and not
  /// welcomed yet, or phones are listed and none has a code here. Not while a picture comes, which the page checks.
  bool get ownCodeCardShows {
    final own = ownCode;
    if (own == null) {
      return false;
    }
    if (ownCodeRefused) {
      return true;
    }
    final target = this.target;
    if (target != null) {
      return usingOwnCode && (target.id == null || rememberedCodes[target.id] != own);
    }
    if (phones.isEmpty) {
      return false;
    }
    return phones.every((phone) => phone.id == null || !rememberedCodes.containsKey(phone.id));
  }
}

class DjiRelayNotifier extends Notifier<DjiRelayState> {
  DjiRelayEnvironment get _environment => ref.read(djiRelayEnvironmentProvider);
  DjiLinkApi get _api => ref.read(djiLinkApiProvider);

  Future<void> Function()? _stopAnnouncing;
  Completer<void>? _browsing;
  StreamSubscription<MdnsService>? _discovery;
  bool _pageVisible = false;

  /// The live screen of the phone is in front: the screen stays on whatever the link does
  bool _liveShown = false;
  int _headsets = -1;
  bool _fallbackTried = false;

  /// The phone the watch page connects to by itself once it is announced; null once tried, after Stop watching, or
  /// when the page closed
  String? _autoConnectId;

  /// The last phone this device received from, as kept in the secure storage
  String? _lastPhoneId;

  /// Bumped by every start and stop, so that a start overtaken by a stop undoes what it made
  int _generation = 0;

  /// The tries of a TV's own code: the timer while the page asks for them, the tries made in this opening, and held
  /// after Stop watching until the page opens again or a phone is chosen
  Timer? _tries;
  int _triesMade = 0;
  bool _triesHeld = false;

  /// The state of the receiver as the last snapshot said it; a try is made only while no receiver works
  DjiRelayReceiveState? _receiveState;

  bool _screensLoaded = false;

  @override
  DjiRelayState build() {
    ref.onDispose(() => _tries?.cancel());
    return const DjiRelayState();
  }

  /// The page of the phone opened: the code it would send with, read from the secure storage, and the TVs added
  Future<void> loadCode() async {
    try {
      final stored = await _environment.readSecret(djiRelayCodeKey);
      if (stored != null && normalizePairingCode(stored) == stored) {
        state = state.copyWith(code: stored);
      }
    } catch (error) {
      _log.fine('No relay code: $error');
    }
    await loadScreens();
  }

  // The TVs added on this phone

  /// The TVs added on this phone, read once from the secure storage
  Future<void> loadScreens() async {
    if (_screensLoaded) {
      return;
    }
    _screensLoaded = true;
    try {
      final stored = await _environment.readSecret(djiRelayScreensKey);
      if (stored == null) {
        return;
      }
      final decoded = jsonDecode(stored);
      if (decoded is! List) {
        return;
      }
      final screens = [for (final entry in decoded) ?DjiRelayScreen.fromJson(entry)];
      state = state.copyWith(screens: screens.take(djiRelayMaxScreens).toList());
    } catch (error) {
      _log.fine('No TV list: $error');
    }
  }

  /// "Add a TV": the code its Drone page shows, scanned or typed; the relay welcomes it at once when it sends
  Future<DjiRelayAddScreen> addScreen(String typed) async {
    await loadScreens();
    final code = normalizePairingCode(typed);
    if (code == null) {
      return DjiRelayAddScreen.invalid;
    }
    if (state.screens.any((screen) => screen.code == code)) {
      return DjiRelayAddScreen.already;
    }
    if (state.screens.length >= djiRelayMaxScreens) {
      return DjiRelayAddScreen.full;
    }
    final screen = DjiRelayScreen(id: _environment.newScreenId(), code: code, addedMs: _environment.nowMs());
    state = state.copyWith(screens: [...state.screens, screen]);
    _log.info('A TV was added: ${state.screens.length} in the list');
    await _saveScreens();
    await _pushScreens();
    return DjiRelayAddScreen.added;
  }

  /// "Remove": the TV is told to leave at once, and its code is refused from now on
  Future<void> removeScreen(String id) async {
    final kept = state.screens.where((screen) => screen.id != id).toList();
    if (kept.length == state.screens.length) {
      return;
    }
    state = state.copyWith(screens: kept);
    await _saveScreens();
    await _pushScreens();
  }

  List<DjiRelayScreenCode> _screenCodes() => [
    for (final screen in state.screens) DjiRelayScreenCode(id: screen.id, code: screen.code),
  ];

  Future<void> _saveScreens() async {
    try {
      await _environment.writeSecret(
        djiRelayScreensKey,
        jsonEncode([for (final screen in state.screens) screen.toJson()]),
      );
    } catch (error) {
      _log.fine('The TV list was not kept: $error');
    }
  }

  /// The relay that sends takes the new list: a TV removed leaves, a TV added is welcomed
  Future<void> _pushScreens() async {
    if (!state.sending) {
      return;
    }
    try {
      await _api.setRelayScreenCodes(_screenCodes());
    } catch (error) {
      _log.fine('The TV list did not reach the relay: $error');
    }
  }

  /// Each TV takes the name it gave in its first connection
  void _nameScreens(List<DjiRelayHeadsetRow> rows) {
    final names = <String, String>{};
    for (final row in rows) {
      final id = row.screenCodeId;
      final name = cleanPairingText(row.name ?? '');
      if (id != null && name.isNotEmpty) {
        names[id] = name;
      }
    }
    if (names.isEmpty || !state.screens.any((screen) => screen.name == null && names.containsKey(screen.id))) {
      return;
    }
    state = state.copyWith(
      screens: [
        for (final screen in state.screens)
          if (screen.name == null && names[screen.id] != null) screen.named(names[screen.id]!) else screen,
      ],
    );
    unawaited(_saveScreens());
  }

  // A TV's own code

  /// The TV's page opened: its own code, made once and kept on this device only, never logged
  Future<void> loadOwnCode() async {
    if (state.ownCode != null) {
      return;
    }
    String? stored;
    try {
      stored = await _environment.readSecret(djiWatchOwnCodeKey);
    } catch (error) {
      _log.fine('No code of this TV: $error');
    }
    if (stored != null && normalizePairingCode(stored) == stored) {
      state = state.copyWith(ownCode: stored);
      return;
    }
    final made = _environment.newCode();
    try {
      await _environment.writeSecret(djiWatchOwnCodeKey, made);
    } catch (error) {
      _log.fine('The code of this TV was not kept: $error');
    }
    state = state.copyWith(ownCode: made);
  }

  /// "New code for this TV": every phone that knew the old one is forgotten here, and must add the TV again
  Future<void> newOwnCode() async {
    final old = state.ownCode;
    final made = _environment.newCode();
    try {
      await _environment.writeSecret(djiWatchOwnCodeKey, made);
    } catch (error) {
      _log.fine('The code of this TV was not kept: $error');
    }
    final forgotten = [
      for (final entry in state.rememberedCodes.entries)
        if (entry.value == old) entry.key,
    ];
    final ids = {...forgotten, ...await _ownCodePhones()};
    for (final id in ids) {
      try {
        final remembered = await _environment.readSecret(djiRelayRememberedCodeKey(id));
        if (remembered == null || remembered == old) {
          await _environment.deleteSecret(djiRelayRememberedCodeKey(id));
        }
      } catch (error) {
        _log.fine('A code was not forgotten: $error');
      }
    }
    try {
      await _environment.deleteSecret(djiWatchOwnCodePhonesKey);
    } catch (error) {
      _log.fine('The list of phones was not forgotten: $error');
    }
    final codes = {...state.rememberedCodes}..removeWhere((id, code) => code == old);
    state = state.copyWith(ownCode: made, rememberedCodes: codes, ownCodeRefused: false);
  }

  Future<Set<String>> _ownCodePhones() async {
    try {
      final stored = await _environment.readSecret(djiWatchOwnCodePhonesKey);
      final decoded = stored == null ? null : jsonDecode(stored);
      return decoded is List ? {...decoded.whereType<String>()} : <String>{};
    } catch (error) {
      _log.fine('No list of phones: $error');
      return <String>{};
    }
  }

  /// A phone welcomed this TV's own code: remembered for it, as a typed code is, and listed for a new code to forget
  Future<void> _rememberOwnCode(String id, String code) async {
    state = state.copyWith(rememberedCodes: {...state.rememberedCodes, id: code});
    try {
      await _environment.writeSecret(djiRelayRememberedCodeKey(id), code);
      final phones = {...await _ownCodePhones(), id};
      await _environment.writeSecret(djiWatchOwnCodePhonesKey, jsonEncode(phones.toList()));
    } catch (error) {
      _log.fine('The code was not remembered: $error');
    }
  }

  /// The TV's page opened: its tries start again from zero
  void beginOwnCodeTries() {
    _triesMade = 0;
    _triesHeld = false;
    if (state.triesStopped) {
      state = state.copyWith(triesStopped: false);
    }
  }

  /// The TV's page asks for the tries of its own code while it is in front, or stops them
  void setOwnCodeTries(bool on) {
    if (!on) {
      _tries?.cancel();
      _tries = null;
      return;
    }
    if (_tries != null) {
      return;
    }
    _tries = Timer.periodic(djiWatchTryEvery, (_) => _tryOwnCode());
    _tryOwnCode();
  }

  /// A phone chosen on the TV: the tries go on, counted from zero, even after Stop watching or after they stopped
  void chosenOnTv() => beginOwnCodeTries();

  /// One try of the TV's own code on the next listed phone it has no code for, while no receiver works
  void _tryOwnCode() {
    final own = state.ownCode;
    if (_tries == null || own == null || !_pageVisible || _triesHeld || state.triesStopped) {
      return;
    }
    final working = switch (_receiveState) {
      null ||
      DjiRelayReceiveState.idle ||
      DjiRelayReceiveState.wrongCode ||
      DjiRelayReceiveState.otherVersion ||
      DjiRelayReceiveState.phoneUnproven => false,
      _ => true,
    };
    if (working) {
      return;
    }
    final candidates = state.phones
        .where((phone) => phone.id == null || !state.rememberedCodes.containsKey(phone.id))
        .toList();
    if (candidates.isEmpty) {
      return;
    }
    if (_triesMade >= djiWatchOwnCodeTries) {
      _log.info('This TV stopped trying its code after $_triesMade tries');
      state = state.copyWith(triesStopped: true);
      return;
    }
    final phone = candidates[_triesMade % candidates.length];
    _triesMade += 1;
    unawaited(connect(phone, own));
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
    state = state.copyWith(starting: true, startFailed: false, stoppedRemotely: false);
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
    state = state.copyWith(phoneName: deviceName);
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
    await loadScreens();
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
          screenCodes: _screenCodes(),
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

  /// Stop in the notification, or the idle stop: the native side stopped the relay already
  Future<void> onStopRequested() async {
    _generation += 1;
    state = state.copyWith(stoppedRemotely: true);
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

  /// The live screen of the phone is in front or not: while it is, the screen stays on in every stage
  Future<void> setLiveScreenShown(bool shown) async {
    _liveShown = shown;
    await _applyScreen();
  }

  /// The one place that decides the wake lock, so that the live screen and the sending rule never fight over it
  Future<void> _applyScreen() async {
    try {
      await _environment.keepScreenOn(_liveShown || (state.sending && state.keepScreenOn && _pageVisible));
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
    if (service.lost) {
      _lost(service);
      return;
    }
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
    _autoConnect(phone);
    // A TV tries its own code at once on the first phone it can: the pilot may have added it already
    if (_tries != null && _triesMade == 0) {
      _tryOwnCode();
    }
  }

  /// A phone that stopped announcing itself leaves the list, but the one this device receives from or tries to
  void _lost(MdnsService service) {
    final name = cleanPairingText(service.name);
    final target = state.target?.address;
    final kept = state.phones.where((phone) => phone.name != name || phone.address == target).toList();
    if (kept.length != state.phones.length) {
      state = state.copyWith(phones: kept);
    }
  }

  /// The watch page opened: it connects by itself to the last phone it received from, once, as soon as that phone is
  /// announced with its code remembered
  Future<void> armAutoConnect() async {
    String? last;
    try {
      last = await _environment.readSecret(djiRelayLastPhoneKey);
    } catch (error) {
      _log.fine('No last phone: $error');
    }
    _lastPhoneId = last;
    _autoConnectId = last;
    for (final phone in state.phones) {
      _autoConnect(phone);
    }
  }

  /// The watch page closed: no connection by itself any more
  void disarmAutoConnect() {
    _autoConnectId = null;
  }

  void _autoConnect(DjiRelayPhone phone) {
    final id = phone.id;
    final code = id == null ? null : state.rememberedCodes[id];
    if (id == null || id != _autoConnectId || code == null || state.target != null || !_pageVisible) {
      return;
    }
    _autoConnectId = null;
    _log.info('Connecting by itself to ${phone.name}, the last phone watched');
    unawaited(connect(phone, code));
  }

  /// Connects to [phone] with the code as typed; the code is remembered for the phone's id once the connect started.
  /// A TV's own code is remembered only once the phone welcomed it: a refusal then leaves nothing to forget.
  Future<void> connect(DjiRelayPhone phone, String typedCode) async {
    final code = normalizePairingCode(typedCode);
    if (code == null) {
      state = state.copyWith(connectError: 'badCode');
      return;
    }
    final own = code == state.ownCode;
    // A receiver is being started: no try of a TV's own code meanwhile
    _receiveState = DjiRelayReceiveState.connecting;
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
      _receiveState = null;
      state = state.copyWith(connectError: outcome);
      return;
    }
    _fallbackTried = false;
    state = state.copyWith(
      target: phone,
      clearConnectError: true,
      flightViewFailed: false,
      usingOwnCode: own,
      ownCodeRefused: own && state.ownCodeRefused,
    );
    final id = phone.id;
    if (id != null && !own) {
      state = state.copyWith(rememberedCodes: {...state.rememberedCodes, id: code});
      try {
        await _environment.writeSecret(djiRelayRememberedCodeKey(id), code);
      } catch (error) {
        _log.fine('The code was not remembered: $error');
      }
    }
  }

  /// "Stop watching": the receiver stops, and the page does not connect by itself again until it is opened again, nor
  /// does a TV try its code before a phone is chosen
  Future<void> disconnect() async {
    _autoConnectId = null;
    _triesHeld = true;
    await _stopReceiving();
  }

  /// The app went to the background with the watch page in front (a TV's Home): receiving and browsing stop, and
  /// coming back connects by itself again
  Future<void> pauseWatching() async {
    _autoConnectId = null;
    setOwnCodeTries(false);
    stopBrowsing();
    await _stopReceiving();
  }

  /// Back in front: browsing again, the last phone connected by itself, the tries going on
  Future<void> resumeWatching({required bool tries}) async {
    startBrowsing();
    await armAutoConnect();
    if (tries) {
      setOwnCodeTries(true);
    }
  }

  /// A TV's page opened: the receiver stopped with the link when the page last closed, so no phone is watched here
  void forgetTarget() {
    _receiveState = null;
    if (state.target != null || state.usingOwnCode || state.ownCodeRefused) {
      state = state.copyWith(clearTarget: true, usingOwnCode: false, ownCodeRefused: false);
    }
  }

  Future<void> _stopReceiving() async {
    try {
      await _api.disconnectRelay();
    } catch (error) {
      _log.fine('The receiver did not stop cleanly: $error');
    }
    _receiveState = DjiRelayReceiveState.idle;
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
  /// three times in a row tries the address the announcement now gives for the same phone; a refused code is forgotten;
  /// a TV's own code welcomed is remembered, refused is said; a TV added takes the name it gave
  void onSnapshot(DjiLinkSnapshot snapshot) {
    final sending = snapshot.relaySending;
    if (state.sending && sending != null && sending.on && sending.headsets.length != _headsets) {
      _headsets = sending.headsets.length;
      final text = StaticTranslations.instance.dji_link_relay_notification_text(count: _headsets);
      unawaited(_api.updateRelayNotification(text).catchError((Object error) => _log.fine('Notification: $error')));
    }
    if (sending != null && state.screens.isNotEmpty) {
      _nameScreens(sending.headsets);
    }
    final receiving = snapshot.relayReceiving;
    _receiveState = receiving?.state;
    final target = state.target;
    if (receiving == null || target == null) {
      return;
    }
    final id = target.id;
    if (receiving.state == DjiRelayReceiveState.receiving) {
      if (state.ownCodeRefused) {
        state = state.copyWith(ownCodeRefused: false);
      }
      final own = state.ownCode;
      if (state.usingOwnCode && own != null && id != null && state.rememberedCodes[id] != own) {
        unawaited(_rememberOwnCode(id, own));
      }
    }
    if (receiving.state == DjiRelayReceiveState.wrongCode && state.usingOwnCode && !state.ownCodeRefused) {
      state = state.copyWith(ownCodeRefused: true);
    }
    if (receiving.state == DjiRelayReceiveState.receiving && id != null && id != _lastPhoneId) {
      _lastPhoneId = id;
      unawaited(
        _environment
            .writeSecret(djiRelayLastPhoneKey, id)
            .catchError((Object error) => _log.fine('The last phone was not kept: $error')),
      );
    }
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
