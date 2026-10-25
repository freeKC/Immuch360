// The DJI live video on a headset (p2/design-ux-phone-2026-10-24.md, section 6): the phones that send the drone's
// picture on this network, one tap to watch one, its code asked once in a dialog, then the picture in the window and
// the flight view of stage 2b. The page connects by itself to the last phone it received from, once per opening. The
// observer rule and "Watching only" are on top at all times and on the picture; nothing on the headset reaches the
// remote or the drone.
//
// On Android TV and Google TV (p2/design-tv-2026-10-24.md) the same page, with the same session logic, is drawn for the
// remote by DjiWatchTvView: the phones view, this TV's own code with its QR code for the phone to add, and the full
// screen view. On a TV the page also stops receiving when the app goes to the background and connects again by itself
// when it comes back, and lets the screen saver come after 10 minutes without a picture.

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/platform/tv_api.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_capture.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_latency.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_observer.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_receive.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_video.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_advanced.panel.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_fields.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_notice.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_obstacle.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_watch_tv.widget.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';
import 'package:immich_mobile/providers/drone/dji_live_frame.provider.dart';
import 'package:immich_mobile/providers/drone/dji_relay.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/routing/router.dart';

/// After this many failed attempts in a row, the state line says what to check
const djiWatchStillTryingFailures = 3;

/// The texts of the flight view, with the placeholders the native side fills ten times a second. Its two columns get a
/// label and a value template per value the gate lets over the picture, the same values as the phone's bands, and the
/// obstacle ring the distance it may write by the glow.
Map<String, String> djiFlightViewLabels(
  Translations t, {
  Map<DjiLiveField, DjiLiveGate> gates = djiLiveGates,
}) => {
  'live': t.dji_link_flight_view_live,
  'replay': t.dji_link_flight_view_replay(name: '{name}'),
  'noSource': t.dji_link_flight_view_no_source,
  'lost': t.dji_link_flight_view_lost,
  'local': t.dji_link_flight_view_local,
  'ended': t.dji_link_flight_view_ended,
  'wrongCode': t.dji_link_receive_state_wrong_code,
  'otherVersion': t.dji_link_receive_state_other_version,
  'unproven': t.dji_link_receive_state_unproven,
  'noPicture': t.dji_link_flight_view_no_picture,
  'stale': t.dji_link_latency_stale(seconds: '{seconds}'),
  'noValues': t.dji_link_flight_none,
  ...djiLiveFlightViewTemplates(t, gates: gates),
  'batteryLow': t.dji_live_battery_low,
  'obstacleDistance': t.dji_live_obstacle_distance(distance: '{distance}'),
  'on': t.dji_link_flight_view_on,
  'off': t.dji_link_flight_view_off,
  'valuesStale': t.dji_link_flight_view_values_stale,
  'delay': t.dji_live_quest_delay(ms: '{ms}'),
  'delayEstimate': t.dji_live_quest_delay_estimate(ms: '{ms}'),
  'delayHigh': t.dji_link_flight_view_delay_high(ms: '{ms}'),
  'flyNote': t.dji_link_flight_view_fly_note,
  'observer': t.dji_link_observer_note,
  'watching': t.dji_link_observer_watching,
  'hint': t.dji_link_flight_view_hint,
  'back': t.dji_link_flight_view_back,
};

/// The values under the picture of the window (p2/design-final-2026-10-24.md, 7.3): the flight values then the state of
/// the drone, each a small label over a number, the same gate and order as the phone's bands
class DjiWatchCells extends ConsumerWidget {
  const DjiWatchCells({super.key, this.gates = djiLiveGates});

