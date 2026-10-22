// The pairing panel of the big screens' sign-in page: the QR code a phone scans, the short code, how long it lives,
// the steps, and what happens. It runs the listener for as long as it shows (screen_pairing.provider.dart), and once a
// phone (or the browser page) signed the screen in, it ends the sign in as the password form does.
//
// The TV and the computer show the QR code first; the Quest window shows the code first and large, since no phone
// camera can see a window that exists only inside the headset. Nothing in it takes the focus of the remote but "Show
// a new code".

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/network/computer_share.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/pairing/pairing_protocol.dart';
import 'package:immich_mobile/domain/services/pairing/screen_pairing_session.dart';
import 'package:immich_mobile/domain/services/pairing/screen_sign_in.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/presentation/widgets/pairing/qr_code.widget.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/auth.provider.dart';
import 'package:immich_mobile/providers/pairing/paired_screen_check.provider.dart';
import 'package:immich_mobile/providers/pairing/screen_pairing.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/services/widget.service.dart';
import 'package:immich_mobile/utils/provider_utils.dart';
import 'package:immich_mobile/utils/url_helper.dart';
import 'package:immich_mobile/widgets/common/immich_toast.dart';
import 'package:immich_mobile/widgets/forms/login/sign_in_completion.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:openapi/api.dart';

/// See the top of this file. [compact] for a narrow window: a smaller code, no steps. In a dialog too: the timeline
/// replaces the sign-in page and the dialog with it.
class PairingPanel extends ConsumerStatefulWidget {
  const PairingPanel({super.key, this.compact = false});

  final bool compact;

  @override
  ConsumerState<PairingPanel> createState() => _PairingPanelState();
}

class _PairingPanelState extends ConsumerState<PairingPanel> {
  late final ScreenPairingController _controller;
  Timer? _ticker;
  bool _completing = false;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(screenPairingProvider.notifier);
    unawaited(_controller.show(AppScreenSignInActions(ref)));
    // The countdown of the code
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    unawaited(_controller.hide());
    super.dispose();
  }

  Future<void> _complete(ScreenPairingView view) async {
    if (_completing) {
      return;
    }
    _completing = true;
    final signedIn = view.signedIn;
    if (signedIn != null && signedIn.user.isNotEmpty && signedIn.phone != null) {
      ImmichToast.show(
        context: context,
        msg: context.t.pairing_screen_signed_in_with(user: signedIn.user, phone: signedIn.phone!),
        toastType: ToastType.success,
        gravity: ToastGravity.TOP,
      );
    }
    if (signedIn?.phone != null) {
      ref.read(pairedScreenCheckProvider).afterPairing();
    }
    await completeSignIn(context, ref);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(screenPairingProvider, (previous, next) {
      if (next.phase == ScreenPairingPhase.signedIn && previous?.phase != ScreenPairingPhase.signedIn) {
        unawaited(_complete(next));
      }
    });
    final view = ref.watch(screenPairingProvider);
    return PairingPanelContent(
      view: view,
      compact: widget.compact,
      now: DateTime.now(),
      onShowNewCode: () => unawaited(_controller.showNewCode()),
    );
  }
}

/// What the panel shows of [view], without any listener: the page and the widget tests use it alike
class PairingPanelContent extends StatelessWidget {
  const PairingPanelContent({
    super.key,
    required this.view,
    required this.now,
    required this.onShowNewCode,
    this.compact = false,
  });

  final ScreenPairingView view;
  final DateTime now;
  final VoidCallback onShowNewCode;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = context.textTheme;
    final scheme = context.colorScheme;
    final headset = view.kind == PairingScreenKind.headset;
    final computer = view.kind == PairingScreenKind.computer;
    final qrText = view.qrText;
    final code = view.code;
    final qrSize = compact ? 168.0 : (headset ? 132.0 : 176.0);
    // The QR code beside the code on a TV and a computer, so that the steps fit under them on a 540 dp TV; the code
    // above a smaller QR code in the headset, one above the other in a narrow window
    final sideBySide = !headset && !compact;

