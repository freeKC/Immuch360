// The live view of a camera (Tapo design 3.8). On Android and the Quest a platform view (CameraLiveView.kt) plays the
// RTSP stream of the camera with Media3; it gets the address and the camera account through CameraLiveApi.setSource,
// never through the creation parameters of the view, and reports its state through CameraLiveEvents. The sub stream
// (SD) on a phone, the main one (HD) in full screen and on the Quest. On iPhone and iPad the live view comes later:
// AVPlayer has no RTSP. On a computer, DesktopCameraLiveView (lib/desktop/video/camera_live_view.dart) plays the same
// stream through libmpv and reports the same states; where libmpv is missing (Linux and macOS until their video
// libraries come) the live view is announced for later.
//
// A platform view never takes the focus (a remote would get stuck in it): it sits in an ExcludeFocus, and its buttons
// are Flutter buttons above it.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/video/camera_live_view.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/tapo/rtsp_probe.dart';
import 'package:immich_mobile/platform/camera_live_api.g.dart';
import 'package:immich_mobile/providers/tapo/tapo_camera.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('CameraLiveView');

/// The type of the platform view, CameraLiveViewFactory.VIEW_TYPE in Kotlin
const cameraLiveViewType = 'immuch/camera_live';

/// The RTSP address of a stream of the camera at [host], without the account: Kotlin puts it in
String cameraRtspUrl(String host, int port, {required bool hd}) =>
    'rtsp://${host.contains(':') ? '[$host]' : host}:$port${hd ? tapoRtspHdPath : tapoRtspSdPath}';

/// The platform view playing a camera, see the header
class CameraLiveView extends ConsumerStatefulWidget {
  const CameraLiveView({
    super.key,
    required this.host,
    required this.port,
    required this.user,
    required this.password,
    required this.hd,
    required this.muted,
    this.onEvent,
  });

  final String host;
  final int port;
  final String user;
  final String password;
  final bool hd;
  final bool muted;
  final ValueChanged<CameraLiveEvent>? onEvent;

  @override
  ConsumerState<CameraLiveView> createState() => _CameraLiveViewState();
}

class _CameraLiveViewState extends ConsumerState<CameraLiveView> with WidgetsBindingObserver {
  int? _viewId;
  StreamSubscription<CameraLiveEvent>? _events;
  bool _stopped = false;