  final Map<DjiLiveField, DjiLiveGate> gates;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final frame = ref.watch(djiLiveFrameProvider);
    final fields = [
      ...djiLiveBandFields(DjiLiveBand.left, gates: gates),
      ...djiLiveBandFields(DjiLiveBand.right, gates: gates),
    ];
    final small = context.textTheme.labelSmall;
    final number = context.textTheme.titleMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    final cells = [
      for (final field in fields)
        if (djiLiveFieldValue(t, frame, field) case final String value)
          (
            field,
            djiLiveFieldLabel(t, field, place: DjiLivePlace.overlay, gates: gates),
            value,
            field == DjiLiveField.droneBattery && djiLiveBatteryIsLow(frame),
          ),
    ];
    if (cells.isEmpty) {
      return const SizedBox.shrink();
    }
    return Wrap(
      key: const Key('dji_watch_values'),
      spacing: 20,
      runSpacing: 8,
      children: [
        for (final (field, label, value, low) in cells)
          Semantics(
            label: [label, value, if (low) t.dji_live_battery_low].where((part) => part.isNotEmpty).join(' '),
            excludeSemantics: true,
            child: Column(
              key: Key('dji_watch_value_${field.name}'),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (label.isNotEmpty) Text(label, style: small),
                Text(value, style: low ? number?.copyWith(color: const Color(0xFFFFB300)) : number),
              ],
            ),
          ),
      ],
    );
  }
}

@RoutePage()
class DjiWatchPage extends ConsumerStatefulWidget {
  const DjiWatchPage({super.key});

  @override
  ConsumerState<DjiWatchPage> createState() => _DjiWatchPageState();
}

class _DjiWatchPageState extends ConsumerState<DjiWatchPage> with WidgetsBindingObserver {
  late final DjiLinkNotifier _notifier;
  late final DjiRelayNotifier _relay;
  final _address = TextEditingController();
  String? _addressError;

  /// The code dialog is open: a refused code does not open a second one
  bool _asking = false;

  /// A TV, or the remote control layout: the TV's own code, its tries, the app going to the background and the screen
  /// saver. A television keeps it with the layout turned off, as its Drone card, its setting and its hello do.
  late final bool _tv;

  /// The app went to the background with this page in front (a TV only)
  bool _paused = false;

  /// After [djiWatchTvScreenIdle] without a picture, a TV lets its screen saver come
  Timer? _screenIdle;
  bool _screenReleased = false;