    final status = _status(t);
    final problem = _problem(t);
    final notice = _notice(t);

    final qr = qrText == null
        ? SizedBox.square(dimension: qrSize)
        : QrCodeView(key: const Key('pairing_qr'), data: qrText, size: qrSize, semanticLabel: t.pairing_scan_prompt);
    final codeText = code == null
        ? const SizedBox.shrink()
        : Column(
            key: const Key('pairing_code'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(t.pairing_screen_code_label, style: theme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  code,
                  maxLines: 1,
                  style: TextStyle(
                    fontFamily: 'GoogleSansCode',
                    fontSize: headset ? 40 : (compact ? 24 : 28),
                    fontWeight: FontWeight.w600,
                    letterSpacing: 2,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ],
          );

    final expiresAt = view.expiresAt;
    final startedAt = view.startedAt;
    final secondsLeft = expiresAt?.difference(now).inSeconds.clamp(0, 9999);
    final total = expiresAt == null || startedAt == null ? null : expiresAt.difference(startedAt).inSeconds;
    final countdown = secondsLeft == null || total == null || total <= 0 || code == null
        ? const SizedBox(height: 4)
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: sideBySide ? 140 : qrSize,
                child: LinearProgressIndicator(value: secondsLeft / total, minHeight: 3),
              ),
              const SizedBox(height: 2),
              Text(
                t.pairing_screen_new_code_in(seconds: '$secondsLeft'),
                style: theme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          );

    final steps = <String>[
      t.pairing_screen_step_open_app,
      t.pairing_screen_step_scan,
      switch (view.kind) {
        PairingScreenKind.headset => t.pairing_screen_same_wifi_headset,
        PairingScreenKind.computer => t.pairing_screen_same_network_computer,
        PairingScreenKind.tv => t.pairing_screen_same_wifi_tv,
      },
    ];
    final small = theme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final typedUrl = view.typedUrl;

    final showsCode = view.problem == ScreenPairingProblem.none && view.phase != ScreenPairingPhase.paused;
    // What happens: why the code changed, and what the phone does
    final state = [
      if (notice != null) ...[
        const SizedBox(height: ImmichSpacing.xs),
        Text(
          notice,
          style: theme.bodySmall?.copyWith(color: scheme.error),
          textAlign: TextAlign.center,
        ),
      ],
      if (status != null) ...[
        const SizedBox(height: ImmichSpacing.xs),
        Text(status, key: const Key('pairing_status'), style: theme.bodyMedium, textAlign: TextAlign.center),
      ],
      // The number each phone that said hello shows too: the user checks it, and a second number tells that another
      // device is signing in
      if (view.phase == ScreenPairingPhase.confirmOnPhone && view.checks.isNotEmpty) ...[
        Text(
          view.checks.length == 1 ? t.pairing_screen_check : t.pairing_screen_checks,
          style: small,
          textAlign: TextAlign.center,
        ),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            view.checks.map(formatPairingCheckNumber).join('   '),
            key: const Key('pairing_checks'),
            maxLines: 1,
            style: TextStyle(
              fontFamily: 'GoogleSansCode',
              fontSize: headset ? 32 : 24,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
              color: scheme.primary,
            ),
          ),
        ),
      ],
    ];
    return Column(
      key: const Key('pairing_panel'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(t.pairing_screen_title, style: theme.titleMedium, textAlign: TextAlign.center),
        const SizedBox(height: ImmichSpacing.sm),
        if (showsCode) ...[
          if (sideBySide)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                qr,
                const SizedBox(width: ImmichSpacing.md),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      codeText,
                      const SizedBox(height: ImmichSpacing.xs),
                      countdown,
                      ...state,
                    ],
                  ),
                ),
              ],
            )
          else ...[
            if (headset) ...[codeText, const SizedBox(height: ImmichSpacing.sm), qr] else ...[qr, codeText],
            const SizedBox(height: ImmichSpacing.xs),
            countdown,
            ...state,
          ],
          if (!compact) ...[
            const SizedBox(height: ImmichSpacing.sm),
            for (final step in steps) Text(step, style: theme.bodySmall, textAlign: TextAlign.center),
            if (headset) Text(t.pairing_screen_headset_hint, style: theme.bodySmall, textAlign: TextAlign.center),
          ],
          if (typedUrl != null) ...[
            const SizedBox(height: ImmichSpacing.xs),
            Text(
              t.pairing_screen_no_app(url: typedUrl),
              style: small,
              textAlign: TextAlign.center,
            ),
          ],
          if (computer && view.port != null)
            Text(
              t.pairing_screen_firewall_port(port: '${view.port}'),
              style: small,
              textAlign: TextAlign.center,
            ),
        ] else ...[
          if (problem != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: ImmichSpacing.md),
              child: Text(problem, key: const Key('pairing_problem'), textAlign: TextAlign.center),
            ),
          if (view.phase == ScreenPairingPhase.paused) ...[
            Text(t.pairing_screen_paused, textAlign: TextAlign.center),
            const SizedBox(height: ImmichSpacing.md),
          ],
          if (view.problem == ScreenPairingProblem.publicNetwork && CurrentPlatform.isWindows)
            TextButton(
              onPressed: () => unawaited(openWindowsNetworkSettings()),
              child: Text(t.local_session_permission_settings),
            ),
          if (view.phase == ScreenPairingPhase.paused ||
              view.problem == ScreenPairingProblem.failed ||
              view.problem == ScreenPairingProblem.noNetwork)
            FilledButton.tonal(
              key: const Key('pairing_new_code'),
              onPressed: onShowNewCode,
              child: Text(t.pairing_screen_show_new_code),
            ),
        ],
      ],
    );
  }

  String? _status(Translations t) => switch (view.phase) {
    ScreenPairingPhase.waiting => t.pairing_screen_waiting,
    ScreenPairingPhase.confirmOnPhone => t.pairing_screen_confirm_on_phone,
    ScreenPairingPhase.signingIn || ScreenPairingPhase.signedIn => t.pairing_screen_signing_in,
    ScreenPairingPhase.paused || ScreenPairingPhase.stopped => null,
  };

  String? _notice(Translations t) => switch (view.notice) {
    ScreenPairingNotice.none => null,
    ScreenPairingNotice.tooManyAttempts => t.pairing_screen_too_many_attempts,
    ScreenPairingNotice.serverUnreachable => t.pairing_screen_server_unreachable(server: view.noticeDetail ?? ''),
    ScreenPairingNotice.signInFailed => t.pairing_screen_sign_in_failed,
  };

  String? _problem(Translations t) => switch (view.problem) {
    ScreenPairingProblem.none => null,
    ScreenPairingProblem.publicNetwork => t.pairing_screen_public_network,
    ScreenPairingProblem.noNetwork || ScreenPairingProblem.failed => t.pairing_screen_no_network,
  };
}

