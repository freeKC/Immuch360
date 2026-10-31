// The start of the kiosk mode of the Meta Quest (lot quest-kiosk, see KioskConfig and KioskSettings): once per run of
// the app, after the first frame of the tab shell, the photo or the film chosen opens in the immersive viewer as a
// kiosk (KioskSession on the headset), without previous or next. Nothing happens with the switch off or nothing chosen,
// which phones, TVs and computers never have (the setting shows on a Meta Quest only), nor off a Meta Quest. On a Meta
// Quest a notice with Cancel comes first, for a few seconds (kioskCountdown): the way back to the settings when the
// kiosk cannot be left in the headset (hands only, no B or Y; a viewer that fails on the media). The need comes from the
// exhibition builds of ppawelstachh-sys/Immuch360 (branch immuch360).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/kiosk_config.dart';
import 'package:immich_mobile/domain/models/kiosk_media.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/immersive_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('KioskStart');

/// What a call of [KioskStart.run] did
enum KioskStartOutcome {
  /// The switch is off, or nothing is chosen: the app starts as usual
  off,

  /// A media is chosen, but the device is no Meta Quest: the app starts as usual
  notHeadset,

  /// The kiosk opened
  opened,

  /// The media chosen did not open (gone, unreachable, refused by the viewer): the app says so and starts as usual
  failed,

  /// The kiosk start ran already in this run of the app
  ranBefore,

  /// Cancel was pressed on the notice before the opening: the app starts as usual, its settings at hand
  cancelled,
}

/// Opens the media of the kiosk in the immersive viewer: what [KioskStart.run] calls once the device is known to be a
/// Meta Quest. Throws when the media cannot be found or read, or when the viewer does not open.
typedef KioskOpener = Future<void> Function();

/// The notice before a kiosk opens, see [kioskCountdown]: true to open [media], false when Cancel was pressed
typedef KioskCountdown = Future<bool> Function(KioskMedia media);

/// How long the notice before a kiosk stays on screen, its Cancel at hand
const kioskCountdownDelay = Duration(seconds: 8);

/// The kiosk start of a run of the app: once, whatever builds the tab shell again later (a login, a return from the
/// welcome page), so that choosing a media never turns a running app into a kiosk
class KioskStart {
  bool _ran = false;

  /// Whether [run] was called in this run of the app
  bool get ran => _ran;

  /// With the kiosk [config] on and a media chosen, on a Meta Quest ([isHorizonOs]), opens the media through the
  /// opener [prepare] makes for it, once the notice [countdown] ends without Cancel. [prepare] is called before any
  /// wait, the caller reading its services there; never for a kiosk that is off.
  Future<KioskStartOutcome> run({
    required KioskConfig config,
    required Future<bool> Function() isHorizonOs,
    required KioskOpener Function(KioskMedia media) prepare,
    required KioskCountdown countdown,
  }) async {
    if (_ran) {
      return KioskStartOutcome.ranBefore;
    }
    _ran = true;
    final media = config.chosenMedia;
    if (!config.enabled || media == null) {
      return KioskStartOutcome.off;
    }
    final open = prepare(media);
    if (!await isHorizonOs()) {
      _log.info('A kiosk media is chosen, but this device is no Meta Quest');
      return KioskStartOutcome.notHeadset;
    }
    if (!await countdown(media)) {
      _log.info('Kiosk mode: ${media.name} cancelled on the notice, the app starts as usual');
      return KioskStartOutcome.cancelled;
    }
    try {
      await open();
      _log.info('Kiosk mode: ${media.name} opened for visitors');
      return KioskStartOutcome.opened;
    } catch (error, stackTrace) {
      _log.warning('The kiosk media ${media.name} did not open', error, stackTrace);
      return KioskStartOutcome.failed;
    }
  }
}

/// The kiosk start of this run of the app
final kioskStartProvider = Provider<KioskStart>((_) => KioskStart());

