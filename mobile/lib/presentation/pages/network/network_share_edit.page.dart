import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/tv_api.g.dart';
import 'package:immich_mobile/presentation/widgets/forms/discard_changes.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/found_servers.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_focusable.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_text_entry.widget.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/network/network_discovery.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';
import 'package:immich_mobile/widgets/common/immich_toast.dart';
import 'package:logging/logging.dart';

final _log = Logger('NetworkShareEditPage');

/// What a pasted address says: smb://nas/media/photos, \\nas\media, https://cloud.example.com/remote.php/dav,
/// http://192.168.1.10:8200/rootDesc.xml
@visibleForTesting
class NetworkAddress {
  const NetworkAddress({
    required this.type,
    required this.host,
    this.port,
    this.share = '',
    this.rootPath,
    this.useTls = false,
  });

  final NetworkSourceType type;
  final String host;
  final int? port;

  /// SMB share name, the path of the WebDAV address, or the path and query of the DLNA device description
  final String share;

  /// SMB: the folder after the share name, null when there is none
  final String? rootPath;
  final bool useTls;
}

/// Reads a full address typed or pasted in the server field; null when it is a plain server name or address. An http
/// or https address is the device description of a DLNA media server when the form is for one ([current]) or when it
/// names an XML file, else a WebDAV address.
@visibleForTesting
NetworkAddress? parseNetworkAddress(String input, {NetworkSourceType? current}) {
  var text = input.trim();
  if (text.startsWith(r'\\')) {
    // A Windows path: \\server\share\folder
    text = 'smb://${text.substring(2).replaceAll(r'\', '/')}';
  }
  if (!text.contains('://')) {
    return null;
  }
  final uri = Uri.tryParse(text);
  if (uri == null || uri.host.isEmpty) {
    return null;
  }
  final scheme = uri.scheme.toLowerCase();
  final segments = uri.pathSegments.where((segment) => segment.isNotEmpty).toList();
  final type = switch (scheme) {
    'smb' || 'cifs' => NetworkSourceType.smb,
    'upnp' || 'dlna' => NetworkSourceType.dlna,
    'http' || 'https'
        when current == NetworkSourceType.dlna || (segments.lastOrNull ?? '').toLowerCase().endsWith('.xml') =>
      NetworkSourceType.dlna,
    'http' || 'https' || 'dav' || 'davs' || 'webdav' || 'webdavs' => NetworkSourceType.webdav,
    _ => null,
  };
  if (type == null) {
    return null;
  }
  final port = uri.hasPort ? uri.port : null;
  if (type == NetworkSourceType.dlna) {
    return NetworkAddress(
      type: type,
      host: uri.host,
      port: port,
      share: uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path,
      useTls: scheme == 'https',
    );
  }
  if (type == NetworkSourceType.smb) {
    return NetworkAddress(
      type: type,
      host: uri.host,
      port: port,
      share: segments.firstOrNull ?? '',
      rootPath: segments.length > 1 ? '/${segments.skip(1).join('/')}' : null,
    );
  }
  return NetworkAddress(
    type: type,
    host: uri.host,
    port: port,
    share: segments.isEmpty ? '' : '/${segments.join('/')}',
    useTls: scheme == 'https' || scheme == 'davs' || scheme == 'webdavs',
  );
}