/// The app's side of a sign in from the pairing panel: the settings, the stores and the server of the app
class AppScreenSignInActions implements ScreenSignInActions {
  AppScreenSignInActions(this._ref);

  final WidgetRef _ref;

  ApiService get _api => _ref.read(apiServiceProvider);

  @override
  Future<ScreenSignInSnapshot> snapshot() async => ScreenSignInSnapshot(
    headers: Map.of(SettingsRepository.instance.appConfig.network.customHeaders),
    label: Store.tryGet(StoreKey.pairingScreenLabel),
    serverUrl: Store.tryGet(StoreKey.serverUrl),
    serverEndpoint: Store.tryGet(StoreKey.serverEndpoint),
  );

  @override
  Future<void> restore(ScreenSignInSnapshot snapshot) async {
    // The token first: the Store's cache also follows the database through a stream, whose later events then no
    // longer hold it
    await Store.delete(StoreKey.accessToken);
    // The home screen widget got the token with the sign in
    await _ref.read(widgetServiceProvider).clearCredentials();
    await SettingsRepository.instance.write(.networkCustomHeaders, snapshot.headers);
    Future<void> put(StoreKey<String> key, String? value) => value == null ? Store.delete(key) : Store.put(key, value);
    await put(StoreKey.pairingScreenLabel, snapshot.label);
    // The server the attempt named goes too: the login form fills its address from these at the next start
    await put(StoreKey.serverUrl, snapshot.serverUrl);
    await put(StoreKey.serverEndpoint, snapshot.serverEndpoint);
    _api.setEndpoint(snapshot.serverEndpoint ?? '');
    await _api.setDeviceInfoHeader();
    await _api.updateHeaders();
  }