  late final CameraLiveApi _api = ref.read(cameraLiveApiProvider);
  late final CameraLiveEventsHub _hub = ref.read(cameraLiveEventsProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void _created(int viewId) {
    if (!mounted) {
      return;
    }
    _viewId = viewId;
    _events = _hub.of(viewId).listen((event) => widget.onEvent?.call(event));
    _play();
  }

  void _play() {
    final viewId = _viewId;
    if (viewId == null) {
      return;
    }
    _stopped = false;
    // Called from didUpdateWidget too, while the tile builds: it hears of the new state once that is over
    scheduleMicrotask(() {
      if (mounted) {
        widget.onEvent?.call((state: CameraLiveState.connecting, error: null, hasAudio: true));
      }
    });
    unawaited(
      _call(() async {
        await _api.setSource(
          viewId,
          CameraLiveSource(
            url: cameraRtspUrl(widget.host, widget.port, hd: widget.hd),
            username: widget.user,
            password: widget.password,
            isHls: false,
          ),
        );
        await _api.setMuted(viewId, widget.muted);
      }),
    );
  }

  void _stop() {
    final viewId = _viewId;
    if (viewId == null || _stopped) {
      return;
    }
    _stopped = true;
    unawaited(_call(() => _api.stop(viewId)));
  }

  /// A failure of the platform side is logged without its arguments: they hold the camera account
  Future<void> _call(Future<void> Function() call) async {
    try {
      await call();
    } on PlatformException catch (error) {
      _log.warning('The live view refused a call: ${error.code}');
    } catch (error) {
      _log.warning('The live view refused a call: ${error.runtimeType}');
    }
  }

  @override
  void didUpdateWidget(CameraLiveView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.host != widget.host ||
        oldWidget.port != widget.port ||
        oldWidget.hd != widget.hd ||
        oldWidget.user != widget.user ||
        oldWidget.password != widget.password) {
      _play();
    } else if (oldWidget.muted != widget.muted && _viewId != null) {
      final viewId = _viewId!;
      unawaited(_call(() => _api.setMuted(viewId, widget.muted)));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The camera serves two viewers at most: none is held while the app is away
    switch (state) {
      case AppLifecycleState.resumed:
        if (_stopped) {
          _play();
        }
      case AppLifecycleState.hidden || AppLifecycleState.paused || AppLifecycleState.detached:
        _stop();
      case AppLifecycleState.inactive:
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stop();
    unawaited(_events?.cancel());
    final viewId = _viewId;
    if (viewId != null) {
      _hub.release(viewId);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.read(cameraLivePlatformViewProvider)?.call(_created) ?? _androidView();
    return ExcludeFocus(child: IgnorePointer(child: view));
  }

  Widget _androidView() => PlatformViewLink(
    viewType: cameraLiveViewType,
    surfaceFactory: (context, controller) => AndroidViewSurface(
      controller: controller as AndroidViewController,
      gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
      hitTestBehavior: PlatformViewHitTestBehavior.transparent,
    ),
    onCreatePlatformView: (params) {
      final controller =
          PlatformViewsService.initSurfaceAndroidView(
              id: params.id,
              viewType: cameraLiveViewType,
              layoutDirection: TextDirection.ltr,
            )
            ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
            ..addOnPlatformViewCreatedListener(_created);
      unawaited(controller.create());
      return controller;
    },
  );
}

/// The live tile of the camera page: the live view with its state line, a "Live" badge while it plays, and its
/// buttons (sound, HD or SD, full screen); the reason when there is no live view
class CameraLiveTile extends StatefulWidget {
  const CameraLiveTile({
    super.key,
    required this.host,
    required this.port,
    required this.user,
    required this.password,
    required this.fullScreen,
    required this.preferHd,
    required this.onFullScreen,
    this.autofocus = false,
  });

  final String host;
  final int port;

  /// The camera account; null or empty: the hint to add one
  final String user;
  final String? password;
  final bool fullScreen;

  /// The HD stream when not in full screen (the Quest)
  final bool preferHd;
  final ValueChanged<bool> onFullScreen;

  /// TV mode: the first button takes the focus
  final bool autofocus;

  @override
  State<CameraLiveTile> createState() => _CameraLiveTileState();
}

class _CameraLiveTileState extends State<CameraLiveTile> {
  bool _muted = true;
  bool? _hd;
  CameraLiveEvent _event = (state: CameraLiveState.idle, error: null, hasAudio: true);

  bool get _isHd => widget.fullScreen || (_hd ?? widget.preferHd);

  @override
  Widget build(BuildContext context) {
    if (CurrentPlatform.isDesktop && !DesktopCameraLiveView.available) {
      return _Message(key: const Key('camera_live_later'), text: context.t.desktop_tapo_live_later);
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return _Message(key: const Key('camera_live_later'), text: context.t.camera_live_later_on_ios);
    }
    final password = widget.password;
    if (widget.user.isEmpty || password == null || password.isEmpty) {
      return _Message(key: const Key('camera_live_needs_account'), text: context.t.camera_live_needs_account);
    }
    final playing = _event.state == CameraLiveState.playing;
    final failed = _event.state == CameraLiveState.failed;
    final line = switch (_event.state) {
      CameraLiveState.connecting || CameraLiveState.buffering => context.t.camera_live_connecting,
      CameraLiveState.failed => context.t.camera_live_failed(error: _event.error ?? ''),
      CameraLiveState.idle || CameraLiveState.playing => null,
    };
    final buttonStyle = IconButton.styleFrom(
      backgroundColor: Colors.black45,
      foregroundColor: Colors.white,
      disabledForegroundColor: Colors.white38,
    );
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (CurrentPlatform.isDesktop)
            DesktopCameraLiveView(
              url: cameraRtspUrl(widget.host, widget.port, hd: _isHd),
              user: widget.user,
              password: password,
              muted: _muted,
              onEvent: (event) {
                if (mounted) {
                  setState(() => _event = event);
                }
              },
            )
          else
            CameraLiveView(
              host: widget.host,
              port: widget.port,
              user: widget.user,
              password: password,
              hd: _isHd,
              muted: _muted,
              onEvent: (event) {
                if (mounted) {
                  setState(() => _event = event);
                }
              },
            ),
          if (line != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  line,
                  key: const Key('camera_live_state'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: failed ? Colors.red.shade200 : Colors.white),
                ),
              ),
            ),
          if (playing)
            Positioned(
              left: 12,
              top: 12,
              child: DecoratedBox(
                key: const Key('camera_live_badge'),
                decoration: const BoxDecoration(color: Colors.red, borderRadius: BorderRadius.all(Radius.circular(4))),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  child: Text(
                    context.t.camera_live,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ),
          Positioned(
            right: 8,
            bottom: 8,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: const Key('camera_live_sound'),
                  autofocus: widget.autofocus,
                  style: buttonStyle,
                  tooltip: !_event.hasAudio
                      ? context.t.camera_live_no_sound
                      : _muted
                      ? context.t.camera_live_sound_on
                      : context.t.camera_live_sound_off,
                  onPressed: _event.hasAudio ? () => setState(() => _muted = !_muted) : null,
                  icon: Icon(!_event.hasAudio || _muted ? Icons.volume_off_outlined : Icons.volume_up_outlined),
                ),
                const SizedBox(width: 8),
                if (!widget.fullScreen) ...[
                  TextButton(
                    key: const Key('camera_live_quality'),
                    style: TextButton.styleFrom(backgroundColor: Colors.black45, foregroundColor: Colors.white),
                    onPressed: () => setState(() => _hd = !_isHd),
                    child: Text(_isHd ? context.t.camera_live_hd : context.t.camera_live_sd),
                  ),
                  const SizedBox(width: 8),
                ],
                IconButton(
                  key: const Key('camera_live_full_screen'),
                  style: buttonStyle,
                  tooltip: widget.fullScreen
                      ? context.t.camera_live_exit_full_screen
                      : context.t.camera_live_full_screen,
                  onPressed: () => widget.onFullScreen(!widget.fullScreen),
                  icon: Icon(widget.fullScreen ? Icons.fullscreen_exit : Icons.fullscreen),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.colorScheme.surfaceContainerHighest,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.videocam_off_outlined, color: context.colorScheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Flexible(child: Text(text, style: context.textTheme.bodyMedium)),
          ],
        ),
      ),
    ),
  );
}
