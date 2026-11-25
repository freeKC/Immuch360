import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/jellyfin_server_info.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_address.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_api.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_client.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_file_system.dart';
import 'package:immich_mobile/platform/tv_api.g.dart';
import 'package:immich_mobile/presentation/widgets/network/found_servers.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/jellyfin_failure.widget.dart';
import 'package:immich_mobile/presentation/widgets/pairing/qr_code.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_text_entry.widget.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/jellyfin_connector.provider.dart';
import 'package:immich_mobile/providers/network/network_discovery.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';
import 'package:immich_mobile/widgets/common/immich_toast.dart';
import 'package:logging/logging.dart';

final _log = Logger('JellyfinServerEditPage');

/// Adds a Jellyfin or Emby server, or edits, signs in again to or removes one when [source] is given. [server] is a
/// server found on the network, which fills the page; [focusCredentials] opens the sign in at once (the "Sign in
/// again" of a server that ended the session).
///
/// Two ways to sign in: the user and the password, sent once to the server and kept nowhere, or Quick Connect on
/// Jellyfin (a code shown here, approved on a phone or a computer already signed in), first on a TV and on a Meta
/// Quest. Only the token is kept, in the secure storage of this device.
@RoutePage()
class JellyfinServerEditPage extends ConsumerStatefulWidget {
  const JellyfinServerEditPage({super.key, this.source, this.server, this.focusCredentials = false});

  final NetworkSource? source;
  final DiscoveredServer? server;
  final bool focusCredentials;

  @override
  ConsumerState<JellyfinServerEditPage> createState() => _JellyfinServerEditPageState();
}

class _JellyfinServerEditPageState extends ConsumerState<JellyfinServerEditPage> {
  late final String _id = widget.source?.id ?? NetworkSourcesNotifier.newId();
  late final _address = TextEditingController(text: _addressOf(widget.source));
  late final _name = TextEditingController(text: widget.source?.name ?? '');
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _addressEntry = FocusNode(canRequestFocus: false, skipTraversal: true);
  final _signInEntry = FocusNode(canRequestFocus: false, skipTraversal: true);
  final _saveFocus = FocusNode();

  /// The server the page connected to, null until then
  JellyfinTarget? _target;
  bool _connecting = false;
  JellyfinFailure? _connectFailure;
  int? _connectStatus;
  int _connects = 0;

  List<JellyfinPublicUser> _users = const [];

  /// Quick Connect: on (null until known), the request shown, its expiry, its failure
  bool? _quickConnectOn;
  JellyfinQuickConnect? _quickConnect;
  bool _quickConnectExpired = false;
  JellyfinFailure? _quickConnectFailure;
  Timer? _poll;
  bool _polling = false;

  bool _signingIn = false;
  JellyfinFailure? _signInFailure;
  int? _signInStatus;
  JellyfinSignIn? _signedIn;

  /// An existing source shows its sign in only after "Sign in again"
  late bool _signingInAgain = widget.focusCredentials;
  bool _saving = false;

  List<DiscoveredServer> _servers = const [];
  StreamSubscription<List<DiscoveredServer>>? _discovery;
  bool _scanning = false;
  bool _scanned = false;

  bool get _isNew => widget.source == null;

  /// The found list shows for a server added from scratch
  bool get _showsDiscovery => _isNew && widget.server == null;

  /// What the page shows of the sign in: a new server once connected, an existing one after "Sign in again"
  bool get _showsSignIn => _target != null && _signedIn == null && (_isNew || _signingInAgain);

  /// A TV or a Meta Quest: Quick Connect first, since typing a password with a remote or in a headset is slow
  bool get _codeFirst => ref.read(tvModeProvider) || (ref.read(isHorizonOsProvider).valueOrNull ?? false);

  static String _addressOf(NetworkSource? source) {
    if (source == null) {
      return '';
    }
    final base = jellyfinBaseOf(source);
    return '$base';
  }

