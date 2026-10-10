import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/tapo_camera_info.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/tv_api.g.dart';
import 'package:immich_mobile/presentation/widgets/camera/camera_badges.widget.dart';
import 'package:immich_mobile/presentation/widgets/forms/discard_changes.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/found_servers.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_text_entry.widget.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/network_discovery.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/providers/tapo/tapo_infrastructure.provider.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';
import 'package:immich_mobile/widgets/common/immich_toast.dart';
import 'package:logging/logging.dart';

final _log = Logger('CameraEditPage');

/// What the fields of the camera page hold, the passwords apart (they are read later for a camera already added)
typedef _CameraFormFields = ({String host, String name, String user});

/// Adds a Tapo camera, or edits or removes one when [source] is given. [server] is a camera found on the network,
/// which fills the page.
///
/// Two secrets, at least one of them: the password of the TP-Link account (the recordings) and the camera account
/// (the live view). "Test the camera" tries each once per press: a refused password is never tried again on its own,
/// since every refusal counts towards a lockout of the camera.
@RoutePage()
class CameraEditPage extends ConsumerStatefulWidget {
  const CameraEditPage({super.key, this.source, this.server});

  final NetworkSource? source;
  final DiscoveredServer? server;

  @override
  ConsumerState<CameraEditPage> createState() => _CameraEditPageState();
}

class _CameraEditPageState extends ConsumerState<CameraEditPage> {
  /// Made when the page opens and given to the test, so that its login serves the connection opened after the save
  late final String _id = widget.source?.id ?? NetworkSourcesNotifier.newId();
  late final _host = TextEditingController(text: widget.source?.host ?? widget.server?.host ?? '');
  late final _name = TextEditingController(text: widget.source?.name ?? widget.server?.displayName ?? '');
  final _cloudPassword = TextEditingController();
  late final _user = TextEditingController(text: widget.source?.username ?? '');
  final _cameraPassword = TextEditingController();
  late final _fieldChanges = Listenable.merge([_host, _name, _cloudPassword, _user, _cameraPassword]);
  final _body = FocusScopeNode(debugLabel: 'camera_edit_body');

  /// What the page held when it opened (a camera found filled in, the stored passwords once read): leaving with
  /// other values asks first
  late final _CameraFormFields _openedWith;
  String _openedWithCloudPassword = '';
  String _openedWithCameraPassword = '';

  /// The page is going away on purpose (saved, removed)
  bool _leaving = false;

  /// What the name field holds from a find or a test, replaced by the next one unless the user typed another
  late String? _filledName = widget.source == null ? widget.server?.displayName : null;
  late String? _discoveryId = widget.source?.discoveryId ?? widget.server?.discoveryId;

  /// What is known of the camera: stored, then what a test learned
  late TapoCameraInfo? _info = widget.source?.camera;

  /// False until the stored secrets of an existing camera are in the fields; saving before keeps the stored ones
  late bool _secretsLoaded = widget.source == null;
  bool _showCloudPassword = false;
  bool _showCameraPassword = false;

  List<DiscoveredServer> _servers = const [];
  StreamSubscription<List<DiscoveredServer>>? _discovery;
  bool _scanning = false;
  bool _scanned = false;

  bool _testing = false;
  bool _saving = false;
  bool _missingSecret = false;
  TapoTestResult? _result;

  bool get _isNew => widget.source == null;

  _CameraFormFields _fields() => (host: _host.text, name: _name.text, user: _user.text);

  bool get _hasUnsavedChanges =>
      !_saving &&
      !_leaving &&
      (_fields() != _openedWith ||
          _cloudPassword.text != _openedWithCloudPassword ||
          _cameraPassword.text != _openedWithCameraPassword);

