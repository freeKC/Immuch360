// "Share this phone on the network": the switch of the page, and everything it runs while on. The read-only WebDAV
// server (see PhoneShareServer), its announcement on the network (bonsoir, _webdav._tcp, so that a headset finds it
// under "Found on the network" with the user name filled in), and what keeps it alive: the foreground service and its
// notification on Android, the screen kept awake on iOS.
//
// The share never starts by itself (the switch is not stored: it is off at every start of the app) and stops on the
// switch, from the Stop action of the notification, after an hour without any request, and when the app is closed.
// iOS gives no background time to a server: it pauses while the app is in the background and resumes when it comes
// back, with the same address and credentials.
//
// The credentials are generated once and kept in the secure storage, so that a headset keeps its saved share from one
// session to the next; "New password" replaces the password. The install id (StoreKey.phoneShareId) goes in the TXT
// record, so that a headset finds the phone again when its address changes, and the phone does not list itself.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bonsoir/bonsoir.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/phone_share/phone_gallery_tree.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/network/phone_share_server.dart';
import 'package:immich_mobile/infrastructure/repositories/phone_gallery.repository.dart';
import 'package:immich_mobile/platform/phone_share_api.g.dart';
import 'package:immich_mobile/providers/asset_viewer/local_panorama.provider.dart';
import 'package:immich_mobile/providers/gallery_permission.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/permission.provider.dart';
import 'package:immich_mobile/services/secure_storage.service.dart';
import 'package:logging/logging.dart';

final _log = Logger('PhoneShare');

/// The keys of the credentials in the secure storage
const phoneShareUsernameKey = 'phone_share_username';
const phoneSharePasswordKey = 'phone_share_password';

/// The DNS-SD type and the TXT record that tell a headset this is a phone share (see MdnsProbe.serverOf)
const phoneShareServiceType = '_webdav._tcp';
const phoneShareAppTag = 'immuch360';

enum PhoneShareStatus {
  off,
  starting,
  on,

  /// iOS, while the app is in the background
  paused,
  error,
}

/// What the page shows of the share
class PhoneShareState {
  const PhoneShareState({
    this.status = PhoneShareStatus.off,
    this.addresses = const [],
    this.port,
    this.serviceName,
    this.username,
    this.password,
    this.clients = 0,
    this.lastFile,
    this.error,
    this.stoppedIdle = false,
  });

  final PhoneShareStatus status;

  /// The IPv4 addresses of the phone on the local network, Wi-Fi and Ethernet first, then its own hotspot
  final List<String> addresses;
  final int? port;

  /// The name the share is announced under
  final String? serviceName;
  final String? username;

  /// As stored, without the space of [displayedPassword]
  final String? password;

  /// The devices that asked for something in the last minute
  final int clients;

  /// The name of the file a client read last
  final String? lastFile;
  final String? error;

  /// Off because nobody used it for an hour
  final bool stoppedIdle;

  /// Whether the switch is on
  bool get isEnabled =>
      status == PhoneShareStatus.starting || status == PhoneShareStatus.on || status == PhoneShareStatus.paused;

  /// The URLs a client can type, one per address
  List<String> get urls => port == null ? const [] : [for (final address in addresses) 'http://$address:$port'];

  String? get address => urls.firstOrNull;

  String? get displayedPassword {
    final current = password;
    return current == null ? null : formatPhoneSharePassword(current);
  }

  PhoneShareState copyWith({
    PhoneShareStatus? status,
    List<String>? addresses,
    int? port,
    String? serviceName,
    String? username,
    String? password,
    int? clients,
    String? lastFile,
    String? error,
    bool? stoppedIdle,
  }) => PhoneShareState(
    status: status ?? this.status,
    addresses: addresses ?? this.addresses,
    port: port ?? this.port,
    serviceName: serviceName ?? this.serviceName,
    username: username ?? this.username,
    password: password ?? this.password,
    clients: clients ?? this.clients,
    lastFile: lastFile ?? this.lastFile,
    error: error ?? this.error,
    stoppedIdle: stoppedIdle ?? this.stoppedIdle,
  );

