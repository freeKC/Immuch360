// The DJI live video on a phone (p2/design-ux-phone-2026-10-24.md, section 3): one full screen, landscape, that is
// the connect screen until the picture comes and the flight screen after. While no picture shows, its middle is one
// step card; then the drone's picture fills the screen, with Back, Send to a headset and Advanced in the band on its
// left and the state of the picture and the gated values in the band on its right. Nothing in the picture is a control:
// a tap anywhere only brings the warnings back for five seconds (FreeKC's rule of 25 October: they come and fade,
// dji_live_transient.dart), and the screen stays on for as long as it is in front.
//
// Receive only: the phone never replaces the remote's sticks. The link writes nothing but the one byte probe of the USB
// transport, and nothing on this screen can move the drone. The safety notice shows once per run of the app, and
// everything the link gives stays one tap away in Advanced, Diagnostics.

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_video.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_advanced.panel.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_fields.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_notice.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_obstacle.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_overlay.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_send.panel.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_stage.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_steps.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_transient.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';
import 'package:immich_mobile/providers/drone/dji_live_frame.provider.dart';
import 'package:immich_mobile/providers/drone/dji_relay.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/system_ui.utils.dart';

/// A band beside the picture narrower than this cannot hold the buttons: they go over the picture's edges instead
const djiLiveBandMin = 64.0;

/// The width of a panel opened from the right edge, the picture staying in sight on the left
const djiLivePanelWidth = 360.0;

/// The panels of the live screen
enum DjiLivePanel { send, advanced }

@RoutePage()
class DjiLivePage extends ConsumerStatefulWidget {
  const DjiLivePage({super.key});

  @override
  ConsumerState<DjiLivePage> createState() => _DjiLivePageState();
}

class _DjiLivePageState extends ConsumerState<DjiLivePage> {
  late final DjiLinkNotifier _notifier;
  late final DjiRelayNotifier _relay;
  late final DjiLiveMemory _memory;
  Timer? _ticker;

  /// Seconds since the screen opened, counted by [_ticker]
  int _ticks = 0;
  DjiLiveStage _stage = DjiLiveStage.checking;
  int _stageSince = 0;

  /// A remote was open, and a live picture showed, earlier in this session
  bool _hadRemote = false;
  bool _hadPicture = false;

  /// The drone answered earlier in this session: it may be in the air, whatever the stage now
  bool _droneSeen = false;
  int _lostPictures = 0;
  int _lostAt = -100;
  DjiLivePanel? _panel;

  /// A previous session of this install showed a live picture, and the offer was not answered yet
  bool _offerable = false;
  bool _pictureKept = false;

  /// A tap on the picture brings the warnings back for five seconds
  final _recall = DjiTransientRecall();