  @override
  void initState() {
    super.initState();
    // Before anything fills a field
    _openedWith = _fields();
    if (_isNew) {
      _scan();
    } else {
      unawaited(_loadSecrets());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // With a remote, something of the page holds the focus from the start: the first camera found or the address
      if (mounted && ref.read(tvModeProvider) && !_body.hasFocus) {
        _body.nextFocus();
      }
    });
  }

  @override
  void dispose() {
    for (final controller in [_host, _name, _cloudPassword, _user, _cameraPassword]) {
      controller.dispose();
    }
    _body.dispose();
    unawaited(_discovery?.cancel());
    super.dispose();
  }

  Future<void> _loadSecrets() async {
    try {
      final sources = ref.read(networkSourcesProvider.notifier);
      final cloud = await sources.readPassword(_id);
      final camera = await sources.readCameraPassword(_id);
      if (!mounted) {
        return;
      }
      setState(() {
        if (_cloudPassword.text.isEmpty) {
          _cloudPassword.text = cloud ?? '';
          _openedWithCloudPassword = _cloudPassword.text;
        }
        if (_cameraPassword.text.isEmpty) {
          _cameraPassword.text = camera ?? '';
          _openedWithCameraPassword = _cameraPassword.text;
        }
        _secretsLoaded = true;
      });
    } catch (error, stackTrace) {
      _log.warning('Could not read the passwords of a camera', error, stackTrace);
    }
  }

  /// Looks for the cameras of the network, again when called again
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
                _log.warning('The search for cameras failed', error, stackTrace),
            onDone: ended,
          );
    } catch (error, stackTrace) {
      _log.warning('The search for cameras failed to start', error, stackTrace);
      _discovery = null;
      ended();
    }
  }

  void _fillFrom(DiscoveredServer server) {
    setState(() {
      _host.text = server.host;
      if (_name.text.trim().isEmpty || _name.text == _filledName) {
        _name.text = server.displayName;
        _filledName = server.displayName;
      }
      _discoveryId = server.discoveryId;
      // What a test of another address taught does not belong to this camera; what this one announces (its login
      // generation) leads its first login
      _info = server.camera;
      _result = null;
    });
  }

  void _changed() => setState(() {
    _result = null;
    _missingSecret = false;
  });

  bool get _hasCloud => _cloudPassword.text.isNotEmpty;

  bool get _hasAccount => _user.text.trim().isNotEmpty && _cameraPassword.text.isNotEmpty;

  /// At least one secret, or the stored ones not read yet
  bool get _hasSecret => _hasCloud || _hasAccount || !_secretsLoaded;

  Future<void> _test() async {
    final host = _host.text.trim();
    if (host.isEmpty) {
      return;
    }
    if (!_hasCloud && !_hasAccount) {
      setState(() => _missingSecret = true);
      return;
    }
    setState(() {
      _testing = true;
      _result = null;
    });
    TapoTestResult result;
    try {
      result = await ref.read(tapoCameraTesterProvider)(
        TapoTestRequest(
          sourceId: _id,
          host: host,
          cloudPassword: _hasCloud ? _cloudPassword.text : null,
          cameraUser: _hasAccount ? _user.text.trim() : null,
          cameraPassword: _hasAccount ? _cameraPassword.text : null,
          known: _info,
        ),
      );
    } on TapoCameraException catch (error) {
      result = TapoTestResult(recordingsError: error);
    } catch (error, stackTrace) {
      _log.warning('The test of a camera failed', error, stackTrace);
      result = TapoTestResult(recordingsError: TapoCameraException(TapoErrorKind.unsupported, detail: '$error'));
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _testing = false;
      _result = result;
      final info = result.info;
      if (info != null) {
        _info = info;
      }
      final details = result.details;
      if (details != null && (_name.text.trim().isEmpty || _name.text == _filledName)) {
        final name = details.alias.isNotEmpty ? details.alias : details.model;
        _name.text = name;
        _filledName = name;
      }
      if (details != null && details.mac.isNotEmpty) {
        _discoveryId = details.mac;
      }
    });
    final changed = result.recordingsError;
    if (changed != null && changed.kind == TapoErrorKind.certificateChanged) {
      await _askCertificate(changed);
    }
  }

  /// The camera shows another certificate than the one stored: a reset camera, or someone in its place
  Future<void> _askCertificate(TapoCameraException error) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(context.t.camera_error_certificate_changed(host: _host.text.trim())),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(context.t.cancel)),
          TextButton(
            key: const Key('camera_certificate_continue'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.t.continue$),
          ),
        ],
      ),
    );
    final certificate = error.certificateSha256;
    if (accepted != true || certificate == null || !mounted) {
      return;
    }
    setState(() => _info = (_info ?? const TapoCameraInfo()).copyWith(certificateSha256: certificate));
    // The user accepted the new certificate: that press is the one the test goes on with
    await _test();
  }

  NetworkSource? _formSource() {
    final host = _host.text.trim();
    if (host.isEmpty) {
      return null;
    }
    final name = _name.text.trim();
    return NetworkSource(
      id: _id,
      type: NetworkSourceType.tapo,
      name: name.isEmpty ? host : name,
      host: host,
      username: _user.text.trim(),
      useTls: true,
      discoveryId: _discoveryId,
      camera: _info,
      extraJson: widget.source?.extraJson ?? const {},
    );
  }

  Future<void> _save() async {
    final source = _formSource();
    if (source == null) {
      return;
    }
    if (!_hasSecret) {
      setState(() => _missingSecret = true);
      return;
    }
    setState(() => _saving = true);
    final sources = ref.read(networkSourcesProvider.notifier);
    final readCertificate = ref.read(tapoCertificateReaderProvider);
    // An empty field forgets the secret, unless the stored one was not read yet
    final cloud = _secretsLoaded || _cloudPassword.text.isNotEmpty ? _cloudPassword.text : null;
    final camera = _secretsLoaded || _cameraPassword.text.isNotEmpty ? _cameraPassword.text : null;
    var saved = source;
    try {
      if (source.camera?.certificateSha256 == null && (cloud == null || cloud.isNotEmpty)) {
        // Saved without a test that pinned the certificate: the one shown now is pinned at this press, as a test would
        // do, since the camera page never trusts one on its own later (by then another device may hold the address).
        // Reading it sends nothing to the camera.
        final seen = await readCertificate(source.host);
        if (seen != null) {
          saved = source.copyWith(camera: (source.camera ?? const TapoCameraInfo()).copyWith(certificateSha256: seen));
        }
      }
      if (_isNew) {
        await sources.add(saved, password: cloud, cameraPassword: camera);
      } else {
        await sources.update(saved, password: cloud, cameraPassword: camera);
      }
      if (mounted) {
        await context.maybePop();
      }
    } catch (error, stackTrace) {
      _log.severe('Could not save a camera', error, stackTrace);
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
      builder: (context) =>
          ConfirmDialog(title: context.t.camera_remove, content: context.t.camera_remove_confirm, ok: context.t.remove),
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

  Widget _field(
    TextEditingController controller,
    String label, {
    required Key key,
    required TvTextKind kind,
    String? hint,
    bool obscure = false,
    Widget? suffix,
    TextInputType? keyboardType,
    Iterable<String>? autofillHints,
  }) {
    return TvTextEntry(
      controller: controller,
      label: label,
      kind: kind,
      onSubmitted: (_) => _changed(),
      child: TextField(
        key: key,
        controller: controller,
        obscureText: obscure,
        autocorrect: false,
        enableSuggestions: !obscure,
        keyboardType: keyboardType,
        autofillHints: autofillHints,
        textInputAction: TextInputAction.next,
        onChanged: (_) => _changed(),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(fontWeight: FontWeight.bold),
          floatingLabelBehavior: FloatingLabelBehavior.always,
          border: const OutlineInputBorder(),
          hintText: hint,
          hintStyle: const TextStyle(fontWeight: FontWeight.normal, fontSize: 14),
          suffixIcon: suffix,
        ),
      ),
    );
  }

  Widget _hint(String text, {Key? key}) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Text(
      text,
      key: key,
      style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
    ),
  );

  Widget _visibility(bool shown, VoidCallback toggle) => IconButton(
    tooltip: shown ? context.t.hide_password : context.t.show_password,
    icon: Icon(shown ? Icons.visibility_off_outlined : Icons.visibility_outlined),
    onPressed: toggle,
  );

  @override
  Widget build(BuildContext context) {
    final canSubmit = _host.text.trim().isNotEmpty && !_testing && !_saving;
    final labelStyle = context.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold);
    final result = _result;
    final host = _host.text.trim();

    return DiscardChangesScope(
      listenable: _fieldChanges,
      hasChanges: () => _hasUnsavedChanges,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isNew ? context.t.camera_add : context.t.camera_edit),
          elevation: 0,
          leading: const CloseButton(),
          centerTitle: false,
        ),
        body: SafeArea(
          child: FocusScope(
            node: _body,
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
                    filter: (server) => server.type == NetworkSourceType.tapo,
                    scanningText: context.t.camera_scan_scanning,
                    noneFoundText: context.t.camera_scan_none_found,
                  ),
                  const SizedBox(height: 12),
                ],
                _field(
                  _host,
                  context.t.camera_host,
                  key: const Key('camera_host'),
                  kind: TvTextKind.url,
                  hint: '192.168.1.30',
                  keyboardType: TextInputType.url,
                  autofillHints: const [AutofillHints.url],
                ),
                const SizedBox(height: 16),
                _field(_name, context.t.network_share_name, key: const Key('camera_name'), kind: TvTextKind.text),
                const SizedBox(height: 24),
                Text(context.t.camera_recordings, style: labelStyle),
                const SizedBox(height: 8),
                _field(
                  _cloudPassword,
                  context.t.camera_cloud_password,
                  key: const Key('camera_cloud_password'),
                  kind: TvTextKind.password,
                  obscure: !_showCloudPassword,
                  autofillHints: const [AutofillHints.password],
                  suffix: _visibility(
                    _showCloudPassword,
                    () => setState(() => _showCloudPassword = !_showCloudPassword),
                  ),
                ),
                _hint(context.t.camera_cloud_password_hint),
                const SizedBox(height: 24),
                Text(context.t.camera_live, style: labelStyle),
                const SizedBox(height: 8),
                _field(
                  _user,
                  context.t.camera_account_user,
                  key: const Key('camera_account_user'),
                  kind: TvTextKind.text,
                  autofillHints: const [AutofillHints.username],
                ),
                const SizedBox(height: 16),
                _field(
                  _cameraPassword,
                  context.t.camera_account_password,
                  key: const Key('camera_account_password'),
                  kind: TvTextKind.password,
                  obscure: !_showCameraPassword,
                  suffix: _visibility(
                    _showCameraPassword,
                    () => setState(() => _showCameraPassword = !_showCameraPassword),
                  ),
                ),
                _hint(context.t.camera_account_hint),
                const SizedBox(height: 16),
                _hint(context.t.camera_third_party_hint, key: const Key('camera_third_party_hint')),
                if (_missingSecret) ...[
                  const SizedBox(height: 12),
                  _Line(
                    key: const Key('camera_needs_a_password'),
                    message: context.t.camera_needs_a_password,
                    ok: false,
                  ),
                ],
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    key: const Key('camera_test'),
                    onPressed: canSubmit ? _test : null,
                    icon: _testing
                        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.network_check_rounded),
                    label: Text(
                      context.t.camera_test,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                if (result != null) ...[
                  if (result.details case final details?) ...[
                    const SizedBox(height: 12),
                    _Line(
                      key: const Key('camera_test_recordings'),
                      message: context.t.camera_test_recordings_ok(model: details.model, firmware: details.firmware),
                      ok: true,
                    ),
                    if (result.card case final card?)
                      Padding(
                        padding: const EdgeInsets.only(left: 28, top: 4),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: CameraCardBadge(card: card),
                        ),
                      ),
                  ],
                  if (result.recordingsError case final error? when error.kind != TapoErrorKind.cancelled) ...[
                    const SizedBox(height: 12),
                    _Line(
                      key: const Key('camera_test_recordings'),
                      message: context.t.camera_test_recordings_failed(
                        error: cameraErrorText(context, error, host: host),
                      ),
                      ok: false,
                    ),
                  ],
                  if (result.live case final live?) ...[
                    const SizedBox(height: 12),
                    _Line(
                      key: const Key('camera_test_live'),
                      message: context.t.camera_test_live_ok(video: live.video ?? '-', audio: live.audio ?? '-'),
                      ok: true,
                    ),
                  ],
                  if (result.liveError case final error?) ...[
                    const SizedBox(height: 12),
                    _Line(
                      key: const Key('camera_test_live'),
                      message: context.t.camera_test_live_failed(error: cameraErrorText(context, error, host: host)),
                      ok: false,
                    ),
                  ],
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
                          key: const Key('camera_remove'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: context.colorScheme.error,
                            side: BorderSide(color: context.colorScheme.error),
                          ),
                          onPressed: _saving ? null : _remove,
                          icon: const Icon(Icons.delete_outline),
                          label: Text(
                            context.t.camera_remove,
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ElevatedButton.icon(
                        key: const Key('camera_save'),
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

/// A line of the outcome of the test
class _Line extends StatelessWidget {
  const _Line({super.key, required this.message, required this.ok});

  final String message;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final color = ok ? context.primaryColor : context.colorScheme.error;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(ok ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded, color: color, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(message, style: context.textTheme.bodyMedium?.copyWith(color: color)),
        ),
      ],
    );
  }
}