  @override
  String toString() => 'PhoneShareState($status, $urls, clients: $clients)';
}

/// The user name and the password of the share
class PhoneShareCredentials {
  const PhoneShareCredentials({required this.username, required this.password});

  final String username;
  final String password;
}

/// The symbols of the passwords: no 0, o, 1, l, which read alike; 32 of them, 5 bits each
const _passwordAlphabet = 'abcdefghijkmnpqrstuvwxyz23456789';

/// "phone" and four digits: not a secret, the TXT record tells it
String newPhoneShareUsername([Random? random]) =>
    'phone${(random ?? Random.secure()).nextInt(10000).toString().padLeft(4, '0')}';

/// Eight symbols of [_passwordAlphabet], 40 bits: out of reach of a guess with the limit of ten failures a minute
String newPhoneSharePassword([Random? random]) {
  final source = random ?? Random.secure();
  return String.fromCharCodes(
    List.generate(8, (_) => _passwordAlphabet.codeUnitAt(source.nextInt(_passwordAlphabet.length))),
  );
}

/// [password] in groups of four, easier to read and to type on a headset: "k7m3 x9p2"
String formatPhoneSharePassword(String password) {
  final groups = <String>[];
  for (var start = 0; start < password.length; start += 4) {
    groups.add(password.substring(start, min(start + 4, password.length)));
  }
  return groups.join(' ');
}

