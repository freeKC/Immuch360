import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/tapo_camera_info.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/pages/network/network_shares.page.dart';
import 'package:immich_mobile/presentation/widgets/camera/camera_badges.widget.dart';
import 'package:immich_mobile/presentation/widgets/camera/camera_live_view.widget.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/network_discovery.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/providers/tapo/tapo_camera.provider.dart';
import 'package:immich_mobile/providers/tapo/tapo_infrastructure.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:immich_mobile/utils/system_ui.utils.dart';
import 'package:logging/logging.dart';

final _log = Logger('CameraPage');

/// A Tapo camera: its live view, the state of its memory card and the days it recorded
///
/// When the camera does not answer at its address, it is looked for once on the network by its MAC address; when it
/// shows another certificate than the one stored (at a new address or after a reset), the user decides.
@RoutePage()
class CameraPage extends ConsumerStatefulWidget {
  const CameraPage({super.key, required this.sourceId});

  final String sourceId;

  @override
  ConsumerState<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends ConsumerState<CameraPage> {
  /// Full screen is a state of this page (no route): Back leaves it first
  bool _fullScreen = false;
  bool _relocating = false;
  bool _relocationTried = false;
  bool _askingCertificate = false;

  String get _id => widget.sourceId;

  @override
  void dispose() {
    if (_fullScreen) {
      unawaited(_restoreScreen());
    }
    super.dispose();
  }

  Future<void> _setFullScreen(bool fullScreen) async {
    setState(() => _fullScreen = fullScreen);
    if (fullScreen) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      if (!ref.read(tvModeProvider)) {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      }
    } else {
      await _restoreScreen();
    }
  }

  static Future<void> _restoreScreen() async {
    // Not edgeToEdge alone: on Android 15 and later it leaves the bars that immersiveSticky hid hidden
    await restoreEdgeToEdge();
    await SystemChrome.setPreferredOrientations(const []);
  }

  Future<void> _refresh() async {
    ref.invalidate(tapoCameraStatusProvider(_id));
    ref.invalidate(tapoCameraCacheBytesProvider(_id));
    await ref.read(tapoCameraDaysProvider(_id).notifier).refresh();
  }

  /// What a failure of the camera asks for: the user's word on a new certificate, or a look for the camera elsewhere
  void _onError(Object error) {
    if (error is! TapoCameraException) {
      return;
    }
    if (error.kind == TapoErrorKind.certificateChanged) {
      unawaited(_askCertificate(error.certificateSha256));
    } else if (error.kind == TapoErrorKind.unreachable && !_relocationTried) {
      _relocationTried = true;
      unawaited(_relocate());
    }
  }