/// Says through [messenger] that the kiosk opens soon ([text]), for [delay] once the notice is on screen, with a
/// [cancelLabel] action. Completes with false when it is pressed, else with true: at the end of [delay], or as soon as
/// the notice is swiped away. The messages shown before are cleared, so that the notice shows at once.
Future<bool> kioskCountdown(
  ScaffoldMessengerState messenger, {
  required String text,
  required String cancelLabel,
  Duration delay = kioskCountdownDelay,
}) {
  final result = Completer<bool>();
  Timer? timer;
  void finish({required bool open}) {
    timer?.cancel();
    if (!result.isCompleted) {
      result.complete(open);
    }
  }

  messenger.clearSnackBars();
  // A timer of its own rather than the one of the SnackBar, which keeps a SnackBar with an action until it is closed
  late final ScaffoldFeatureController<SnackBar, SnackBarClosedReason> notice;
  notice = messenger.showSnackBar(
    SnackBar(
      content: Text(text),
      persist: true,
      onVisible: () => timer ??= Timer(delay, () {
        finish(open: true);
        notice.close();
      }),
      action: SnackBarAction(label: cancelLabel, onPressed: () => finish(open: false)),
    ),
  );
  // Closed another way (swiped away): the kiosk opens. Cancel completed already, before the notice slides away
  unawaited(notice.closed.then((_) => finish(open: true)));
  return result.future;
}

/// What the viewer of a kiosk is told, in the language of the app ([t]): the end card text typed in the settings, else
/// "Thank you for the journey", and how to leave
KioskOptions kioskOptions(KioskConfig config, Translations t) =>
    KioskOptions(endText: config.endTextOr(t.kiosk_mode_end_text_default), exitHint: t.kiosk_mode_exit_hint);

/// The asset of [media] as the database holds it now: from the server when [remote] finds it there and not in the
/// trash, else from the device ([local]). Throws when it is in neither any more.
Future<BaseAsset> findKioskAsset(
  KioskAssetMedia media, {
  required Future<RemoteAsset?> Function(String id) remote,
  required Future<LocalAsset?> Function(String id) local,
}) async {
  final remoteId = media.remoteId;
  if (remoteId != null) {
    final asset = await remote(remoteId);
    if (asset != null && !asset.isTrashed) {
      return asset;
    }
  }
  final localId = media.localId;
  if (localId != null) {
    final asset = await local(localId);
    if (asset != null) {
      return asset;
    }
  }
  throw StateError('${media.name} is no longer on the server nor on the device');
}

/// What the immersive viewer opens for [media], a file of a network share: its URL on the media bridge ([mediaUrl],
/// which opens the share), and its sphere view from what the file declares ([detect] through [reader]), as the photo
/// and video pages of the shares do; a raw file of a 360° camera through [raw]. Throws when the share cannot be
/// reached, or when the file cannot be read on it (gone, renamed, empty): its first byte is read first, [detect]
/// giving nothing rather than an error for a file it cannot read.
Future<ImmersiveRequest> kioskShareRequest(
  KioskShareFile media, {
  required Future<Uri> Function(String sourceId, String path) mediaUrl,
  required ByteRangeReader Function(Uri url) reader,
  required Future<NetworkMediaInfo?> Function(NetworkEntry entry, ByteRangeReader read) detect,
  RawImmersiveMedia? raw,
}) async {
  final url = await mediaUrl(media.sourceId, media.path);
  final entry = NetworkEntry(sourceId: media.sourceId, path: media.path, isDirectory: false, size: media.size);
  final read = reader(url);
  if ((await read(0, 1)).isEmpty) {
    throw StateError('${media.name} is empty on the share');
  }
  final info = await detect(entry, read);
  if (raw != null && info?.rawKind != null) {
    return raw.sharedMedia(entry, url, read: read, probe: info?.probe);
  }
  return ImmersiveRequest(
    url: url.toString(),
    isVideo: entry.isVideo,
    title: entry.name,
    view: (info ?? const NetworkMediaInfo()).sphereView(entry.name, width: info?.frameWidth, height: info?.frameHeight),
  );
}

