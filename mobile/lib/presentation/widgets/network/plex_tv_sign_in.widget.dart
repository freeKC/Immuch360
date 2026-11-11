import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_tv_auth.dart';
import 'package:immich_mobile/presentation/widgets/pairing/qr_code.widget.dart';
import 'package:immich_mobile/providers/network/plex_pairing.provider.dart';
import 'package:immich_mobile/providers/network/plex_tv_auth.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('PlexTvSignIn');

/// The second way of the Plex server page, beside the address and the token typed: sign in at plex.tv, pick a server
/// of the account, and the page is filled with its address and its token ([onConnected]), to be tested and saved as
/// if typed. Nothing talks to plex.tv until the user starts it.
///
/// [shortCode] is for the screens without a browser to speak of (a TV, a headset): the 4 character code typed at
/// plex.tv/link on another device, with a QR code of that page; elsewhere the auth page of plex.tv opens in the
/// browser. [messageOf] tells a failure of a server in the words of the page.
class PlexTvSignInPanel extends ConsumerStatefulWidget {
  const PlexTvSignInPanel({super.key, required this.shortCode, required this.onConnected, required this.messageOf});

  final bool shortCode;
  final ValueChanged<PlexTvConnected> onConnected;
  final String Function(NetworkFileSystemException error) messageOf;

  @override
  ConsumerState<PlexTvSignInPanel> createState() => _PlexTvSignInPanelState();
}

class _PlexTvSignInPanelState extends ConsumerState<PlexTvSignInPanel> {
  StreamSubscription<PlexTvSignInState>? _signIn;

  /// Where the sign in stands; null before it starts
  PlexTvSignInState? _state;

  /// The PIN whose auth page was opened, so that it opens once
  PlexTvPin? _opened;

  /// The token of the account, only between the sign in and the pick of a server
  String? _accountToken;
  bool _listing = false;
  List<PlexTvServer>? _servers;

  /// A failure of plex.tv after the sign in (the list of servers)
  PlexTvException? _listError;

  /// The machine identifier of the server being reached, and the failure of the last one tried
  String? _connecting;
  ({String id, String message})? _connectError;

  /// The name of the server that filled the page
  String? _connectedName;

  @override
  void dispose() {
    unawaited(_signIn?.cancel());
    _accountToken = null;
    super.dispose();
  }

  void _start() {
    unawaited(_signIn?.cancel());
    setState(() {
      _state = const PlexTvRequesting();
      _opened = null;
      _accountToken = null;
      _listing = false;
      _servers = null;
      _listError = null;
      _connecting = null;
      _connectError = null;
      _connectedName = null;
    });
    _signIn = ref.read(plexTvAuthProvider).signIn(strong: !widget.shortCode).listen(_onState);
  }

  void _cancel() {
    unawaited(_signIn?.cancel());
    _signIn = null;
    setState(() {
      _state = null;
      _accountToken = null;
      _servers = null;
      _listing = false;
      _listError = null;
      _connecting = null;
      _connectError = null;
    });
  }

  void _onState(PlexTvSignInState state) {
    if (!mounted) {
      return;
    }
    setState(() => _state = state);
    switch (state) {
      case PlexTvWaiting(:final pin) when pin.strong && !identical(_opened, pin):
        _opened = pin;
        unawaited(_openAuthPage(pin));
      case PlexTvAuthorised(:final token):
        _accountToken = token;
        unawaited(_listServers());
      default:
        break;
    }
  }

  Future<void> _openAuthPage(PlexTvPin pin) async {
    try {
      final auth = ref.read(plexTvAuthProvider);
      final url = plexTvAuthUrl(pin, await auth.clientIdentifier());
      final opened = await ref.read(plexTvOpenBrowserProvider)(url);
      if (!opened) {
        _log.info('No browser opened the page of plex.tv');
      }
    } catch (error) {
      _log.warning('The page of plex.tv could not be opened: ${error.runtimeType}');
    }
  }

  void _openAgain() {
    final state = _state;
    if (state is PlexTvWaiting) {
      unawaited(_openAuthPage(state.pin));
    }
  }

  Future<void> _listServers() async {
    final token = _accountToken;
    if (token == null) {
      return;
    }
    setState(() => _listing = true);
    try {
      final servers = await ref.read(plexTvAuthProvider).servers(token);
      if (!mounted || _accountToken != token) {
        return;
      }
      setState(() {
        _listing = false;
        _servers = servers;
      });
      if (servers.length == 1) {
        unawaited(_connect(servers.single));
      }
    } on PlexTvException catch (error) {
      if (!mounted || _accountToken != token) {
        return;
      }
      setState(() {
        _listing = false;
        _accountToken = null;
        _listError = error;
      });
    }
  }

  Future<void> _connect(PlexTvServer server) async {
    final token = _accountToken;
    if (token == null || _connecting != null) {
      return;
    }
    setState(() {
      _connecting = server.clientIdentifier;
      _connectError = null;
    });
    try {
      final pairing = ref.read(plexPairingProvider);
      final connected = await connectPlexTvServer(server, token, pairing.lookUp);
      if (!mounted || _accountToken != token) {
        return;
      }
      setState(() {
        // Nothing of plex.tv is kept past this point
        _accountToken = null;
        _servers = null;
        _connecting = null;
        _connectedName = server.name;
      });
      widget.onConnected(connected);
    } on NetworkFileSystemException catch (error) {
      if (!mounted || _accountToken != token) {
        return;
      }
      setState(() {
        _connecting = null;
        _connectError = (id: server.clientIdentifier, message: widget.messageOf(error));
      });
    }
  }

