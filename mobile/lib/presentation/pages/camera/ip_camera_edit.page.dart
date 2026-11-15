import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/ip_camera_info.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/ip_camera.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/ipcam/camera_address.dart';
import 'package:immich_mobile/infrastructure/ipcam/ip_camera_service.dart';
import 'package:immich_mobile/infrastructure/ipcam/onvif_client.dart';
import 'package:immich_mobile/platform/tv_api.g.dart';
import 'package:immich_mobile/presentation/widgets/camera/ip_camera_text.dart';
import 'package:immich_mobile/presentation/widgets/forms/discard_changes.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_text_entry.widget.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/ipcam/ip_camera.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/widgets/common/confirm_dialog.dart';
import 'package:immich_mobile/widgets/common/immich_toast.dart';
import 'package:logging/logging.dart';

final _log = Logger('IpCameraEditPage');

/// What the address field holds: a camera to read through ONVIF (an address, a port when not the usual ones), or a
/// pasted RTSP or RTSPS link
sealed class _Target {
  const _Target();
}

class _OnvifTarget extends _Target {
  const _OnvifTarget(this.host, this.port);

  final String host;

  /// Null: the usual ONVIF ports are tried in turn
  final int? port;
}

class _LinkTarget extends _Target {
  const _LinkTarget(this.address);

  final CameraStreamAddress address;
}

/// The address field: "192.0.2.40", "192.0.2.40:8000", "[2001:db8::5]:80", or an rtsp:// or rtsps:// link. Null when
/// it is none of them.
_Target? _parseTarget(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  final lower = trimmed.toLowerCase();
  if (lower.startsWith('rtsp://') || lower.startsWith('rtsps://')) {
    final address = parseCameraStreamAddress(trimmed);
    return address == null ? null : _LinkTarget(address);
  }
  if (lower.startsWith('http://')) {
    final uri = Uri.tryParse(trimmed);
    return uri == null || uri.host.isEmpty ? null : _OnvifTarget(uri.host, uri.hasPort ? uri.port : null);
  }
  final v6 = RegExp(r'^\[([0-9a-fA-F:]+)\](?::(\d+))?$').firstMatch(trimmed);
  if (v6 != null) {
    return _OnvifTarget(v6.group(1)!, int.tryParse(v6.group(2) ?? ''));
  }
  final match = RegExp(r'^([A-Za-z0-9.-]+)(?::(\d{1,5}))?$').firstMatch(trimmed);
  if (match == null) {
    return null;
  }
  final port = int.tryParse(match.group(2) ?? '');
  if (port != null && (port <= 0 || port > 65535)) {
    return null;
  }
  return _OnvifTarget(match.group(1)!, port);
}

/// What the read of the camera gave: the setup of an ONVIF camera, or the test of a link, and the streams to keep
class _Reading {
  const _Reading({required this.info, required this.streams, this.test, this.device});

  final IpCameraInfo info;
  final IpCameraStreams streams;
  final IpCameraStreamTest? test;
  final OnvifDeviceInfo? device;
}

/// Adds a camera of another brand than Tapo, or edits or removes one when [source] is given: one found on the network
/// by ONVIF (WS-Discovery, or its address typed), or a pasted RTSP or RTSPS link (UniFi Protect, go2rtc, Frigate, a
/// camera without ONVIF). "Read the camera" asks it once per press: ONVIF reads its profiles and the address of the
/// main and sub streams, then the main stream is described (nothing played) to tell its codecs and whether this
/// device plays them. The password and the stream addresses go to the secure storage; nothing is ever written to the
/// camera.
@RoutePage()
class IpCameraEditPage extends ConsumerStatefulWidget {
  const IpCameraEditPage({super.key, this.source});

  final NetworkSource? source;

  @override
  ConsumerState<IpCameraEditPage> createState() => _IpCameraEditPageState();
}

