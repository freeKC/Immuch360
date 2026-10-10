import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/plex_server_info.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/datetime_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_api.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_client.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_direct.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_file_system.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_pairing.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_token.dart';
import 'package:immich_mobile/platform/tv_api.g.dart';
import 'package:immich_mobile/presentation/widgets/forms/discard_changes.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/found_servers.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_text_entry.widget.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/network_discovery.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/providers/network/plex_learned_addresses.provider.dart';
import 'package:immich_mobile/providers/network/plex_pairing.provider.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';
import 'package:immich_mobile/widgets/common/immich_toast.dart';
import 'package:logging/logging.dart';

final _log = Logger('PlexServerEditPage');

/// What the fields of the Plex page hold, the token apart (it is read later for a server already added)
typedef _PlexFormFields = ({String address, String name, String publicHost, String publicPort, String rootPath});

/// Adds a Plex Media Server, or edits or removes one when [source] is given. [server] is a Plex server found on the
/// network, which fills the page; [focusToken] puts the focus on the token field (the "Paste a new token" action of a
/// server that refused its token).
///
/// The token is never shown unless asked, never copied back to the clipboard, never logged: it only goes to the
/// secure storage and, in a header, to the server whose certificate the page checked.
@RoutePage()
class PlexServerEditPage extends ConsumerStatefulWidget {
  const PlexServerEditPage({super.key, this.source, this.server, this.focusToken = false});

  final NetworkSource? source;
  final DiscoveredServer? server;
  final bool focusToken;

  @override
  ConsumerState<PlexServerEditPage> createState() => _PlexServerEditPageState();
}

class _PlexServerEditPageState extends ConsumerState<PlexServerEditPage> {
  late final String _id = widget.source?.id ?? NetworkSourcesNotifier.newId();
  late final String _initialAddress = _addressOf(widget.source);
  late final _address = TextEditingController(text: _initialAddress);
  final _token = TextEditingController();
  late final _name = TextEditingController(text: widget.source?.name ?? '');
  late final _publicHost = TextEditingController(text: widget.source?.plex?.publicHost ?? '');
  late final _publicPort = TextEditingController(text: widget.source?.plex?.publicPort?.toString() ?? '');
  late final _fieldChanges = Listenable.merge([_address, _token, _name, _publicHost, _publicPort]);

  /// What the page held once open (a server found filled in, the stored token once read): leaving with other values
  /// asks first
  late final _PlexFormFields _openedWith;
  String _openedWithToken = '';

  /// The page is going away on purpose (saved, removed)
  bool _leaving = false;
  final _addressFocus = FocusNode();
  final _tokenFocus = FocusNode();
  final _publicHostFocus = FocusNode();

  // Around the address and token entries, so that the focus can be put in them whatever widget takes it (the field,
  // or on a TV the focusable frame of TvTextEntry)
  final _addressEntry = FocusNode(canRequestFocus: false, skipTraversal: true);
  final _tokenEntry = FocusNode(canRequestFocus: false, skipTraversal: true);
  final _tokenKey = GlobalKey();

  /// The server the page found: tapped in the list, or looked up at the typed address; null until then
  PlexServerFound? _server;

  /// Whether [_server] was found at the address outside home of the source rather than at the address typed: one the
  /// server told (which goes on being learned) or the one already typed, so not a new address outside home
  bool _foundOutsideHome = false;
  bool _lookingUp = false;
  String? _lookupError;
  int _lookups = 0;

  /// The text the last look up was made for
  String? _lookedUp;

  /// The token stored for an existing server, once read; the field starting with it means "keep it"
  String? _storedToken;
  bool _showToken = false;

  bool _testing = false;
  String? _testMessage;
  bool _testSucceeded = false;
  PlexTokenCheck? _check;

  /// The token and the server the last successful test was made with: another one needs a new test
  String? _testedToken;
  PlexServerFound? _testedServer;

  late String _rootPath = widget.source?.rootPath ?? '/';
  bool _saving = false;

  /// What the server of an existing source told of its address outside home at its last connection at home
  PlexLearnedAddress? _learned;

  /// What was put in the name field, replaced by the next server unless the user typed another name meanwhile
  String? _filledName;

  List<DiscoveredServer> _servers = const [];
  StreamSubscription<List<DiscoveredServer>>? _discovery;
  bool _scanning = false;
  bool _scanned = false;

