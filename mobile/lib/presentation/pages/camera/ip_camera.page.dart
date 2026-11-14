import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/ip_camera_info.dart';
import 'package:immich_mobile/domain/services/ip_camera.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/pages/network/network_shares.page.dart';
import 'package:immich_mobile/presentation/widgets/camera/camera_live_view.widget.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/ipcam/ip_camera.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/utils/system_ui.utils.dart';

/// A camera of another brand than Tapo (ONVIF or a typed RTSP address): its live view and what it told of itself.
/// Live only: its recordings are not read in this version, and nothing is ever sent to it but what the live view
/// needs.
@RoutePage()
class IpCameraPage extends ConsumerStatefulWidget {
  const IpCameraPage({super.key, required this.sourceId});

  final String sourceId;

  @override
  ConsumerState<IpCameraPage> createState() => _IpCameraPageState();
}

class _IpCameraPageState extends ConsumerState<IpCameraPage> {
  bool _fullScreen = false;

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
    await restoreEdgeToEdge();
    await SystemChrome.setPreferredOrientations(const []);
  }

  @override
  Widget build(BuildContext context) {
    final source = ref.watch(networkSourceProvider(widget.sourceId));
    final info = source?.ipCamera;
    if (source == null || info == null) {
      return Scaffold(appBar: AppBar(title: Text(context.t.camera_cameras)));
    }
    final tvMode = ref.watch(tvModeProvider);
    final isQuest = ref.watch(isHorizonOsProvider).valueOrNull ?? false;
    final password = ref.watch(ipCameraPasswordProvider(source.id));
    final streams = ref.watch(ipCameraStreamsProvider(source.id));

    final Widget live;
    if (password.isLoading || streams.isLoading) {
      live = const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (streams.valueOrNull case final stored?) {
      live = CameraLiveTile(
        key: const Key('ip_camera_live_tile'),
        host: source.host,
        port: info.rtspPort,
        user: source.username,
        password: password.valueOrNull,
        model: info.label,
        firmware: info.firmware,
        fullScreen: _fullScreen,
        preferHd: isQuest,
        autofocus: tvMode,
        ipStreams: IpCameraLiveStreams(
          hdPath: stored.pathFor(hd: true),
          sdPath: stored.pathFor(hd: false),
          secure: info.secure,
        ),
        onFullScreen: (value) => unawaited(_setFullScreen(value)),
      );
    } else {
      // A settings file restored without its accounts: the stream addresses went with them
      live = _Note(key: const Key('ip_camera_no_streams'), text: context.t.ip_camera_no_streams);
    }

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
                    key: const Key('ip_camera_edit'),
                    tooltip: context.t.camera_edit,
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => context.pushRoute(networkSourceEditRoute(source)),
                  ),
                ],
              ),
              body: SafeArea(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 32),
                  children: [
                    AspectRatio(aspectRatio: _aspect(info), child: live),
                    _Details(info: info),
                  ],
                ),
              ),
            ),
    );
  }

  /// The tile at the shape of the main stream when the camera told it (a square fisheye, a 4:3 camera), 16:9 else
  static double _aspect(IpCameraInfo info) {
    final width = info.main?.width;
    final height = info.main?.height;
    if (width == null || height == null || width <= 0 || height <= 0) {
      return 16 / 9;
    }
    return (width / height).clamp(0.5, 2.5);
  }
}

class _Details extends StatelessWidget {
  const _Details({required this.info});

  final IpCameraInfo info;

  @override
  Widget build(BuildContext context) {
    String stream(IpCameraStreamInfo? stream) =>
        OnvifProfile(token: '', encoding: stream?.codec, width: stream?.width, height: stream?.height).label;
    final label = info.label;
    final main = stream(info.main);
    final sub = stream(info.sub);
    final style = context.textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null)
            Text(
              info.firmware == null ? label : context.t.camera_model_firmware(model: label, firmware: info.firmware!),
              key: const Key('ip_camera_model'),
              style: style,
            ),
          if (main.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              context.t.ip_camera_read_profiles(main: main, sub: sub.isEmpty ? '-' : sub),
              key: const Key('ip_camera_streams'),
              style: style,
            ),
          ],
          const SizedBox(height: 16),
          Text(
            context.t.ip_camera_live_only,
            style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.colorScheme.surfaceContainerHighest,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(text, textAlign: TextAlign.center, style: context.textTheme.bodyMedium),
      ),
    ),
  );
}
