// "Play on...": the sheet of a film on a phone or a tablet. "This phone" first, then the linked screens with their
// state: Ready (announced nearby), "Open Immuch360 on it" (linked, not announced; "Put on the headset and open
// Immuch360" for the Quest), "Does not have (server) yet" (it said so), with "Add (server) to (screen)". Footer
// "Add a screen", the Connect page. With no linked screen, how to link one. Then the Cast devices nearby
// (experimental, cast_group.widget.dart), with the controls of a cast under way.

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/play_on_screen/screen_player_session.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/cast/cast_group.widget.dart';
import 'package:immich_mobile/presentation/widgets/pairing/pairing_confirm.sheet.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/play_handover.sheet.dart';
import 'package:immich_mobile/providers/cast/cast_play.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_play.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/play_links.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_ui/immich_ui.dart';

/// Opens the sheet for [request]; true once the film plays on a screen (the page then shows the mini controller) or
/// is cast to a Cast device (the dock shows its controls): the phone's player then pauses
Future<bool> showPlayOnSheet(BuildContext context, PlayOnRequest request) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final playing =
      await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => PlayOnSheet(request: request),
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

/// What a row of the sheet says of a screen
enum PlayScreenRowState { ready, notAnnounced, withoutServer }

/// The state of [screen] for [server]: announced or not, and whether it said it lacks the server
PlayScreenRowState playScreenRowState({
  required LinkedPeer screen,
  required Map<String, PlayScreenAddress> nearby,
  required Map<String, Set<String>> withoutServer,
  required String server,
}) {
  if (!nearby.containsKey(screen.id)) {
    return PlayScreenRowState.notAnnounced;
  }
  if (withoutServer[screen.id]?.contains(server) ?? false) {
    return PlayScreenRowState.withoutServer;
  }
  return PlayScreenRowState.ready;
}

class PlayOnSheet extends ConsumerStatefulWidget {
  const PlayOnSheet({super.key, required this.request});

  final PlayOnRequest request;

  @override
  ConsumerState<PlayOnSheet> createState() => _PlayOnSheetState();
}

class _PlayOnSheetState extends ConsumerState<PlayOnSheet> {
  /// The screen a play or a handover is under way with
  String? _busy;

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
  };

  Future<void> _play(LinkedPeer screen, PlayScreenAddress address) async {
    final t = context.t;
    setState(() => _busy = screen.id);
    final outcome = await ref.read(remotePlaybackProvider.notifier).play(screen, address, widget.request);
    if (!mounted) {
      return;
    }
    setState(() => _busy = null);
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
        _say(t.play_on_err_not_found(server: widget.request.serverName));
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
      case HandoverResult.failed:
        _say(t.play_on_err_failed(device: screen.name));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = context.textTheme;
    final scheme = context.colorScheme;
    final screens = ref.watch(linkedScreensProvider).valueOrNull ?? const <LinkedPeer>[];
    final nearby = ref.watch(nearbyPlayScreensProvider);
    final withoutServer = ref.watch(screensWithoutServerProvider);
    final message = _message;
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
                child: Text(t.play_on_title, style: theme.titleLarge),
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
                  child: Text(t.play_on_empty, key: const Key('play_on_empty'), style: theme.bodyMedium),
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
                    ),
                    nearby[screen.id],
                  ),
              ],
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
      onTap: state == PlayScreenRowState.ready && address != null && idle
          ? () => unawaited(_play(screen, address))
          : null,
    );
  }
}
