// The live view of a camera (Tapo design 3.8). On Android and the Quest a platform view (CameraLiveView.kt) plays the
// RTSP stream of the camera with Media3; it gets the address and the camera account through CameraLiveApi.setSource,
// never through the creation parameters of the view, and reports its state through CameraLiveEvents. The sub stream
// (SD) on a phone, the main one (HD) in full screen and on the Quest. On iPhone and iPad, where AVPlayer has no RTSP,
// Dart pulls the stream and makes a live HLS playlist of it on the local media bridge, which the platform view
// (CameraLiveView.swift) plays without ever getting the account (CameraLiveHlsController). On a computer,
// DesktopCameraLiveView (lib/desktop/video/camera_live_view.dart) plays the same stream through libmpv and reports the
// same states; where libmpv is missing (Linux and macOS until their video libraries come) the live view is announced
// for later.
//
// A camera without RTSP (the battery and solar ones) streams through its media port instead, with the password of the
// TP-Link account: Dart makes the same live HLS playlist of it on every phone (TapoPreviewLiveHls), which the platform
// view plays (Media3 HLS on Android and the Quest, AVPlayer on iPhone and iPad). A camera whose RTSP does not even
// start on a visit is tried through its media port too, when the TP-Link password is there. When the live view fails,
// the tile shows the reason in words and a diagnostics line (model, firmware, power, route, the step that failed and
// the camera's code) that the user can read back.
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
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/tapo/rtsp_probe.dart';
import 'package:immich_mobile/platform/camera_live_api.g.dart';
import 'package:immich_mobile/presentation/widgets/camera/camera_live_diagnostics.dart';
import 'package:immich_mobile/presentation/widgets/camera/camera_live_hls.dart';
import 'package:immich_mobile/providers/tapo/tapo_camera.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('CameraLiveView');

/// The type of the platform view, CameraLiveViewFactory.VIEW_TYPE in Kotlin and viewType in Swift
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
    this.mediaPort = false,
    this.onEvent,
    this.onFailure,
  });

  final String host;
  final int port;
  final String user;
  final String password;
  final bool hd;
  final bool muted;

  /// The stream of the media port: [port] is the media port and [password] the TP-Link one; [user] is not used
  final bool mediaPort;
  final ValueChanged<CameraLiveEvent>? onEvent;

  /// What made an open of the live playlist fail, for the diagnostics line
  final ValueChanged<Object>? onFailure;

  @override
  ConsumerState<CameraLiveView> createState() => _CameraLiveViewState();
}

class _CameraLiveViewState extends ConsumerState<CameraLiveView> with WidgetsBindingObserver {
  int? _viewId;
  StreamSubscription<CameraLiveEvent>? _events;
  bool _stopped = false;