  @override
  void initState() {
    super.initState();
    _notifier = ref.read(djiLinkProvider.notifier);
    _relay = ref.read(djiRelayProvider.notifier);
    _tv = ref.read(tvModeProvider) || ref.read(tvDeviceProvider).isTelevision;
    if (_tv) {
      WidgetsBinding.instance.addObserver(this);
      _pictureFlows(false);
    }
    // After the first frame, which a change of the providers must not reach
    unawaited(Future.microtask(_notifier.pageShown));
    // The values ten times a second while this page is in front (and the flight view over it), the obstacle ring's
    // sound and number as set here (the rest comes from the phone), and the screen kept on
    unawaited(Future.microtask(() => _notifier.setFrameStream(true)));
    unawaited(Future.microtask(() => ref.read(djiObstacleSettingsProvider.notifier).sync()));
    if (!_tv) {
      // A headset's choice of the lowest delay, taken by the next reception
      unawaited(Future.microtask(() => ref.read(djiLowestDelayProvider.notifier).sync()));
    }
    unawaited(Future.microtask(() => _relay.setLiveScreenShown(true)));
    unawaited(
      Future.microtask(() async {
        await _relay.setPageVisible(true);
        if (_tv) {
          // The link stopped with the last opening: no phone is watched any more, and the last one connects by itself
          _relay.forgetTarget();
          await _relay.loadOwnCode();
          _relay.beginOwnCodeTries();
        }
        _relay.startBrowsing();
        await _relay.armAutoConnect();
        if (_tv && mounted) {
          _relay.setOwnCodeTries(true);
        }
      }),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_noticeOnce()));
  }

  @override
  void dispose() {
    if (_tv) {
      WidgetsBinding.instance.removeObserver(this);
      _screenIdle?.cancel();
      _relay.setOwnCodeTries(false);
    }
    _relay.disarmAutoConnect();
    _relay.stopBrowsing();
    unawaited(_notifier.setFrameStream(false));
    unawaited(_relay.setLiveScreenShown(false));
    unawaited(_relay.setPageVisible(false));
    // Receiving stops with the page, as the link does
    unawaited(_notifier.pageHidden());
    _address.dispose();
    super.dispose();
  }

  /// A TV: Home or another app in front stops receiving and browsing; back in front, it browses and connects by itself
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_tv) {
      return;
    }
    if ((state == AppLifecycleState.hidden || state == AppLifecycleState.paused) && !_paused) {
      _paused = true;
      unawaited(_relay.pauseWatching());
    } else if (state == AppLifecycleState.resumed && _paused) {
      _paused = false;
      unawaited(_relay.resumeWatching(tries: true));
    }
  }

  /// A TV keeps its screen on while pictures come, and lets its screen saver come [djiWatchTvScreenIdle] after the last
  /// one; the screen is taken again as soon as a picture comes back
  void _pictureFlows(bool flows) {
    _screenIdle?.cancel();
    _screenIdle = null;
    if (flows) {
      if (_screenReleased) {
        _screenReleased = false;
        unawaited(_relay.setLiveScreenShown(true));
      }
      return;
    }
    _screenIdle = Timer(djiWatchTvScreenIdle, () {
      _screenIdle = null;
      if (mounted) {
        _screenReleased = true;
        unawaited(_relay.setLiveScreenShown(false));
      }
    });
  }

  Future<void> _noticeOnce() async {
    if (!mounted || ref.read(djiLiveNoticeReadProvider)) {
      return;
    }
    final read = await showDjiLiveNotice(context, headset: true, tv: _tv, alert: _alertOffered());
    if (!mounted) {
      return;
    }
    if (read) {
      ref.read(djiLiveNoticeReadProvider.notifier).state = true;
    } else {
      Navigator.of(context).pop();
    }
  }

  /// A tap on a phone: its remembered code connects at once, otherwise the code is asked. A TV never types first: it
  /// proves its own code, which the phone knows once the pilot added the TV.
  Future<void> _watch(DjiRelayPhone phone) async {
    final relay = ref.read(djiRelayProvider);
    final id = phone.id;
    final remembered = id == null ? null : relay.rememberedCodes[id];
    if (_tv) {
      if (_relay.busyWith(phone)) {
        // Already starting or watching that phone: a held OK, or a second press, starts nothing again
        return;
      }
      _relay.chosenOnTv();
      final code = remembered ?? relay.ownCode;
      if (code != null) {
        await _relay.connect(phone, code);
        return;
      }
      await _askCodeOnTv(phone);
      return;
    }
    if (remembered != null) {
      await _relay.connect(phone, remembered);
      return;
    }
    await _askCode(phone);
  }

  /// The phone's code typed on a TV, in its native text dialog (the Gboard TV grid or a keyboard): asked again while
  /// it is not a code of the alphabet, and again with "The code does not match" when the phone refuses it
  Future<void> _askCodeOnTv(DjiRelayPhone phone, {bool wrong = false}) async {
    if (_asking) {
      return;
    }
    _asking = true;
    final t = context.t;
    try {
      var title = wrong ? t.dji_link_receive_state_wrong_code : t.dji_live_watch_code_title(phone: phone.name);
      while (mounted) {
        final typed = await ref
            .read(tvApiProvider)
            .editText(
              TvTextRequest(
                title: title,
                text: '',
                kind: TvTextKind.text,
                okLabel: t.dji_live_watch,
                cancelLabel: t.cancel,
              ),
            );
        if (typed == null || !mounted) {
          return;
        }
        final code = normalizePairingCode(typed);
        if (code != null) {
          _relay.chosenOnTv();
          await _relay.connect(phone, code);
          return;
        }
        title = t.dji_link_receive_code_invalid;
      }
    } catch (_) {
      // No text dialog on this device: the phone's code cannot be typed here, its own code still works
      return;
    } finally {
      _asking = false;
    }
  }

  /// "Phone not listed? Type its address", in the TV's native text dialog
  Future<void> _typeAddressOnTv() async {
    final t = context.t;
    final String? typed;
    try {
      typed = await ref
          .read(tvApiProvider)
          .editText(
            TvTextRequest(
              title: t.dji_link_receive_address,
              text: _address.text,
              kind: TvTextKind.url,
              okLabel: t.ok,
              cancelLabel: t.cancel,
            ),
          );
    } catch (_) {
      return;
    }
    if (typed == null || !mounted) {
      return;
    }
    _address.text = typed;
    await _watchTyped();
  }

  Future<void> _askCode(DjiRelayPhone phone, {bool wrong = false}) async {
    if (_asking) {
      return;
    }
    _asking = true;
    try {
      final code = await showDialog<String>(
        context: context,
        builder: (_) => DjiWatchCodeDialog(phoneName: phone.name, wrong: wrong),
      );
      if (code != null && mounted) {
        await _relay.connect(phone, code);
      }
    } finally {
      _asking = false;
    }
  }

  /// "Phone not listed? Type its address": a listed phone at that address keeps its id, for its remembered code
  Future<void> _watchTyped() async {
    final typed = parseDjiRelayAddress(_address.text);
    if (typed == null) {
      setState(() => _addressError = context.t.dji_link_receive_address_invalid);
      return;
    }
    setState(() => _addressError = null);
    final listed = ref
        .read(djiRelayProvider)
        .phones
        .where((phone) => phone.host == typed.host && phone.port == typed.port)
        .firstOrNull;
    await _watch(listed ?? DjiRelayPhone(name: typed.host, host: typed.host, port: typed.port));
  }

  /// The obstacle ring may show here: the phone offers it, and the notice then says it never steers or stops the drone
  bool _alertOffered() => djiObstacleOffer() != DjiObstacleOffer.none;

  Future<void> _saveRecord() async {
    final outcome = await _notifier.exportReception();
    if (!mounted) {
      return;
    }
    showDjiExportToast(context, outcome, ref.read(djiLinkProvider).export, record: true);
  }

  Future<void> _menu(String choice) async {
    final settings = ref.read(djiObstacleSettingsProvider);
    final obstacle = ref.read(djiObstacleSettingsProvider.notifier);
    switch (choice) {
      case 'record':
        await _saveRecord();
      case 'sound':
        await obstacle.setSound(!settings.soundOn);
      case 'lowestDelay':
        final delay = ref.read(djiLowestDelayProvider.notifier);
        await delay.set(!ref.read(djiLowestDelayProvider));
      case 'ringNumbers':
        await obstacle.setNumbers(!settings.numbersOn);
      case 'sample':
        final flying = context.t.dji_live_obstacle_sample_flying;
        final shown = await obstacle.showSample();
        if (!shown && mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(flying)));
        }
      case 'play':
        await showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (_) => const SafeArea(
            child: SingleChildScrollView(padding: EdgeInsets.all(16), child: DjiLinkPlaySection()),
          ),
        );
      case 'safety':
        await showDjiLiveNotice(context, headset: true, tv: _tv, alert: _alertOffered());
      case 'diagnostics':
        await context.pushRoute(const DjiLinkRoute());
      case 'testSound':
        final volumeOff = context.t.dji_live_media_volume_off;
        await obstacle.playTest();
        final off = await obstacle.mediaVolumeOff();
        if (!mounted) {
          return;
        }
        if (off) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(volumeOff)));
        }
      case 'newCode':
        await _relay.newOwnCode();
      case 'stop':
        await _relay.disconnect();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // A refused or new code asks for the code again, in the dialog; a TV whose own code was refused shows its card
    ref.listen(djiLinkProvider.select((state) => state.snapshot?.relayReceiving?.state), (previous, next) {
      final relay = ref.read(djiRelayProvider);
      final target = relay.target;
      if (next == DjiRelayReceiveState.wrongCode && previous != next && target != null && !relay.usingOwnCode) {
        unawaited(_tv ? _askCodeOnTv(target, wrong: true) : _askCode(target, wrong: true));
      }
    });
    if (_tv) {
      ref.listen<bool>(
        djiLinkProvider.select(
          (state) => djiLinkPictureFlows(state.snapshot?.videoDecode) && !djiLinkRelayPictureStopped(state.snapshot),
        ),
        (_, flows) => _pictureFlows(flows),
      );
      return DjiWatchTvView(
        addressError: _addressError,
        onWatch: (phone) => unawaited(_watch(phone)),
        onTypeCode: (phone) => unawaited(_askCodeOnTv(phone)),
        onTypeAddress: () => unawaited(_typeAddressOnTv()),
        onMenu: (choice) => unawaited(_menu(choice)),
      );
    }
    final relay = ref.watch(djiRelayProvider);
    final snapshot = ref.watch(djiLinkProvider.select((state) => state.snapshot));
    final horizonOs = ref.watch(isHorizonOsProvider).valueOrNull ?? false;
    final obstacle = ref.watch(djiObstacleSettingsProvider);
    final lowestDelay = ref.watch(djiLowestDelayProvider);
    final offer = djiObstacleOffer();
    final phones = _phones(t, relay);
    final picture = _picture(t, relay, snapshot, horizonOs: horizonOs);
    return Scaffold(
      key: const Key('dji_watch'),
      appBar: AppBar(
        title: Text(t.dji_live_title),
        actions: [
          PopupMenuButton<String>(
            key: const Key('dji_watch_menu'),
            tooltip: t.dji_live_advanced,
            icon: const Icon(Icons.more_horiz_rounded),
            onSelected: (choice) => unawaited(_menu(choice)),
            itemBuilder: (_) => [
              PopupMenuItem(value: 'play', child: Text(t.dji_live_play_capture)),
              PopupMenuItem(
                key: const Key('dji_watch_save_record'),
                value: 'record',
                child: Text(t.dji_live_watch_save_record),
              ),
              // The ring's own items of this headset: whether it shows, its distances and its side come from the phone
              if (offer != DjiObstacleOffer.none) ...[
                CheckedPopupMenuItem(
                  key: const Key('dji_watch_obstacle_sound'),
                  value: 'sound',
                  checked: obstacle.soundOn,
                  child: Text(t.dji_live_obstacle_sound),
                ),
                PopupMenuItem(
                  key: const Key('dji_watch_obstacle_sound_test'),
                  value: 'testSound',
                  child: Text(t.dji_live_obstacle_sound_test),
                ),
                CheckedPopupMenuItem(
                  key: const Key('dji_watch_obstacle_numbers'),
                  value: 'ringNumbers',
                  checked: obstacle.numbersOn,
                  child: Text(t.dji_live_obstacle_numbers),
                ),
                PopupMenuItem(
                  key: const Key('dji_watch_obstacle_sample'),
                  value: 'sample',
                  child: Text(t.dji_live_obstacle_sample),
                ),
              ],
              CheckedPopupMenuItem(
                key: const Key('dji_watch_lowest_delay'),
                value: 'lowestDelay',
                checked: lowestDelay,
                child: Text(t.dji_live_watch_lowest_delay),
              ),
              PopupMenuItem(value: 'safety', child: Text(t.dji_live_safety_again)),
              PopupMenuItem(value: 'diagnostics', child: Text(t.dji_live_diagnostics)),
            ],
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 840;
          if (wide) {
            return Column(
              children: [
                const DjiLinkObserverNote(),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 2, child: ListView(padding: const EdgeInsets.all(16), children: [phones])),
                      Expanded(flex: 3, child: ListView(padding: const EdgeInsets.all(16), children: [picture])),
                    ],
                  ),
                ),
              ],
            );
          }
          return ListView(
            children: [
              const DjiLinkObserverNote(),
              Padding(padding: const EdgeInsets.all(16), child: picture),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: phones),
            ],
          );
        },
      ),
    );
  }

  /// The phones that send on this network, and the typed address under them
  Widget _phones(Translations t, DjiRelayState relay) {
    final small = context.textTheme.bodySmall;
    final connectError = relay.connectError;
    final error = _addressError ?? (connectError == null ? null : djiRelayConnectErrorText(t, connectError));
    return Column(
      key: const Key('dji_watch_phones'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.dji_live_watch_phones, style: context.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        if (relay.phones.isEmpty)
          Text(t.dji_live_watch_none, key: const Key('dji_watch_none'), style: small)
        else
          for (final phone in relay.phones)
            ListTile(
              key: ValueKey('dji_watch_phone_${phone.address}'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.smartphone_rounded),
              title: Text(phone.name),
              subtitle: Text(_phoneLine(t, relay, phone)),
              selected: relay.target?.address == phone.address,
              trailing: relay.target?.address == phone.address ? const Icon(Icons.visibility_rounded) : null,
              onTap: () => unawaited(_watch(phone)),
            ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              error,
              key: const Key('dji_watch_error'),
              style: small?.copyWith(color: context.colorScheme.error),
            ),
          ),
        ExpansionTile(
          key: const Key('dji_watch_address'),
          tilePadding: EdgeInsets.zero,
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          title: Text(t.dji_live_watch_address, style: context.textTheme.bodyMedium),
          children: [
            TextField(
              key: const Key('dji_watch_address_field'),
              controller: _address,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: t.dji_link_receive_address,
                hintText: '192.168.1.23:$djiRelayDefaultPort',
                isDense: true,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => unawaited(_watchTyped()),
            ),
            const SizedBox(height: 8),
            FilledButton(
              key: const Key('dji_watch_address_watch'),
              onPressed: () => unawaited(_watchTyped()),
              child: Text(t.dji_live_watch),
            ),
            const SizedBox(height: 8),
          ],
        ),
        Text(t.dji_link_receive_not_encrypted, style: small),
      ],
    );
  }

  String _phoneLine(Translations t, DjiRelayState relay, DjiRelayPhone phone) {
    if (relay.target?.address == phone.address) {
      return t.dji_live_watch_watching;
    }
    final id = phone.id;
    return id != null && relay.rememberedCodes.containsKey(id) ? t.dji_live_watch_tap : t.dji_live_watch_code_needed;
  }

  /// The picture with the strip over it, where it stands, the gated values, the delay, and the flight view
  Widget _picture(Translations t, DjiRelayState relay, DjiLinkSnapshot? snapshot, {required bool horizonOs}) {
    final receiving = snapshot?.relayReceiving;
    final decode = snapshot?.videoDecode;
    final source = snapshot?.source;
    final small = context.textTheme.bodySmall;
    // The reception while it is under way, null while idle
    final active = receiving != null && receiving.state != DjiRelayReceiveState.idle ? receiving : null;
    final shows = djiLinkPictureFlows(decode) && !djiLinkRelayPictureStopped(snapshot);
    final flowing =
        receiving != null && receiving.state == DjiRelayReceiveState.receiving && djiLinkPictureFlows(decode);
    final delay = djiLinkDelayNowMs(receiving);
    final replay = source?.replay ?? false;
    return Column(
      key: const Key('dji_watch_picture'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: djiLinkVideoAspect(decode),
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Colors.black),
              if (shows) const DjiLinkVideoSurface(),
              // The obstacle ring over the picture, as the phone's: nothing while nothing is close
              const DjiObstacleRing(),
              if (active != null)
                Positioned(
                  left: 8,
                  top: 8,
                  right: 8,
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 520),
                      child: DjiLinkReceiveStrip(receiving: active),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        if (active != null) ...[
          Text(
            djiRelayReceiveStateText(t, active),
            key: const Key('dji_watch_state'),
            style: small?.copyWith(fontWeight: FontWeight.w700),
          ),
          if (active.state == DjiRelayReceiveState.lost && active.failures >= djiWatchStillTryingFailures)
            Text(t.dji_live_watch_still_trying, key: const Key('dji_watch_still_trying'), style: small),
        ],
        if (replay) ...[
          Text(
            t.dji_live_capture_playing(name: source?.name ?? '-'),
            key: const Key('dji_watch_capture'),
            style: small,
          ),
          TextButton(
            key: const Key('dji_watch_capture_stop'),
            onPressed: () => unawaited(_notifier.stopPlayback()),
            child: Text(t.dji_link_play_stop),
          ),
        ],
        const Padding(padding: EdgeInsets.only(top: 4), child: DjiWatchCells()),
        if (active != null && delay != null)
          Text(t.dji_live_quest_delay(ms: delay.toStringAsFixed(0)), key: const Key('dji_watch_delay'), style: small),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (horizonOs)
              FilledButton.icon(
                key: const Key('dji_link_flight_view_open'),
                icon: const Icon(Icons.view_in_ar_rounded),
                label: Text(t.dji_link_flight_view_open),
                onPressed: flowing ? () => unawaited(_relay.openFlightView(djiFlightViewLabels(t))) : null,
              ),
            OutlinedButton(
              key: const Key('dji_watch_stop'),
              onPressed: active != null || relay.target != null ? () => unawaited(_relay.disconnect()) : null,
              child: Text(t.dji_live_watch_stop),
            ),
          ],
        ),
        if (horizonOs) Text(t.dji_link_flight_view_note, style: small),
        if (relay.flightViewFailed || (snapshot?.flightViewFailed ?? false))
          Text(
            t.dji_link_flight_view_failed,
            key: const Key('dji_link_flight_view_failed'),
            style: small?.copyWith(color: context.colorScheme.error),
          ),
      ],
    );
  }
}

