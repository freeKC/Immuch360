// "Play on…" of what only the phone has (release 53): the phone's own photos and videos, and the items a linked screen
// cannot reach with its own access (an Immich item of another account or another server, a file of a share the screen
// does not have) once the user of the phone chose "Send it from this phone". The phone serves the item from its relay
// (cast_relay.dart) under a lease made for that screen alone: pinned to the screen's address, and asking for the MAC
// of its path under the K_relay of the play link session (play_link_protocol.dart). The play message names the lease
// and the port, never a host: the screen reads it from the address its session talks to.
//
// One item at a time: the lease of what the screen shows now lives, every other one is revoked. The leases end with
// the item (Stop, its end, Back on the screen), when another phone plays there, when the screen is lost, and from the
// notification's Stop.
//
// Keeping it alive: on Android a foreground service of type connectedDevice runs while a lease lives (its notification
// "Sending to (screen)" offers Stop), with a Wi-Fi lock and a partial wake lock, so that a video keeps playing on the
// screen with the phone's screen off (PlayRelayService.kt). iOS gives no background mode to a server of this kind: the
// screen of the iPhone is kept on while it sends, and the sheet says to keep Immuch360 open.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/cast/cast_media.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_messages.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/network/cast/cast_relay.dart';
import 'package:immich_mobile/providers/network/phone_share.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_play.provider.dart';
import 'package:logging/logging.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

final _log = Logger('PhonePlay');

/// What the relay serves of an item, made when the lease is: its content, its type and its size when known
class PlayOnRelayContent {
  const PlayOnRelayContent({required this.content, required this.mime, this.size});

  final CastRelayContent content;

  /// image/... or video/...
  final String mime;
  final int? size;
}

/// An item the phone sends from its relay: what the play says of it, and how its content is made
@immutable
class PlayOnRelayItem {
  const PlayOnRelayItem({
    required this.key,
    required this.name,
    required this.media,
    required this.content,
    this.projection = PlayProjection.flat,
  });

  /// What the item is on the phone ("local:(id)", "immich:(id)", "share:(source):(path)"): two requests of the same
  /// item are the same
  final String key;

  /// The file's name (one segment): its extension tells the screen how to read it
  final String name;
  final PlayMedia media;
  final PlayProjection projection;

  /// Made when the lease is (a picture of the gallery is drawn then); null when the item cannot be read any more
  final Future<PlayOnRelayContent?> Function() content;
}

/// Keeps the phone sending while its screen is off, replaced in the tests
abstract interface class PlayRelayKeepAlive {
  /// Starts with the texts of its notification; never throws
  Future<void> start({required String title, required String text, required String stopLabel, required String channel});

  /// Never throws
  Future<void> stop();

  /// The Stop of the notification
  Stream<void> get stopRequests;

  /// Whether the phone sends only while the app is open (iOS): the sheet says so
  bool get needsAppOpen;
}

/// Android: the foreground service PlayRelayService, through app.immuch360/play_relay
class AndroidPlayRelayKeepAlive implements PlayRelayKeepAlive {
  AndroidPlayRelayKeepAlive() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'stopRequested') {
        _stops.add(null);
      }
    });
  }

  static const _channel = MethodChannel('app.immuch360/play_relay');
  final _stops = StreamController<void>.broadcast();

  @override
  Future<void> start({
    required String title,
    required String text,
    required String stopLabel,
    required String channel,
  }) async {
    try {
      await _channel.invokeMethod<void>('start', {'title': title, 'text': text, 'stop': stopLabel, 'channel': channel});
    } catch (error) {
      _log.info('Play on: the sending service did not start (${error.runtimeType})');
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (error) {
      _log.info('Play on: the sending service did not stop (${error.runtimeType})');
    }
  }

  @override
  Stream<void> get stopRequests => _stops.stream;

  @override
  bool get needsAppOpen => false;
}

/// iOS: no background mode fits a server, so the screen of the iPhone stays on while it sends (the sheet says to keep
/// the app open); the system still suspends the app once it leaves the front
class WakelockPlayRelayKeepAlive implements PlayRelayKeepAlive {
  @override
  Future<void> start({
    required String title,
    required String text,
    required String stopLabel,
    required String channel,
  }) async {
    try {
      await WakelockPlus.enable();
    } catch (error) {
      _log.info('Play on: the screen could not be kept on (${error.runtimeType})');
    }
  }

  @override
  Future<void> stop() async {
    try {
      await WakelockPlus.disable();
    } catch (_) {}
  }

  @override
  Stream<void> get stopRequests => const Stream.empty();

  @override
  bool get needsAppOpen => true;
}

class _NoKeepAlive implements PlayRelayKeepAlive {
  @override
  Future<void> start({
    required String title,
    required String text,
    required String stopLabel,
    required String channel,
  }) async {}

  @override
  Future<void> stop() async {}

  @override
  Stream<void> get stopRequests => const Stream.empty();

  @override
  bool get needsAppOpen => false;
}

/// The texts of the notification, given by the app (i18n) once
typedef PlayRelayTexts = ({String Function(String screen) title, String text, String stopLabel, String channel});

