// The watch page of the DJI live video on Android TV and Google TV (p2/design-tv-2026-10-24.md, sections 2 to 5): a
// spectator screen driven by the remote. Two views of one page. The phones view lists the phones that send the drone's
// picture on this network, with the picture in its box or the card "Let this TV watch" (this TV's own code in two
// groups of five and its QR code, for the phone's "Add a TV"). The full screen view shows the picture edge to edge, the
// values on dark plates at its sides inside the TV's safe area, and a strip with the delay from the phone. Where the
// picture comes from, "Watching only" and the observer rule show for five seconds when the view opens, when they
// change and after any key, then fade (dji_live_transient.dart); an error that needs an action stays. The obstacle
// indicator shows over the picture in both views, only while something is close (p2/design-obstacle-ring-2026-10-25.md,
// 5.2). One picture box under a GlobalKey moves between the two views,
// so the TV's decoder never changes surface. Nothing here reaches the phone, the remote or the
// drone: OK shows or hides the numbers, Menu, Info or OK held opens Options, Back goes back to the phones.

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/dji_watch_code.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/dji_link_api.g.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_latency.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_observer.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_receive.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_texts.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_video.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_fields.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_obstacle.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_overlay.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_transient.dart';
import 'package:immich_mobile/presentation/widgets/pairing/qr_code.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_keys.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_shell.widget.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';
import 'package:immich_mobile/providers/drone/dji_live_frame.provider.dart';
import 'package:immich_mobile/providers/drone/dji_relay.provider.dart';

/// After this long without a picture, a TV lets its screen saver come and its panel rest (design 3.7)
const djiWatchTvScreenIdle = Duration(minutes: 10);

/// How long the hint of the keys stays
const djiWatchTvHintFor = Duration(seconds: 5);

/// How long after the welcome "no picture yet" becomes "Still no picture"
const djiWatchTvNoPictureLong = Duration(seconds: 5);

/// A value read from the sofa, about 3 m away (design 3.1 and 3.2): the number, its label, and the dark plate under
/// each cell, black at 70 % (about 8.5 to 1 for white text over a white sky)
const djiWatchTvValueSize = 32.0;
const djiWatchTvLabelSize = 16.0;
const djiWatchTvPlate = Color(0xB3000000);
const djiWatchTvColumnWidth = 200.0;

/// The red of the bar beside "Watching only" and of the line of a picture that stopped
const _red = Color(0xFFFF6B6B);

/// Menu and Info open Options, on the phones view and in full screen
final _optionsKeys = {LogicalKeyboardKey.contextMenu, LogicalKeyboardKey.info};

/// The keys that do nothing on a live picture: it is never paused, a paused picture would look live
final _ignoredKeys = {
  ...remotePlayPauseKeys,
  LogicalKeyboardKey.mediaFastForward,
  LogicalKeyboardKey.mediaRewind,
  LogicalKeyboardKey.mediaStop,
  LogicalKeyboardKey.mediaTrackNext,
  LogicalKeyboardKey.mediaTrackPrevious,
  LogicalKeyboardKey.colorF0Red,
  LogicalKeyboardKey.colorF1Green,
  LogicalKeyboardKey.colorF2Yellow,
  LogicalKeyboardKey.colorF3Blue,
  LogicalKeyboardKey.channelUp,
  LogicalKeyboardKey.channelDown,
};

final _arrowKeys = {
  LogicalKeyboardKey.arrowUp,
  LogicalKeyboardKey.arrowDown,
  LogicalKeyboardKey.arrowLeft,
  LogicalKeyboardKey.arrowRight,
};

/// The numbers over the picture are hidden: OK shows or hides them, and the choice stays for the run of the app
final djiWatchTvNumbersHiddenProvider = StateProvider<bool>((_) => false);

/// The state line of the phones view and the first line of the strip: one sentence in plain words, what to do in it
/// (design section 5). [longWait]: the phone welcomed this TV more than [djiWatchTvNoPictureLong] ago and no picture
/// came. [refusedBy]: the phone that refused this TV's own code, which says it does not know this TV yet rather than
/// ask for a code to type.
String djiWatchTvStateLine(
  Translations t,
  DjiRelayReceiving receiving, {
  required bool pictureFlows,
  DjiLinkDecode? decode,
  bool longWait = false,
  String? refusedBy,
}) {
  final failure = decode?.failure;
  if (failure == 'no-decoder') {
    return t.dji_live_tv_decoder_none;
  }
  if (failure == 'configuration-refused' || decode?.switchReason == 'noPictureNothingLeft') {
    return t.dji_live_tv_decoder_refused;
  }
  if (receiving.state == DjiRelayReceiveState.wrongCode && refusedBy != null) {
    return t.dji_live_tv_code_refused(phone: refusedBy);
  }
  final phone = receiving.phoneName ?? receiving.host ?? '-';
  switch (receiving.state) {
    case DjiRelayReceiveState.receiving:
      if (pictureFlows || receiving.phoneSource == 'none') {
        return djiRelayReceiveStateText(t, receiving);
      }
      return longWait ? t.dji_live_tv_no_picture_long : t.dji_live_tv_no_picture(phone: phone);
    case DjiRelayReceiveState.blocked:
      return t.dji_live_tv_blocked;
    case DjiRelayReceiveState.full:
      return t.dji_live_tv_full;
    case DjiRelayReceiveState.lost:
      if (receiving.failures >= djiWatchTvStillTryingFailures) {
        return t.dji_live_tv_still_trying;
      }
      return djiRelayReceiveStateText(t, receiving);
    default:
      return djiRelayReceiveStateText(t, receiving);
  }
}

