// "Play on...": the sheet of a film on a phone or a tablet. "This phone" first, then the linked screens with their
// state: Ready (announced nearby), "Open Immuch360 on it" (linked, not announced; "Put on the headset and open
// Immuch360" for the Quest), "Does not have (server) yet" (it said so), with "Add (server) to (screen)". Footer
// "Add a screen", the Connect page. With no linked screen, how to link one. Then the Cast devices nearby
// (cast_group.widget.dart), with the controls of a cast under way.
//
// Release 53: a photo or a video on this phone only goes to a linked screen from the phone's relay (no Cast group
// then), and a screen that cannot reach an item (another account or server, a share it does not have) gets "Send it
// from this phone" under its row. On iPhone and iPad the sheet says to keep the app open while it sends.

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_messages.dart';
import 'package:immich_mobile/domain/services/play_on_screen/screen_player_session.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/cast/cast_group.widget.dart';
import 'package:immich_mobile/presentation/widgets/pairing/pairing_confirm.sheet.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/play_handover.sheet.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/play_on_asset.dart';
import 'package:immich_mobile/providers/cast/cast_play.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_play.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_relay.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/play_links.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_ui/immich_ui.dart';

/// Opens the sheet for [request]; true once the film plays on a screen (the page then shows the mini controller) or
/// is cast to a Cast device (the dock shows its controls): the phone's player then pauses
Future<bool> showPlayOnSheet(BuildContext context, PlayOnRequest request, {String? title}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final playing =
      await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => PlayOnSheet(request: request, title: title),
      ) ??
      false;
  if (playing) {
    return true;
  }
  final cast = container.read(castPlaybackProvider);
  return cast != null &&
      cast.live &&
      cast.request.sourceId == request.sourceId &&
      cast.request.ratingKey == request.ratingKey;
}

/// Asks before an archived or a locked item of the Immich library goes to [device]: true on Show. Anything else is
/// asked nothing.
Future<bool> confirmPrivatePlayOn(BuildContext context, PlayOnRequest request, String device) async {
  final asset = request.immich;
  if (asset == null || (!asset.locked && !asset.archived)) {
    return true;
  }
  final t = context.t;
  final answer = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      key: const Key('play_on_private_dialog'),
      title: Text(asset.locked ? t.play_on_locked_title(device: device) : t.play_on_archived_title(device: device)),
      content: Text(asset.locked ? t.play_on_locked_body(device: device) : t.play_on_archived_body(device: device)),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: Text(t.cancel)),
        TextButton(
          key: const Key('play_on_private_show'),
          onPressed: () => Navigator.of(dialog).pop(true),
          child: Text(t.play_on_show),
        ),
      ],
    ),
  );
  return answer ?? false;
}

/// Whether a screen that answered [outcome] cannot reach the item with its own access, so that the phone may send it
bool playOnSendableFromPhone(PlayOnOutcome outcome) => switch (outcome) {
  PlayOnOutcome.otherAccount ||
  PlayOnOutcome.otherServer ||
  PlayOnOutcome.notVisible ||
  PlayOnOutcome.noSuchSource => true,
  _ => false,
};

/// What a row of the sheet says of a screen
enum PlayScreenRowState { ready, notAnnounced, withoutServer, signedOut }

/// The state of [screen] for [server]: announced or not, whether it said it lacks the server, and for an Immich item
/// ([immich]) whether it said it is signed in to no server
PlayScreenRowState playScreenRowState({
  required LinkedPeer screen,
  required Map<String, PlayScreenAddress> nearby,
  required Map<String, Set<String>> withoutServer,
  required String server,
  Set<String> signedOut = const {},
  bool immich = false,
}) {
  if (!nearby.containsKey(screen.id)) {
    return PlayScreenRowState.notAnnounced;
  }
  if (withoutServer[screen.id]?.contains(server) ?? false) {
    return PlayScreenRowState.withoutServer;
  }
  if (immich && signedOut.contains(screen.id)) {
    return PlayScreenRowState.signedOut;
  }
  return PlayScreenRowState.ready;
}

class PlayOnSheet extends ConsumerStatefulWidget {
  const PlayOnSheet({super.key, required this.request, this.title});

  final PlayOnRequest request;

  /// The sheet's title in place of "Play on…": "Slideshow on…" for a selection or an album
  final String? title;

  @override
  ConsumerState<PlayOnSheet> createState() => _PlayOnSheetState();
}

class _PlayOnSheetState extends ConsumerState<PlayOnSheet> {
  /// The screen a play or a handover is under way with
  String? _busy;