/// The id of this install in the TXT record, 16 hexadecimal digits, made on first use (StoreKey.phoneShareId)
Future<String> phoneShareInstallId(StoreService store) async {
  final existing = store.tryGet(StoreKey.phoneShareId);
  if (existing != null && RegExp(r'^[0-9a-f]{16}$').hasMatch(existing)) {
    return existing;
  }
  final random = Random.secure();
  final id = List.generate(8, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  await store.put(StoreKey.phoneShareId, id);
  return id;
}

/// The name the share is announced under: "Immuch360 on" and the name of the device, within the 63 bytes of a
/// DNS-SD instance name
String phoneShareServiceName(String deviceName) {
  var device = deviceName.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
  if (device.isEmpty) {
    device = 'phone';
  }
  var name = 'Immuch360 on $device';
  while (utf8.encode(name).length > 63) {
    name = name.substring(0, name.length - 1);
  }
  // Some resolvers drop a trailing dot
  return name.replaceAll(RegExp(r'[.\s]+$'), '');
}

/// The addresses a client of the local network can reach the phone at, among the IPv4 [addresses] of its interfaces
/// by name: the main Wi-Fi or Ethernet first, then the other Wi-Fi and Ethernet ones, then the hotspot of the phone
/// (ap, swlan, the bridge of an iPhone), then any other private one. Mobile data, VPNs and loopback are left out.
List<String> phoneShareAddressesOf(List<(String, InternetAddress)> addresses) {
  const skipped = [
    'rmnet', 'ccmni', 'pdp', 'tun', 'ppp', 'wg', 'ipsec', 'clat', 'v4-', 'dummy', 'utun', 'docker', 'lo', //
  ];
  int rank(String name) {
    if (const ['wlan0', 'eth0', 'en0'].contains(name)) {
      return 0;
    }
    if (const ['ap', 'swlan', 'softap', 'bridge'].any(name.startsWith)) {
      return 2;
    }
    if (const ['wlan', 'eth', 'en'].any(name.startsWith)) {
      return 1;
    }
    return 3;
  }

  final ranked = <(int, int, String)>[];
  for (final (index, (name, address)) in addresses.indexed) {
    final lowerName = name.toLowerCase();
    if (address.type != InternetAddressType.IPv4 || address.isLoopback || address.isLinkLocal) {
      continue;
    }
    if (skipped.any(lowerName.startsWith) || !isLocalNetworkAddress(address)) {
      continue;
    }
    ranked.add((rank(lowerName), index, address.address));
  }
  ranked.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
  return [
    ...{for (final (_, _, address) in ranked) address},
  ];
}

/// The addresses of this phone on the local network, see [phoneShareAddressesOf]
Future<List<String>> phoneShareLocalAddresses() async {
  try {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    return phoneShareAddressesOf([
      for (final interface in interfaces)
        for (final address in interface.addresses) (interface.name, address),
    ]);
  } catch (error) {
    _log.fine('No network interface: $error');
    return const [];
  }
}

/// The name of the phone: the one of the settings on Android when there is one, else its model; the name iOS gives
/// ("iPhone" from iOS 16 on, without the entitlement for the user's name, which is fine)
Future<String> phoneShareDeviceName() async {
  try {
    final info = DeviceInfoPlugin();
    if (CurrentPlatform.isAndroid) {
      final android = await info.androidInfo;
      return android.name.trim().isNotEmpty ? android.name.trim() : android.model;
    }
    if (CurrentPlatform.isIOS) {
      return (await info.iosInfo).name;
    }
  } catch (error) {
    _log.fine('No device name: $error');
  }
  return 'phone';
}

/// Announces the share with bonsoir; gives what stops the announcement
Future<Future<void> Function()> bonsoirAdvertise(String name, int port, Map<String, String> attributes) async {
  final broadcast = BonsoirBroadcast(
    service: BonsoirService(name: name, type: phoneShareServiceType, port: port, attributes: attributes),
    printLogs: false,
  );
  try {
    await broadcast.ready.timeout(const Duration(seconds: 2));
    await broadcast.start().timeout(const Duration(seconds: 2));
  } catch (_) {
    // A start that timed out may still register the service later: stop it, so that no announcement outlives the
    // share
    if (!broadcast.isStopped) {
      await broadcast.stop().then<void>((_) {}, onError: (Object _) {});
    }
    rethrow;
  }
  return () async {
    if (!broadcast.isStopped) {
      await broadcast.stop();
    }
  };
}

/// The changes of the state of the app, for as long as the stream is listened to
Stream<AppLifecycleState> appLifecycleStates() {
  AppLifecycleListener? listener;
  // Closed by its listener, when it cancels
  // ignore: close_sinks
  late final StreamController<AppLifecycleState> controller;
  controller = StreamController<AppLifecycleState>(
    onListen: () => listener = AppLifecycleListener(onStateChange: controller.add),
    onCancel: () {
      listener?.dispose();
      listener = null;
    },
  );
  return controller.stream;
}

/// The files of the gallery through the platform
class PlatformPhoneShareFiles implements PhoneShareFiles {
  const PlatformPhoneShareFiles(this._api);

  final PhoneShareApi _api;

  @override
  Future<List<PhoneShareFileInfo>> fileInfos(List<String> assetIds) => _api.fileInfos(assetIds);

  @override
  Future<PhoneShareOpenedFile?> openFile(String assetId) => _api.openFile(assetId);
}

/// Announces the share on the network; gives what stops the announcement
typedef PhoneShareAdvertise =
    Future<Future<void> Function()> Function(String name, int port, Map<String, String> attributes);

/// Makes the server of the share with these credentials, listening first on [preferredPort]
typedef PhoneShareServerFactory =
    PhoneShareServer Function({required String username, required String password, required int preferredPort});

/// What the share needs from the device, replaced by fakes in the tests
class PhoneShareEnvironment {
  const PhoneShareEnvironment({
    required this.api,
    required this.createServer,
    required this.advertise,
    required this.localAddresses,
    required this.networkChanges,
    required this.lifecycle,
    required this.deviceName,
    required this.installId,
    required this.setUpEvents,
    required this.isIOS,
    this.clock = DateTime.now,
  });

  final PhoneShareApi api;
  final PhoneShareServerFactory createServer;
  final PhoneShareAdvertise advertise;
  final Future<List<String>> Function() localAddresses;
  final Stream<void> Function() networkChanges;
  final Stream<AppLifecycleState> Function() lifecycle;
  final Future<String> Function() deviceName;
  final Future<String> Function() installId;

  /// Registers (or with null, removes) what hears the Stop action of the notification
  final void Function(PhoneShareEvents? events) setUpEvents;

  /// iOS pauses the share in the background
  final bool isIOS;
  final DateTime Function() clock;
}

final phoneShareEnvironmentProvider = Provider<PhoneShareEnvironment>((ref) {
  final api = PhoneShareApi();
  final files = PlatformPhoneShareFiles(api);
  return PhoneShareEnvironment(
    api: api,
    createServer: ({required username, required password, required preferredPort}) {
      final db = ref.read(driftProvider);
      return PhoneShareServer(
        tree: PhoneGalleryTree(
          source: PhoneGalleryRepository(db, db.localAlbumRepository),
          files: files,
          panoramaIds: () => ref.read(localPanoramaIdsProvider),
        ),
        files: files,
        username: username,
        password: password,
        servedAddresses: phoneShareLocalAddresses,
        preferredPort: preferredPort,
      );
    },
    advertise: bonsoirAdvertise,
    localAddresses: phoneShareLocalAddresses,
    networkChanges: () => Connectivity().onConnectivityChanged.map<void>((_) {}),
    lifecycle: appLifecycleStates,
    deviceName: phoneShareDeviceName,
    installId: () => phoneShareInstallId(ref.read(storeServiceProvider)),
    setUpEvents: (events) => PhoneShareEvents.setUp(events),
    isIOS: CurrentPlatform.isIOS,
  );
});

/// Asks what the share needs before it starts: the photos and videos (the existing permission flow; false when
/// refused), and on Android 13 and later the notifications of the foreground service, without waiting for the answer
/// (the share works without its notification)
final phoneSharePermissionsProvider = Provider<Future<bool> Function()>((ref) {
  return () async {
    final gallery = ref.read(galleryPermissionNotifier.notifier);
    var status = await gallery.getGalleryPermissionStatus();
    if (!status.hasAccess) {
      status = await gallery.requestGalleryPermission();
    }
    if (!status.hasAccess) {
      return false;
    }
    if (CurrentPlatform.isAndroid) {
      unawaited(
        ref
            .read(notificationPermissionProvider.notifier)
            .requestNotificationPermission()
            .then<void>((_) {}, onError: (Object error) => _log.fine('Notification permission: $error')),
      );
    }
    return true;
  };
});

/// See the top of this file
class PhoneShareController extends Notifier<PhoneShareState> {
  /// Without any request for this long, the share stops
  static const idleTimeout = Duration(minutes: 60);

  /// How often the idle time, the clients and the addresses are checked
  static const tick = Duration(minutes: 1);

  /// A client counts as connected for this long after its last request
  static const clientWindow = Duration(minutes: 1);

  late PhoneShareEnvironment _environment;
  PhoneShareCredentials? _credentials;
  String? _installId;
  String? _serviceName;
  int? _lastPort;

  PhoneShareServer? _server;
  Future<void> Function()? _stopAdvertising;
  StreamSubscription<PhoneShareActivity>? _activity;
  StreamSubscription<void>? _network;
  StreamSubscription<AppLifecycleState>? _lifecycle;
  Timer? _ticker;

  /// Since when the server answers: the idle time counts from there when nobody asked anything yet
  DateTime? _onSince;
  final Map<String, DateTime> _seen = {};

  /// Bumped by every start, pause, resume and stop, so that a start overtaken by one of them undoes what it made
  int _generation = 0;

  @override
  PhoneShareState build() {
    _environment = ref.read(phoneShareEnvironmentProvider);
    ref.onDispose(() {
      _generation++;
      _stopWatching();
      unawaited(_bringDown());
    });
    return const PhoneShareState();
  }

  /// Turns the share on; nothing when it is on already
  Future<void> start() async {
    if (state.isEnabled) {
      return;
    }
    final generation = ++_generation;
    state = PhoneShareState(
      status: PhoneShareStatus.starting,
      username: _credentials?.username,
      password: _credentials?.password,
      serviceName: _serviceName,
    );
    // The copies a session left when the app was killed while it shared
    await _releaseTemporaryFiles(generation);
    try {
      final credentials = _credentials ??= await _loadCredentials();
      _installId ??= await _environment.installId();
      _serviceName ??= phoneShareServiceName(await _environment.deviceName());
      if (generation != _generation) {
        return;
      }
      state = state.copyWith(username: credentials.username, password: credentials.password, serviceName: _serviceName);
      _watch();
      await _bringUp(generation);
    } catch (error, stackTrace) {
      if (generation != _generation) {
        return;
      }
      _log.warning('The phone share did not start', error, stackTrace);
      _generation++;
      _stopWatching();
      await _bringDown();
      state = PhoneShareState(
        status: PhoneShareStatus.error,
        error: '$error',
        username: _credentials?.username,
        password: _credentials?.password,
        serviceName: _serviceName,
      );
    }
  }

  /// Turns the share off; [idle] when it stops because nobody used it
  Future<void> stop({bool idle = false}) async {
    if (state.status == PhoneShareStatus.off && !idle) {
      return;
    }
    final generation = ++_generation;
    _stopWatching();
    state = PhoneShareState(
      stoppedIdle: idle,
      username: _credentials?.username,
      password: _credentials?.password,
      serviceName: _serviceName,
    );
    await _bringDown();
    await _releaseTemporaryFiles(generation);
    _log.info(idle ? 'Phone share stopped after an hour without use' : 'Phone share stopped');
  }

  /// A new password, kept for the next sessions; a running share restarts with it
  Future<void> newPassword() async {
    final current = _credentials ?? await _loadCredentials();
    final credentials = PhoneShareCredentials(username: current.username, password: newPhoneSharePassword());
    await _saveCredentials(credentials);
    _credentials = credentials;
    state = state.copyWith(password: credentials.password);
    if (state.status != PhoneShareStatus.on && state.status != PhoneShareStatus.starting) {
      return;
    }
    final generation = ++_generation;
    await _bringDown();
    if (generation != _generation) {
      // Stopped or paused meanwhile: it does not start again
      return;
    }
    state = state.copyWith(status: PhoneShareStatus.starting);
    await _restart(generation);
  }

  /// The state of the app changed: iOS pauses the share in the background; closing the app stops it
  @visibleForTesting
  void onLifecycle(AppLifecycleState lifecycle) {
    switch (lifecycle) {
      case AppLifecycleState.detached:
        unawaited(stop());
      case AppLifecycleState.hidden || AppLifecycleState.paused when _environment.isIOS:
        if (state.status == PhoneShareStatus.on || state.status == PhoneShareStatus.starting) {
          unawaited(_pause());
        }
      case AppLifecycleState.resumed when _environment.isIOS:
        if (state.status == PhoneShareStatus.paused) {
          unawaited(_restart(++_generation));
        }
      default:
        break;
    }
  }

  Future<void> _pause() async {
    final generation = ++_generation;
    state = state.copyWith(status: PhoneShareStatus.paused, clients: 0);
    await _bringDown();
    // iOS may end the app while it is in the background, and stop() would then never delete the copies
    await _releaseTemporaryFiles(generation);
    _log.info('Phone share paused while the app is in the background');
  }

  /// Brings the share up again for [generation], or shows why it could not
  Future<void> _restart(int generation) async {
    try {
      state = state.copyWith(status: PhoneShareStatus.starting);
      await _bringUp(generation);
    } catch (error, stackTrace) {
      if (generation != _generation) {
        return;
      }
      _log.warning('The phone share did not start again', error, stackTrace);
      _generation++;
      _stopWatching();
      await _bringDown();
      state = state.copyWith(status: PhoneShareStatus.error, error: '$error');
    }
  }

  /// Starts the server, its announcement and what keeps it alive, unless [generation] is overtaken meanwhile. What it
  /// makes stays its own until its last check: overtaken, it undoes that and nothing else, since the fields of the
  /// share may belong to a newer start by then.
  Future<void> _bringUp(int generation) async {
    final credentials = _credentials!;
    final server = _environment.createServer(
      username: credentials.username,
      password: credentials.password,
      preferredPort: _lastPort ?? PhoneShareServer.defaultPort,
    );
    final port = await server.start();
    if (generation != _generation) {
      await server.stop();
      return;
    }
    _lastPort = port;

    final List<String> addresses;
    try {
      addresses = await _environment.localAddresses();
    } catch (_) {
      await server.stop();
      rethrow;
    }
    Future<void> Function()? stopAdvertising;
    try {
      stopAdvertising = await _environment.advertise(_serviceName!, port, {
        'path': '/',
        'u': credentials.username,
        'app': phoneShareAppTag,
        'id': _installId!,
        'v': '1',
      });
    } catch (error) {
      // The address can still be typed by hand on the headset
      _log.warning('The phone share is not announced on the network: $error');
    }
    if (generation != _generation) {
      await _stopAnnouncement(stopAdvertising);
      await server.stop();
      return;
    }

    _server = server;
    _stopAdvertising = stopAdvertising;
    _activity = server.activity.listen(_onActivity);
    _onSince = _environment.clock();
    _seen.clear();
    state = state.copyWith(status: PhoneShareStatus.on, port: port, addresses: addresses, clients: 0);
    final t = StaticTranslations.instance;
    try {
      await _environment.api.startKeepAlive(t.phone_share_notification_title, _notificationText(), t.phone_share_stop);
    } catch (error) {
      _log.warning('The phone share runs without its keep-alive: $error');
    }
    _log.info('Phone share on at port $port, ${addresses.length} address(es)');
  }

  /// Stops the server, its announcement and what keeps it alive
  Future<void> _bringDown() async {
    final server = _server;
    _server = null;
    // A subscription to a broadcast stream ends at once: nothing to wait for
    unawaited(_activity?.cancel());
    _activity = null;
    final stopAdvertising = _stopAdvertising;
    _stopAdvertising = null;
    _onSince = null;
    _seen.clear();
    await _stopAnnouncement(stopAdvertising);
    if (server != null) {
      try {
        await _environment.api.stopKeepAlive();
      } catch (error) {
        _log.fine('The keep-alive of the phone share did not stop: $error');
      }
      await server.stop();
    }
  }

  Future<void> _stopAnnouncement(Future<void> Function()? stopAdvertising) async {
    if (stopAdvertising == null) {
      return;
    }
    try {
      await stopAdvertising();
    } catch (error) {
      _log.fine('The announcement of the phone share did not stop: $error');
    }
  }

  /// Deletes the copies the platform made of the files it could not give in place, unless [generation] is overtaken
  /// meanwhile: a share started since may be serving new ones
  Future<void> _releaseTemporaryFiles(int generation) async {
    if (generation != _generation) {
      return;
    }
    try {
      await _environment.api.releaseTemporaryFiles();
    } catch (error) {
      _log.fine('The copies of the phone share were not deleted: $error');
    }
  }

  /// Listens to what may stop or change the share for as long as the switch is on
  void _watch() {
    _cancelWatchers();
    _environment.setUpEvents(_StopEvents(this));
    _lifecycle = _environment.lifecycle().listen(onLifecycle);
    _network = _environment.networkChanges().listen(
      (_) => unawaited(_refreshAddresses()),
      onError: (Object error) => _log.fine('Network changes: $error'),
    );
    _ticker = Timer.periodic(tick, (_) => _onTick());
  }

  void _stopWatching() {
    _cancelWatchers();
    try {
      _environment.setUpEvents(null);
    } catch (error) {
      _log.fine('The Stop action is not removed: $error');
    }
  }

  void _cancelWatchers() {
    _ticker?.cancel();
    _ticker = null;
    unawaited(_lifecycle?.cancel());
    _lifecycle = null;
    unawaited(_network?.cancel());
    _network = null;
  }

  void _onTick() {
    final server = _server;
    final since = _onSince;
    if (state.status != PhoneShareStatus.on || server == null || since == null) {
      return;
    }
    final now = _environment.clock();
    final lastRequest = server.lastRequestAt;
    final lastUse = lastRequest != null && lastRequest.isAfter(since) ? lastRequest : since;
    if (now.difference(lastUse) >= idleTimeout) {
      unawaited(stop(idle: true));
      return;
    }
    final clients = _clientsAt(now);
    if (clients != state.clients) {
      state = state.copyWith(clients: clients);
    }
    unawaited(_refreshAddresses());
  }

  void _onActivity(PhoneShareActivity activity) {
    _seen[activity.client] = activity.at;
    final lastFile = activity.method == 'GET' ? activity.path.substring(activity.path.lastIndexOf('/') + 1) : null;
    final clients = _clientsAt(activity.at);
    if (clients != state.clients || (lastFile != null && lastFile != state.lastFile)) {
      state = state.copyWith(clients: clients, lastFile: lastFile);
    }
  }

  int _clientsAt(DateTime now) {
    _seen.removeWhere((_, at) => now.difference(at) >= clientWindow);
    return _seen.length;
  }

  /// Shows the addresses of now, and puts them in the notification when they changed. With none the server keeps
  /// running: the phone may join a network again.
  Future<void> _refreshAddresses() async {
    if (state.status != PhoneShareStatus.on) {
      return;
    }
    final addresses = await _environment.localAddresses();
    if (state.status != PhoneShareStatus.on || _sameList(addresses, state.addresses)) {
      return;
    }
    state = state.copyWith(addresses: addresses);
    // The server listens on the addresses of the local network only: on the new ones at once
    unawaited(_server?.refreshServedAddresses());
    try {
      await _environment.api.updateKeepAlive(_notificationText());
    } catch (error) {
      _log.fine('The notification of the phone share was not updated: $error');
    }
  }

  String _notificationText() {
    final t = StaticTranslations.instance;
    final address = state.address;
    if (address == null) {
      return t.phone_share_no_network;
    }
    return t.phone_share_notification_text(address: address, user: _credentials?.username ?? '');
  }

  Future<PhoneShareCredentials> _loadCredentials() async {
    final storage = ref.read(secureStorageServiceProvider);
    final username = await storage.read(phoneShareUsernameKey);
    final password = await storage.read(phoneSharePasswordKey);
    if (username != null && username.isNotEmpty && password != null && password.isNotEmpty) {
      return PhoneShareCredentials(username: username, password: password);
    }
    final credentials = PhoneShareCredentials(
      username: username == null || username.isEmpty ? newPhoneShareUsername() : username,
      password: newPhoneSharePassword(),
    );
    await _saveCredentials(credentials);
    return credentials;
  }

  Future<void> _saveCredentials(PhoneShareCredentials credentials) async {
    final storage = ref.read(secureStorageServiceProvider);
    await storage.write(phoneShareUsernameKey, credentials.username);
    await storage.write(phoneSharePasswordKey, credentials.password);
  }

  static bool _sameList(List<String> a, List<String> b) {
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
}

/// The Stop action of the Android notification
class _StopEvents implements PhoneShareEvents {
  _StopEvents(this._controller);

  final PhoneShareController _controller;

  @override
  void stopRequested() => unawaited(_controller.stop());
}

/// The phone share, off at every start of the app; kept for the life of the app
final phoneShareProvider = NotifierProvider<PhoneShareController, PhoneShareState>(PhoneShareController.new);