/// The kind of [djiWatchTvStateLine], in the same order: whether the line comes and goes over the picture or stays
DjiReceiveLine djiWatchTvLine(
  DjiRelayReceiving receiving, {
  required bool pictureFlows,
  DjiLinkDecode? decode,
  bool longWait = false,
  String? refusedBy,
}) {
  final failure = decode?.failure;
  if (failure == 'no-decoder') {
    return DjiReceiveLine.decoderNone;
  }
  if (failure == 'configuration-refused' || decode?.switchReason == 'noPictureNothingLeft') {
    return DjiReceiveLine.decoderRefused;
  }
  if (receiving.state == DjiRelayReceiveState.wrongCode && refusedBy != null) {
    return DjiReceiveLine.codeRefused;
  }
  return switch (receiving.state) {
    DjiRelayReceiveState.receiving when !pictureFlows && receiving.phoneSource != 'none' =>
      longWait ? DjiReceiveLine.stillNoPicture : DjiReceiveLine.waiting,
    DjiRelayReceiveState.lost when receiving.failures >= djiWatchTvStillTryingFailures => DjiReceiveLine.stillTrying,
    _ => djiRelayReceiveLine(receiving),
  };
}

/// After this many failed attempts in a row, the state line says what to check (as the headset's page)
const djiWatchTvStillTryingFailures = 3;

/// The phone ended or refused the connection: a code it does not know (this TV removed there, or a new code), another
/// version, or a phone that did not prove the code. Nothing comes any more: the full screen view gives way to the
/// phones view, which shows the card or asks for the code again.
bool djiWatchTvRefused(DjiRelayReceiveState? state) => switch (state) {
  DjiRelayReceiveState.wrongCode || DjiRelayReceiveState.otherVersion || DjiRelayReceiveState.phoneUnproven => true,
  _ => false,
};

/// The three lines of "Picture and decoder": the decoder with its kind and the choice, the rate and the decode time,
/// the delay and the reason of the last switch; null lines are left out
List<String> djiWatchTvPictureLines(Translations t, DjiLinkDecode? decode, DjiRelayReceiving? receiving) {
  final name = decode?.decoderName;
  final choice = switch (decode?.choice) {
    DjiLinkDecoderChoice.hardware => t.dji_link_video_choice_hardware,
    DjiLinkDecoderChoice.software => t.dji_link_video_choice_software,
    _ => t.dji_link_video_choice_automatic,
  };
  final median = decode?.decodeMedianMs;
  final delay = djiLinkDelayNowMs(receiving);
  final reason = djiLinkSwitchReasonText(t, decode?.switchReason);
  return [
    if (decode == null || name == null)
      t.dji_link_video_decoder_none
    else
      t.dji_live_tv_decoder_line(
        decoder: name,
        kind: decode.decoderHardware == true ? t.dji_live_tv_hardware : t.dji_live_tv_software,
        choice: choice,
      ),
    if (decode != null && name != null)
      t.dji_live_tv_decoder_rate(
        pictures: decode.picturesPerSecond.toStringAsFixed(0),
        ms: median == null ? '-' : median.toStringAsFixed(1),
      ),
    if (delay != null) t.dji_live_quest_delay(ms: delay.toStringAsFixed(0)),
    ?reason,
  ];
}

/// The TV layout of the watch page. The page keeps the session (browse, connect by itself, the codes, the screen, the
/// app going to the background); this draws it for the remote and hands each choice back.
class DjiWatchTvView extends ConsumerStatefulWidget {
  const DjiWatchTvView({
    super.key,
    required this.onWatch,
    required this.onTypeCode,
    required this.onTypeAddress,
    required this.onMenu,
    this.addressError,
  });

  /// OK on a phone row that is not shown full screen: watch it, with its remembered code or this TV's own
  final ValueChanged<DjiRelayPhone> onWatch;

  /// "Type the phone's code instead", for that phone
  final ValueChanged<DjiRelayPhone> onTypeCode;

  /// "Phone not listed? Type its address"
  final VoidCallback onTypeAddress;

  /// A choice of Options the page carries out: ring, sound, testSound, ringNumbers, shape, sample, safety, diagnostics,
  /// record, newCode, stop.
  /// "Type the phone's code instead" goes to [onTypeCode] with the phone watched, else the row focused last.
  final ValueChanged<String> onMenu;

  /// The typed address was not one of a phone of this network
  final String? addressError;

  @override
  ConsumerState<DjiWatchTvView> createState() => _DjiWatchTvViewState();
}

class _DjiWatchTvViewState extends ConsumerState<DjiWatchTvView> {
  /// The one picture box, moved between the two views: its platform view is never made again for the move
  final _pictureKey = GlobalKey(debugLabel: 'dji_watch_tv_picture');
  final _fullFocus = FocusNode(debugLabel: 'dji_watch_tv_full');

  /// The row the focus starts on (the phone watched, else one with a code here, else the first), and "Phone not
  /// listed?", which has it while no phone is listed
  final _rowFocus = FocusNode(debugLabel: 'dji_watch_tv_row');
  final _addressFocus = FocusNode(debugLabel: 'dji_watch_tv_address');

  bool _fullScreen = false;
  bool _hint = false;
  Timer? _hintTimer;

  /// Any key brings the warnings back for five seconds
  final _recall = DjiTransientRecall();

  /// OK down in full screen: held [remoteOkHoldForDetails], it opens Options; released before, it shows or hides the
  /// numbers. What is left of a held OK (its repeats, its release) is dropped once Options opened.
  Timer? _okHold;
  bool _dropHeldOk = false;
  bool _optionsOpen = false;

  /// The phone whose first picture of this connection already opened the full screen view
  String? _enteredFor;

  /// The phone row that had the focus last, for "Type the phone's code instead"
  DjiRelayPhone? _focusedPhone;