  /// The screens that said they cannot reach the item: their row offers "Send it from this phone"
  final Set<String> _unreachableThere = {};

  /// What the last attempt said, one sentence that fades
  String? _message;
  Timer? _messageTimer;

  @override
  void dispose() {
    _messageTimer?.cancel();
    super.dispose();
  }

  void _say(String message) {
    _messageTimer?.cancel();
    setState(() => _message = message);
    _messageTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) {
        setState(() => _message = null);
      }
    });
  }

  String _rowLine(Translations t, LinkedPeer screen, PlayScreenRowState state) => switch (state) {
    PlayScreenRowState.ready => t.play_on_ready,
    PlayScreenRowState.notAnnounced =>
      screen.kind == PairingScreenKind.headset ? t.play_on_open_app_headset : t.play_on_open_app,
    PlayScreenRowState.withoutServer => t.play_on_without_server(server: widget.request.serverName),
    PlayScreenRowState.signedOut => t.play_on_signed_out(server: widget.request.serverName),
  };

  /// [widget.request] for [screen], or with [fromPhone] the same item sent from this phone's relay
  Future<void> _play(LinkedPeer screen, PlayScreenAddress address, {bool fromPhone = false}) async {
    final t = context.t;
    // A screen never opens a locked item with its own session (screen_item_openers.dart): nothing to send
    if (widget.request.immich?.locked ?? false) {
      _say(t.play_on_err_locked);
      return;
    }
    final request = fromPhone ? ref.read(playOnSendFromPhoneProvider)(widget.request) : widget.request;
    if (request == null) {
      return;
    }
    if (!await confirmPrivatePlayOn(context, request, screen.name) || !mounted) {
      return;
    }
    setState(() => _busy = screen.id);
    final outcome = await ref.read(remotePlaybackProvider.notifier).play(screen, address, request);
    if (!mounted) {
      return;
    }
    final canSendFromPhone =
        request.relay == null && ref.read(playOnSendFromPhoneProvider)(widget.request)?.relay != null;
    setState(() {
      _busy = null;
      // What the screen cannot reach with its own access goes from this phone, on the user's choice
      if (canSendFromPhone && playOnSendableFromPhone(outcome)) {
        _unreachableThere.add(screen.id);
      } else if (outcome == PlayOnOutcome.playing) {
        _unreachableThere.remove(screen.id);
      }
    });
    switch (outcome) {
      case PlayOnOutcome.playing:
        Navigator.of(context).pop(true);
      case PlayOnOutcome.noSuchServer:
        _say(t.play_on_err_no_server(device: screen.name, server: widget.request.serverName));
      case PlayOnOutcome.declined:
        _say(t.play_on_err_declined(device: screen.name));
      case PlayOnOutcome.unreachable:
        _say(t.play_on_err_unreachable(device: screen.name));
      case PlayOnOutcome.notLinked:
        _say(t.play_on_err_not_linked(device: screen.name));
      case PlayOnOutcome.screenCannotOpen:
        _say(t.play_on_err_screen_cannot_open(device: screen.name, server: widget.request.serverName));
      case PlayOnOutcome.notFound:
        _say(
          widget.request.kind == PlayKind.plex
              ? t.play_on_err_not_found(server: widget.request.serverName)
              : t.play_on_err_item_not_found(server: widget.request.serverName),
        );
      case PlayOnOutcome.needsUpdate:
        _say(t.play_on_err_update_screen(device: screen.name));
      case PlayOnOutcome.notSignedIn:
        _say(t.play_on_err_not_signed_in(device: screen.name, server: widget.request.serverName));
      case PlayOnOutcome.otherAccount:
        _say(t.play_on_err_other_account(device: screen.name));
      case PlayOnOutcome.otherServer:
        _say(t.play_on_err_other_server(device: screen.name));
      case PlayOnOutcome.notVisible:
        _say(t.play_on_err_not_visible(device: screen.name));
      case PlayOnOutcome.locked:
        _say(t.play_on_err_locked);
      case PlayOnOutcome.noSuchSource:
        _say(t.play_on_err_no_server(device: screen.name, server: widget.request.serverName));
      case PlayOnOutcome.relayFailed:
        _say(t.play_on_err_relay(device: screen.name));
      case PlayOnOutcome.failed:
        _say(t.play_on_err_failed(device: screen.name));
    }
  }

  Future<void> _addServer(LinkedPeer screen, PlayScreenAddress address) async {
    final t = context.t;
    final source = ref.read(networkSourceProvider(widget.request.sourceId));
    if (source == null) {
      return;
    }
    setState(() => _busy = screen.id);
    final result = await ref
        .read(remotePlaybackProvider.notifier)
        .addServer(
          screen,
          address,
          source,
          confirm: (check) async =>
              mounted && await showPlayHandoverSheet(context, screen: screen.name, server: source.name, check: check),
          onSent: () {
            if (mounted) {
              _say(t.play_handover_waiting(device: screen.name));
            }
          },
        );
    if (!mounted) {
      return;
    }
    setState(() => _busy = null);
    switch (result) {
      case null:
        return;
      case HandoverResult.added:
        _say(t.play_handover_added(device: screen.name, server: source.name));
        // What the user wanted in the first place
        await _play(screen, address);
      case HandoverResult.declined:
        _say(t.play_on_err_declined(device: screen.name));
      case HandoverResult.tokenRefused:
        _say(t.play_handover_err_token(server: source.name));
      case HandoverResult.unreachable:
        _say(t.play_handover_err_unreachable(device: screen.name, server: source.name));
      case HandoverResult.otherServer:
        _say(t.play_handover_err_other(device: screen.name, server: source.name));
      case HandoverResult.failed || HandoverResult.alreadySignedIn:
        _say(t.play_on_err_failed(device: screen.name));
    }
  }

  /// "Sign (screen) in to (server)": the sheet with the check number, then the sign in, then what the user wanted
  Future<void> _signIn(LinkedPeer screen, PlayScreenAddress address) async {
    final t = context.t;
    final server = widget.request.serverName;
    setState(() => _busy = screen.id);
    final outcome = await ref
        .read(remotePlaybackProvider.notifier)
        .signInScreen(
          screen,
          address,
          confirm: (check, account) async =>
              mounted &&
              await showPlaySignInSheet(
                context,
                screen: screen.name,
                server: server,
                user: account.userName.isNotEmpty ? account.userName : account.userEmail,
                check: check,
              ),
          onSent: () {
            if (mounted) {
              _say(t.play_handover_waiting(device: screen.name));
            }
          },
        );
    if (!mounted) {
      return;
    }
    setState(() => _busy = null);
    switch (outcome) {
      case null:
        return;
      case ScreenSignInOutcome.signedIn:
        _say(t.play_sign_in_done(device: screen.name, server: server));
        // What the user wanted in the first place, once the screen has left its sign in page
        await Future<void>.delayed(signInSettle);
        if (mounted) {
          await _play(screen, address);
        }
      case ScreenSignInOutcome.declined:
        _say(t.play_on_err_declined(device: screen.name));
      case ScreenSignInOutcome.alreadySignedIn:
        _say(t.play_sign_in_err_already(device: screen.name));
      case ScreenSignInOutcome.serverUnreachable:
        _say(t.pairing_err_screen_cannot_reach(device: screen.name, server: server));
      case ScreenSignInOutcome.tokenRejected:
        _say(t.pairing_err_token_rejected(device: screen.name));
      case ScreenSignInOutcome.serverTooOld:
        _say(t.pairing_err_server_old);
      case ScreenSignInOutcome.phoneOffline:
        _say(t.pairing_err_phone_offline);
      case ScreenSignInOutcome.unreachable:
        _say(t.play_on_err_unreachable(device: screen.name));
      case ScreenSignInOutcome.failed:
        _say(t.play_on_err_failed(device: screen.name));
    }
  }

  /// How long the sheet waits after a sign in before it plays: the screen leaves its sign in page meanwhile
  static const signInSettle = Duration(seconds: 2);

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = context.textTheme;
    final scheme = context.colorScheme;
    final screens = ref.watch(linkedScreensProvider).valueOrNull ?? const <LinkedPeer>[];
    final nearby = ref.watch(nearbyPlayScreensProvider);
    final withoutServer = ref.watch(screensWithoutServerProvider);
    final signedOut = ref.watch(screensSignedOutProvider);
    final message = _message;
    // On this phone only: no Cast device reads it, the phone's relay sends it to a linked screen
    final local = widget.request.kind == PlayKind.relay;
    final keepOpen =
        (local || _unreachableThere.isNotEmpty) && ref.read(phoneRelayEnvironmentProvider).keepAlive.needsAppOpen;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(ImmichSpacing.md, 0, ImmichSpacing.md, ImmichSpacing.md),
        child: SingleChildScrollView(
          child: Column(
            key: const Key('play_on_sheet'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: ImmichSpacing.sm),
                child: Text(widget.title ?? t.play_on_title, style: theme.titleLarge),
              ),
              const SizedBox(height: ImmichSpacing.sm),
              ListTile(
                key: const Key('play_on_this_phone'),
                leading: const Icon(Icons.smartphone_rounded),
                title: Text(t.play_on_this_phone),
                trailing: Icon(Icons.check_rounded, color: scheme.primary),
                onTap: () => Navigator.of(context).pop(false),
              ),
              if (screens.isEmpty) ...[
                const Divider(),
                Padding(
                  padding: const EdgeInsets.all(ImmichSpacing.sm),
                  child: Text(
                    widget.request.kind == PlayKind.plex ? t.play_on_empty : t.play_on_empty_item,
                    key: const Key('play_on_empty'),
                    style: theme.bodyMedium,
                  ),
                ),
              ] else ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(ImmichSpacing.sm, ImmichSpacing.md, ImmichSpacing.sm, 0),
                  child: Text(t.play_on_your_screens, style: theme.titleSmall),
                ),
                for (final screen in screens)
                  _row(
                    context,
                    screen,
                    playScreenRowState(
                      screen: screen,
                      nearby: nearby,
                      withoutServer: withoutServer,
                      server: widget.request.server,
                      signedOut: signedOut,
                      immich: widget.request.kind == PlayKind.immich,
                    ),
                    nearby[screen.id],
                  ),
              ],
              if (local)
                Padding(
                  padding: const EdgeInsets.fromLTRB(ImmichSpacing.sm, ImmichSpacing.sm, ImmichSpacing.sm, 0),
                  child: Text(t.play_on_local_note, key: const Key('play_on_local_note'), style: theme.bodySmall),
                ),
              if (keepOpen)
                Padding(
                  padding: const EdgeInsets.fromLTRB(ImmichSpacing.sm, ImmichSpacing.sm, ImmichSpacing.sm, 0),
                  child: Text(t.play_on_keep_open, key: const Key('play_on_keep_open'), style: theme.bodySmall),
                ),
              if (!local)
                CastGroup(request: widget.request, screenHosts: {for (final address in nearby.values) address.host}),
              if (message != null)
                Padding(
                  padding: const EdgeInsets.all(ImmichSpacing.sm),
                  child: Text(
                    message,
                    key: const Key('play_on_message'),
                    style: theme.bodyMedium?.copyWith(color: scheme.primary),
                  ),
                ),
              const SizedBox(height: ImmichSpacing.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('play_on_add_screen'),
                  icon: const Icon(Icons.qr_code_scanner_rounded),
                  label: Text(t.play_on_add_screen),
                  onPressed: () {
                    final router = context.router;
                    Navigator.of(context).pop(false);
                    unawaited(router.push(ConnectScreenRoute()));
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, LinkedPeer screen, PlayScreenRowState state, PlayScreenAddress? address) {
    final t = context.t;
    final busy = _busy == screen.id;
    final idle = _busy == null;
    final line = Text(_rowLine(t, screen, state));
    // Under the line rather than beside it: "Add (server) to (screen)" is longer than a trailing button may be
    final addServer = state == PlayScreenRowState.withoutServer && address != null
        ? Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: ValueKey('play_on_add_server_${screen.id}'),
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              icon: const Icon(Icons.dns_rounded),
              onPressed: idle ? () => unawaited(_addServer(screen, address)) : null,
              label: Text(t.play_handover_button(server: widget.request.serverName, device: screen.name)),
            ),
          )
        : _unreachableThere.contains(screen.id) && address != null
        ? Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: ValueKey('play_on_send_from_phone_${screen.id}'),
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              icon: const Icon(Icons.send_to_mobile_rounded),
              onPressed: idle ? () => unawaited(_play(screen, address, fromPhone: true)) : null,
              label: Text(t.play_on_send_from_phone),
            ),
          )
        : state == PlayScreenRowState.signedOut && address != null
        ? Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: ValueKey('play_on_sign_in_${screen.id}'),
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              icon: const Icon(Icons.login_rounded),
              onPressed: idle ? () => unawaited(_signIn(screen, address)) : null,
              label: Text(t.play_on_sign_in_button(device: screen.name, server: widget.request.serverName)),
            ),
          )
        : null;
    return ListTile(
      key: ValueKey('play_on_${screen.id}'),
      leading: Icon(pairingKindIcon(screen.kind)),
      title: Text(screen.name),
      subtitle: addServer == null
          ? line
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [line, addServer]),
      enabled: state != PlayScreenRowState.notAnnounced,
      trailing: busy ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 3)) : null,
      onTap: (state == PlayScreenRowState.ready || state == PlayScreenRowState.signedOut) && address != null && idle
          ? () => unawaited(_play(screen, address))
          : null,
    );
  }
}