class _IpCameraEditPageState extends ConsumerState<IpCameraEditPage> {
  late final String _id = widget.source?.id ?? NetworkSourcesNotifier.newId();
  late final _address = TextEditingController(text: _storedAddressText());
  late final _name = TextEditingController(text: widget.source?.name ?? '');
  late final _user = TextEditingController(text: widget.source?.username ?? '');
  final _password = TextEditingController();
  late final _fieldChanges = Listenable.merge([_address, _name, _user, _password]);
  final _body = FocusScopeNode(debugLabel: 'ip_camera_edit_body');

  /// What the page held when it opened: leaving with other values asks first
  late final ({String address, String name, String user}) _openedWith;
  String _openedWithPassword = '';
  bool _leaving = false;
  late bool _secretsLoaded = widget.source == null;
  bool _showPassword = false;

  /// The ONVIF device service of a camera found on the network: its path and the endpoint kept as the discovery id
  String _devicePath = onvifDevicePath;
  late String? _discoveryId = widget.source?.discoveryId;
  String? _filledName;

  List<DiscoveredOnvifDevice> _found = const [];
  StreamSubscription<DiscoveredOnvifDevice>? _search;
  bool _searching = false;

  bool _reading = false;
  bool _saving = false;
  _Reading? _result;
  IpCameraException? _error;

  /// The stored streams of a camera being edited, kept when its address does not change
  IpCameraStreams? _storedStreams;

  bool get _isNew => widget.source == null;

  /// The address field of a stored camera: its host (and port) for ONVIF; for a link, the masked address, since its
  /// path may hold a token (pasted again to change it)
  String _storedAddressText() {
    final source = widget.source;
    final info = source?.ipCamera;
    if (source == null || info == null) {
      return '';
    }
    final host = source.host.contains(':') ? '[${source.host}]' : source.host;
    if (info.kind == IpCameraKind.onvif) {
      final port = info.onvifPort;
      return port == null || port == 80 ? host : '$host:$port';
    }
    return '${info.secure ? 'rtsps' : 'rtsp'}://$host:${info.rtspPort}/…';
  }

  ({String address, String name, String user}) _fields() =>
      (address: _address.text, name: _name.text, user: _user.text);

  bool get _hasUnsavedChanges =>
      !_saving && !_leaving && (_fields() != _openedWith || _password.text != _openedWithPassword);