  @override
  void initState() {
    super.initState();
    _notifier = ref.read(djiLinkProvider.notifier);
    _relay = ref.read(djiRelayProvider.notifier);
    _memory = ref.read(djiLiveMemoryProvider);
    _pictureKept = _memory.read(StoreKey.djiLivePictureSeen);
    _offerable = _pictureKept && !_memory.read(StoreKey.djiLiveOfferAnswered);
    unawaited(_enterScreen());
    // After the first frame: reading the environment changes the state, which a build under way must not see
    unawaited(Future.microtask(() => _notifier.pageShown(capture: true)));
    unawaited(Future.microtask(_relay.loadCode));
    unawaited(Future.microtask(() => _relay.setPageVisible(true)));
    unawaited(Future.microtask(() => _relay.setLiveScreenShown(true)));
    // The values ten times a second while this screen is in front, and the obstacle ring as the pilot set it
    unawaited(Future.microtask(() => _notifier.setFrameStream(true)));
    unawaited(Future.microtask(() => ref.read(djiObstacleSettingsProvider.notifier).sync()));
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_noticeOnce()));
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _recall.dispose();
    // The relay keeps sending without the screen; only the screen is no longer kept on for it, and nothing beeps
    unawaited(_notifier.setFrameStream(false));
    unawaited(_relay.setLiveScreenShown(false));
    unawaited(_relay.setPageVisible(false));
    unawaited(_notifier.pageHidden());
    unawaited(_leaveScreen());
    super.dispose();
  }

  /// Landscape both ways and no system bars, as the camera's full screen
  static Future<void> _enterScreen() async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  }

  static Future<void> _leaveScreen() async {
    // Not edgeToEdge alone: on Android 15 and later it leaves the bars that immersiveSticky hid hidden
    await restoreEdgeToEdge();
    await SystemChrome.setPreferredOrientations(const []);
  }

  void _tick() {
    _ticks += 1;
    // The "Nothing yet?" hints follow the time spent on a step, with no snapshot needed
    if (mounted && (_stage == DjiLiveStage.plug || _stage == DjiLiveStage.remote || _stage == DjiLiveStage.drone)) {
      setState(() {});
    }
  }

  /// The safety notice, once per run of the app; Back on it leaves this screen
  Future<void> _noticeOnce() async {
    if (!mounted || ref.read(djiLiveNoticeReadProvider)) {
      return;
    }
    final read = await showDjiLiveNotice(
      context,
      headset: false,
      remote: ref.read(tvModeProvider),
      alert: _alertOffered(),
    );
    if (!mounted) {
      return;
    }
    if (read) {
      ref.read(djiLiveNoticeReadProvider.notifier).state = true;
    } else {
      Navigator.of(context).pop();
    }
  }

  /// Follows the stage, the time spent in it, and what this session has seen; called from build
  void _follow(DjiLiveStage stage, DjiLinkSnapshot? snapshot) {
    if (stage != _stage) {
      _stage = stage;
      _stageSince = _ticks;
    }
    if (djiLiveRemoteOpen(stage)) {
      _hadRemote = true;
    }
    if (stage == DjiLiveStage.drone || stage == DjiLiveStage.live || stage == DjiLiveStage.noPicture) {
      _droneSeen = true;
    }
    if (stage == DjiLiveStage.live) {
      _hadPicture = true;
      if (!_pictureKept) {
        _pictureKept = true;
        unawaited(Future.microtask(() => _memory.write(StoreKey.djiLivePictureSeen, true)));
      }
    }
    final lost = snapshot?.videoDecode?.lostPictures ?? 0;
    if (lost > _lostPictures) {
      _lostAt = _ticks;
    }
    _lostPictures = lost;
  }

  Future<void> _answerOffer(bool yes) async {
    setState(() => _offerable = false);
    if (yes) {
      await _notifier.setOpenOnPlug(true);
    }
    await _memory.write(StoreKey.djiLiveOfferAnswered, true);
  }

  /// Back: a panel closes first; once a picture showed in this session the pilot is asked, whatever the stage (a
  /// picture lost in flight, a lost cable link, an unplug: the moments Back is pressed by reflex); before that the
  /// screen goes at once
  Future<void> _onBack() async {
    if (_panel != null) {
      setState(() => _panel = null);
      return;
    }
    if (_hadPicture && !await _confirmLeave()) {
      return;
    }
    if (mounted) {
      _leave();
    }
  }

  Future<bool> _confirmLeave() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('dji_live_leave_dialog'),
        title: Text(context.t.dji_live_leave_question),
        content: Text(context.t.dji_live_leave_note),
        actions: [
          TextButton(
            key: const Key('dji_live_stay'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.t.dji_live_stay),
          ),
          TextButton(
            key: const Key('dji_live_leave'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.t.dji_live_leave),
          ),
        ],
      ),
    );
    return leave ?? false;
  }

  /// Leaving while sending keeps sending, and says so once on the page underneath
  void _leave() {
    if (ref.read(djiRelayProvider).sending) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.t.dji_live_leave_sending)));
    }
    Navigator.of(context).pop();
  }

  void _open(DjiLivePanel panel) => setState(() => _panel = _panel == panel ? null : panel);

  Future<void> _safetyAgain() async {
    setState(() => _panel = null);
    await showDjiLiveNotice(context, headset: false, remote: ref.read(tvModeProvider), alert: _alertOffered());
  }

  /// The obstacle ring is offered on this device: the notice then says it never steers or stops the drone
  bool _alertOffered() => ref.read(djiObstacleSettingsProvider).offered(djiObstacleOffer());

  /// Diagnostics turns freely and shows the system bars; the live screen takes landscape again when it comes back
  Future<void> _openDiagnostics() async {
    setState(() => _panel = null);
    await _leaveScreen();
    if (!mounted) {
      return;
    }
    await context.pushRoute(const DjiLinkRoute());
    if (mounted) {
      await _enterScreen();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final state = ref.watch(djiLinkProvider);
    final relay = ref.watch(djiRelayProvider);
    final snapshot = state.snapshot;
    final stage = djiLiveStage(state, hadRemote: _hadRemote, hadPicture: _hadPicture);
    _follow(stage, snapshot);
    // A received stream is never relayed, and a headset does not send
    final sends = state.environment?.flavour == 'phone' && !(snapshot?.source?.relay ?? false);
    final panel = _panel;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          unawaited(_onBack());
        }
      },
      child: Scaffold(
        key: const Key('dji_live'),
        backgroundColor: Colors.black,
        body: DjiTransientScope(
          recall: _recall,
          // A tap anywhere brings the warnings back; it goes on to what is under it (a button, a step card's button)
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => _recall.recall(),
            child: LayoutBuilder(
              builder: (context, constraints) => Stack(
                children: [
                  ..._frame(t, constraints.biggest, state, stage, sends, relay),
                  if (panel != null) ...[
                    Positioned.fill(
                      child: GestureDetector(
                        key: const Key('dji_live_scrim'),
                        behavior: HitTestBehavior.opaque,
                        onTap: () => setState(() => _panel = null),
                        child: const ColoredBox(color: Color(0x66000000)),
                      ),
                    ),
                    Positioned(
                      top: 0,
                      bottom: 0,
                      right: 0,
                      width: constraints.maxWidth < djiLivePanelWidth ? constraints.maxWidth : djiLivePanelWidth,
                      child: Material(
                        child: SafeArea(
                          left: false,
                          child: switch (panel) {
                            DjiLivePanel.send => const DjiLiveSendPanel(),
                            DjiLivePanel.advanced => DjiLiveAdvancedPanel(
                              onSafety: () => unawaited(_safetyAgain()),
                              onDiagnostics: () => unawaited(_openDiagnostics()),
                            ),
                          },
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The picture in its 16:9 place, with the step card while it does not show, and the two columns beside it
  List<Widget> _frame(
    Translations t,
    Size size,
    DjiLinkPageState state,
    DjiLiveStage stage,
    bool sends,
    DjiRelayState relay,
  ) {
    final snapshot = state.snapshot;
    final decode = snapshot?.videoDecode;
    final aspect = djiLinkVideoAspect(decode);
    var pictureWidth = size.width;
    var pictureHeight = pictureWidth / aspect;
    if (pictureHeight > size.height) {
      pictureHeight = size.height;
      pictureWidth = pictureHeight * aspect;
    }
    final band = (size.width - pictureWidth) / 2;
    final banded = band >= djiLiveBandMin;
    final columnWidth = banded ? band : djiLiveEdgeWidth;
    final source = snapshot?.source;
    final capture = stage == DjiLiveStage.capture;
    final showPicture = (stage == DjiLiveStage.live || capture) && djiLinkPictureFlows(decode);
    // A capture says so under its name: no Live chip over a picture that is not live
    final picture = !capture && (showPicture || stage == DjiLiveStage.noPicture)
        ? djiLivePicture(decode, lostRecently: _ticks - _lostAt < 5)
        : DjiLivePicture.none;
    final ago = decode?.lastOutputAgoMs;
    final card = djiLiveCardText(
      t,
      stage,
      seconds: _ticks - _stageSince,
      djiFly: state.environment?.djiApplicationInstalled ?? false,
      untried: snapshot?.profile != null && snapshot?.profile?.id != 'rc-n3-neo2',
      remoteAnswers: snapshot?.state == DjiLinkState.controllerIdentified,
      aircraftPresent: snapshot?.telemetryValues?.aircraftPresent ?? false,
      droneSeen: _droneSeen,
    );
    final headsets = relay.sending ? snapshot?.relaySending?.headsets.length ?? 0 : 0;
    return [
      Positioned(
        left: band,
        top: (size.height - pictureHeight) / 2,
        width: pictureWidth,
        height: pictureHeight,
        child: ColoredBox(
          key: const Key('dji_live_picture_area'),
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _pictureOrCard(stage, state, card, showPicture: showPicture, banded: banded),
              // The obstacle indicator over whatever shows, the picture, "No picture" or a step card: nothing while
              // nothing is close, and it takes no touch
              const DjiObstacleRing(),
            ],
          ),
        ),
      ),
      Positioned(
        left: 0,
        top: 0,
        bottom: 0,
        width: columnWidth,
        child: DecoratedBox(
          decoration: banded ? const BoxDecoration() : djiLiveEdgeShade(left: true),
          child: SafeArea(
            right: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: DjiLiveButtons(
                onBack: () => unawaited(Navigator.of(context).maybePop()),
                onAdvanced: () => _open(DjiLivePanel.advanced),
                onSend: sends ? () => _open(DjiLivePanel.send) : null,
                headsets: headsets,
              ),
            ),
          ),
        ),
      ),
      Positioned(
        right: 0,
        top: 0,
        bottom: 0,
        width: columnWidth,
        child: DecoratedBox(
          decoration: banded ? const BoxDecoration() : djiLiveEdgeShade(left: false),
          child: SafeArea(
            left: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
              child: DjiLiveReadout(
                picture: picture,
                staleSeconds: ago == null ? null : (ago / 1000).toStringAsFixed(1),
                captureName: capture ? source?.name ?? '-' : null,
                onStopCapture: () => unawaited(_notifier.stopPlayback()),
              ),
            ),
          ),
        ),
      ),
    ];
  }

  /// The drone's picture, or the step card while it does not show
  Widget _pictureOrCard(
    DjiLiveStage stage,
    DjiLinkPageState state,
    DjiLiveCardText? card, {
    required bool showPicture,
    required bool banded,
  }) {
    if (showPicture) {
      return const DjiLinkVideoSurface();
    }
    if (card == null) {
      return const SizedBox.expand();
    }
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: banded ? 0 : djiLiveEdgeWidth),
      child: Center(
        child: DjiLiveStepCard(
          stage: stage,
          text: card,
          // A start that failed starts again; a lost link asks the native side to try at once
          onRetry: () => unawaited(
            stage == DjiLiveStage.failed ? _notifier.pageShown(capture: true) : _notifier.retry(),
          ),
          offer: stage == DjiLiveStage.plug && _offerable && !state.openOnPlug,
          onOfferYes: () => unawaited(_answerOffer(true)),
          onOfferNo: () => unawaited(_answerOffer(false)),
        ),
      ),
    );
  }
}