  bool get _isNew => widget.source == null;

  _PlexFormFields _fields() => (
    address: _address.text,
    name: _name.text,
    publicHost: _publicHost.text,
    publicPort: _publicPort.text,
    rootPath: _rootPath,
  );

  bool get _hasUnsavedChanges => !_saving && !_leaving && (_fields() != _openedWith || _token.text != _openedWithToken);

  /// The found list shows for a server added from scratch
  bool get _showsDiscovery => _isNew && widget.server == null;

  static String _addressOf(NetworkSource? source) {
    if (source == null) {
      return '';
    }
    if (source.host.isNotEmpty) {
      return '${source.host}:${source.port ?? plexDefaultPort}';
    }
    final publicHost = source.plex?.publicHost;
    return publicHost == null ? '' : '$publicHost:${source.plex?.publicPort ?? plexDefaultPort}';
  }

  @override
  void initState() {
    super.initState();
    _addressFocus.addListener(() {
      if (!_addressFocus.hasFocus && mounted && _address.text.trim().isNotEmpty && _address.text != _lookedUp) {
        unawaited(_lookUp());
      }
    });
    _publicHostFocus.addListener(() {
      if (!_publicHostFocus.hasFocus) {
        _splitPublicAddress();
      }
    });
    final server = widget.server;
    final source = widget.source;
    var lookUp = false;
    if (server != null) {
      lookUp = _fill(server);
    } else if (_showsDiscovery) {
      _scan();
    }
    // A server tapped in the share form came filled in: no change of the user yet
    _openedWith = _fields();
    if (source != null) {
      unawaited(_loadToken(source));
      try {
        _learned = ref.read(plexLearnedAddressStoreProvider).read(source.id);
      } catch (error, stackTrace) {
        _log.warning('Could not read what a Plex server told of its address outside home', error, stackTrace);
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusFirst();
      if (lookUp && mounted) {
        unawaited(_lookUp());
      }
    });
  }

  /// In TV mode one entry has the focus from the start; on a phone only the token after "Paste a new token", whose
  /// keyboard then opens
  void _focusFirst() {
    if (!mounted) {
      return;
    }
    final tv = ref.read(tvModeProvider);
    if (widget.focusToken) {
      final target = _tokenKey.currentContext;
      if (target != null) {
        unawaited(Scrollable.ensureVisible(target, alignment: 0.2));
      }
      tv ? _focusInside(_tokenEntry) : _tokenFocus.requestFocus();
    } else if (tv) {
      _focusInside(_addressEntry);
    }
  }

  /// Gives the focus to the first widget that takes it under [entry]
  static void _focusInside(FocusNode entry) {
    final target = entry.descendants.where((node) => node.canRequestFocus && !node.skipTraversal).firstOrNull;
    target?.requestFocus();
  }

  Future<void> _loadToken(NetworkSource source) async {
    try {
      final token = await ref.read(networkSourcesProvider.notifier).readPassword(source.id);
      if (!mounted) {
        return;
      }
      setState(() {
        _storedToken = token;
        // "Paste a new token" starts from an empty field: the stored token is the one the server refused
        if (_token.text.isEmpty && !widget.focusToken) {
          _token.text = token ?? '';
          _openedWithToken = _token.text;
        }
      });
    } catch (error, stackTrace) {
      _log.warning('Could not read the token of a Plex server', error, stackTrace);
    }
  }

  @override
  void dispose() {
    for (final controller in [_address, _token, _name, _publicHost, _publicPort]) {
      controller.dispose();
    }
    for (final node in [_addressFocus, _tokenFocus, _publicHostFocus, _addressEntry, _tokenEntry]) {
      node.dispose();
    }
    unawaited(_discovery?.cancel());
    super.dispose();
  }