  @override
  Future<void> setCustomHeaders(Map<String, String> headers) async {
    await SettingsRepository.instance.write(.networkCustomHeaders, headers);
    await _api.updateHeaders();
  }

  @override
  Future<void> setLabel(String label) => Store.put(StoreKey.pairingScreenLabel, label);

  @override
  Future<String?> tryServer(String endpoint, Duration timeout) async {
    // A ping only, which changes nothing: an address that answers late cannot become the server under the next one
    final url = normalizeServerUrl(endpoint);
    final candidates = url.endsWith('/api') ? [url] : ['$url/api', url];
    String? reached;
    final deadline = DateTime.now().add(timeout);
    for (final candidate in candidates) {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) {
        break;
      }
      try {
        final response = await NetworkRepository.client.get(Uri.parse('$candidate/server/ping')).timeout(left);
        if (response.statusCode == 200 && response.body.contains('pong')) {
          reached = candidate;
          break;
        }
      } catch (_) {
        // Another candidate, or the next address
      }
    }
    return reached;
  }

  @override
  Future<void> useServer(String apiUrl) async {
    // What validateServerUrl does once the address answered, without asking the server again
    _api.setEndpoint(apiUrl);
    await Store.put(StoreKey.serverEndpoint, apiUrl);
    await _api.setDeviceInfoHeader();
    await Store.put(StoreKey.serverUrl, apiUrl);
  }

  @override
  Future<bool> useToken(String token) async {
    invalidateAllApiRepositoryProviders(_ref);
    // The token goes in the cookie jar of the native clients (or the computers' stack), as a sign in sets it
    await NetworkRepository.setHeaders(ApiService.getNativeHeaders(), ApiService.getServerUrls(), token: token);
    return _ref.read(authProvider.notifier).saveAuthInfo(accessToken: token);
  }

  @override
  Future<({bool passwordLogin, String? oauthProvider})> loginOptions() async {
    await _ref.read(serverInfoProvider.notifier).getServerInfo();
    final info = _ref.read(serverInfoProvider);
    final label = info.serverConfig.oauthButtonText;
    return (
      passwordLogin: info.serverFeatures.passwordLogin,
      oauthProvider: info.serverFeatures.oauthEnabled ? (label.isNotEmpty ? label : 'OAuth') : null,
    );
  }

  @override
  Future<PasswordSignInOutcome> login(String email, String password) async {
    invalidateAllApiRepositoryProviders(_ref);
    try {
      await _ref.read(authProvider.notifier).login(email, password);
      return PasswordSignInOutcome.signedIn;
    } on ApiException catch (error) {
      return error.code == 401 || error.code == 400
          ? PasswordSignInOutcome.wrongCredentials
          : PasswordSignInOutcome.failed;
    } catch (_) {
      return PasswordSignInOutcome.failed;
    }
  }

  @override
  Future<void> setSignedInBy(String? phone) async {
    if (phone == null) {
      await Store.delete(StoreKey.pairingSignedInBy);
    } else {
      await Store.put(StoreKey.pairingSignedInBy, phone);
    }
  }

  @override
  String? userName() {
    final name = _ref.read(authProvider).name;
    return name.isEmpty ? null : name;
  }
}