  @override
  void initState() {
    super.initState();
    _openedWith = _fields();
    if (_isNew) {
      _startSearch();
    } else {
      _devicePath = widget.source?.ipCamera?.onvifPath ?? onvifDevicePath;
      unawaited(_loadSecrets());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ref.read(tvModeProvider) && !_body.hasFocus) {
        _body.nextFocus();
      }
    });
  }

  @override
  void dispose() {
    for (final controller in [_address, _name, _user, _password]) {
      controller.dispose();
    }
    _body.dispose();
    unawaited(_search?.cancel());
    super.dispose();
  }

  Future<void> _loadSecrets() async {
    try {
      final sources = ref.read(networkSourcesProvider.notifier);
      final password = await sources.readPassword(_id);
      final streams = IpCameraStreams.decode(await sources.readCameraPassword(_id));
      if (!mounted) {
        return;
      }
      setState(() {
        if (_password.text.isEmpty) {
          _password.text = password ?? '';
          _openedWithPassword = _password.text;
        }
        _storedStreams = streams;
        _secretsLoaded = true;
      });
    } catch (error, stackTrace) {
      _log.warning('Could not read the secrets of a camera', error, stackTrace);
    }
  }

  void _startSearch() {
    unawaited(_search?.cancel());
    setState(() {
      _found = const [];
      _searching = true;
    });
    void ended() {
      if (mounted) {
        setState(() => _searching = false);
      }
    }

    try {
      _search = ref
          .read(ipCameraServiceProvider)
          .search()
          .listen(
            (device) {
              if (mounted) {
                setState(() => _found = [..._found, device]);
              }
            },
            onError: (Object error) {
              _log.warning('The search for ONVIF cameras failed: ${error.runtimeType}');
              ended();
            },
            onDone: ended,
          );
    } catch (error) {
      _log.warning('The search for ONVIF cameras did not start: ${error.runtimeType}');
      ended();
    }
  }

  void _fillFrom(DiscoveredOnvifDevice device) {
    setState(() {
      final host = device.host.contains(':') ? '[${device.host}]' : device.host;
      _address.text = device.port == 80 ? host : '$host:${device.port}';
      _devicePath = device.path;
      _discoveryId = device.endpoint;
      if (_name.text.trim().isEmpty || _name.text == _filledName) {
        _name.text = device.label;
        _filledName = device.label;
      }
      _result = null;
      _error = null;
    });
  }

  void _changed() => setState(() {
    _result = null;
    _error = null;
  });

  /// The address field unchanged on a stored camera: its stored streams serve
  bool get _addressUnchanged => !_isNew && _address.text == _openedWith.address;

  /// Reads the camera (see the page's comment), once per press; null with the reason shown when it failed
  Future<_Reading?> _read() async {
    final target = _addressUnchanged && widget.source?.ipCamera?.kind == IpCameraKind.rtsp
        ? null
        : _parseTarget(_address.text);
    if (target == null && !(_addressUnchanged && _storedStreams != null)) {
      setState(() => _error = const IpCameraException(IpCameraErrorKind.badAddress));
      return null;
    }
    // An account pasted in a link moves to its fields, and the field keeps the link without it
    if (target case _LinkTarget(:final address) when address.user != null) {
      _user.text = address.user!;
      _password.text = address.password ?? '';
      _address.text = address.url;
    }
    setState(() {
      _reading = true;
      _result = null;
      _error = null;
    });
    final service = ref.read(ipCameraServiceProvider);
    final user = _user.text.trim();
    final password = _password.text;
    try {
      final _Reading reading;
      switch (target) {
        case _OnvifTarget(:final host, :final port):
          final setup = await service.readOnvif(
            host: host,
            port: port,
            path: _devicePath,
            user: user,
            password: password,
          );
          final main = setup.mainStream!;
          final test = await service.testStream(main, user: user, password: password);
          reading = _Reading(
            device: setup.reading.device,
            test: test,
            info: IpCameraInfo(
              kind: IpCameraKind.onvif,
              onvifPort: setup.port,
              onvifPath: setup.path,
              rtspPort: main.port,
              secure: main.secure,
              manufacturer: setup.reading.device.manufacturer,
              model: setup.reading.device.model,
              firmware: setup.reading.device.firmware,
              main: IpCameraStreamInfo(
                profileToken: setup.main.token,
                codec: test.video ?? setup.main.encoding,
                width: setup.main.width,
                height: setup.main.height,
                audio: test.audio ?? setup.main.audioEncoding,
              ),
              sub: setup.sub == null
                  ? null
                  : IpCameraStreamInfo(
                      profileToken: setup.sub!.token,
                      codec: setup.sub!.encoding,
                      width: setup.sub!.width,
                      height: setup.sub!.height,
                      audio: setup.sub!.audioEncoding,
                    ),
            ),
            streams: IpCameraStreams(
              main: main.pathAndQuery,
              // A sub stream on another port than the main one is not kept: the source has one RTSP port
              sub: setup.subStream?.port == main.port ? setup.subStream?.pathAndQuery : null,
              snapshot: setup.snapshot,
            ),
          );
        case _LinkTarget(:final address):
          final test = await service.testStream(address, user: user, password: password);
          reading = _Reading(
            test: test,
            info: IpCameraInfo(
              kind: IpCameraKind.rtsp,
              rtspPort: address.port,
              secure: address.secure,
              main: IpCameraStreamInfo(codec: test.video, audio: test.audio),
            ),
            streams: IpCameraStreams(main: address.pathAndQuery),
          );
        case null:
          // A stored link, unchanged: its stream described again
          final info = widget.source!.ipCamera!;
          final streams = _storedStreams!;
          final test = await service.testStream(
            CameraStreamAddress(
              secure: info.secure,
              host: widget.source!.host,
              port: info.rtspPort,
              pathAndQuery: streams.main,
            ),
            user: user,
            password: password,
          );
          reading = _Reading(test: test, info: info, streams: streams);
      }
      if (!mounted) {
        return null;
      }
      setState(() {
        _reading = false;
        _result = reading;
        final label = reading.device?.label;
        if (label != null && (_name.text.trim().isEmpty || _name.text == _filledName)) {
          _name.text = label;
          _filledName = label;
        }
      });
      return reading;
    } on IpCameraException catch (error) {
      _log.info('The camera could not be read: ${error.kind.name}');
      if (mounted) {
        setState(() {
          _reading = false;
          _error = error;
        });
      }
    } catch (error, stackTrace) {
      _log.warning('The camera could not be read', error, stackTrace);
      if (mounted) {
        setState(() {
          _reading = false;
          _error = IpCameraException(IpCameraErrorKind.other, detail: error.runtimeType.toString());
        });
      }
    }
    return null;
  }

  Future<void> _save() async {
    // Saved from what the last read gave; without one, the camera is read first (its stream addresses are needed)
    final reading = _result ?? await _read();
    if (reading == null || !mounted) {
      return;
    }
    final target = _parseTarget(_address.text);
    final host = switch (target) {
      _OnvifTarget(:final host) => host,
      _LinkTarget(:final address) => address.host,
      null => widget.source!.host,
    };
    final name = _name.text.trim();
    final source = NetworkSource(
      id: _id,
      type: NetworkSourceType.ipCamera,
      name: name.isEmpty ? (reading.device?.label ?? host) : name,
      host: host,
      username: _user.text.trim(),
      useTls: reading.info.secure,
      discoveryId: reading.info.kind == IpCameraKind.onvif ? _discoveryId : null,
      ipCamera: reading.info,
      extraJson: widget.source?.extraJson ?? const {},
    );
    setState(() => _saving = true);
    final sources = ref.read(networkSourcesProvider.notifier);
    final password = _secretsLoaded || _password.text.isNotEmpty ? _password.text : null;
    try {
      if (_isNew) {
        await sources.add(source, password: password, cameraPassword: reading.streams.encode());
      } else {
        await sources.update(source, password: password, cameraPassword: reading.streams.encode());
      }
      if (mounted) {
        _leaving = true;
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
  }) => TvTextEntry(
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

  Widget _hint(String text, {Key? key}) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Text(
      text,
      key: key,
      style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
    ),
  );

  List<Widget> _resultLines(String host) {
    final error = _error;
    if (error != null) {
      return [
        const SizedBox(height: 12),
        _Line(
          key: const Key('ip_camera_error'),
          message: ipCameraErrorText(context, error, host: host),
          ok: false,
        ),
      ];
    }
    final result = _result;
    if (result == null) {
      return const [];
    }
    final lines = <Widget>[];
    final device = result.device;
    if (device != null) {
      lines.add(
        _Line(
          key: const Key('ip_camera_device'),
          message: context.t.ip_camera_read_device(device: device.label ?? host, firmware: device.firmware ?? '?'),
          ok: true,
        ),
      );
    }
    String stream(IpCameraStreamInfo? info) {
      if (info == null) {
        return '-';
      }
      final codec = OnvifProfile(token: '', encoding: info.codec, width: info.width, height: info.height).label;
      return codec.isEmpty ? '?' : codec;
    }

    if (result.info.kind == IpCameraKind.onvif) {
      lines.add(
        _Line(
          key: const Key('ip_camera_profiles'),
          message: context.t.ip_camera_read_profiles(main: stream(result.info.main), sub: stream(result.info.sub)),
          ok: true,
        ),
      );
    }
    final test = result.test;
    if (test != null) {
      lines.add(
        _Line(
          key: const Key('ip_camera_stream'),
          message: test.playsHere == false
              ? context.t.ip_camera_error_codec_here(codec: _codecName(test.video))
              : test.video == null
              ? context.t.ip_camera_read_stream_untested
              : context.t.camera_test_live_ok(video: _codecName(test.video), audio: test.audio ?? '-'),
          ok: test.playsHere != false,
        ),
      );
    }
    return [
      for (final line in lines) ...[const SizedBox(height: 12), line],
    ];
  }

  static String _codecName(String? codec) => switch (codec) {
    'H264' => 'H.264',
    'H265' => 'H.265',
    'JPEG' => 'MJPEG',
    final String other => other,
    null => '?',
  };

  @override
  Widget build(BuildContext context) {
    final busy = _reading || _saving;
    final canSubmit = _address.text.trim().isNotEmpty && !busy;
    final labelStyle = context.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold);
    final target = _parseTarget(_address.text);
    final host = switch (target) {
      _OnvifTarget(:final host) => host,
      _LinkTarget(:final address) => address.host,
      null => widget.source?.host ?? _address.text.trim(),
    };

    return DiscardChangesScope(
      listenable: _fieldChanges,
      hasChanges: () => _hasUnsavedChanges,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isNew ? context.t.ip_camera_add : context.t.camera_edit),
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
                  Row(
                    children: [
                      Expanded(child: Text(context.t.ip_camera_found, style: labelStyle)),
                      if (_searching)
                        const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      else
                        TextButton.icon(
                          key: const Key('ip_camera_search_again'),
                          onPressed: _startSearch,
                          icon: const Icon(Icons.refresh_rounded),
                          label: Text(context.t.ip_camera_search_again),
                        ),
                    ],
                  ),
                  for (final device in _found)
                    ListTile(
                      key: Key('ip_camera_found_${device.endpoint}'),
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.videocam_outlined),
                      title: Text(device.label),
                      subtitle: Text(device.port == 80 ? device.host : '${device.host}:${device.port}'),
                      onTap: () => _fillFrom(device),
                    ),
                  if (!_searching && _found.isEmpty)
                    _hint(context.t.ip_camera_none_found, key: const Key('ip_camera_none_found')),
                  const SizedBox(height: 20),
                ],
                _field(
                  _address,
                  context.t.ip_camera_address,
                  key: const Key('ip_camera_address'),
                  kind: TvTextKind.url,
                  hint: '192.168.1.40',
                  keyboardType: TextInputType.url,
                ),
                _hint(context.t.ip_camera_address_hint),
                const SizedBox(height: 16),
                _field(_name, context.t.network_share_name, key: const Key('ip_camera_name'), kind: TvTextKind.text),
                const SizedBox(height: 24),
                Text(context.t.ip_camera_account, style: labelStyle),
                const SizedBox(height: 8),
                _field(
                  _user,
                  context.t.camera_account_user,
                  key: const Key('ip_camera_user'),
                  kind: TvTextKind.text,
                  autofillHints: const [AutofillHints.username],
                ),
                const SizedBox(height: 16),
                _field(
                  _password,
                  context.t.camera_account_password,
                  key: const Key('ip_camera_password'),
                  kind: TvTextKind.password,
                  obscure: !_showPassword,
                  suffix: IconButton(
                    tooltip: _showPassword ? context.t.hide_password : context.t.show_password,
                    icon: Icon(_showPassword ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                    onPressed: () => setState(() => _showPassword = !_showPassword),
                  ),
                ),
                _hint(context.t.ip_camera_account_hint),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    key: const Key('ip_camera_read'),
                    onPressed: canSubmit ? () => unawaited(_read()) : null,
                    icon: _reading
                        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.network_check_rounded),
                    label: Text(
                      context.t.ip_camera_read,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                ..._resultLines(host),
                const SizedBox(height: 16),
                _hint(context.t.ip_camera_brands_hint, key: const Key('ip_camera_brands_hint')),
                const SizedBox(height: 8),
                _hint(context.t.ip_camera_refused_brands_hint),
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
                          key: const Key('ip_camera_remove'),
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
                        key: const Key('ip_camera_save'),
                        onPressed: canSubmit ? () => unawaited(_save()) : null,
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

/// A line of the outcome of a read
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