  /// iPhone and iPad: the live playlist made in Dart and its player
  CameraLiveHlsController? _hls;

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
    if (defaultTargetPlatform == TargetPlatform.iOS || widget.mediaPort) {
      final hls = _hls = CameraLiveHlsController(
        viewId: viewId,
        api: _api,
        startStream: widget.mediaPort ? ref.read(cameraPreviewHlsProvider) : ref.read(cameraLiveHlsProvider),
        onEvent: (event) => widget.onEvent?.call(event),
        onFailure: (error) => widget.onFailure?.call(error),
      );
      _events = _hub.of(viewId).listen(hls.onPlayerEvent);
    } else {
      _events = _hub.of(viewId).listen((event) => widget.onEvent?.call(event));
    }
    _play();
  }

  void _play() {
    final viewId = _viewId;
    if (viewId == null) {
      return;
    }
    _stopped = false;
    final hls = _hls;
    if (hls != null) {
      // The playlist comes with the muting of the view
      hls
        ..setMuted(widget.muted)
        ..play(host: widget.host, port: widget.port, user: widget.user, password: widget.password, hd: widget.hd);
      return;
    }
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
    final hls = _hls;
    if (hls != null) {
      hls.stop();
      return;
    }
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
    } else if (oldWidget.muted != widget.muted && _hls != null) {
      _hls!.setMuted(widget.muted);
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
    // The page is going too: the live playlist stops without telling it
    final hls = _hls;
    if (hls != null) {
      hls.dispose();
    } else {
      _stop();
    }
    unawaited(_events?.cancel());
    final viewId = _viewId;
    if (viewId != null) {
      _hub.release(viewId);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final view =
        ref.read(cameraLivePlatformViewProvider)?.call(_created) ??
        (defaultTargetPlatform == TargetPlatform.iOS ? _iosView() : _androidView());
    return ExcludeFocus(child: IgnorePointer(child: view));
  }

  /// No creation parameters: the playlist comes through setSource
  Widget _iosView() => UiKitView(
    viewType: cameraLiveViewType,
    layoutDirection: TextDirection.ltr,
    hitTestBehavior: PlatformViewHitTestBehavior.transparent,
    onPlatformViewCreated: _created,
  );

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
/// buttons (sound, HD or SD, full screen); the reason when there is no live view, and when it failed, the reason in
/// words, a Retry button and the diagnostics line
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
    this.cloudPassword,
    this.mediaPort = 8800,
    this.model,
    this.firmware,
    this.power,
    this.deviceType,
    this.autofocus = false,
  });

  final String host;

  /// The RTSP port
  final int port;

  /// The camera account; null or empty: the hint to add one
  final String user;
  final String? password;

  /// The password of the TP-Link account: the live view through the media port, for a camera without RTSP
  final String? cloudPassword;
  final int mediaPort;

  /// What the camera told of itself (stored with the source, or fresh from the camera), for the route and the
  /// diagnostics line
  final String? model;
  final String? firmware;
  final String? power;
  final String? deviceType;
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

  /// RTSP failed on this visit before its first frame: the media port is tried in its place, when it can be
  bool _rtspFailed = false;
  String? _rtspError;

  /// A frame of the current route was shown
  bool _played = false;

  /// What made the last open of a live playlist fail
  Object? _failure;

  /// Bumped by Retry: a new live view
  int _attempt = 0;

  bool get _isHd => widget.fullScreen || (_hd ?? widget.preferHd);

  bool get _hasAccount => widget.user.isNotEmpty && (widget.password?.isNotEmpty ?? false);

  bool get _hasCloudPassword => widget.cloudPassword?.isNotEmpty ?? false;

  TapoLiveRoute get _route => tapoLiveRoute(
    model: widget.model,
    power: widget.power,
    deviceType: widget.deviceType,
    hasCameraAccount: _hasAccount,
    hasCloudPassword: _hasCloudPassword,
    rtspFailed: _rtspFailed,
  );

  void _onEvent(TapoLiveRoute route, CameraLiveEvent event) {
    if (!mounted) {
      return;
    }
    setState(() {
      if (event.state == CameraLiveState.playing) {
        _played = true;
        _failure = null;
      }
      if (event.state == CameraLiveState.failed &&
          route == TapoLiveRoute.rtsp &&
          !_played &&
          _hasCloudPassword &&
          !CurrentPlatform.isDesktop) {
        // A camera without RTSP that this build does not know as one (or RTSP off with Tapo Care and a card): the
        // media port, with the TP-Link password (not on a computer yet, where the RTSP reason stays)
        _log.info('RTSP did not start (${event.error}); trying the media port');
        _rtspFailed = true;
        _rtspError = event.error;
        _event = (state: CameraLiveState.connecting, error: null, hasAudio: true);
        return;
      }
      _event = event;
    });
  }

  void _retry() => setState(() {
    _attempt++;
    _played = false;
    _failure = null;
    _event = (state: CameraLiveState.idle, error: null, hasAudio: true);
  });

  String _failureText(BuildContext context) {
    final error = _event.error;
    final failure = _failure;
    final notAnswering =
        (failure is TapoLiveException && failure.step == TapoLiveStep.connect) || error == cameraLiveUnreachable;
    return switch (error) {
      // An H.265 camera on iPhone and iPad: its own message, the SD stream may still be H.264
      cameraLiveH265 => context.t.camera_live_h265_later_on_ios,
      cameraLiveMediaLocked => context.t.camera_error_media_locked,
      cameraLiveBusy => context.t.camera_error_busy,
      _ when notAnswering && _route == TapoLiveRoute.mediaPort => context.t.camera_live_asleep,
      _ => context.t.camera_live_failed(error: error ?? ''),
    };
  }

  @override
  Widget build(BuildContext context) {
    if (CurrentPlatform.isDesktop && !DesktopCameraLiveView.available) {
      return _Message(key: const Key('camera_live_later'), text: context.t.desktop_tapo_live_later);
    }
    final route = _route;
    switch (route) {
      case TapoLiveRoute.hub:
        return _Message(key: const Key('camera_live_hub'), text: context.t.camera_live_hub);
      case TapoLiveRoute.needsCloudPassword:
        return _Message(
          key: const Key('camera_live_needs_cloud_password'),
          text: context.t.camera_live_needs_cloud_password,
        );
      case TapoLiveRoute.needsAccount:
        return _Message(key: const Key('camera_live_needs_account'), text: context.t.camera_live_needs_account);
      // The computers have no media port live view yet: a camera with RTSP (a mains one without a camera account)
      // still asks for the camera account there, only a battery or solar one is told that it has no RTSP
      case TapoLiveRoute.mediaPort
          when CurrentPlatform.isDesktop && !tapoIsBatteryCamera(model: widget.model, power: widget.power):
        return _Message(key: const Key('camera_live_needs_account'), text: context.t.camera_live_needs_account);
      case TapoLiveRoute.mediaPort when CurrentPlatform.isDesktop:
        return _Message(
          key: const Key('camera_live_media_port_later'),
          text: context.t.camera_live_media_port_later_desktop,
        );
      case TapoLiveRoute.rtsp || TapoLiveRoute.mediaPort:
        break;
    }
    final mediaPort = route == TapoLiveRoute.mediaPort;
    final playing = _event.state == CameraLiveState.playing;
    final failed = _event.state == CameraLiveState.failed;
    final line = switch (_event.state) {
      CameraLiveState.connecting || CameraLiveState.buffering => context.t.camera_live_connecting,
      CameraLiveState.failed => _failureText(context),
      CameraLiveState.idle || CameraLiveState.playing => null,
    };
    final diagnostics = failed
        ? cameraLiveDiagnostics(
            model: widget.model,
            firmware: widget.firmware,
            power: widget.power,
            route: route,
            hd: _isHd,
            rtspPort: widget.port,
            mediaPort: widget.mediaPort,
            rtspError: _rtspError,
            failure: _failure,
            error: _event.error,
          )
        : null;
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
              key: ValueKey(_attempt),
              url: cameraRtspUrl(widget.host, widget.port, hd: _isHd),
              user: widget.user,
              password: widget.password ?? '',
              muted: _muted,
              onEvent: (event) => _onEvent(route, event),
            )
          else
            CameraLiveView(
              // A new view for another route or a retry: the controller of a view keeps its route
              key: ValueKey((route, _attempt)),
              host: widget.host,
              port: mediaPort ? widget.mediaPort : widget.port,
              user: mediaPort ? '' : widget.user,
              password: (mediaPort ? widget.cloudPassword : widget.password) ?? '',
              hd: _isHd,
              muted: _muted,
              mediaPort: mediaPort,
              onEvent: (event) => _onEvent(route, event),
              onFailure: (error) {
                if (mounted) {
                  setState(() => _failure = error);
                }
              },
            ),
          if (line != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      line,
                      key: const Key('camera_live_state'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: failed ? Colors.red.shade200 : Colors.white),
                    ),
                    if (diagnostics != null) ...[
                      const SizedBox(height: 8),
                      SelectableText(
                        context.t.camera_live_diagnostics(details: diagnostics),
                        key: const Key('camera_live_diagnostics'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                      const SizedBox(height: 8),
                      TextButton.icon(
                        key: const Key('camera_live_retry'),
                        style: TextButton.styleFrom(backgroundColor: Colors.black45, foregroundColor: Colors.white),
                        onPressed: _retry,
                        icon: const Icon(Icons.refresh_rounded),
                        label: Text(context.t.retry),
                      ),
                    ],
                  ],
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