  Future<bool> _confirmCertificate(String host) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(context.t.camera_error_certificate_changed(host: host)),
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
    return accepted == true;
  }

  Future<void> _askCertificate(String? certificate) async {
    final source = ref.read(networkSourceProvider(_id));
    if (_askingCertificate || source == null || certificate == null) {
      return;
    }
    _askingCertificate = true;
    try {
      if (!await _confirmCertificate(source.host) || !mounted) {
        return;
      }
      final camera = (source.camera ?? const TapoCameraInfo()).copyWith(certificateSha256: certificate);
      await ref.read(networkSourcesProvider.notifier).update(source.copyWith(camera: camera));
    } finally {
      _askingCertificate = false;
    }
  }

  /// Finds the camera again by its MAC address, and keeps the new address once its certificate is the stored one, or
  /// one the user accepts (a camera that answers in its place would show another)
  Future<void> _relocate() async {
    final source = ref.read(networkSourceProvider(_id));
    if (source == null || source.discoveryId == null) {
      return;
    }
    setState(() => _relocating = true);
    try {
      final relocated = await ref.read(networkSourceRelocatorProvider).relocate(source);
      if (relocated == null || !mounted) {
        return;
      }
      final seen = await ref.read(tapoCertificateReaderProvider)(relocated.host);
      if (seen == null || !mounted) {
        return;
      }
      // The search is over; what is left is the user's word, when it is needed: another certificate than the pinned
      // one, or none pinned yet, since this page never trusts a first certificate on its own
      setState(() => _relocating = false);
      final pin = source.camera?.certificateSha256?.toLowerCase();
      if (pin != seen) {
        if (!await _confirmCertificate(relocated.host) || !mounted) {
          return;
        }
      }
      _log.info('A camera answers at a new address now');
      final camera = (source.camera ?? const TapoCameraInfo()).copyWith(certificateSha256: seen);
      // Once per visit of the page: a camera that does not answer at its new address either is not looked for again
      await ref.read(networkSourcesProvider.notifier).update(relocated.copyWith(camera: camera));
    } catch (error, stackTrace) {
      _log.warning('Could not look for a camera on the network', error, stackTrace);
    } finally {
      if (mounted) {
        setState(() => _relocating = false);
      }
    }
  }

  Future<void> _clearCache() async {
    final recordings = await ref.read(tapoRecordingsProvider(_id).future);
    await recordings?.clearCache();
    ref.invalidate(tapoCameraCacheBytesProvider(_id));
  }

  @override
  Widget build(BuildContext context) {
    final source = ref.watch(networkSourceProvider(_id));
    if (source == null) {
      return Scaffold(appBar: AppBar(title: Text(context.t.camera_cameras)));
    }
    ref.listen(tapoCameraStatusProvider(_id), (_, next) {
      if (next case AsyncError(:final error)) {
        _onError(error);
      }
    });
    ref.listen(tapoCameraDaysProvider(_id), (_, next) {
      if (next case AsyncError(:final error)) {
        _onError(error);
      }
    });
    final tvMode = ref.watch(tvModeProvider);
    final isQuest = ref.watch(isHorizonOsProvider).valueOrNull ?? false;
    final accountPassword = ref.watch(tapoCameraAccountPasswordProvider(_id)).valueOrNull;
    final hasLive =
        defaultTargetPlatform == TargetPlatform.android &&
        source.username.isNotEmpty &&
        (accountPassword?.isNotEmpty ?? false);

    final live = CameraLiveTile(
      key: const Key('camera_live_tile'),
      host: source.host,
      port: source.camera?.rtspPort ?? TapoCameraInfo.defaultRtspPort,
      user: source.username,
      password: accountPassword,
      fullScreen: _fullScreen,
      preferHd: isQuest,
      autofocus: tvMode && hasLive,
      onFullScreen: (value) => unawaited(_setFullScreen(value)),
    );

    return PopScope(
      canPop: !_fullScreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _fullScreen) {
          unawaited(_setFullScreen(false));
        }
      },
      child: _fullScreen
          ? Scaffold(backgroundColor: Colors.black, body: live)
          : Scaffold(
              appBar: AppBar(
                title: Text(source.name),
                elevation: 0,
                centerTitle: false,
                actions: [
                  IconButton(
                    key: const Key('camera_refresh'),
                    tooltip: context.t.refresh,
                    icon: const Icon(Icons.refresh_rounded),
                    onPressed: () => unawaited(_refresh()),
                  ),
                  IconButton(
                    key: const Key('camera_edit'),
                    tooltip: context.t.camera_edit,
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => context.pushRoute(networkSourceEditRoute(source)),
                  ),
                ],
              ),
              body: SafeArea(
                child: RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 32),
                    children: [
                      AspectRatio(aspectRatio: 16 / 9, child: live),
                      if (_relocating)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                          child: Row(
                            children: [
                              const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                              const SizedBox(width: 12),
                              Expanded(child: Text(context.t.network_share_relocating(name: source.name))),
                            ],
                          ),
                        ),
                      _Status(source: source),
                      _Recordings(source: source, autofocusFirst: tvMode && !hasLive, onClearCache: _clearCache),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}

/// Model and firmware, and the memory card
class _Status extends ConsumerWidget {
  const _Status({required this.source});