  @override
  void initState() {
    super.initState();
    final server = widget.server;
    if (server != null) {
      _address.text = _addressOfFound(server);
      _name.text = server.displayName;
    } else if (_showsDiscovery) {
      _scan();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      if (server != null || widget.focusCredentials) {
        unawaited(_connect());
      } else if (ref.read(tvModeProvider) && _isNew) {
        _focusInside(_addressEntry);
      }
    });
  }

  static String _addressOfFound(DiscoveredServer server) =>
      '${server.useTls ? 'https' : 'http'}://${server.host.contains(':') ? '[${server.host}]' : server.host}:'
      '${server.port}${server.path}';

  static void _focusInside(FocusNode entry) {
    final target = entry.descendants.where((node) => node.canRequestFocus && !node.skipTraversal).firstOrNull;
    target?.requestFocus();
  }

  @override
  void dispose() {
    _poll?.cancel();
    for (final controller in [_address, _name, _user, _password]) {
      controller.dispose();
    }
    for (final node in [_addressEntry, _signInEntry, _saveFocus]) {
      node.dispose();
    }
    unawaited(_discovery?.cancel());
    super.dispose();
  }

  void _scan() {
    unawaited(_discovery?.cancel());
    void ended() {
      if (mounted) {
        setState(() {
          _scanning = false;
          _scanned = true;
        });
      }
    }

    setState(() {
      _servers = const [];
      _scanning = true;
      _scanned = false;
    });
    try {
      _discovery = ref
          .read(networkDiscoveryServiceProvider)
          .discover()
          .listen(
            (servers) {
              if (mounted) {
                setState(() => _servers = servers);
              }
            },
            onError: (Object error, StackTrace stackTrace) => _log.warning('The search for servers failed', error),
            onDone: ended,
          );
    } catch (error) {
      _log.warning('The search for servers failed to start: ${error.runtimeType}');
      _discovery = null;
      ended();
    }
  }

  void _fillFrom(DiscoveredServer server) {
    setState(() {
      _address.text = _addressOfFound(server);
      if (_name.text.trim().isEmpty) {
        _name.text = server.displayName;
      }
    });
    unawaited(_connect());
  }

  JellyfinAddress? get _typed => parseJellyfinAddress(_address.text);

  /// Reads the public information at the typed address, then what the sign in needs: the users the server shows,
  /// whether Quick Connect is on (and its first code)
  Future<void> _connect() async {
    final typed = _typed;
    _stopQuickConnect();
    if (typed == null) {
      setState(() {
        _target = null;
        _connectFailure = null;
      });
      return;
    }
    final connect = ++_connects;
    setState(() {
      _connecting = true;
      _connectFailure = null;
      _connectStatus = null;
      _target = null;
      _signInFailure = null;
    });
    final connector = ref.read(jellyfinConnectorProvider);
    try {
      final info = await connector.publicInfo(typed.base, _id);
      if (!mounted || connect != _connects) {
        return;
      }
      final target = (base: typed.base, info: info);
      setState(() {
        _target = target;
        _connecting = false;
        if (_name.text.trim().isEmpty && info.serverName != null) {
          _name.text = info.serverName!;
        }
        _quickConnectOn = info.product == JellyfinProduct.jellyfin ? null : false;
      });
      unawaited(_loadUsers(target));
      if (info.product == JellyfinProduct.jellyfin && _showsSignIn) {
        unawaited(_startQuickConnect(target, first: true));
      }
      if (ref.read(tvModeProvider)) {
        WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _focusInside(_signInEntry) : null);
      }
    } on JellyfinException catch (error) {
      if (!mounted || connect != _connects) {
        return;
      }
      setState(() {
        _connecting = false;
        _connectFailure = error.failure;
        _connectStatus = error.status;
      });
    }
  }

  Future<void> _loadUsers(JellyfinTarget target) async {
    try {
      final users = await ref.read(jellyfinConnectorProvider).publicUsers(target, _id);
      if (mounted && identical(_target, target)) {
        setState(() => _users = users);
      }
    } catch (error) {
      _log.fine('No public users: ${jellyfinErrorKind(error)}');
    }
  }

  void _stopQuickConnect() {
    _poll?.cancel();
    _poll = null;
    _quickConnect = null;
    _quickConnectExpired = false;
    _quickConnectFailure = null;
  }

  /// Asks the server for a code, then polls every 5 seconds whether it was approved, until it is, expires, or the
  /// page goes away
  Future<void> _startQuickConnect(JellyfinTarget target, {bool first = false}) async {
    final connector = ref.read(jellyfinConnectorProvider);
    setState(_stopQuickConnect);
    try {
      final on = await connector.quickConnectEnabled(target, _id);
      if (!mounted || !identical(_target, target)) {
        return;
      }
      setState(() => _quickConnectOn = on);
      if (!on) {
        return;
      }
      final started = await connector.quickConnectStart(target, _id);
      if (!mounted || !identical(_target, target)) {
        return;
      }
      setState(() => _quickConnect = started);
      _poll = Timer.periodic(pollInterval, (_) => unawaited(_checkQuickConnect(target, started)));
    } on JellyfinException catch (error) {
      if (mounted) {
        setState(() {
          if (error.failure == JellyfinFailure.quickConnectOff) {
            _quickConnectOn = false;
          } else {
            _quickConnectFailure = error.failure;
          }
        });
      }
    }
  }

  static const pollInterval = Duration(seconds: 5);

  Future<void> _checkQuickConnect(JellyfinTarget target, JellyfinQuickConnect request) async {
    if (_polling || !mounted || !identical(_quickConnect, request)) {
      return;
    }
    _polling = true;
    final connector = ref.read(jellyfinConnectorProvider);
    try {
      if (!await connector.quickConnectApproved(target, _id, request.secret)) {
        return;
      }
      _poll?.cancel();
      final signedIn = await connector.quickConnectSignIn(target, _id, request.secret);
      if (mounted && identical(_quickConnect, request)) {
        _signedInWith(signedIn);
      }
    } on JellyfinException catch (error) {
      if (!mounted || !identical(_quickConnect, request)) {
        return;
      }
      _poll?.cancel();
      setState(() {
        if (error.failure == JellyfinFailure.quickConnectExpired) {
          _quickConnectExpired = true;
        } else {
          _quickConnectFailure = error.failure;
        }
      });
    } finally {
      _polling = false;
    }
  }

  Future<void> _signInWithPassword() async {
    final target = _target;
    final user = _user.text.trim();
    if (target == null || user.isEmpty || _signingIn) {
      return;
    }
    setState(() {
      _signingIn = true;
      _signInFailure = null;
      _signInStatus = null;
    });
    try {
      final signedIn = await ref.read(jellyfinConnectorProvider).signIn(target, _id, user, _password.text);
      if (mounted) {
        _signedInWith(signedIn);
      }
    } on JellyfinException catch (error) {
      if (mounted) {
        setState(() {
          _signingIn = false;
          _signInFailure = error.failure;
          _signInStatus = error.status;
        });
      }
    }
  }

  void _signedInWith(JellyfinSignIn signedIn) {
    _stopQuickConnect();
    setState(() {
      _signedIn = signedIn;
      _signingIn = false;
      _password.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _saveFocus.requestFocus();
      }
    });
  }

  /// The source the page describes, null when it cannot be saved
  NetworkSource? _formSource() {
    final previous = widget.source;
    final target = _target;
    final signedIn = _signedIn;
    final name = _name.text.trim();
    if (previous != null && signedIn == null) {
      // A rename: the address, the server and the session stay
      return previous.copyWith(name: name.isEmpty ? previous.name : name);
    }
    final typed = _typed;
    if (target == null || signedIn == null || typed == null) {
      return null;
    }
    final info = JellyfinServerInfo(
      serverId: target.info.id,
      userId: signedIn.userId,
      product: target.info.product.name,
      version: target.info.version,
    );
    final shown = name.isNotEmpty ? name : (target.info.serverName ?? typed.host);
    return NetworkSource(
      id: _id,
      type: NetworkSourceType.jellyfin,
      name: shown,
      host: typed.host,
      port: typed.storedPort,
      share: typed.basePath,
      rootPath: previous?.rootPath ?? '/',
      username: signedIn.userName,
      useTls: typed.useTls,
      discoveryId: target.info.id,
      jellyfin: info,
    );
  }

  bool get _canSave => !_saving && _formSource() != null && (_isNew ? _signedIn != null : true);

  Future<void> _save() async {
    final source = _formSource();
    if (source == null || !_canSave) {
      return;
    }
    setState(() => _saving = true);
    final sources = ref.read(networkSourcesProvider.notifier);
    final token = _signedIn?.accessToken;
    try {
      if (_isNew) {
        await sources.add(source, password: token);
      } else {
        // A null token keeps the stored one (a rename)
        await sources.update(source, password: token);
      }
      if (mounted) {
        await context.maybePop();
      }
    } catch (error, stackTrace) {
      _log.severe('Could not save a Jellyfin server', error, stackTrace);
      if (mounted) {
        setState(() => _saving = false);
        ImmichToast.show(context: context, toastType: ToastType.error, msg: context.t.scaffold_body_error_occurred);
      }
    }
  }

  Future<void> _remove() async {
    final source = widget.source;
    if (source == null) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => ConfirmDialog(
        title: context.t.network_share_remove,
        content: context.t.jellyfin_remove_confirm(name: source.name),
        ok: context.t.remove,
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    final sources = ref.read(networkSourcesProvider.notifier);
    final info = source.jellyfin;
    try {
      final token = await sources.readPassword(source.id);
      if (token != null && info != null) {
        // Best effort: the session ends on the server too, when it answers
        final target = (
          base: jellyfinBaseOf(source),
          info: JellyfinPublicInfo(
            id: info.serverId,
            product: info.isEmby ? JellyfinProduct.emby : JellyfinProduct.jellyfin,
            version: info.version,
          ),
        );
        await ref.read(jellyfinConnectorProvider).signOut(target, source.id, token).timeout(const Duration(seconds: 5));
      }
    } catch (error) {
      _log.info('The server was not told of the sign out: ${jellyfinErrorKind(error)}');
    }
    await sources.remove(source.id);
    if (mounted) {
      await context.maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final labelStyle = context.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold);
    final hintStyle = context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceVariant);
    const buttonText = TextStyle(fontSize: 14, fontWeight: FontWeight.bold);
    final source = widget.source;
    final target = _target;
    final typed = _typed;
    final product = target?.info.product.shownName ?? source?.jellyfin?.productName ?? 'Jellyfin';
    final signIn = _showsSignIn;
    final codeFirst = _codeFirst;
    final quickConnect = _quickConnectPanel(context, hintStyle, buttonText);
    final password = _passwordPanel(context, labelStyle, buttonText);
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? context.t.jellyfin_page_title_add : context.t.jellyfin_page_title_edit(product: product)),
        elevation: 0,
        leading: const CloseButton(),
        centerTitle: false,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          children: [
            const SizedBox(height: 12),
            if (_showsDiscovery) ...[
              FoundServersList(
                servers: _servers,
                scanning: _scanning,
                scanned: _scanned,
                onScan: _scan,
                onSelected: _fillFrom,
                filter: (server) => server.type == NetworkSourceType.jellyfin,
                scanningText: context.t.jellyfin_scan_scanning,
                noneFoundText: context.t.jellyfin_scan_none_found,
              ),
              const SizedBox(height: 4),
            ],
            Focus(
              focusNode: _addressEntry,
              child: _field(
                _address,
                context.t.jellyfin_address,
                TvTextKind.url,
                key: const Key('jellyfin_address'),
                hint: context.t.jellyfin_address_hint,
                keyboardType: TextInputType.url,
                errorText: _address.text.trim().isNotEmpty && typed == null ? context.t.jellyfin_address_invalid : null,
                onEntered: () => unawaited(_connect()),
              ),
            ),
            if (typed != null && typed.isPlainOutsideHome) ...[
              const SizedBox(height: 4),
              Text(
                context.t.jellyfin_http_outside,
                key: const Key('jellyfin_http_outside'),
                style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.error),
              ),
            ],
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('jellyfin_connect'),
                onPressed: typed == null || _connecting ? null : () => unawaited(_connect()),
                icon: _connecting
                    ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.link_rounded),
                label: Text(context.t.jellyfin_connect, style: buttonText),
              ),
            ),
            if (_connectFailure != null) ...[
              _ResultLine(
                key: const Key('jellyfin_connect_error'),
                message: jellyfinFailureMessage(context, _connectFailure!),
                succeeded: false,
              ),
              const SizedBox(height: 4),
              JellyfinDiagnostics(
                line: jellyfinDiagnosticsLine(
                  product: source?.jellyfin?.isEmby ?? false ? JellyfinProduct.emby : JellyfinProduct.jellyfin,
                  version: source?.jellyfin?.version,
                  step: 'connect',
                  status: _connectStatus,
                  tls: typed?.useTls ?? false,
                ),
              ),
            ] else if (target != null)
              Card(
                key: const Key('jellyfin_server_card'),
                margin: const EdgeInsets.only(top: 4),
                child: ListTile(
                  leading: const Icon(Icons.live_tv_outlined),
                  title: Text(
                    context.t.jellyfin_found(
                      product: target.info.product.shownName,
                      version: target.info.version ?? '?',
                      name: target.info.serverName ?? target.base.host,
                    ),
                  ),
                  subtitle: Text('${target.base}', maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
            if (signIn)
              Focus(
                focusNode: _signInEntry,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 16),
                    if (codeFirst) ...[
                      quickConnect,
                      const SizedBox(height: 20),
                      password,
                    ] else ...[
                      password,
                      const SizedBox(height: 20),
                      quickConnect,
                    ],
                  ],
                ),
              ),
            if (_signedIn != null) ...[
              const SizedBox(height: 16),
              _ResultLine(
                key: const Key('jellyfin_signed_in'),
                message: context.t.jellyfin_signed_in(user: _signedIn!.userName),
                succeeded: true,
              ),
            ],
            if (!_isNew || _signedIn != null) ...[
              const SizedBox(height: 20),
              _field(
                _name,
                context.t.network_share_name,
                TvTextKind.text,
                key: const Key('jellyfin_name'),
                hint: target?.info.serverName,
              ),
            ],
            const SizedBox(height: 24),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (!_isNew) ...[
                    OutlinedButton.icon(
                      key: const Key('jellyfin_remove'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: context.colorScheme.error,
                        side: BorderSide(color: context.colorScheme.error),
                      ),
                      onPressed: _saving ? null : () => unawaited(_remove()),
                      icon: const Icon(Icons.delete_outline),
                      label: Text(context.t.network_share_remove, style: buttonText),
                    ),
                    if (!_signingInAgain)
                      OutlinedButton.icon(
                        key: const Key('jellyfin_sign_in_again'),
                        onPressed: () {
                          setState(() => _signingInAgain = true);
                          unawaited(_connect());
                        },
                        icon: const Icon(Icons.login_rounded),
                        label: Text(context.t.jellyfin_sign_in_again, style: buttonText),
                      ),
                  ],
                  ElevatedButton.icon(
                    key: const Key('jellyfin_save'),
                    focusNode: _saveFocus,
                    onPressed: _canSave ? () => unawaited(_save()) : null,
                    icon: const Icon(Icons.check),
                    label: Text(context.t.network_share_save, style: buttonText),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _passwordPanel(BuildContext context, TextStyle? labelStyle, TextStyle buttonText) {
    final failure = _signInFailure;
    final target = _target;
    return Column(
      key: const Key('jellyfin_password_panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(context.t.jellyfin_sign_in_password, style: labelStyle),
        const SizedBox(height: 8),
        if (_users.isNotEmpty) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final user in _users)
                ChoiceChip(
                  key: Key('jellyfin_user_${user.id}'),
                  avatar: const Icon(Icons.person_outline, size: 18),
                  label: Text(user.name),
                  selected: _user.text == user.name,
                  onSelected: (_) => setState(() => _user.text = user.name),
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        _field(_user, context.t.jellyfin_user, TvTextKind.text, key: const Key('jellyfin_user')),
        const SizedBox(height: 12),
        _field(
          _password,
          context.t.jellyfin_password,
          TvTextKind.password,
          key: const Key('jellyfin_password'),
          obscureText: true,
          onEntered: () => unawaited(_signInWithPassword()),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('jellyfin_sign_in'),
            onPressed: _user.text.trim().isEmpty || _signingIn ? null : () => unawaited(_signInWithPassword()),
            icon: _signingIn
                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.login_rounded),
            label: Text(context.t.jellyfin_sign_in, style: buttonText),
          ),
        ),
        if (failure != null) ...[
          _ResultLine(
            key: const Key('jellyfin_sign_in_error'),
            message: jellyfinFailureMessage(context, failure),
            succeeded: false,
          ),
          if (target != null && failure != JellyfinFailure.passwordRefused)
            JellyfinDiagnostics(
              line: jellyfinDiagnosticsLine(
                product: target.info.product,
                version: target.info.version,
                step: 'sign in',
                status: _signInStatus,
                tls: target.base.scheme == 'https',
              ),
            ),
        ],
      ],
    );
  }

  Widget _quickConnectPanel(BuildContext context, TextStyle? hintStyle, TextStyle buttonText) {
    final target = _target;
    final labelStyle = context.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold);
    final request = _quickConnect;
    final List<Widget> body;
    if (target == null) {
      body = const [];
    } else if (target.info.product == JellyfinProduct.emby) {
      body = [
        Text(context.t.jellyfin_emby_password_only, key: const Key('jellyfin_emby_password_only'), style: hintStyle),
      ];
    } else if (_quickConnectOn == false) {
      body = [
        Text(context.t.jellyfin_quick_connect_off, key: const Key('jellyfin_quick_connect_off'), style: hintStyle),
      ];
    } else if (_quickConnectExpired || _quickConnectFailure != null) {
      body = [
        _ResultLine(
          key: const Key('jellyfin_quick_connect_expired'),
          message: _quickConnectExpired
              ? context.t.jellyfin_quick_connect_expired
              : jellyfinFailureMessage(context, _quickConnectFailure!),
          succeeded: false,
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('jellyfin_quick_connect_new'),
            onPressed: () => unawaited(_startQuickConnect(target)),
            icon: const Icon(Icons.refresh_rounded),
            label: Text(context.t.jellyfin_quick_connect_new, style: buttonText),
          ),
        ),
      ];
    } else if (request == null) {
      body = [const LinearProgressIndicator()];
    } else {
      body = [
        Text(context.t.jellyfin_quick_connect_steps, style: hintStyle),
        const SizedBox(height: 12),
        Wrap(
          spacing: 24,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SelectableText(
              request.code,
              key: const Key('jellyfin_quick_connect_code'),
              style: context.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.bold, letterSpacing: 8),
            ),
            QrCodeView(
              key: const Key('jellyfin_quick_connect_qr'),
              data: ref.read(jellyfinConnectorProvider).quickConnectPage(target).toString(),
              size: 140,
              semanticLabel: context.t.jellyfin_quick_connect_qr_label,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(context.t.jellyfin_quick_connect_waiting, style: hintStyle),
        const SizedBox(height: 4),
        const LinearProgressIndicator(),
      ];
    }
    return Column(
      key: const Key('jellyfin_quick_connect_panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(context.t.jellyfin_quick_connect, style: labelStyle),
        const SizedBox(height: 8),
        ...body,
      ],
    );
  }

  Widget _field(
    TextEditingController controller,
    String label,
    TvTextKind kind, {
    required Key key,
    String? hint,
    String? errorText,
    TextInputType? keyboardType,
    bool obscureText = false,
    VoidCallback? onEntered,
  }) {
    return TvTextEntry(
      controller: controller,
      label: label,
      kind: kind,
      onSubmitted: (_) {
        setState(() {});
        onEntered?.call();
      },
      child: TextField(
        key: key,
        controller: controller,
        keyboardType: keyboardType,
        obscureText: obscureText,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.next,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(fontWeight: FontWeight.bold),
          floatingLabelBehavior: FloatingLabelBehavior.always,
          border: const OutlineInputBorder(),
          hintText: hint,
          errorText: errorText,
        ),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => onEntered?.call(),
      ),
    );
  }
}

class _ResultLine extends StatelessWidget {
  const _ResultLine({super.key, required this.message, required this.succeeded});

  final String message;
  final bool succeeded;

  @override
  Widget build(BuildContext context) {
    final color = succeeded ? context.primaryColor : context.colorScheme.error;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(succeeded ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message, style: context.textTheme.bodyMedium?.copyWith(color: color)),
          ),
        ],
      ),
    );
  }
}