  String _messageOf(PlexTvException error) => switch (error.failure) {
    PlexTvFailure.unreachable => context.t.plex_signin_unreachable,
    PlexTvFailure.refused => context.t.plex_signin_refused,
    PlexTvFailure.failed => context.t.plex_signin_failed,
  };

  @override
  Widget build(BuildContext context) {
    final labelStyle = context.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold);
    final hintStyle = context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceVariant);
    return Card(
      key: const Key('plex_signin'),
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.t.plex_signin_title, style: labelStyle),
            const SizedBox(height: 4),
            Text(context.t.plex_signin_intro, style: hintStyle),
            const SizedBox(height: 4),
            Text(context.t.plex_signin_privacy, key: const Key('plex_signin_privacy'), style: hintStyle),
            const SizedBox(height: 12),
            ..._body(context, hintStyle),
          ],
        ),
      ),
    );
  }

  List<Widget> _body(BuildContext context, TextStyle? hintStyle) {
    const buttonText = TextStyle(fontSize: 14, fontWeight: FontWeight.bold);
    final cancel = TextButton(
      key: const Key('plex_signin_cancel'),
      onPressed: _cancel,
      child: Text(context.t.cancel, style: buttonText),
    );
    Widget retry(String text) => OutlinedButton.icon(
      key: const Key('plex_signin_restart'),
      onPressed: _start,
      icon: const Icon(Icons.refresh_rounded),
      label: Text(text, style: buttonText),
    );
    Widget progress(String text) => Row(
      children: [
        const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: hintStyle)),
      ],
    );
    Widget failure(String text) => Text(
      text,
      key: const Key('plex_signin_error'),
      style: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.error),
    );

    final connectedName = _connectedName;
    if (connectedName != null) {
      return [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.check_circle_outline_rounded, color: context.primaryColor, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                context.t.plex_signin_done(name: connectedName),
                key: const Key('plex_signin_done'),
                style: context.textTheme.bodyMedium?.copyWith(color: context.primaryColor),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(context.t.plex_signin_sign_out, key: const Key('plex_signin_sign_out'), style: hintStyle),
      ];
    }
    final listError = _listError;
    if (listError != null) {
      return [failure(_messageOf(listError)), const SizedBox(height: 8), retry(context.t.retry)];
    }
    if (_listing) {
      return [progress(context.t.plex_signin_listing), cancel];
    }
    final servers = _servers;
    if (servers != null) {
      if (servers.isEmpty) {
        return [failure(context.t.plex_signin_no_servers), const SizedBox(height: 8), retry(context.t.retry)];
      }
      return [
        Text(context.t.plex_signin_choose, style: context.textTheme.labelLarge),
        for (final server in servers) _serverTile(context, server, hintStyle),
        Align(alignment: Alignment.centerRight, child: cancel),
      ];
    }
    return switch (_state) {
      null => [
        OutlinedButton.icon(
          key: const Key('plex_signin_start'),
          onPressed: _start,
          icon: const Icon(Icons.login_rounded),
          label: Text(context.t.plex_signin_start, style: buttonText),
        ),
      ],
      PlexTvRequesting() || PlexTvAuthorised() => [
        progress(context.t.plex_signin_requesting),
        Align(alignment: Alignment.centerRight, child: cancel),
      ],
      PlexTvWaiting(:final pin) when pin.strong => [
        progress(context.t.plex_signin_waiting_browser),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const Key('plex_signin_open'),
              onPressed: _openAgain,
              icon: const Icon(Icons.open_in_new_rounded),
              label: Text(context.t.plex_signin_open, style: buttonText),
            ),
            cancel,
          ],
        ),
      ],
      PlexTvWaiting(:final pin) => [
        Text(context.t.plex_signin_code_intro, style: hintStyle),
        const SizedBox(height: 12),
        Wrap(
          spacing: 24,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SelectableText(
              pin.code,
              key: const Key('plex_signin_code'),
              style: context.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.bold, letterSpacing: 8),
            ),
            QrCodeView(
              key: const Key('plex_signin_qr'),
              data: plexTvLinkUrl.toString(),
              size: 140,
              semanticLabel: context.t.plex_signin_qr_label,
            ),
          ],
        ),
        const SizedBox(height: 12),
        const LinearProgressIndicator(),
        Align(alignment: Alignment.centerRight, child: cancel),
      ],
      PlexTvExpired() => [
        failure(context.t.plex_signin_expired),
        const SizedBox(height: 8),
        retry(context.t.plex_signin_new_code),
      ],
      PlexTvFailed(:final error) => [failure(_messageOf(error)), const SizedBox(height: 8), retry(context.t.retry)],
    };
  }

  Widget _serverTile(BuildContext context, PlexTvServer server, TextStyle? hintStyle) {
    final connecting = _connecting == server.clientIdentifier;
    final error = _connectError?.id == server.clientIdentifier ? _connectError!.message : null;
    final String? subtitle = connecting
        ? context.t.plex_signin_connecting
        : (error ?? (server.owned ? null : context.t.plex_signin_shared));
    return ListTile(
      key: Key('plex_signin_server_${server.clientIdentifier}'),
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.dns_outlined),
      title: Text(server.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              style: error != null ? context.textTheme.bodySmall?.copyWith(color: context.colorScheme.error) : null,
            ),
      trailing: connecting
          ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.chevron_right_rounded),
      onTap: _connecting == null ? () => unawaited(_connect(server)) : null,
    );
  }
}