  final NetworkSource source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(tapoCameraStatusProvider(source.id)).valueOrNull;
    final model = status?.details.model ?? source.camera?.model;
    final firmware = status?.details.firmware ?? source.camera?.firmware;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Wrap(
        spacing: 16,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (model != null && model.isNotEmpty)
            Text(
              firmware == null ? model : context.t.camera_model_firmware(model: model, firmware: firmware),
              key: const Key('camera_model_firmware'),
              style: context.textTheme.bodyMedium,
            ),
          if (status != null) CameraCardBadge(card: status.card),
        ],
      ),
    );
  }
}

/// The days with recordings, by month, and what was fetched from the camera
class _Recordings extends ConsumerWidget {
  const _Recordings({required this.source, required this.autofocusFirst, required this.onClearCache});

  final NetworkSource source;
  final bool autofocusFirst;
  final Future<void> Function() onClearCache;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 4),
      child: Text(
        context.t.camera_recordings,
        style: context.textTheme.titleSmall?.copyWith(color: context.primaryColor, fontWeight: FontWeight.bold),
      ),
    );
    final hasPassword = ref.watch(tapoCameraHasCloudPasswordProvider(source.id));
    if (hasPassword.valueOrNull == false) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          _Note(key: const Key('camera_recordings_needs_password'), text: context.t.camera_recordings_needs_password),
        ],
      );
    }
    final days = ref.watch(tapoCameraDaysProvider(source.id));
    final locale = context.locale.toLanguageTag();
    final children = <Widget>[header];
    switch (days) {
      case AsyncData(:final value) when value.isEmpty:
        children.add(_Note(key: const Key('camera_days_empty'), text: context.t.camera_days_empty));
      case AsyncData(:final value):
        String? month;
        for (final (index, day) in value.indexed) {
          final date = DateTime.tryParse(day);
          if (date == null) {
            continue;
          }
          final key = day.substring(0, 7);
          if (key != month) {
            month = key;
            children.add(
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Text(
                  DateFormat.yMMMM(locale).format(date),
                  style: context.textTheme.labelLarge?.copyWith(color: context.colorScheme.onSurfaceVariant),
                ),
              ),
            );
          }
          children.add(
            ListTile(
              key: Key('camera_day_$day'),
              autofocus: autofocusFirst && index == 0,
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              leading: const Icon(Icons.calendar_today_outlined),
              title: Text(DateFormat.yMMMMEEEEd(locale).format(date)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.pushRoute(CameraDayRoute(sourceId: source.id, day: day)),
            ),
          );
        }
      case AsyncError(:final error):
        children.add(
          _Note(
            key: const Key('camera_days_error'),
            text: cameraErrorText(context, error, host: source.host),
            isError: true,
            action: TextButton.icon(
              key: const Key('camera_days_retry'),
              onPressed: () {
                // The user asks the camera again: a refused password or a lockout remembered is tried once more
                ref.read(tapoRefusalsForgetterProvider)(source.id);
                ref.invalidate(tapoRecordingsProvider(source.id));
              },
              icon: const Icon(Icons.refresh_rounded),
              label: Text(context.t.retry),
            ),
          ),
        );
      default:
        children.add(
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
        );
    }
    final cacheBytes = ref.watch(tapoCameraCacheBytesProvider(source.id)).valueOrNull ?? 0;
    if (cacheBytes > 0) {
      children
        ..add(const Divider(height: 32))
        ..add(
          ListTile(
            key: const Key('camera_cache'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            leading: const Icon(Icons.delete_sweep_outlined),
            title: Text(context.t.camera_cache_clear),
            subtitle: Text(context.t.camera_cache_size(size: formatBytes(cacheBytes))),
            onTap: () => unawaited(onClearCache()),
          ),
        );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}

class _Note extends StatelessWidget {
  const _Note({super.key, required this.text, this.isError = false, this.action});

  final String text;
  final bool isError;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          text,
          style: context.textTheme.bodyMedium?.copyWith(
            color: isError ? context.colorScheme.error : context.colorScheme.onSurfaceVariant,
          ),
        ),
        ?action,
      ],
    ),
  );
}