/// What the relay needs from the device, replaced in the tests
class PhoneRelayEnvironment {
  const PhoneRelayEnvironment({
    required this.addressFor,
    required this.bind,
    required this.keepAlive,
    required this.texts,
    this.clientOf = _sameHost,
  });

  static String _sameHost(String host) => host;

  /// This phone's address on the network of the screen at [screenHost], null when it has none there
  final Future<String?> Function(String screenHost) addressFor;
  final Future<CastRelayServer> Function(String address) bind;
  final PlayRelayKeepAlive keepAlive;
  final PlayRelayTexts Function() texts;

  /// The address the requests of the screen at [screenHost] come from: that address (the tests map it to the loopback)
  final String Function(String screenHost) clientOf;
}

/// The texts of the notification, in the language of the app
PlayRelayTexts _translatedTexts() {
  final t = StaticTranslations.instance;
  return (
    title: (screen) => t.play_relay_notification_title(device: screen),
    text: t.play_relay_notification_text,
    stopLabel: t.play_relay_stop,
    channel: t.play_relay_channel,
  );
}

final phoneRelayEnvironmentProvider = Provider<PhoneRelayEnvironment>((ref) {
  final PlayRelayKeepAlive keepAlive = CurrentPlatform.isAndroid
      ? AndroidPlayRelayKeepAlive()
      : CurrentPlatform.isIOS
      ? WakelockPlayRelayKeepAlive()
      : _NoKeepAlive();
  return PhoneRelayEnvironment(
    addressFor: (screenHost) async => castRelayAddressFor(await phoneShareLocalAddresses(), screenHost),
    bind: (address) => CastRelayServer.bind(address),
    keepAlive: keepAlive,
    texts: _translatedTexts,
  );
});

/// What the phone sends from its relay now: the screen's name, null while nothing is sent
@immutable
class PhoneRelayView {
  const PhoneRelayView({required this.screen});

  final String screen;
}

/// See the top of this file
class PhoneRelayController extends Notifier<PhoneRelayView?> {
  CastRelayServer? _server;
  StreamSubscription<void>? _stops;

  /// The leases of plays still on their way: the listener of the playback leaves them alone until they settled
  final Set<String> _pending = {};
  bool _keptAlive = false;

  /// Read once: the provider's dispose may not read another provider
  late PhoneRelayEnvironment _environment;

  @override
  PhoneRelayView? build() {
    _environment = ref.read(phoneRelayEnvironmentProvider);
    ref.listen(remotePlaybackProvider, (_, playback) => _follow(playback));
    _stops = _environment.keepAlive.stopRequests.listen((_) => unawaited(_stopFromNotice()));
    ref.onDispose(() {
      unawaited(_stops?.cancel());
      final server = _server;
      _server = null;
      unawaited(server?.close());
      if (_keptAlive) {
        _keptAlive = false;
        unawaited(_environment.keepAlive.stop());
      }
    });
    return null;
  }

  /// The leases alive, for the tests
  @visibleForTesting
  Iterable<CastRelayLease> get leases => _server?.leases ?? const [];

  /// A lease of [item] for the screen at [screenHost] named [screenName], asking for the MAC of its path under one of
  /// [macKeys] (the K_relay of the sessions of the connection that sends the play); null when the item cannot be read
  /// or the relay cannot listen. The lease stays pending until [settle].
  Future<({CastRelayLease lease, PlayOnRelayContent made})?> lease({
    required String screenHost,
    required String screenName,
    required PlayOnRelayItem item,
    required List<List<int>> Function() macKeys,
  }) async {
    final PlayOnRelayContent? made;
    try {
      made = await item.content();
    } catch (error) {
      _log.info('Play on: the item could not be read for the relay (${error.runtimeType})');
      return null;
    }
    if (made == null) {
      return null;
    }
    final server = await _serverFor(screenHost);
    if (server == null) {
      return null;
    }
    final lease = server.lease(made.content, client: _environment.clientOf(screenHost), macKeys: macKeys);
    _pending.add(lease.id);
    _sending(screenName);
    return (lease: lease, made: made);
  }

  /// The play of [leaseId] answered: kept when it plays (the playback's listener keeps it from now on), else revoked
  void settle(String leaseId, {required bool playing}) {
    _pending.remove(leaseId);
    if (!playing) {
      _revoke((lease) => lease.id == leaseId);
    }
    _follow(ref.read(remotePlaybackProvider));
  }

  /// Every lease ends
  Future<void> endAll() async {
    _pending.clear();
    _revoke((_) => true);
  }

  /// The relay bound to this phone's address on the screen's network, bound again when that address changed
  Future<CastRelayServer?> _serverFor(String screenHost) async {
    final address = await _environment.addressFor(screenHost);
    if (address == null) {
      _log.info('Play on: no address of this phone on the network of the screen');
      return null;
    }
    final current = _server;
    if (current != null && !current.isClosed && current.address == address) {
      return current;
    }
    _server = null;
    await current?.close();
    try {
      return _server = await _environment.bind(address);
    } catch (error) {
      _log.info('Play on: the relay could not listen (${error.runtimeType})');
      return null;
    }
  }