  /// Looks for the Plex servers of the network, again when called again
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
                _log.warning('The search for Plex servers failed', error, stackTrace),
            onDone: ended,
          );
    } catch (error, stackTrace) {
      _log.warning('The search for Plex servers failed to start', error, stackTrace);
      _discovery = null;
      ended();
    }
  }

  /// Fills the page with a server found on the network: what it announces needs no request, and the test checks it.
  /// True when the server must be looked up still, having been announced without its hash.
  bool _fill(DiscoveredServer server) {
    final found = PlexServerFound.fromDiscovery(server);
    final text = '${server.host}:${server.port}';
    _address.text = text;
    _server = found;
    _foundOutsideHome = false;
    _lookedUp = found == null ? null : text;
    _lookupError = null;
    _forgetTest();
    if (_name.text.trim().isEmpty || _name.text == _filledName) {
      _name.text = server.displayName;
      _filledName = server.displayName;
    }
    return found == null;
  }

  void _fillFrom(DiscoveredServer server) {
    var lookUp = false;
    setState(() => lookUp = _fill(server));
    if (lookUp) {
      unawaited(_lookUp());
    }
    if (ref.read(tvModeProvider)) {
      _focusInside(_tokenEntry);
    }
  }

  void _forgetTest() {
    _testMessage = null;
    _testSucceeded = false;
    _check = null;
  }

  /// Looks the server of the address field up: its certificate, then its identity, without the token
  Future<void> _lookUp() async {
    final PlexAddress typed;
    try {
      typed = parsePlexAddress(_address.text);
    } on PlexAddressException catch (error) {
      setState(() {
        _server = null;
        _lookupError = switch (error.problem) {
          PlexAddressProblem.empty => null,
          PlexAddressProblem.ipv6 => context.t.plex_server_ipv6,
          PlexAddressProblem.invalid => context.t.plex_server_address_invalid,
        };
        _forgetTest();
      });
      return;
    }
    final pasted = typed.token;
    final lookup = ++_lookups;
    setState(() {
      // A whole address leaves the server in its field and its token in the other one
      if (_address.text.contains('://')) {
        _address.text = typed.text;
      }
      if (pasted != null) {
        _token.text = pasted.token;
      }
      _lookedUp = _address.text;
      _server = null;
      _lookingUp = true;
      _lookupError = null;
      _forgetTest();
    });
    var outsideHome = false;
    try {
      // A server already paired keeps its certificate: the address typed must hold that one
      final knownHash = typed.hash == null ? widget.source?.plex?.hash : null;
      PlexServerFound found;
      try {
        found = await ref.read(plexPairingProvider).lookUp(typed, knownHash: knownHash);
      } on PlexFileSystemException catch (error) {
        final unreachable =
            error.failure == PlexFailure.unreachable || error.failure == PlexFailure.unreachableOutsideHome;
        final elsewhere = unreachable && mounted && lookup == _lookups ? _outsideHomeOfSource(typed) : null;
        if (elsewhere == null) {
          rethrow;
        }
        found = await _lookUpOutsideHome(elsewhere);
        outsideHome = true;
      }
      if (!mounted || lookup != _lookups) {
        return;
      }
      setState(() {
        _server = found;
        _foundOutsideHome = outsideHome;
        _lookingUp = false;
      });
    } on PlexFileSystemException catch (error) {
      if (!mounted || lookup != _lookups) {
        return;
      }
      setState(() {
        _lookingUp = false;
        _lookupError = _messageOf(error);
      });
    }
  }

  /// For a server already added whose address was left as it is, the address outside home its file system would go
  /// through (see plexPublicAddress) when the one at home does not answer: away from home, "Paste a new token" must be
  /// testable. Null when there is none, when it is [typed] itself, or when the address field was changed.
  PlexAddress? _outsideHomeOfSource(PlexAddress typed) {
    final known = widget.source?.plex;
    if (known == null || _address.text.trim() != _initialAddress || _publicAddressError != null) {
      return null;
    }
    final typedOutside = _publicAddressTyped;
    final outside = plexPublicAddress(
      PlexServerInfo(
        hash: known.hash,
        publicHost: typedOutside?.host,
        publicPort: typedOutside?.port ?? (_publicPortIsValid ? _publicPortValue : null),
      ),
      _learned,
    );
    if (outside == null) {
      return null;
    }
    final PlexAddress address;
    try {
      address = parsePlexAddress('${outside.host}:${outside.port}');
    } on PlexAddressException {
      return null;
    }
    final same = address.host == typed.host && outside.port == (typed.port ?? plexDefaultPort);
    return same ? null : address;
  }

  /// The server of the source at [address], with the certificate and the machine identifier of the source, as its file
  /// system checks them
  Future<PlexServerFound> _lookUpOutsideHome(PlexAddress address) async {
    final source = widget.source!;
    final found = await ref.read(plexPairingProvider).lookUp(address, knownHash: source.plex!.hash);
    final expected = source.discoveryId?.toLowerCase();
    if (expected != null && found.machineIdentifier != expected) {
      throw const PlexFileSystemException('Another Plex server answers at this address', PlexFailure.otherServer);
    }
    return found;
  }

  /// The address outside home typed, null when there is none or it cannot be read (see [_publicAddressError])
  PlexAddress? get _publicAddressTyped {
    try {
      return parsePlexAddress(_publicHost.text);
    } on PlexAddressException {
      return null;
    }
  }

  /// What is wrong with the address outside home typed, null when nothing is
  String? get _publicAddressError {
    final PlexAddress typed;
    try {
      typed = parsePlexAddress(_publicHost.text);
    } on PlexAddressException catch (error) {
      return switch (error.problem) {
        PlexAddressProblem.empty => null,
        PlexAddressProblem.ipv6 => context.t.plex_server_ipv6,
        PlexAddressProblem.invalid => context.t.plex_server_address_invalid,
      };
    }
    // A plex.direct name holds the certificate of its server: another one is another server
    final hash = typed.hash;
    final expected = _server?.hash ?? widget.source?.plex?.hash;
    return hash != null && expected != null && hash != expected ? context.t.plex_server_wrong_certificate : null;
  }

  /// An address outside home typed whole (a URL, or with its port) keeps its host in its field and its port in the port
  /// field, where it shows which port is used
  void _splitPublicAddress() {
    final typed = _publicAddressTyped;
    if (typed == null || !mounted) {
      return;
    }
    final port = typed.port;
    if (_publicHost.text == typed.host && port == null) {
      return;
    }
    setState(() {
      _publicHost.text = typed.host;
      if (port != null) {
        _publicPort.text = '$port';
      }
    });
  }

  /// The address field changed by hand: the server found and the test no longer hold. A whole "View XML" address is
  /// spread over both fields at once.
  void _addressChanged(String text) {
    if (text.toLowerCase().contains('x-plex-token=')) {
      unawaited(_lookUp());
      return;
    }
    setState(() {
      if (_server != null && text != _lookedUp) {
        _server = null;
      }
      _lookupError = null;
      _forgetTest();
    });
  }

  /// The token field changed: a pasted address or text with spaces is read (see parsePastedPlexToken)
  void _tokenChanged(String text) {
    if (text.toLowerCase().contains('x-plex-token=') || text.trim() != text || text.contains(RegExp(r'\s'))) {
      _takePasted(text);
      return;
    }
    setState(_forgetTest);
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.trim().isEmpty || !mounted) {
      return;
    }
    _takePasted(text);
  }

  /// Puts what was pasted in its fields: the token in the token field, and the server of a whole address in the
  /// address field when it is another server than the one shown
  void _takePasted(String text) {
    final pasted = parsePastedPlexToken(text);
    if (pasted == null) {
      return;
    }
    var lookUp = false;
    setState(() {
      _token.text = pasted.token;
      _forgetTest();
      final server = pasted.server;
      if (server != null) {
        final serverText = server.hasPort ? '${server.host}:${server.port}' : server.host;
        if (!_isShown(serverText)) {
          _address.text = serverText;
          _server = null;
          lookUp = true;
        }
      }
    });
    if (lookUp) {
      unawaited(_lookUp());
    }
  }

  /// Whether [text] is an address of the server already found
  bool _isShown(String text) {
    final server = _server;
    if (server == null) {
      return false;
    }
    try {
      final typed = parsePlexAddress(text);
      return typed.host == server.address.address &&
          (typed.port ?? plexDefaultPort) == server.port &&
          (typed.hash == null || typed.hash == server.hash);
    } on PlexAddressException {
      return false;
    }
  }

  /// The token of the field, null when there is none
  String? get _tokenValue => parsePastedPlexToken(_token.text)?.token;

  Future<void> _test() async {
    // An expired token is not sent anywhere
    if (parsePastedPlexToken(_token.text)?.isExpired() ?? false) {
      setState(() {
        _testSucceeded = false;
        _testMessage = context.t.plex_token_expired;
      });
      return;
    }
    if (_server == null || _address.text != _lookedUp) {
      await _lookUp();
    }
    final server = _server;
    final token = _tokenValue;
    if (server == null || token == null || !mounted) {
      return;
    }
    setState(() {
      _testing = true;
      _forgetTest();
    });
    try {
      final check = await ref.read(plexPairingProvider).testToken(server, token);
      if (!mounted) {
        return;
      }
      setState(() {
        _testing = false;
        _check = check;
        _testSucceeded = true;
        _testedToken = token;
        _testedServer = server;
        _testMessage = context.t.plex_connected(count: check.sections.length);
        final name = check.serverName ?? server.name;
        if (name != null && (_name.text.trim().isEmpty || _name.text == _filledName)) {
          _name.text = name;
          _filledName = name;
        }
        if (!_sectionPaths.contains(_rootPath)) {
          _rootPath = '/';
        }
      });
    } on PlexFileSystemException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _testing = false;
        _testSucceeded = false;
        _testMessage = _messageOf(error);
      });
    }
  }

  String _messageOf(PlexFileSystemException error) => switch (error.failure) {
    PlexFailure.unreachable => context.t.plex_server_unreachable,
    PlexFailure.unreachableOutsideHome => context.t.plex_remote_unavailable,
    PlexFailure.wrongCertificate => context.t.plex_server_wrong_certificate,
    PlexFailure.otherServer => context.t.plex_server_other,
    PlexFailure.notPlex => context.t.plex_server_not_plex,
    PlexFailure.tokenRefused => context.t.plex_token_refused,
    PlexFailure.tokenForbidden => context.t.plex_token_forbidden,
    PlexFailure.failed => context.t.network_share_failed(error: error.message),
  };

  /// The start folders to choose from: the root, the libraries of the last test, and the one of the source
  List<String> get _sectionPaths {
    final sections = _check?.sections;
    return {
      '/',
      if (sections != null)
        for (final (item: _, :name) in plexSectionEntryNames(sections)) '/$name'
      else if (widget.source != null)
        widget.source!.rootPath,
    }.toList();
  }

  /// The start folder chosen when it is still one of the list, else the root
  String get _shownRootPath => _sectionPaths.contains(_rootPath) ? _rootPath : '/';

  int? get _publicPortValue => int.tryParse(_publicPort.text.trim());

  bool get _publicPortIsValid {
    if (_publicPort.text.trim().isEmpty) {
      return true;
    }
    final port = _publicPortValue;
    return port != null && port > 0 && port < 65536;
  }

  /// Whether the page may save: after a successful test of the token and the server shown, or for a server already
  /// paired whose token and address were left as they were; never a source left without any address
  bool get _canSave {
    if (_saving || _testing || _lookingUp || !_publicPortIsValid || _publicAddressError != null) {
      return false;
    }
    final token = _tokenValue;
    if (token == null) {
      return false;
    }
    final tested = _testSucceeded && token == _testedToken && identical(_server, _testedServer);
    final kept = !_isNew && token == _storedToken && _address.text.trim() == _initialAddress;
    return (tested || kept) && _formSource() != null;
  }

  /// The source the page describes, null when it cannot be saved
  NetworkSource? _formSource() {
    final previous = widget.source;
    final server = _server;
    if (server == null && previous == null) {
      return null;
    }
    // The port typed alone stays too: it replaces the one the server tells (see plexPublicAddress)
    final typed = _publicAddressTyped;
    String? publicHost = typed?.host;
    int? publicPort = typed?.port ?? (_publicPortIsValid ? _publicPortValue : null);
    final known = previous?.plex;
    final String host;
    final int? port;
    if (server == null) {
      host = previous!.host;
      port = previous.port;
    } else if (server.isLocal) {
      host = server.address.address;
      port = server.port == plexDefaultPort ? null : server.port;
    } else if (previous != null && known != null && server.hash == known.hash && _isSourceMachine(server)) {
      // The same server found outside home: its address at home stays, and the address typed is the one outside home
      host = previous.host;
      port = previous.port;
      if (publicHost == null && !_foundOutsideHome) {
        publicHost = server.typedName ?? server.address.address;
        publicPort = server.port;
      }
    } else {
      // Paired from outside home: the address typed is the one outside home
      host = '';
      port = null;
      if (publicHost == null) {
        publicHost = server.typedName ?? server.address.address;
        publicPort = server.port;
      }
    }
    if (host.isEmpty && publicHost == null) {
      // A server paired from outside home has no other address: the one it had stays rather than none
      publicHost = known?.publicHost;
      publicPort = known?.publicPort;
      if (publicHost == null) {
        return null;
      }
    }
    final hash = server?.hash ?? previous!.plex!.hash;
    final version = _check?.version ?? server?.version ?? previous?.plex?.version;
    final name = _name.text.trim().isNotEmpty
        ? _name.text.trim()
        : (_check?.serverName ?? server?.name ?? previous?.name ?? host);
    final plex = known != null && known.hash == hash
        ? known.copyWith(
            publicHost: publicHost,
            clearPublicHost: publicHost == null,
            publicPort: publicPort,
            clearPublicPort: publicPort == null,
            version: version,
          )
        : PlexServerInfo(hash: hash, publicHost: publicHost, publicPort: publicPort, version: version);
    final discoveryId = server?.machineIdentifier ?? previous?.discoveryId;
    if (previous != null) {
      return previous.copyWith(
        name: name,
        host: host,
        port: port,
        clearPort: port == null,
        rootPath: _shownRootPath,
        useTls: true,
        discoveryId: discoveryId,
        plex: plex,
      );
    }
    return NetworkSource(
      id: _id,
      type: NetworkSourceType.plex,
      name: name,
      host: host,
      port: port,
      rootPath: _shownRootPath,
      useTls: true,
      discoveryId: discoveryId,
      plex: plex,
    );
  }

  /// Whether [server] has the machine identifier of the source edited, when it has one
  bool _isSourceMachine(PlexServerFound server) {
    final expected = widget.source?.discoveryId?.toLowerCase();
    return expected == null || server.machineIdentifier.isEmpty || server.machineIdentifier == expected;
  }

  Future<void> _save() async {
    final source = _formSource();
    final token = _tokenValue;
    if (source == null || token == null || !_canSave) {
      return;
    }
    setState(() => _saving = true);
    final sources = ref.read(networkSourcesProvider.notifier);
    try {
      if (_isNew) {
        await sources.add(source, password: token);
      } else {
        await sources.update(source, password: token == _storedToken ? null : token);
      }
      final learned = _check?.learned;
      if (learned != null) {
        try {
          await ref.read(plexLearnedAddressStoreProvider).write(source.id, learned);
        } catch (error, stackTrace) {
          _log.warning('Could not keep what a Plex server told of its address outside home', error, stackTrace);
        }
      }
      if (mounted) {
        await context.maybePop();
      }
    } catch (error, stackTrace) {
      _log.severe('Could not save a Plex server', error, stackTrace);
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
        content: '${context.t.plex_remove_confirm(name: source.name)}\n\n${context.t.plex_remove_note}',
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
      hintMaxLines: 3,
      hintStyle: const TextStyle(fontWeight: FontWeight.normal, fontSize: 14),
      errorText: errorText,
      suffixIcon: suffixIcon,
    );
  }

  /// A field typed through the dialog of the TV in TV mode (see TvTextEntry)
  Widget _field(
    TextEditingController controller,
    String label,
    TvTextKind kind, {
    required Key key,
    String? hint,
    String? errorText,
    FocusNode? focusNode,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    bool obscureText = false,
    Widget? suffixIcon,
    ValueChanged<String>? onChanged,
    VoidCallback? onEntered,
  }) {
    return TvTextEntry(
      controller: controller,
      label: label,
      kind: kind,
      // The dialog of the TV sets the text without the field telling it, and the field never has the focus to lose
      onSubmitted: (text) {
        onChanged == null ? setState(() {}) : onChanged(text);
        onEntered?.call();
      },
      child: TextField(
        key: key,
        controller: controller,
        focusNode: focusNode,
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        obscureText: obscureText,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.next,
        decoration: _decoration(label, hint: hint, errorText: errorText, suffixIcon: suffixIcon),
        onChanged: (text) => onChanged == null ? setState(() {}) : onChanged(text),
      ),
    );
  }

  /// The line under the token field: what the pasted text looks like
  String? _tokenFormatLine() {
    final pasted = parsePastedPlexToken(_token.text);
    if (pasted == null) {
      return null;
    }
    final expires = pasted.expires;
    return switch (pasted.kind) {
      PlexTokenKind.legacy => null,
      PlexTokenKind.unknown => context.t.plex_token_not_token,
      PlexTokenKind.jwt when pasted.isExpired() => context.t.plex_token_expired,
      PlexTokenKind.jwt when expires != null => context.t.plex_token_expires(date: expires.toLocal().formatDate()),
      PlexTokenKind.jwt => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final labelStyle = context.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold);
    final hintStyle = context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceVariant);
    const buttonText = TextStyle(fontSize: 14, fontWeight: FontWeight.bold);
    final server = _server;
    final source = widget.source;
    final canTest = _address.text.trim().isNotEmpty && _tokenValue != null && !_testing && !_lookingUp && !_saving;
    final formatLine = _tokenFormatLine();
    final learned = _check != null ? _check!.learned : _learned;
    // What the connection goes through once saved: a test that learned nothing (outside home) keeps what was stored
    final used = _check?.learned ?? _learned;
    final askedLearned = (_check != null && (server?.isLocal ?? false)) || (_check == null && _learned != null);
    final showsRemote = _testSucceeded || !_isNew;
    final sectionPaths = _sectionPaths;

    return DiscardChangesScope(
      listenable: _fieldChanges,
      hasChanges: () => _hasUnsavedChanges,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isNew ? context.t.plex_server_add : context.t.plex_server_edit),
          elevation: 0,
          leading: const CloseButton(),
          centerTitle: false,
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            children: [
              const SizedBox(height: 20),
              if (_showsDiscovery) ...[
                FoundServersList(
                  servers: _servers,
                  scanning: _scanning,
                  scanned: _scanned,
                  onScan: _scan,
                  onSelected: _fillFrom,
                  filter: (server) => server.type == NetworkSourceType.plex,
                  scanningText: context.t.plex_scan_scanning,
                  noneFoundText: context.t.plex_scan_none_found,
                ),
                const SizedBox(height: 4),
              ],
              Focus(
                focusNode: _addressEntry,
                child: _field(
                  _address,
                  context.t.plex_server_address,
                  TvTextKind.url,
                  key: const Key('plex_server_address'),
                  hint: context.t.plex_server_address_hint,
                  focusNode: _addressFocus,
                  keyboardType: TextInputType.url,
                  onChanged: _addressChanged,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  TextButton.icon(
                    key: const Key('plex_server_look_up'),
                    onPressed: _address.text.trim().isEmpty || _lookingUp ? null : () => unawaited(_lookUp()),
                    icon: _lookingUp
                        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.search_rounded),
                    label: Text(context.t.plex_server_look_up, style: buttonText),
                  ),
                ],
              ),
              if (_lookupError != null)
                _ResultLine(key: const Key('plex_server_lookup_error'), message: _lookupError!, succeeded: false)
              else if (server != null)
                _ServerCard(
                  key: const Key('plex_server_card'),
                  name:
                      server.name ??
                      _check?.serverName ??
                      (_name.text.trim().isEmpty ? server.addressText : _name.text),
                  version: _check?.version ?? server.version,
                  id: server.shortId,
                  address: server.addressText,
                )
              else if (source != null && _address.text.trim() == _initialAddress)
                _ServerCard(
                  key: const Key('plex_server_card'),
                  name: source.name,
                  version: source.plex?.version,
                  id: _shortId(source.discoveryId),
                  address: _initialAddress,
                ),
              const SizedBox(height: 16),
              KeyedSubtree(
                key: _tokenKey,
                child: Focus(
                  focusNode: _tokenEntry,
                  child: _field(
                    _token,
                    context.t.plex_token,
                    TvTextKind.password,
                    key: const Key('plex_token'),
                    focusNode: _tokenFocus,
                    keyboardType: TextInputType.visiblePassword,
                    obscureText: !_showToken,
                    onChanged: _tokenChanged,
                    suffixIcon: IconButton(
                      key: const Key('plex_token_show'),
                      tooltip: _showToken ? context.t.hide_password : context.t.show_password,
                      icon: Icon(_showToken ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                      onPressed: () => setState(() => _showToken = !_showToken),
                    ),
                  ),
                ),
              ),
              if (formatLine != null) ...[
                const SizedBox(height: 4),
                Text(
                  formatLine,
                  key: const Key('plex_token_format'),
                  style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.error),
                ),
              ],
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('plex_token_paste'),
                  onPressed: () => unawaited(_paste()),
                  icon: const Icon(Icons.content_paste_rounded),
                  label: Text(context.t.plex_token_paste, style: buttonText),
                ),
              ),
              Text(context.t.plex_token_rights, style: hintStyle),
              ExpansionTile(
                key: const Key('plex_token_how'),
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 8),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                shape: const Border(),
                collapsedShape: const Border(),
                title: Text(context.t.plex_token_how, style: labelStyle),
                children: [
                  Text(context.t.plex_token_guide, style: hintStyle),
                  const SizedBox(height: 8),
                  Text(context.t.plex_token_guide_admin, style: hintStyle),
                ],
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const Key('plex_test'),
                  onPressed: canTest ? () => unawaited(_test()) : null,
                  icon: _testing
                      ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.network_check_rounded),
                  label: Text(context.t.network_share_test, style: buttonText),
                ),
              ),
              if (_testMessage != null) ...[
                const SizedBox(height: 12),
                _ResultLine(key: const Key('plex_test_result'), message: _testMessage!, succeeded: _testSucceeded),
              ],
              if (showsRemote) ...[
                const SizedBox(height: 24),
                Text(context.t.plex_remote_title, key: const Key('plex_remote_title'), style: labelStyle),
                const SizedBox(height: 4),
                if (askedLearned)
                  Text(
                    learned == null
                        ? context.t.plex_remote_unknown
                        : context.t.plex_remote_learned(address: learned.host, port: '${learned.port}'),
                    key: const Key('plex_remote_learned'),
                    style: hintStyle,
                  ),
                const SizedBox(height: 12),
                _field(
                  _publicHost,
                  context.t.plex_remote_address,
                  TvTextKind.url,
                  key: const Key('plex_remote_address'),
                  hint: used?.host,
                  errorText: _publicAddressError,
                  focusNode: _publicHostFocus,
                  keyboardType: TextInputType.url,
                  onEntered: _splitPublicAddress,
                ),
                const SizedBox(height: 16),
                _field(
                  _publicPort,
                  context.t.plex_remote_port,
                  TvTextKind.number,
                  key: const Key('plex_remote_port'),
                  // The port used when none is typed: the one written in the address, else the one the server told
                  // (see plexPublicAddress)
                  hint: '${_publicAddressTyped?.port ?? used?.port ?? plexDefaultPort}',
                  errorText: _publicPortIsValid ? null : '1-65535',
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                ),
              ],
              const SizedBox(height: 24),
              _field(
                _name,
                context.t.network_share_name,
                TvTextKind.text,
                key: const Key('plex_name'),
                hint: _check?.serverName ?? server?.name,
              ),
              const SizedBox(height: 16),
              // Built again when its items change: the field keeps its own value, which must stay one of them
              KeyedSubtree(
                key: ValueKey(sectionPaths.join('\n')),
                child: DropdownButtonFormField<String>(
                  key: const Key('plex_root_path'),
                  initialValue: _shownRootPath,
                  decoration: _decoration(context.t.network_share_root_path),
                  items: [
                    for (final path in sectionPaths)
                      DropdownMenuItem(
                        value: path,
                        child: Text(path, maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (path) => setState(() => _rootPath = path ?? '/'),
                ),
              ),
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
                        key: const Key('plex_remove'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: context.colorScheme.error,
                          side: BorderSide(color: context.colorScheme.error),
                        ),
                        onPressed: _saving ? null : () => unawaited(_remove()),
                        icon: const Icon(Icons.delete_outline),
                        label: Text(context.t.network_share_remove, style: buttonText),
                      ),
                    ElevatedButton.icon(
                      key: const Key('plex_save'),
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
      ),
    );
  }

  static String _shortId(String? id) => id == null ? '' : (id.length > 8 ? id.substring(0, 8) : id);
}

/// The server found: its name, version, short id and address, to confirm it is the right one before the token goes
class _ServerCard extends StatelessWidget {
  const _ServerCard({super.key, required this.name, this.version, required this.id, required this.address});

  final String name;
  final String? version;
  final String id;
  final String address;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(top: 4),
      child: ListTile(
        leading: const Icon(Icons.video_library_outlined),
        title: Text(context.t.plex_server_found(name: name, version: version ?? '?', id: id)),
        subtitle: Text(address, maxLines: 1, overflow: TextOverflow.ellipsis),
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