  Timer? _longWaitTimer;
  bool _longWait = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_dropRestOfHeldOk);
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_dropRestOfHeldOk);
    _hintTimer?.cancel();
    _okHold?.cancel();
    _longWaitTimer?.cancel();
    _recall.dispose();
    _fullFocus.dispose();
    _rowFocus.dispose();
    _addressFocus.dispose();
    super.dispose();
  }

  /// After the next frame, the focus on the first phone row, unless the remote already moved it elsewhere than "Phone
  /// not listed?"
  void _focusRowAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _fullScreen || _rowFocus.context == null) {
        return;
      }
      final primary = FocusManager.instance.primaryFocus;
      if (primary == null || identical(primary, _addressFocus) || primary is FocusScopeNode) {
        _rowFocus.requestFocus();
      }
    });
  }

  KeyEventResult _dropRestOfHeldOk(KeyEvent event) {
    if (!_dropHeldOk || !remoteOkKeys.contains(event.logicalKey)) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) {
      // A new press: that release never came
      _dropHeldOk = false;
      return KeyEventResult.ignored;
    }
    if (event is KeyUpEvent) {
      _dropHeldOk = false;
    }
    return KeyEventResult.handled;
  }

  void _enterFullScreen() {
    if (_fullScreen || !mounted) {
      return;
    }
    setState(() => _fullScreen = true);
    _showHint();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _fullScreen) {
        _fullFocus.requestFocus();
      }
    });
  }

  void _leaveFullScreen() {
    _hintTimer?.cancel();
    _okHold?.cancel();
    _okHold = null;
    setState(() {
      _fullScreen = false;
      _hint = false;
    });
    _focusRowAfterFrame();
  }

  void _showHint() {
    _hintTimer?.cancel();
    if (!_hint) {
      setState(() => _hint = true);
    }
    _hintTimer = Timer(djiWatchTvHintFor, () {
      if (mounted) {
        setState(() => _hint = false);
      }
    });
  }

  void _toggleNumbers() {
    final hidden = ref.read(djiWatchTvNumbersHiddenProvider.notifier);
    hidden.state = !hidden.state;
  }

  KeyEventResult _onFullKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (event is KeyDownEvent) {
      _recall.recall();
    }
    if (remoteOkKeys.contains(key)) {
      if (event is KeyDownEvent) {
        _okHold?.cancel();
        _okHold = Timer(remoteOkHoldForDetails, () {
          _okHold = null;
          _dropHeldOk = true;
          unawaited(_openOptions());
        });
      } else if (event is KeyUpEvent) {
        final hold = _okHold;
        _okHold = null;
        if (hold != null && hold.isActive) {
          hold.cancel();
          _toggleNumbers();
        }
      }
      // The repeats of a held OK change nothing
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) {
      return _optionsKeys.contains(key) || _arrowKeys.contains(key) || _ignoredKeys.contains(key)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (_optionsKeys.contains(key)) {
      unawaited(_openOptions());
      return KeyEventResult.handled;
    }
    if (_arrowKeys.contains(key)) {
      _showHint();
      return KeyEventResult.handled;
    }
    if (_ignoredKeys.contains(key)) {
      return KeyEventResult.handled;
    }
    // Back goes to the page's PopScope, the volume to the TV
    return KeyEventResult.ignored;
  }

  /// Menu and Info on the phones view, from whatever row has the focus. A held OK chooses once: its repeats would
  /// start the connection again at the repeat rate, each a wrong proof on a phone that does not know this TV.
  KeyEventResult _onPhonesKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent) {
      _recall.recall();
    }
    if (event is KeyRepeatEvent && remoteOkKeys.contains(event.logicalKey)) {
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent && _optionsKeys.contains(event.logicalKey)) {
      unawaited(_openOptions());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _openOptions() async {
    if (_optionsOpen || !mounted) {
      return;
    }
    _optionsOpen = true;
    final String? choice;
    try {
      choice = await showGeneralDialog<String>(
        context: context,
        barrierDismissible: true,
        barrierLabel: context.t.dji_live_tv_options,
        barrierColor: const Color(0x66000000),
        pageBuilder: (_, _, _) => const DjiWatchTvOptions(),
      );
    } finally {
      _optionsOpen = false;
    }
    if (choice == null || !mounted) {
      return;
    }
    switch (choice) {
      case 'numbers':
        _toggleNumbers();
      case 'typeCode':
        final phone = _phoneForCode(ref.read(djiRelayProvider));
        if (phone != null) {
          widget.onTypeCode(phone);
        }
      case 'stop':
        if (_fullScreen) {
          _leaveFullScreen();
        }
        widget.onMenu(choice);
      default:
        widget.onMenu(choice);
    }
  }

  void _onPhone(DjiRelayPhone phone, {required bool shows}) {
    final relay = ref.read(djiRelayProvider);
    if (relay.target?.address == phone.address && shows) {
      _enteredFor = phone.address;
      _enterFullScreen();
      return;
    }
    widget.onWatch(phone);
  }

  /// "Still no picture" once the phone welcomed this TV [djiWatchTvNoPictureLong] ago without a picture
  void _followWait(bool waiting) {
    if (!waiting) {
      _longWaitTimer?.cancel();
      _longWaitTimer = null;
      if (_longWait) {
        setState(() => _longWait = false);
      }
      return;
    }
    if (_longWaitTimer != null || _longWait) {
      return;
    }
    _longWaitTimer = Timer(djiWatchTvNoPictureLong, () {
      _longWaitTimer = null;
      if (mounted) {
        setState(() => _longWait = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // The first picture of a connection opens the full screen view, once per phone watched
    ref.listen<bool>(djiLinkProvider.select((state) => _picturesShow(state.snapshot)), (previous, next) {
      final target = ref.read(djiRelayProvider).target?.address;
      if (next && previous != true && target != null && _enteredFor != target) {
        _enteredFor = target;
        _enterFullScreen();
      }
    });
    ref.listen<bool>(
      djiLinkProvider.select(
        (state) =>
            state.snapshot?.relayReceiving?.state == DjiRelayReceiveState.receiving &&
            !djiLinkPictureFlows(state.snapshot?.videoDecode),
      ),
      (_, waiting) => _followWait(waiting),
    );
    // The first phone listed takes the focus from "Phone not listed?"
    ref.listen<bool>(djiRelayProvider.select((relay) => relay.phones.isNotEmpty), (previous, listed) {
      if (listed && previous != true) {
        _focusRowAfterFrame();
      }
    });
    // A phone no longer watched: its next first picture opens the full screen view again
    ref.listen<String?>(djiRelayProvider.select((relay) => relay.target?.address), (_, next) {
      if (next == null) {
        _enteredFor = null;
        if (_fullScreen) {
          _leaveFullScreen();
        }
      }
    });
    // The phone removed this TV, or refused it: the phones view with the card (or the code asked again), never a black
    // full screen; the next welcome opens the full screen view again
    final refusedNow = djiLinkProvider.select((state) => djiWatchTvRefused(state.snapshot?.relayReceiving?.state));
    ref.listen<bool>(refusedNow, (previous, refused) {
      if (refused && previous != true) {
        _enteredFor = null;
        if (_fullScreen) {
          _leaveFullScreen();
        }
      }
    });
    ref.listen<bool>(djiRelayProvider.select((relay) => relay.ownCodeCardShows), (previous, card) {
      if (card && previous != true && _fullScreen) {
        _leaveFullScreen();
      }
    });
    final relay = ref.watch(djiRelayProvider);
    final snapshot = ref.watch(djiLinkProvider.select((state) => state.snapshot));
    final decode = snapshot?.videoDecode;
    final receiving = snapshot?.relayReceiving;
    final active = receiving != null && receiving.state != DjiRelayReceiveState.idle ? receiving : null;
    final shows = _picturesShow(snapshot);
    final picture = KeyedSubtree(
      key: _pictureKey,
      child: AspectRatio(
        aspectRatio: djiLinkVideoAspect(decode),
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Colors.black),
            if (shows) const DjiLinkVideoSurface(),
            // The obstacle ring over the picture, in both views: nothing while nothing is close
            const DjiWatchTvRing(),
          ],
        ),
      ),
    );
    return DjiTransientScope(
      recall: _recall,
      child: PopScope(
        // Back in full screen goes to the phones view, still receiving; on the phones view it leaves the page
        canPop: !_fullScreen,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && _fullScreen) {
            _leaveFullScreen();
          }
        },
        child: Scaffold(
          key: const Key('dji_watch'),
          backgroundColor: _fullScreen ? Colors.black : null,
          body: _fullScreen
              ? _fullScreenView(t, relay, active, decode, picture, shows: shows)
              : _phonesView(t, relay, active, decode, picture, shows: shows),
        ),
      ),
    );
  }

  bool _picturesShow(DjiLinkSnapshot? snapshot) =>
      djiLinkPictureFlows(snapshot?.videoDecode) && !djiLinkRelayPictureStopped(snapshot);

  /// The TV's safe area: at least the overscan margins of the TV guidelines, whatever the layout above says
  EdgeInsets _safe(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    const overscan = TvShell.overscan;
    return EdgeInsets.fromLTRB(
      max(padding.left, overscan.left),
      max(padding.top, overscan.top),
      max(padding.right, overscan.right),
      max(padding.bottom, overscan.bottom),
    );
  }

  // The phones view

  Widget _phonesView(
    Translations t,
    DjiRelayState relay,
    DjiRelayReceiving? active,
    DjiLinkDecode? decode,
    Widget picture, {
    required bool shows,
  }) {
    final card = relay.ownCodeCardShows && !shows;
    final focusTarget = _phoneToFocus(relay);
    return Focus(
      // Not a stop of its own: it only hears Menu and Info from the row that has the focus
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onPhonesKey,
      child: Padding(
        padding: _safe(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    t.dji_live_title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 16),
                OutlinedButton.icon(
                  key: const Key('dji_watch_tv_options'),
                  icon: const Icon(Icons.tune_rounded),
                  label: Text(t.dji_live_tv_options),
                  onPressed: () => unawaited(_openOptions()),
                ),
              ],
            ),
            const DjiLinkObserverNote(tv: true, transient: true),
            const SizedBox(height: 8),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 2, child: _phones(t, relay, focusTarget, shows: shows)),
                  const SizedBox(width: 24),
                  Expanded(
                    flex: 3,
                    // Built at once, not lazily: the picture box moves in and out of it with its GlobalKey
                    child: SingleChildScrollView(
                      key: const Key('dji_watch_tv_right'),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (card)
                            _codeCard(t, relay)
                          else if (relay.phones.isEmpty && relay.target == null)
                            Text(
                              t.dji_live_tv_none,
                              key: const Key('dji_watch_none'),
                              style: context.textTheme.bodyLarge,
                            )
                          else
                            AspectRatio(aspectRatio: djiLinkVideoAspect(decode), child: picture),
                          const SizedBox(height: 8),
                          ..._stateLines(t, relay, active, decode, shows: shows, card: card),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The row the focus starts on: the phone watched, else one with a code here, else the first
  DjiRelayPhone? _phoneToFocus(DjiRelayState relay) {
    final phones = relay.phones;
    if (phones.isEmpty) {
      return null;
    }
    final target = relay.target?.address;
    return phones.where((phone) => phone.address == target).firstOrNull ??
        phones.where((phone) => phone.id != null && relay.rememberedCodes.containsKey(phone.id)).firstOrNull ??
        phones.first;
  }

  Widget _phones(Translations t, DjiRelayState relay, DjiRelayPhone? focusTarget, {required bool shows}) {
    final small = context.textTheme.bodyMedium;
    final connectError = relay.connectError;
    final error = widget.addressError ?? (connectError == null ? null : djiRelayConnectErrorText(t, connectError));
    final typeFor = _phoneForCode(relay);
    return ListView(
      key: const Key('dji_watch_phones'),
      children: [
        Text(t.dji_live_watch_phones, style: context.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        for (final phone in relay.phones)
          ListTile(
            key: ValueKey('dji_watch_phone_${phone.address}'),
            focusNode: identical(phone, focusTarget) ? _rowFocus : null,
            autofocus: identical(phone, focusTarget),
            leading: const Icon(Icons.smartphone_rounded),
            title: Text(phone.name, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(_phoneLine(t, relay, phone)),
            selected: relay.target?.address == phone.address,
            trailing: relay.target?.address == phone.address ? const Icon(Icons.visibility_rounded) : null,
            onFocusChange: (focused) {
              if (focused) {
                _focusedPhone = phone;
              }
            },
            onTap: () => _onPhone(phone, shows: shows),
          ),
        ListTile(
          key: const Key('dji_watch_address'),
          focusNode: _addressFocus,
          autofocus: focusTarget == null,
          leading: const Icon(Icons.edit_rounded),
          title: Text(t.dji_live_watch_address),
          onTap: widget.onTypeAddress,
        ),
        if (typeFor != null)
          ListTile(
            key: const Key('dji_watch_tv_type_code'),
            leading: const Icon(Icons.password_rounded),
            title: Text(t.dji_live_tv_type_code),
            onTap: () => widget.onTypeCode(typeFor),
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
        const SizedBox(height: 8),
        Text(t.dji_link_receive_not_encrypted, style: context.textTheme.bodySmall),
      ],
    );
  }

  /// The phone "Type the phone's code instead" asks the code of: the phone watched, else the row focused last while it
  /// is listed, else the first listed
  DjiRelayPhone? _phoneForCode(DjiRelayState relay) {
    final focused = _focusedPhone?.address;
    return relay.target ??
        relay.phones.where((phone) => phone.address == focused).firstOrNull ??
        relay.phones.firstOrNull;
  }

  /// OK on a row with no code here tries this TV's own code: it asks nothing
  String _phoneLine(Translations t, DjiRelayState relay, DjiRelayPhone phone) {
    if (relay.target?.address == phone.address) {
      return t.dji_live_watch_watching;
    }
    final id = phone.id;
    return id != null && relay.rememberedCodes.containsKey(id) ? t.dji_live_tv_press_ok : t.dji_live_tv_press_ok_try;
  }

  /// "Let this TV watch": this TV's own code in two groups of five and its QR code, for the phone's "Add a TV"
  Widget _codeCard(Translations t, DjiRelayState relay) {
    final code = relay.ownCode!;
    final refusedBy = relay.ownCodeRefusedBy;
    return Card(
      key: const Key('dji_watch_tv_code_card'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.dji_live_tv_code_title,
                    style: context.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  if (refusedBy != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      t.dji_live_tv_code_refused(phone: refusedBy),
                      key: const Key('dji_watch_tv_code_refused'),
                      style: context.textTheme.bodyLarge?.copyWith(color: context.colorScheme.error),
                    ),
                  ],
                  const SizedBox(height: 8),
                  // The two groups on one line beside the QR code, smaller where they would not fit, so that the card
                  // keeps its height in a 960 by 540 screen
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      formatPairingCode(code),
                      key: const Key('dji_watch_tv_own_code'),
                      maxLines: 1,
                      softWrap: false,
                      style: const TextStyle(fontFamily: 'GoogleSansCode', fontSize: 40, letterSpacing: 3),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(t.dji_live_tv_code_steps, style: context.textTheme.bodyLarge),
                  if (relay.triesStopped) ...[
                    const SizedBox(height: 8),
                    Text(
                      t.dji_live_tv_code_stopped,
                      key: const Key('dji_watch_tv_tries_stopped'),
                      style: context.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 16),
            QrCodeView(
              key: const Key('dji_watch_tv_qr'),
              data: buildDjiWatchQrText(code),
              size: 200,
              semanticLabel: t.dji_live_tv_code_title,
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _stateLines(
    Translations t,
    DjiRelayState relay,
    DjiRelayReceiving? active,
    DjiLinkDecode? decode, {
    required bool shows,
    required bool card,
  }) {
    final style = context.textTheme.bodyLarge;
    if (active == null) {
      if (relay.phones.isNotEmpty && relay.target == null && !card) {
        return [Text(t.dji_live_tv_select, key: const Key('dji_watch_tv_select'), style: style)];
      }
      return const [];
    }
    if (card && active.state == DjiRelayReceiveState.wrongCode) {
      // The card says it: the phone does not know this TV yet
      return const [];
    }
    final delay = djiLinkDelayNowMs(active);
    final stale = djiLinkStaleLine(t, active);
    final cannotKeepUp = djiLinkCannotKeepUpLine(t, active);
    // Under the picture box, the state line is the page's own and stays; the red lines come and go as over the
    // picture, the line of a picture that stopped staying while it does not show
    return [
      Text(
        djiWatchTvStateLine(
          t,
          active,
          pictureFlows: shows,
          decode: decode,
          longWait: _longWait,
          refusedBy: relay.usingOwnCode ? relay.ownCodeRefusedBy : null,
        ),
        key: const Key('dji_watch_state'),
        style: style?.copyWith(fontWeight: FontWeight.w700),
      ),
      if (stale != null)
        DjiTransient(
          kind: 'stale',
          keep: !shows,
          child: Text(
            stale,
            key: const Key('dji_watch_tv_stale'),
            style: style?.copyWith(color: context.colorScheme.error),
          ),
        ),
      if (cannotKeepUp != null)
        DjiTransient(
          kind: 'cannotKeepUp',
          child: Text(
            cannotKeepUp,
            key: const Key('dji_watch_tv_cannot_keep_up'),
            style: style?.copyWith(color: context.colorScheme.error),
          ),
        ),
      if (active.state == DjiRelayReceiveState.receiving && delay != null)
        Text(t.dji_live_quest_delay(ms: delay.toStringAsFixed(0)), key: const Key('dji_watch_delay'), style: style),
    ];
  }

  // The full screen view

  Widget _fullScreenView(
    Translations t,
    DjiRelayState relay,
    DjiRelayReceiving? active,
    DjiLinkDecode? decode,
    Widget picture, {
    required bool shows,
  }) {
    final hidden = ref.watch(djiWatchTvNumbersHiddenProvider);
    return Focus(
      key: const Key('dji_watch_tv_full'),
      focusNode: _fullFocus,
      autofocus: true,
      onKeyEvent: _onFullKey,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Colors.black),
          // The picture fills the screen at the stream's aspect: full screen media ignore the overscan margins
          Center(child: picture),
          Padding(
            padding: _safe(context),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (!hidden) ...[
                  const Positioned(left: 0, top: 0, child: DjiWatchTvColumn(band: DjiLiveBand.left)),
                  const Positioned(right: 0, top: 0, child: DjiWatchTvColumn(band: DjiLiveBand.right, flyNote: true)),
                ],
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_hint)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: _plate(
                            Text(
                              t.dji_live_tv_hint,
                              key: const Key('dji_watch_tv_hint'),
                              style: const TextStyle(color: Colors.white, fontSize: 16),
                            ),
                          ),
                        ),
                      if (_hint) const SizedBox(height: 8),
                      _strip(t, relay, active, decode, shows: shows),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _plate(Widget child) => DecoratedBox(
    decoration: const BoxDecoration(color: djiWatchTvPlate, borderRadius: BorderRadius.all(Radius.circular(8))),
    child: Padding(padding: const EdgeInsets.all(12), child: child),
  );

  /// The strip at the bottom of the full screen view: the delay from the phone, which stays, and the warnings, which
  /// come and go (dji_live_transient.dart): where the picture comes from, the red line of a picture that stopped, "This
  /// device cannot keep up", then "Watching only" and the observer rule beside a red bar. Each shows five seconds when
  /// it appears or changes kind and after any key, then fades; the plate under them shrinks with them, down to the
  /// delay alone or to nothing. An error that needs an action stays, and so does the one line that says no picture
  /// shows while the picture is missing.
  Widget _strip(
    Translations t,
    DjiRelayState relay,
    DjiRelayReceiving? active,
    DjiLinkDecode? decode, {
    required bool shows,
  }) {
    final refusedBy = relay.usingOwnCode ? relay.ownCodeRefusedBy : null;
    final line = active == null
        ? t.dji_link_receive_state_idle
        : djiWatchTvStateLine(
            t,
            active,
            pictureFlows: shows,
            decode: decode,
            longWait: _longWait,
            refusedBy: refusedBy,
          );
    final kind = active == null
        ? DjiReceiveLine.idle
        : djiWatchTvLine(active, pictureFlows: shows, decode: decode, longWait: _longWait, refusedBy: refusedBy);
    final delay = djiLinkDelayNowMs(active);
    final stale = active == null ? null : djiLinkStaleLine(t, active);
    final cannotKeepUp = djiLinkCannotKeepUpLine(t, active);
    // While no picture shows, one line says so and stays: the red line when there is one, else the state line
    final keepLine = kind.keeps || (!shows && stale == null && active != null);
    const white = TextStyle(color: Colors.white, fontSize: 15);
    final state = Text(
      line,
      key: const Key('dji_watch_tv_strip_state'),
      style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
    );
    return DecoratedBox(
      key: const Key('dji_watch_tv_strip'),
      decoration: const BoxDecoration(color: djiWatchTvPlate, borderRadius: BorderRadius.all(Radius.circular(8))),
      // No padding of the plate's own: each line brings its own, so that the plate is gone when they all are
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (active?.state == DjiRelayReceiveState.receiving && delay != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: DjiTransient(kind: kind, keep: keepLine, child: state),
                  ),
                  const SizedBox(width: 16),
                  Text(
                    t.dji_live_quest_delay(ms: delay.toStringAsFixed(0)),
                    key: const Key('dji_watch_tv_strip_delay'),
                    style: const TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                ],
              ),
            )
          else
            DjiTransient(
              kind: kind,
              keep: keepLine,
              child: Padding(padding: const EdgeInsets.fromLTRB(16, 10, 16, 4), child: state),
            ),
          if (stale != null)
            DjiTransient(
              kind: 'stale',
              keep: !shows,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
                child: Text(
                  stale,
                  key: const Key('dji_watch_tv_strip_stale'),
                  style: const TextStyle(color: _red, fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          // The phone sends its steady picture: said for a few seconds at each switch, then gone
          if (active?.state == DjiRelayReceiveState.receiving && active?.steady == true)
            DjiTransient(
              kind: 'steady${active?.streamSwitches ?? 0}',
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
                child: Text(t.dji_watch_steady_switch, key: const Key('dji_watch_tv_strip_steady'), style: white),
              ),
            ),
          if (cannotKeepUp != null)
            DjiTransient(
              kind: 'cannotKeepUp',
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
                child: Text(
                  cannotKeepUp,
                  key: const Key('dji_watch_tv_strip_cannot_keep_up'),
                  style: const TextStyle(color: _red, fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          DjiTransient(
            kind: 'watching',
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  border: Border(left: BorderSide(color: _red, width: 6)),
                ),
                child: Padding(
                  padding: const EdgeInsets.only(left: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.dji_live_tv_watching,
                        key: const Key('dji_watch_tv_strip_watching'),
                        style: white.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(t.dji_live_tv_observer, key: const Key('dji_watch_tv_strip_observer'), style: white),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One column of values over the picture, from the top of the safe area: each value on its own dark plate, a small
/// label over a large number, in a fixed place; a value whose group stops coming leaves its place empty, and a column
/// that had values and lost them all says so rather than vanish. The flight column is empty on the ground, where the
/// height and the speeds are not given (in the air only) and the range below stops with the motors: no such line
/// then while the flight data still comes.
class DjiWatchTvColumn extends ConsumerStatefulWidget {
  const DjiWatchTvColumn({super.key, required this.band, this.flyNote = false, this.gates = djiLiveGates});

  final DjiLiveBand band;

  /// "Not compared with DJI Fly yet" under the column, hidden with the numbers
  final bool flyNote;
  final Map<DjiLiveField, DjiLiveGate> gates;

  @override
  ConsumerState<DjiWatchTvColumn> createState() => _DjiWatchTvColumnState();
}

class _DjiWatchTvColumnState extends ConsumerState<DjiWatchTvColumn> {
  bool _hadValues = false;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final fields = djiLiveBandFields(widget.band, gates: widget.gates);
    if (fields.isEmpty) {
      return const SizedBox.shrink();
    }
    final (any, grounded) = ref.watch(
      djiLiveFrameProvider.select(
        (frame) => (
          fields.any((field) => djiLiveFieldValue(t, frame, field) != null),
          widget.band == DjiLiveBand.left && frame?.motorsOn != null,
        ),
      ),
    );
    final Widget body;
    if (any) {
      _hadValues = true;
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final field in fields) DjiWatchTvCell(field: field, gates: widget.gates),
          // A warning: it comes and goes with the others (dji_live_transient.dart)
          if (widget.flyNote)
            DjiTransient(
              kind: 'flyNote',
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: djiWatchTvColumnWidth),
                child: Text(
                  t.dji_link_flight_view_fly_note,
                  key: const Key('dji_watch_tv_fly_note'),
                  style: const TextStyle(color: Colors.white, fontSize: 14, backgroundColor: djiWatchTvPlate),
                ),
              ),
            ),
        ],
      );
    } else if (_hadValues && !grounded) {
      body = DjiTransient(
        kind: 'valuesStale',
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: djiWatchTvColumnWidth),
          child: DecoratedBox(
            decoration: const BoxDecoration(
              color: djiWatchTvPlate,
              borderRadius: BorderRadius.all(Radius.circular(8)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                t.dji_link_flight_view_values_stale,
                key: Key('dji_watch_tv_values_stale_${widget.band.name}'),
                style: const TextStyle(color: Colors.white, fontSize: djiWatchTvLabelSize),
              ),
            ),
          ),
        ),
      );
    } else {
      body = const SizedBox.shrink();
    }
    return KeyedSubtree(key: Key('dji_watch_tv_column_${widget.band.name}'), child: body);
  }
}

/// The height of a cell over the picture, the same with or without its value: a label line, a number line, the
/// plate's padding and the gap under it
double djiWatchTvCellHeight(TextScaler scaler) =>
    scaler.scale(djiWatchTvLabelSize) * 1.4 + scaler.scale(djiWatchTvValueSize) * 1.3 + 24 + 8;

/// One value over the picture of a TV: it listens to its own field only, keeps its place when its value stops coming,
/// tabular figures, no animation; the drone's battery in amber with its icon and "low" under 20 %
class DjiWatchTvCell extends ConsumerWidget {
  const DjiWatchTvCell({super.key, required this.field, this.gates = djiLiveGates});

  final DjiLiveField field;
  final Map<DjiLiveField, DjiLiveGate> gates;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final (value, low) = ref.watch(
      djiLiveFrameProvider.select(
        (frame) => (
          djiLiveFieldValue(t, frame, field),
          field == DjiLiveField.droneBattery && djiLiveBatteryIsLow(frame),
        ),
      ),
    );
    final height = djiWatchTvCellHeight(MediaQuery.textScalerOf(context));
    if (value == null) {
      return SizedBox(key: Key('dji_watch_tv_cell_${field.name}'), height: height, width: djiWatchTvColumnWidth);
    }
    final label = djiLiveFieldLabel(t, field, place: DjiLivePlace.overlay, gates: gates);
    final semantics = [label, value, if (low) t.dji_live_battery_low].where((part) => part.isNotEmpty).join(' ');
    return RepaintBoundary(
      child: SizedBox(
        key: Key('dji_watch_tv_cell_${field.name}'),
        height: height,
        width: djiWatchTvColumnWidth,
        child: Semantics(
          label: semantics,
          excludeSemantics: true,
          child: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.topLeft,
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    color: djiWatchTvPlate,
                    borderRadius: BorderRadius.all(Radius.circular(8)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      key: Key('dji_watch_tv_value_${field.name}'),
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (label.isNotEmpty)
                          Text(
                            label,
                            maxLines: 1,
                            softWrap: false,
                            style: const TextStyle(color: Color(0xD9FFFFFF), fontSize: djiWatchTvLabelSize),
                          ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (low) ...[
                              const Icon(
                                Icons.battery_alert_rounded,
                                key: Key('dji_watch_tv_battery_low'),
                                size: 28,
                                color: djiLiveAmber,
                              ),
                              const SizedBox(width: 4),
                            ],
                            Text(
                              value,
                              maxLines: 1,
                              softWrap: false,
                              style: TextStyle(
                                color: low ? djiLiveAmber : Colors.white,
                                fontSize: djiWatchTvValueSize,
                                fontWeight: FontWeight.w700,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The obstacle ring over the TV's picture, at the TV's depth: OK hides its number with the other numbers, never the
/// ring itself. Whether it shows, its distances and its side come from the phone's record.
class DjiWatchTvRing extends ConsumerWidget {
  const DjiWatchTvRing({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      DjiObstacleRing(tv: true, numbersHidden: ref.watch(djiWatchTvNumbersHiddenProvider));
}

/// Options, from the right: each choice closes the panel with its name, which the page carries out; the picture and
/// decoder lines and the values of Advanced are read only (design 3.6). The panel is built whole, not lazily, and each
/// read only block is a stop of the remote: the arrows only move between widgets that are built, and a long block with
/// no stop left the items below it out of reach of a remote without channel keys.
class DjiWatchTvOptions extends ConsumerWidget {
  const DjiWatchTvOptions({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final hidden = ref.watch(djiWatchTvNumbersHiddenProvider);
    final obstacle = ref.watch(djiObstacleSettingsProvider);
    final offer = djiObstacleOffer();
    final snapshot = ref.watch(djiLinkProvider.select((state) => state.snapshot));
    final watching = ref.watch(djiRelayProvider.select((relay) => relay.target != null));
    final frame = ref.watch(djiLiveFrameProvider);
    final values = djiLiveValues(t, frame, DjiLivePlace.advanced);
    final small = context.textTheme.bodyMedium;
    final heading = context.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700);
    void choose(String choice) => Navigator.of(context).pop(choice);
    return Align(
      alignment: Alignment.centerRight,
      child: Material(
        key: const Key('dji_watch_tv_options_panel'),
        elevation: 8,
        child: SizedBox(
          width: 400,
          height: double.infinity,
          child: SafeArea(
            left: false,
            child: SingleChildScrollView(
              key: const Key('dji_watch_tv_options_scroll'),
              padding: const EdgeInsets.fromLTRB(8, 12, 8, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text(t.dji_live_tv_options, style: context.textTheme.titleLarge),
                  ),
                  ListTile(
                    key: const Key('dji_watch_tv_numbers'),
                    autofocus: true,
                    leading: Icon(hidden ? Icons.visibility_rounded : Icons.visibility_off_rounded),
                    title: Text(hidden ? t.dji_live_tv_numbers_show : t.dji_live_tv_numbers_hide),
                    onTap: () => choose('numbers'),
                  ),
                  // The ring's own items of this TV, each on by default: whether the phone offers it, its distances and its
                  // side come from the phone; this TV can only turn it off on its own screen
                  if (offer != DjiObstacleOffer.none) ...[
                    SwitchListTile(
                      key: const Key('dji_watch_obstacle_here'),
                      title: Text(t.dji_live_obstacle_here),
                      subtitle: Text(t.dji_live_obstacle_here_note),
                      value: obstacle.alertOn,
                      onChanged: (_) => choose('ring'),
                    ),
                    SwitchListTile(
                      key: const Key('dji_watch_obstacle_sound'),
                      title: Text(t.dji_live_obstacle_sound),
                      subtitle: Text(t.dji_live_obstacle_sound_note),
                      value: obstacle.soundOn,
                      onChanged: (_) => choose('sound'),
                    ),
                    ListTile(
                      key: const Key('dji_watch_tv_sound_test'),
                      leading: const Icon(Icons.volume_up_rounded),
                      title: Text(t.dji_live_obstacle_sound_test),
                      onTap: () => choose('testSound'),
                    ),
                    SwitchListTile(
                      key: const Key('dji_watch_obstacle_numbers'),
                      title: Text(t.dji_live_obstacle_numbers),
                      subtitle: Text(t.dji_live_obstacle_numbers_note),
                      value: obstacle.numbersOn,
                      onChanged: (_) => choose('ringNumbers'),
                    ),
                    ListTile(
                      key: const Key('dji_watch_obstacle_shape'),
                      leading: Icon(obstacle.frame ? Icons.crop_free_rounded : Icons.radio_button_unchecked_rounded),
                      title: Text(t.dji_live_obstacle_shape),
                      subtitle: Text(
                        obstacle.frame ? t.dji_live_obstacle_shape_frame : t.dji_live_obstacle_shape_circle,
                      ),
                      onTap: () => choose('shape'),
                    ),
                    ListTile(
                      key: const Key('dji_watch_obstacle_sample'),
                      leading: const Icon(Icons.blur_on_rounded),
                      title: Text(t.dji_live_obstacle_sample),
                      subtitle: Text(t.dji_live_obstacle_sample_note),
                      onTap: () => choose('sample'),
                    ),
                  ],
                  const Divider(),
                  _ReadOnlyStop(
                    child: Column(
                      key: const Key('dji_watch_tv_picture_lines'),
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t.dji_live_tv_picture, style: heading),
                        for (final line in djiWatchTvPictureLines(t, snapshot?.videoDecode, snapshot?.relayReceiving))
                          Text(line, style: small),
                      ],
                    ),
                  ),
                  _ReadOnlyStop(
                    child: Column(
                      key: const Key('dji_watch_tv_values'),
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t.dji_live_tv_values, style: heading),
                        if (values.isEmpty)
                          Text(t.dji_link_flight_none, style: small)
                        else
                          for (final value in values) Text(value.line, style: small),
                      ],
                    ),
                  ),
                  const Divider(),
                  ListTile(
                    key: const Key('dji_watch_tv_safety'),
                    leading: const Icon(Icons.warning_amber_rounded),
                    title: Text(t.dji_live_safety_again),
                    onTap: () => choose('safety'),
                  ),
                  ListTile(
                    key: const Key('dji_watch_tv_diagnostics'),
                    leading: const Icon(Icons.analytics_outlined),
                    title: Text(t.dji_live_diagnostics),
                    onTap: () => choose('diagnostics'),
                  ),
                  ListTile(
                    key: const Key('dji_watch_save_record'),
                    leading: const Icon(Icons.save_alt_rounded),
                    title: Text(t.dji_live_watch_save_record),
                    onTap: () => choose('record'),
                  ),
                  ListTile(
                    key: const Key('dji_watch_tv_options_type_code'),
                    leading: const Icon(Icons.password_rounded),
                    title: Text(t.dji_live_tv_type_code),
                    onTap: () => choose('typeCode'),
                  ),
                  ListTile(
                    key: const Key('dji_watch_tv_new_code'),
                    leading: const Icon(Icons.refresh_rounded),
                    title: Text(t.dji_live_tv_code_new),
                    subtitle: Text(t.dji_live_tv_code_new_note),
                    onTap: () => choose('newCode'),
                  ),
                  if (watching)
                    ListTile(
                      key: const Key('dji_watch_stop'),
                      leading: const Icon(Icons.stop_circle_outlined),
                      title: Text(t.dji_live_watch_stop),
                      onTap: () => choose('stop'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A read only block of Options as one stop of the remote: the arrows bring it into view, and go on below it; OK does
/// nothing there. The TV's focus ring shows where the focus is.
class _ReadOnlyStop extends StatelessWidget {
  const _ReadOnlyStop({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Focus(
    child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), child: child),
  );
}