  /// Keeps the lease of what the screen shows now, and those of plays on their way; revokes the rest
  ///
  /// The foreground service stays while the playback goes on after its last lease (an Immich item of the same
  /// slideshow, a video that ended before the next item): the phone's clock keeps running with its screen off, and the
  /// next item it sends from its relay needs no start from the background, which Android refuses
  void _follow(RemotePlayback? playback) {
    final target = playback?.request.target;
    final live = playback != null && !playback.lost && target is RelayPlayTarget && !_ends(playback.state.phase)
        ? target.lease
        : null;
    final goesOn =
        playback != null &&
        !playback.lost &&
        playback.state.phase != ScreenPlayPhase.idle &&
        playback.state.phase != ScreenPlayPhase.failed;
    _revoke((lease) => lease.id != live && !_pending.contains(lease.id), playbackGoesOn: goesOn);
  }

  /// The item ended on the screen, or did not show: its lease goes
  static bool _ends(ScreenPlayPhase phase) =>
      phase == ScreenPlayPhase.idle || phase == ScreenPlayPhase.ended || phase == ScreenPlayPhase.failed;

  void _revoke(bool Function(CastRelayLease lease) which, {bool playbackGoesOn = false}) {
    final server = _server;
    if (server != null) {
      for (final lease in server.leases.where(which)) {
        lease.revoke();
      }
    }
    if ((server == null || server.leaseCount == 0) && !playbackGoesOn) {
      _idle();
    }
  }

  void _sending(String screen) {
    final before = state?.screen;
    if (before != screen) {
      state = PhoneRelayView(screen: screen);
    }
    // Started again for another screen: its notification names the new one
    if (_keptAlive && before == screen) {
      return;
    }
    _keptAlive = true;
    final texts = _environment.texts();
    unawaited(
      _environment.keepAlive.start(
        title: texts.title(screen),
        text: texts.text,
        stopLabel: texts.stopLabel,
        channel: texts.channel,
      ),
    );
  }

  void _idle() {
    if (state != null) {
      state = null;
    }
    if (_keptAlive) {
      _keptAlive = false;
      unawaited(_environment.keepAlive.stop());
    }
  }

  /// Stop in the notification: the screen stops showing the item, and the leases end
  Future<void> _stopFromNotice() async {
    _log.info('Play on: Stop from the notification of the relay');
    final playback = ref.read(remotePlaybackProvider);
    if (playback != null && playback.request.target is RelayPlayTarget) {
      await ref.read(remotePlaybackProvider.notifier).stop();
    }
    await endAll();
  }
}

final phoneRelayProvider = NotifierProvider<PhoneRelayController, PhoneRelayView?>(PhoneRelayController.new);

/// The type of a file of [name], from its extension: what the screen reads it as
String? playRelayMimeOf(String name, {required bool photo}) {
  final dot = name.lastIndexOf('.');
  final extension = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  if (photo) {
    return switch (extension) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      'heic' || 'heif' => 'image/heic',
      'avif' => 'image/avif',
      'tif' || 'tiff' => 'image/tiff',
      'dng' => 'image/x-adobe-dng',
      _ => 'image/jpeg',
    };
  }
  return switch (extension) {
    'mov' || 'qt' => 'video/quicktime',
    'mkv' => 'video/x-matroska',
    'webm' => 'video/webm',
    'avi' => 'video/x-msvideo',
    '3gp' => 'video/3gpp',
    'mts' || 'm2ts' => 'video/mp2t',
    _ => 'video/mp4',
  };
}

/// A name the play may carry for [name]: one segment, 120 characters at most, its extension kept
String playRelayNameOf(String name, {required bool photo}) {
  final last = name.split(RegExp(r'[/\\]')).lastWhere((part) => part.isNotEmpty, orElse: () => '');
  final clean = String.fromCharCodes(last.codeUnits.where((unit) => unit >= 0x20 && unit != 0x7f)).trim();
  if (RelayPlayTarget.isSafeName(clean)) {
    return clean;
  }
  if (clean.length > 120) {
    final dot = clean.lastIndexOf('.');
    final extension = dot > 0 && clean.length - dot <= 10 ? clean.substring(dot) : '';
    final cut = clean.substring(0, 120 - extension.length) + extension;
    if (RelayPlayTarget.isSafeName(cut)) {
      return cut;
    }
  }
  return photo ? 'photo.jpg' : 'video.mp4';
}

/// The relay's content of a picture made in memory
PlayOnRelayContent playRelayPicture(Uint8List jpeg) => PlayOnRelayContent(
  content: CastRelayContent.local(bytes: jpeg, contentType: 'image/jpeg'),
  mime: 'image/jpeg',
);

/// The relay's content of a file of this device
Future<PlayOnRelayContent?> playRelayFile(File file, {required String mime}) async {
  if (!file.existsSync()) {
    return null;
  }
  return PlayOnRelayContent(
    content: CastRelayContent.local(file: () async => file.existsSync() ? file : null, contentType: mime),
    mime: mime,
    size: file.lengthSync(),
  );
}