/// A folder path as the sources keep it: "/" separated, starting with "/", no "/" at the end; [empty] for the root
@visibleForTesting
String normalizeNetworkPath(String input, {String empty = '/'}) {
  final segments = input.trim().replaceAll(r'\', '/').split('/').where((segment) => segment.isNotEmpty);
  return segments.isEmpty ? empty : '/${segments.join('/')}';
}

/// The path and query of a DLNA device description as the sources keep it: starting with "/", the rest as typed (the
/// query of Jellyfin or Plex matters); "" when nothing was typed
@visibleForTesting
String normalizeDescriptionPath(String input) {
  final text = input.trim();
  return text.isEmpty || text.startsWith('/') ? text : '/$text';
}

/// What the fields of the share form hold, the password apart (it is read later for an existing share)
typedef _ShareFormFields = ({
  NetworkSourceType type,
  bool useTls,
  String name,
  String host,
  String port,
  String share,
  String rootPath,
  String username,
});

/// Adds a network share, or edits or removes one when [source] is given
@RoutePage()
class NetworkShareEditPage extends ConsumerStatefulWidget {
  const NetworkShareEditPage({super.key, this.source});

  final NetworkSource? source;

  @override
  ConsumerState<NetworkShareEditPage> createState() => _NetworkShareEditPageState();
}

class _NetworkShareEditPageState extends ConsumerState<NetworkShareEditPage> {
  late final String _id = widget.source?.id ?? NetworkSourcesNotifier.newId();
  late NetworkSourceType _type = widget.source?.type ?? NetworkSourceType.smb;
  late bool _useTls = widget.source?.useTls ?? false;
  late final _name = TextEditingController(text: widget.source?.name ?? '');
  late final _host = TextEditingController(text: widget.source?.host ?? '');
  late final _port = TextEditingController(text: widget.source?.port?.toString() ?? '');
  late final _share = TextEditingController(text: widget.source?.share ?? '');
  late final _rootPath = TextEditingController(
    text: widget.source == null || widget.source!.rootPath == '/' ? '' : widget.source!.rootPath,
  );
  late final _username = TextEditingController(text: widget.source?.username ?? '');
  final _password = TextEditingController();
  late final _fieldChanges = Listenable.merge([_name, _host, _port, _share, _rootPath, _username, _password]);
  final _hostFocus = FocusNode();
  final _usernameFocus = FocusNode();
  final _passwordFocus = FocusNode();

  /// False until the stored password of an existing share is in the field; saving before keeps the stored one
  late bool _passwordLoaded = widget.source == null;
  bool _showPassword = false;
  bool _testing = false;
  bool _saving = false;

  /// The outcome of the last connection test, null when there was none since the last change
  String? _testMessage;
  bool _testSucceeded = false;

  /// The servers found on the network, for a new share only
  List<DiscoveredServer> _servers = const [];
  StreamSubscription<List<DiscoveredServer>>? _discovery;
  bool _scanning = false;

  /// Whether a scan ended, so that "nothing found" is not told before
  bool _scanned = false;

  bool _listingShares = false;

  /// Why the shares of the server could not be listed, null when they could or were not asked
  String? _shareListError;

  /// What [_fillFrom] last put in the name and share fields (the share picked in the list of the server counts too):
  /// the next server tapped replaces a field that still holds it, and leaves alone what the user typed instead
  String? _filledName;
  String? _filledShare;

  /// The id the server tapped announces (see NetworkSource.discoveryId), saved with a share of its type; dropped when
  /// the user edits the server field, the share being then the server typed
  late ({NetworkSourceType type, String id})? _filledDiscovery = switch (widget.source) {
    NetworkSource(:final type, discoveryId: final String id) => (type: type, id: id),
    _ => null,
  };

  bool get _isNew => widget.source == null;

  /// What the form held when it opened, the stored password once read included: leaving with other values asks first
  late final _ShareFormFields _openedWith;
  String _openedWithPassword = '';

  /// The page is going away on purpose (saved, removed, replaced by the page of a Plex server or a camera)
  bool _leaving = false;

  _ShareFormFields _fields() => (
    type: _type,
    useTls: _useTls,
    name: _name.text,
    host: _host.text,
    port: _port.text,
    share: _share.text,
    rootPath: _rootPath.text,
    username: _username.text,
  );

  bool get _hasUnsavedChanges =>
      !_saving && !_leaving && (_fields() != _openedWith || _password.text != _openedWithPassword);

  /// Opens the page of a Plex server or a camera in place of this one, once the user agreed to lose what the form
  /// holds, if anything
  Future<void> _replaceWith(PageRouteInfo route) async {
    if (_hasUnsavedChanges && !await confirmDiscardChanges(context)) {
      return;
    }
    if (!mounted) {
      return;
    }
    _leaving = true;
    await context.replaceRoute(route);
  }

  @override
  void initState() {
    super.initState();
    // Before anything fills a field
    _openedWith = _fields();
    _hostFocus.addListener(() {
      if (!_hostFocus.hasFocus && mounted) {
        _expandAddress();
      }
    });
    if (_isNew) {
      _scan();
    } else {
      unawaited(_loadPassword());
    }
  }

  /// Looks for the SMB, WebDAV and DLNA servers, the phone shares, the Plex servers and the cameras of the network
  /// (the last two open their own pages), again when called again
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
            onError: (Object error, StackTrace stackTrace) =>
                _log.warning('The search for network servers failed', error, stackTrace),
            onDone: ended,
          );
    } catch (error, stackTrace) {
      _log.warning('The search for network servers failed to start', error, stackTrace);
      _discovery = null;
      ended();
    }
  }

  /// Fills the form with a server found on the network, then asks for what is missing: the user name, the password
  /// of a phone share (its user name is announced), nothing for a DLNA media server. A Plex server and a camera have
  /// pages of their own, which take the place of this one, filled in.
  void _fillFrom(DiscoveredServer server) {
    if (server.type == NetworkSourceType.plex) {
      unawaited(_replaceWith(PlexServerEditRoute(server: server)));
      return;
    }
    if (server.type == NetworkSourceType.tapo) {
      unawaited(_replaceWith(CameraEditRoute(server: server)));
      return;
    }
    final isDlna = server.type == NetworkSourceType.dlna;
    setState(() {
      // A share name and a WebDAV path do not mean the same, and what was filled in for another server is not right
      // for this one. The path is "" for SMB. The description path of a DLNA server and the root of a phone share
      // belong to the server.
      final share = server.isPhoneShare ? '/' : server.path;
      if (isDlna ||
          server.isPhoneShare ||
          server.type != _type ||
          _share.text.trim().isEmpty ||
          _share.text == _filledShare) {
        _share.text = share;
        _filledShare = share;
      }
      _type = server.type;
      _host.text = server.host;
      _port.text = '${server.port}';
      if (server.type != NetworkSourceType.smb) {
        _useTls = server.useTls;
      }
      final username = server.username;
      if (server.isPhoneShare && username != null) {
        _username.text = username;
      }
      if (_name.text.trim().isEmpty || _name.text == _filledName) {
        _name.text = server.displayName;
        _filledName = server.displayName;
      }
      final discoveryId = server.discoveryId;
      _filledDiscovery = discoveryId == null ? null : (type: server.type, id: discoveryId);
      _testMessage = null;
      _shareListError = null;
    });
    if (server.isPhoneShare) {
      _passwordFocus.requestFocus();
    } else if (!isDlna) {
      _usernameFocus.requestFocus();
    }
  }

  /// Lists the shares of the SMB server of the fields and puts the one chosen in the share field
  Future<void> _chooseShare() async {
    _expandAddress();
    final host = _host.text.trim();
    // A pasted WebDAV address turns the form into a WebDAV one
    if (host.isEmpty || _type != NetworkSourceType.smb) {
      return;
    }
    final source = NetworkSource(
      id: _id,
      type: NetworkSourceType.smb,
      name: host,
      host: host,
      port: _port.text.trim().isEmpty || !_portIsValid ? null : _portValue,
      username: _username.text.trim(),
    );
    setState(() {
      _listingShares = true;
      _shareListError = null;
    });
    final List<String> shares;
    try {
      shares = await ref.read(networkShareListerProvider)(source, _password.text.isEmpty ? null : _password.text);
    } catch (error) {
      if (mounted) {
        setState(() {
          _listingShares = false;
          _shareListError = context.t.network_share_scan_shares_error(
            error: error is NetworkFileSystemException ? error.message : error,
          );
        });
      }
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() => _listingShares = false);
    final chosen = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _SharePicker(host: host, shares: shares),
    );
    if (chosen != null && mounted) {
      setState(() {
        _share.text = chosen;
        // A share of this server: another server tapped then replaces it
        _filledShare = chosen;
        _testMessage = null;
      });
    }
  }

  Future<void> _loadPassword() async {
    try {
      final password = await ref.read(networkSourcesProvider.notifier).readPassword(_id);
      if (!mounted) {
        return;
      }
      setState(() {
        if (_password.text.isEmpty) {
          _password.text = password ?? '';
          _openedWithPassword = _password.text;
        }
        _passwordLoaded = true;
      });
    } catch (error, stackTrace) {
      _log.warning('Could not read the password of a network share', error, stackTrace);
    }
  }

  @override
  void dispose() {
    for (final controller in [_name, _host, _port, _share, _rootPath, _username, _password]) {
      controller.dispose();
    }
    _hostFocus.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    unawaited(_discovery?.cancel());
    super.dispose();
  }

  /// Spreads a full address typed in the server field over the other fields
  void _expandAddress() {
    final address = parseNetworkAddress(_host.text, current: _type);
    if (address == null) {
      return;
    }
    setState(() {
      _type = address.type;
      _host.text = address.host;
      if (address.port != null) {
        _port.text = '${address.port}';
      }
      if (address.share.isNotEmpty) {
        _share.text = address.share;
      }
      final rootPath = address.rootPath;
      if (rootPath != null) {
        _rootPath.text = rootPath;
      }
      if (address.type != NetworkSourceType.smb) {
        _useTls = address.useTls;
      }
      _testMessage = null;
    });
  }

  /// The buttons depend on the fields, and the outcome of a test no longer holds
  void _changed() => setState(() => _testMessage = null);

  int? get _portValue => int.tryParse(_port.text.trim());

  bool get _portIsValid {
    if (_port.text.trim().isEmpty) {
      return true;
    }
    final port = _portValue;
    return port != null && port > 0 && port < 65536;
  }

  /// The share the fields describe, null while a required field is missing. A full address still in the server
  /// field counts as spread over the other fields (see [_expandAddress]), so the buttons are ready as soon as it is
  /// typed.
  NetworkSource? _formSource() {
    final address = parseNetworkAddress(_host.text, current: _type);
    final type = address?.type ?? _type;
    final host = address?.host ?? _host.text.trim();
    final shareText = address != null && address.share.isNotEmpty ? address.share : _share.text;
    final share = switch (type) {
      NetworkSourceType.smb => shareText.trim().replaceAll(RegExp(r'^[/\\]+|[/\\]+$'), ''),
      NetworkSourceType.webdav => normalizeNetworkPath(shareText, empty: ''),
      NetworkSourceType.dlna => normalizeDescriptionPath(shareText),
      // Never held by this form: they have pages of their own
      NetworkSourceType.plex || NetworkSourceType.tapo => null,
    };
    if (share == null) {
      return null;
    }
    if (host.isEmpty || !_portIsValid || (type != NetworkSourceType.webdav && share.isEmpty)) {
      return null;
    }
    final name = _name.text.trim();
    final discovery = _filledDiscovery;
    return NetworkSource(
      id: _id,
      type: type,
      name: name.isEmpty ? host : name,
      host: host,
      port: address?.port ?? (_port.text.trim().isEmpty ? null : _portValue),
      share: share,
      rootPath: normalizeNetworkPath(address?.rootPath ?? _rootPath.text),
      // DLNA has no authentication
      username: type == NetworkSourceType.dlna ? '' : _username.text.trim(),
      useTls: type != NetworkSourceType.smb && (address?.useTls ?? _useTls),
      discoveryId: discovery != null && discovery.type == type ? discovery.id : null,
      // What a later build stored with the share, which this form does not show, is written back as it was
      extraJson: widget.source?.extraJson ?? const {},
    );
  }

  Future<void> _test() async {
    _expandAddress();
    final source = _formSource();
    if (source == null) {
      return;
    }
    setState(() {
      _testing = true;
      _testMessage = null;
    });
    String message;
    var succeeded = false;
    try {
      final count = await ref.read(networkConnectionsProvider).testConnection(source, _password.text);
      if (!mounted) {
        return;
      }
      message = context.t.network_share_connected(count: count);
      succeeded = true;
    } catch (error) {
      if (!mounted) {
        return;
      }
      message = context.t.network_share_failed(error: error is NetworkFileSystemException ? error.message : error);
    }
    setState(() {
      _testing = false;
      _testMessage = message;
      _testSucceeded = succeeded;
    });
  }

  Future<void> _save() async {
    _expandAddress();
    final source = _formSource();
    if (source == null) {
      return;
    }
    setState(() => _saving = true);
    final sources = ref.read(networkSourcesProvider.notifier);
    // An empty field forgets the password, unless the stored one was not read yet. DLNA has no password: one left
    // from another type of share is forgotten.
    final password = source.type == NetworkSourceType.dlna
        ? ''
        : _passwordLoaded || _password.text.isNotEmpty
        ? _password.text
        : null;
    try {
      if (_isNew) {
        await sources.add(source, password: password);
      } else {
        await sources.update(source, password: password);
      }
      if (mounted) {
        await context.maybePop();
      }
    } catch (error, stackTrace) {
      _log.severe('Could not save a network share', error, stackTrace);
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
        content: context.t.network_share_remove_confirm(name: source.name),
        ok: context.t.remove,
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    await ref.read(networkSourcesProvider.notifier).remove(source.id);
    if (mounted) {
      _leaving = true;
      await context.maybePop();
    }
  }

  InputDecoration _decoration(String label, {String? hint, String? errorText, Widget? suffixIcon}) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(fontWeight: FontWeight.bold),
      floatingLabelBehavior: FloatingLabelBehavior.always,
      border: const OutlineInputBorder(),
      hintText: hint,
      hintStyle: const TextStyle(fontWeight: FontWeight.normal, fontSize: 14),
      errorText: errorText,
      suffixIcon: suffixIcon,
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    Key? key,
    String? hint,
    String? errorText,
    FocusNode? focusNode,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    bool obscureText = false,
    Widget? suffixIcon,
    Iterable<String>? autofillHints,
    ValueChanged<String>? onChanged,
    TvTextKind tvKind = TvTextKind.text,
  }) {
    // On a TV the field is typed in through the native text dialog, whose text does not go through onChanged
    return TvTextEntry(
      controller: controller,
      label: label,
      kind: tvKind,
      onSubmitted: (value) {
        onChanged?.call(value);
        _changed();
      },
      child: _textField(
        controller,
        label,
        key: key,
        hint: hint,
        errorText: errorText,
        focusNode: focusNode,
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        obscureText: obscureText,
        suffixIcon: suffixIcon,
        autofillHints: autofillHints,
        onChanged: onChanged,
      ),
    );
  }

  Widget _textField(
    TextEditingController controller,
    String label, {
    Key? key,
    String? hint,
    String? errorText,
    FocusNode? focusNode,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    bool obscureText = false,
    Widget? suffixIcon,
    Iterable<String>? autofillHints,
    ValueChanged<String>? onChanged,
  }) {
    return TextField(
      key: key,
      controller: controller,
      focusNode: focusNode,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      obscureText: obscureText,
      autocorrect: false,
      enableSuggestions: !obscureText,
      autofillHints: autofillHints,
      textInputAction: TextInputAction.next,
      decoration: _decoration(label, hint: hint, errorText: errorText, suffixIcon: suffixIcon),
      onChanged: (value) {
        onChanged?.call(value);
        _changed();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isSmb = _type == NetworkSourceType.smb;
    final isDlna = _type == NetworkSourceType.dlna;
    final canSubmit = _formSource() != null && !_testing && !_saving;
    final canListShares = _host.text.trim().isNotEmpty && _username.text.trim().isNotEmpty && !_listingShares;
    final labelStyle = context.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold);

    return DiscardChangesScope(
      listenable: _fieldChanges,
      hasChanges: () => _hasUnsavedChanges,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isNew ? context.t.network_share_add : context.t.network_share_edit),
          elevation: 0,
          leading: const CloseButton(),
          centerTitle: false,
        ),
        // A remote control starts on the first item: a server found, or the first choice of the form
        body: RemoteInitialFocus(
          enabled: ref.watch(tvModeProvider),
          child: SafeArea(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              children: [
                const SizedBox(height: 20),
                if (_isNew) ...[
                  FoundServersList(
                    servers: _servers,
                    scanning: _scanning,
                    scanned: _scanned,
                    onScan: _scan,
                    onSelected: _fillFrom,
                  ),
                  const SizedBox(height: 20),
                ],
                Text(context.t.network_share_type, style: labelStyle),
                RadioGroup<NetworkSourceType>(
                  groupValue: _type,
                  onChanged: (type) {
                    if (type == NetworkSourceType.plex) {
                      // A Plex server is paired on a page of its own: none of these fields makes sense for it
                      unawaited(_replaceWith(PlexServerEditRoute()));
                      return;
                    }
                    if (type != null && type != _type) {
                      setState(() {
                        _type = type;
                        if (type == NetworkSourceType.dlna) {
                          // The switch is not shown for DLNA: an https description address sets it again
                          _useTls = false;
                        }
                        _testMessage = null;
                      });
                    }
                  },
                  child: Column(
                    children: [
                      RadioListTile<NetworkSourceType>(
                        key: const Key('network_share_type_smb'),
                        value: NetworkSourceType.smb,
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(context.t.network_share_type_smb),
                      ),
                      RadioListTile<NetworkSourceType>(
                        key: const Key('network_share_type_webdav'),
                        value: NetworkSourceType.webdav,
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(context.t.network_share_type_webdav),
                      ),
                      RadioListTile<NetworkSourceType>(
                        key: const Key('network_share_type_dlna'),
                        value: NetworkSourceType.dlna,
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(context.t.network_share_type_dlna),
                      ),
                      // A share saved as another type stays one of those: a Plex server is added, not converted
                      if (_isNew)
                        RadioListTile<NetworkSourceType>(
                          key: const Key('network_share_type_plex'),
                          value: NetworkSourceType.plex,
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: Text(context.t.network_share_type_plex),
                        ),
                    ],
                  ),
                ),
                if (isDlna) ...[
                  const SizedBox(height: 4),
                  Text(
                    context.t.network_share_dlna_hint,
                    key: const Key('network_share_dlna_hint'),
                    style: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceVariant),
                  ),
                ],
                const SizedBox(height: 16),
                _field(_name, context.t.network_share_name, key: const Key('network_share_name')),
                const SizedBox(height: 16),
                _field(
                  _host,
                  context.t.network_share_host,
                  key: const Key('network_share_host'),
                  // The whole description address fits here and fills port and path: what a DLNA server that is not found
                  // needs (minidlna on Linux, never found on iOS, see ssdp.dart)
                  hint: isSmb
                      ? 'nas.local, 192.168.1.20'
                      : isDlna
                      ? 'http://192.168.1.10:8200/rootDesc.xml'
                      : 'cloud.example.com',
                  focusNode: _hostFocus,
                  keyboardType: TextInputType.url,
                  autofillHints: const [AutofillHints.url],
                  tvKind: TvTextKind.url,
                  // Another server: the id of the one tapped no longer goes with it
                  onChanged: (_) => _filledDiscovery = null,
                ),
                const SizedBox(height: 16),
                _field(
                  _port,
                  context.t.network_share_port,
                  key: const Key('network_share_port'),
                  hint: isSmb ? '445' : (_useTls ? '443' : '80'),
                  errorText: _portIsValid ? null : '1-65535',
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  tvKind: TvTextKind.number,
                ),
                const SizedBox(height: 16),
                _field(
                  _share,
                  isSmb
                      ? context.t.network_share_share_name
                      : isDlna
                      ? context.t.network_share_description_path
                      : context.t.network_share_url_path,
                  key: const Key('network_share_share'),
                  hint: isSmb
                      ? 'media'
                      : isDlna
                      ? '/rootDesc.xml'
                      : '/remote.php/dav/files/alice',
                  keyboardType: TextInputType.url,
                ),
                if (isSmb) ...[
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const Key('network_share_choose_share'),
                      onPressed: canListShares ? _chooseShare : null,
                      icon: _listingShares
                          ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.folder_shared_outlined),
                      label: Text(
                        context.t.network_share_scan_choose_share,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                  if (_shareListError != null) _TestResult(message: _shareListError!, succeeded: false),
                ],
                const SizedBox(height: 16),
                _field(
                  _rootPath,
                  context.t.network_share_root_path,
                  key: const Key('network_share_root_path'),
                  hint: '/',
                  keyboardType: TextInputType.url,
                ),
                // DLNA has no authentication
                if (!isDlna) ...[
                  const SizedBox(height: 16),
                  _field(
                    _username,
                    context.t.network_share_username,
                    key: const Key('network_share_username'),
                    focusNode: _usernameFocus,
                    autofillHints: const [AutofillHints.username],
                  ),
                  const SizedBox(height: 16),
                  _field(
                    _password,
                    context.t.network_share_password,
                    key: const Key('network_share_password'),
                    focusNode: _passwordFocus,
                    obscureText: !_showPassword,
                    autofillHints: const [AutofillHints.password],
                    tvKind: TvTextKind.password,
                    suffixIcon: IconButton(
                      icon: Icon(_showPassword ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                      onPressed: () => setState(() => _showPassword = !_showPassword),
                    ),
                  ),
                ],
                if (!isSmb && !isDlna) ...[
                  const SizedBox(height: 8),
                  SwitchListTile.adaptive(
                    key: const Key('network_share_use_tls'),
                    value: _useTls,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    onChanged: (value) => setState(() {
                      _useTls = value;
                      _testMessage = null;
                    }),
                    title: Text(context.t.network_share_use_tls, style: labelStyle),
                  ),
                ],
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: canSubmit ? _test : null,
                    icon: _testing
                        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.network_check_rounded),
                    label: Text(
                      context.t.network_share_test,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                if (_testMessage != null) ...[
                  const SizedBox(height: 12),
                  _TestResult(message: _testMessage!, succeeded: _testSucceeded),
                ],
                const SizedBox(height: 24),
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (!_isNew)
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: context.colorScheme.error,
                            side: BorderSide(color: context.colorScheme.error),
                          ),
                          onPressed: _saving ? null : _remove,
                          icon: const Icon(Icons.delete_outline),
                          label: Text(
                            context.t.network_share_remove,
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ElevatedButton.icon(
                        onPressed: canSubmit ? _save : null,
                        icon: const Icon(Icons.check),
                        label: Text(
                          context.t.network_share_save,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TestResult extends StatelessWidget {
  const _TestResult({required this.message, required this.succeeded});

  final String message;
  final bool succeeded;

  @override
  Widget build(BuildContext context) {
    final color = succeeded ? context.primaryColor : context.colorScheme.error;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(succeeded ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded, color: color, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(message, style: context.textTheme.bodyMedium?.copyWith(color: color)),
        ),
      ],
    );
  }
}

/// The shares of an SMB server to choose from, in a bottom sheet that gives back the name chosen
class _SharePicker extends StatelessWidget {
  const _SharePicker({required this.host, required this.shares});

  final String host;
  final List<String> shares;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: context.height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(
                context.t.network_share_scan_shares_title(host: host),
                style: context.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            if (shares.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                child: Text(context.t.network_share_scan_shares_none),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final share in shares)
                      ListTile(
                        key: Key('network_share_pick_$share'),
                        leading: const Icon(Icons.folder_shared_outlined),
                        title: Text(share),
                        onTap: () => Navigator.of(context).pop(share),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