/// The code of a phone, asked once per phone (6.2): the pairing alphabet, normalised; "Watch" closes the dialog with
/// the code, Cancel with nothing
class DjiWatchCodeDialog extends StatefulWidget {
  const DjiWatchCodeDialog({super.key, required this.phoneName, this.wrong = false});

  final String phoneName;

  /// The phone refused the remembered code, or made a new one
  final bool wrong;

  @override
  State<DjiWatchCodeDialog> createState() => _DjiWatchCodeDialogState();
}

class _DjiWatchCodeDialogState extends State<DjiWatchCodeDialog> {
  final _code = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _submit() {
    final code = normalizePairingCode(_code.text);
    if (code == null) {
      setState(() => _error = context.t.dji_link_receive_code_invalid);
      return;
    }
    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final small = context.textTheme.bodySmall;
    final error = _error ?? (widget.wrong ? t.dji_link_receive_state_wrong_code : null);
    return AlertDialog(
      key: const Key('dji_watch_code_dialog'),
      title: Text(t.dji_live_watch_code_title(phone: widget.phoneName)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('dji_watch_code'),
            controller: _code,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [LengthLimitingTextInputFormatter(14)],
            style: const TextStyle(fontFamily: 'GoogleSansCode', fontSize: 22, letterSpacing: 2),
            decoration: const InputDecoration(hintText: 'K7M2Q 9XRTH', border: OutlineInputBorder()),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 8),
          Text(t.dji_live_watch_code_note, style: small),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                error,
                key: const Key('dji_watch_code_error'),
                style: small?.copyWith(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.cancel)),
        FilledButton(key: const Key('dji_watch_code_watch'), onPressed: _submit, child: Text(t.dji_live_watch)),
      ],
    );
  }
}