/// Opens [request] in the immersive viewer as a kiosk with [options], as an opening of its own in [session] without a
/// navigator: no previous or next, and nothing to follow once it closes. A film starts at 0:00. A kiosk shows no splat:
/// the viewer does not start the splat module of the headset for it.
Future<void> openKioskRequest(
  ImmersiveApi api,
  ImmersiveSession session,
  ImmersiveRequest request, {
  required KioskOptions options,
  required Map<String, String> stereoLabels,
  bool reverseThumbstickTurn = false,
}) async {
  final openingId = session.start(null);
  try {
    await openImmersiveRequest(
      api,
      request,
      stereoLabels: stereoLabels,
      openingId: openingId,
      reverseThumbstickTurn: reverseThumbstickTurn,
      // A kiosk never shows a splat: the viewer does not start the splat module for it
      gaussianSplats: false,
      kiosk: options.toJson(),
    );
  } catch (_) {
    session.cancel(openingId);
    rethrow;
  }
}

/// The kiosk start of this run of the app ([KioskStart.run]) with the services of the app, from the tab shell once its
/// first frame is on screen. [messenger] shows the notice with Cancel before the opening ([kioskCountdown]), and says
/// when the media chosen did not open.
Future<void> startKiosk(WidgetRef ref, {ScaffoldMessengerState? messenger}) async {
  final start = ref.read(kioskStartProvider);
  final config = ref.read(appConfigProvider).kiosk;
  final t = StaticTranslations.instance;
  final outcome = await start.run(
    config: config,
    isHorizonOs: () => ref.read(isHorizonOsProvider.future),
    prepare: (media) => _appKioskOpener(ref, media, kioskOptions(config, t)),
    // MaterialApp gives the shell a messenger; without one, there is nothing to show the notice on
    countdown: (media) async =>
        messenger == null ||
        await kioskCountdown(
          messenger,
          text: t.kiosk_mode_opening_soon(name: media.name),
          cancelLabel: t.cancel,
        ),
  );
  if (outcome == KioskStartOutcome.failed) {
    messenger?.showSnackBar(SnackBar(content: Text(t.kiosk_mode_open_failed(name: config.chosenMedia?.name ?? ''))));
  }
}

/// The opener of the app for [media], its services read now (the tab shell may be gone once the device is known)
KioskOpener _appKioskOpener(WidgetRef ref, KioskMedia media, KioskOptions options) {
  final api = ref.read(immersiveApiProvider);
  final session = ref.read(immersiveSessionProvider);
  final reverseThumbstickTurn = ref.read(appConfigProvider).viewer.reverseThumbstickTurn;
  final stereoLabels = sphereViewerLabels(StaticTranslations.instance);
  // Only what the media needs: the network shares, or the assets
  final Future<ImmersiveRequest> Function() resolve;
  switch (media) {
    case KioskShareFile():
      final connections = ref.read(networkConnectionsProvider);
      final bridgeClient = ref.read(networkBridgeClientProvider);
      final mediaService = ref.read(networkMediaServiceProvider);
      final raw = RawImmersiveMedia.read(ref, forAssets: false);
      resolve = () => kioskShareRequest(
        media,
        mediaUrl: connections.mediaUrl,
        reader: (url) => httpRangeReader(bridgeClient, url),
        detect: (entry, read) => mediaService.detect(entry, read, thorough: true),
        raw: raw,
      );
    case KioskAssetMedia():
      final assets = ref.read(assetServiceProvider);
      final resolver = ImmersiveAssetResolver.read(ref, stereoLabels: stereoLabels);
      resolve = () async =>
          resolver.resolve(await findKioskAsset(media, remote: assets.getRemoteAsset, local: assets.getLocalAsset));
  }
  return () async => openKioskRequest(
    api,
    session,
    await resolve(),
    options: options,
    stereoLabels: stereoLabels,
    reverseThumbstickTurn: reverseThumbstickTurn,
  );
}
