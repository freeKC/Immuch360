import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';
import 'package:immich_mobile/widgets/common/immich_toast.dart';
import 'package:logging/logging.dart';

final _log = Logger('NetworkShareEditPage');

/// What a pasted address says: smb://nas/media/photos, \\nas\media, https://cloud.example.com/remote.php/dav
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

  /// SMB share name, or the path of the WebDAV address
  final String share;

  /// SMB: the folder after the share name, null when there is none
  final String? rootPath;
  final bool useTls;
}

/// Reads a full address typed or pasted in the server field; null when it is a plain server name or address
@visibleForTesting
NetworkAddress? parseNetworkAddress(String input) {
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
  final type = switch (scheme) {
    'smb' || 'cifs' => NetworkSourceType.smb,
    'http' || 'https' || 'dav' || 'davs' || 'webdav' || 'webdavs' => NetworkSourceType.webdav,
    _ => null,
  };
  if (type == null) {
    return null;
  }
  final segments = uri.pathSegments.where((segment) => segment.isNotEmpty).toList();
  final port = uri.hasPort ? uri.port : null;
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
  final _hostFocus = FocusNode();

  /// False until the stored password of an existing share is in the field; saving before keeps the stored one
  late bool _passwordLoaded = widget.source == null;
  bool _showPassword = false;
  bool _testing = false;
  bool _saving = false;

  /// The outcome of the last connection test, null when there was none since the last change
  String? _testMessage;
  bool _testSucceeded = false;

  bool get _isNew => widget.source == null;

  @override
  void initState() {
    super.initState();
    _hostFocus.addListener(() {
      if (!_hostFocus.hasFocus && mounted) {
        _expandAddress();
      }
    });
    if (!_isNew) {
      unawaited(_loadPassword());
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
    super.dispose();
  }

  /// Spreads a full address typed in the server field over the other fields
  void _expandAddress() {
    final address = parseNetworkAddress(_host.text);
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
      if (address.type == NetworkSourceType.webdav) {
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
    final address = parseNetworkAddress(_host.text);
    final type = address?.type ?? _type;
    final host = address?.host ?? _host.text.trim();
    final shareText = address != null && address.share.isNotEmpty ? address.share : _share.text;
    final share = switch (type) {
      NetworkSourceType.smb => shareText.trim().replaceAll(RegExp(r'^[/\\]+|[/\\]+$'), ''),
      NetworkSourceType.webdav => normalizeNetworkPath(shareText, empty: ''),
    };
    if (host.isEmpty || !_portIsValid || (type == NetworkSourceType.smb && share.isEmpty)) {
      return null;
    }
    final name = _name.text.trim();
    return NetworkSource(
      id: _id,
      type: type,
      name: name.isEmpty ? host : name,
      host: host,
      port: address?.port ?? (_port.text.trim().isEmpty ? null : _portValue),
      share: share,
      rootPath: normalizeNetworkPath(address?.rootPath ?? _rootPath.text),
      username: _username.text.trim(),
      useTls: type == NetworkSourceType.webdav && (address?.useTls ?? _useTls),
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
    // An empty field forgets the password, unless the stored one was not read yet
    final password = _passwordLoaded || _password.text.isNotEmpty ? _password.text : null;
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
      onChanged: (_) => _changed(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isSmb = _type == NetworkSourceType.smb;
    final canSubmit = _formSource() != null && !_testing && !_saving;
    final labelStyle = context.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold);

    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? context.t.network_share_add : context.t.network_share_edit),
        elevation: 0,
        leading: const CloseButton(),
        centerTitle: false,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          children: [
            const SizedBox(height: 20),
            Text(context.t.network_share_type, style: labelStyle),
            RadioGroup<NetworkSourceType>(
              groupValue: _type,
              onChanged: (type) {
                if (type != null && type != _type) {
                  setState(() {
                    _type = type;
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
                ],
              ),
            ),
            const SizedBox(height: 16),
            _field(_name, context.t.network_share_name, key: const Key('network_share_name')),
            const SizedBox(height: 16),
            _field(
              _host,
              context.t.network_share_host,
              key: const Key('network_share_host'),
              hint: isSmb ? 'nas.local, 192.168.1.20' : 'cloud.example.com',
              focusNode: _hostFocus,
              keyboardType: TextInputType.url,
              autofillHints: const [AutofillHints.url],
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
            ),
            const SizedBox(height: 16),
            _field(
              _share,
              isSmb ? context.t.network_share_share_name : context.t.network_share_url_path,
              key: const Key('network_share_share'),
              hint: isSmb ? 'media' : '/remote.php/dav/files/alice',
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 16),
            _field(
              _rootPath,
              context.t.network_share_root_path,
              key: const Key('network_share_root_path'),
              hint: '/',
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 16),
            _field(
              _username,
              context.t.network_share_username,
              key: const Key('network_share_username'),
              autofillHints: const [AutofillHints.username],
            ),
            const SizedBox(height: 16),
            _field(
              _password,
              context.t.network_share_password,
              key: const Key('network_share_password'),
              obscureText: !_showPassword,
              autofillHints: const [AutofillHints.password],
              suffixIcon: IconButton(
                icon: Icon(_showPassword ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                onPressed: () => setState(() => _showPassword = !_showPassword),
              ),
            ),
            if (!isSmb) ...[
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
