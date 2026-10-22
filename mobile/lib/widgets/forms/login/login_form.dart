import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:auto_route/auto_route.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart' hide Store;
import 'package:fluttertoast/fluttertoast.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/tv_api.g.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_focusable.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_text_entry.widget.dart';
import 'package:immich_mobile/providers/auth.provider.dart';
import 'package:immich_mobile/providers/infrastructure/device_features.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/oauth.provider.dart';
import 'package:immich_mobile/providers/pairing/screen_pairing.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/provider_utils.dart';
import 'package:immich_mobile/utils/semver.dart';
import 'package:immich_mobile/utils/url_helper.dart';
import 'package:immich_mobile/utils/version_compatibility.dart';
import 'package:immich_mobile/widgets/common/immich_logo.dart';
import 'package:immich_mobile/widgets/common/immich_title_text.dart';
import 'package:immich_mobile/widgets/common/immich_toast.dart';
import 'package:immich_mobile/widgets/forms/login/sign_in_completion.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart';
import 'package:package_info_plus/package_info_plus.dart';

class LoginForm extends HookConsumerWidget {
  LoginForm({super.key});

  final log = Logger('LoginForm');

  String? _validateUrl(String? url) =>
      normalizeAndValidateServerUrl(url) ? null : StaticTranslations.instance.login_form_err_invalid_url;

  String? _validateEmail(String? email) {
    if (email == null || email == '') {
      return null;
    }
    if (email.endsWith(' ')) {
      return StaticTranslations.instance.login_form_err_trailing_whitespace;
    }
    if (email.startsWith(' ')) {
      return StaticTranslations.instance.login_form_err_leading_whitespace;
    }
    if (email.contains(' ') || !email.contains('@')) {
      return StaticTranslations.instance.login_form_err_invalid_email;
    }
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final emailController = useTextEditingController.fromValue(TextEditingValue.empty);
    final passwordController = useTextEditingController.fromValue(TextEditingValue.empty);
    final serverEndpointController = useTextEditingController.fromValue(TextEditingValue.empty);
    final passwordFocusNode = useFocusNode();
    final isOauthEnable = useState<bool>(false);
    final isPasswordLoginEnable = useState<bool>(false);
    final oAuthButtonLabel = useState<String>('OAuth');
    final serverInfo = ref.watch(serverInfoProvider);
    final warningMessage = useState<String?>(null);
    final loginFormKey = GlobalKey<FormState>();
    final ValueNotifier<String?> serverEndpoint = useState<String?>(null);
    // The remote control layout (Android TV): the fields are typed in through the native text dialog
    final tvMode = ref.watch(tvModeProvider);
    // Not checked on a computer yet: the localhost redirect the desktop needs must be accepted by the server
    final hasOauth = ref.watch(deviceFeaturesProvider.select((features) => features.oauth));
    // A big screen shows the pairing panel beside the form: OAuth is a scan away on a phone
    final bigScreen = ref.watch(isBigScreenProvider);
    final passwordEntryFocus = useFocusNode(debugLabel: 'Password entry');
    // Kept across the builds of the form, whose key changes at each one: a new entry would lose the focus
    final emailEntryFocus = useFocusNode(debugLabel: 'Email entry');

    Future<void> checkVersionMismatch() async {
      try {
        final packageInfo = await PackageInfo.fromPlatform();
        final appSemVer = SemVer.fromString(packageInfo.version);
        final serverSemVer = serverInfo.serverVersion;
        warningMessage.value = getVersionCompatibilityMessage(serverVersion: serverSemVer, appVersion: appSemVer);
      } catch (error) {
        warningMessage.value = 'Error checking version compatibility';
      }
    }

    /// Fetch the server login credential and enables oAuth login if necessary
    /// Returns true if successful, false otherwise
    Future<void> getServerAuthSettings() async {
      final sanitizeServerUrl = normalizeServerUrl(serverEndpointController.text);
      final serverUrl = punycodeEncodeUrl(sanitizeServerUrl);

      // Guard empty URL
      if (serverUrl.isEmpty) {
        ImmichToast.show(context: context, msg: context.t.login_form_server_empty, toastType: ToastType.error);
      }

      try {
        final endpoint = await ref.read(authProvider.notifier).validateServerUrl(serverUrl);
        if (!context.mounted) {
          return;
        }

        // Fetch and load server config and features
        await ref.read(serverInfoProvider.notifier).getServerInfo();
        if (!context.mounted) {
          return;
        }

        final serverInfo = ref.read(serverInfoProvider);
        final features = serverInfo.serverFeatures;
        final config = serverInfo.serverConfig;

        isOauthEnable.value = features.oauthEnabled;
        isPasswordLoginEnable.value = features.passwordLogin;
        oAuthButtonLabel.value = config.oauthButtonText.isNotEmpty ? config.oauthButtonText : 'OAuth';

        serverEndpoint.value = endpoint;
      } on ApiException catch (e) {
        if (!context.mounted) {
          return;
        }

        ImmichToast.show(
          context: context,
          msg: e.message ?? context.t.login_form_api_exception,
          toastType: ToastType.error,
          gravity: ToastGravity.TOP,
        );
        isOauthEnable.value = false;
        isPasswordLoginEnable.value = true;
      } on HandshakeException {
        if (!context.mounted) {
          return;
        }

        ImmichToast.show(
          context: context,
          msg: context.t.login_form_handshake_exception,
          toastType: ToastType.error,
          gravity: ToastGravity.TOP,
        );
        isOauthEnable.value = false;
        isPasswordLoginEnable.value = true;
      } catch (e) {
        if (!context.mounted) {
          return;
        }

        ImmichToast.show(
          context: context,
          msg: context.t.login_form_server_error,
          toastType: ToastType.error,
          gravity: ToastGravity.TOP,
        );
        isOauthEnable.value = false;
        isPasswordLoginEnable.value = true;
      }
    }

    useEffect(() {
      final serverUrl = getServerUrl();
      if (serverUrl != null) {
        serverEndpointController.text = serverUrl;
      }
      return null;
    }, []);

    void populateTestLoginInfo() {
      emailController.text = 'demo@immich.app';
      passwordController.text = 'demo';
      serverEndpointController.text = 'https://demo.immich.app';
    }

    void populateTestLoginInfo1() {
      emailController.text = 'testuser@email.com';
      passwordController.text = 'password';
      serverEndpointController.text = 'http://10.1.15.216:2283/api';
    }

    Future<void> login() async {
      TextInput.finishAutofillContext();

      // Invalidate all api repository provider instance to take into account new access token
      invalidateAllApiRepositoryProviders(ref);

      try {
        final result = await ref.read(authProvider.notifier).login(emailController.text, passwordController.text);

        if (!context.mounted) {
          return;
        }

        if (result.shouldChangePassword && !result.isAdmin) {
          unawaited(context.pushRoute(const ChangePasswordRoute()));
          passwordController.clear();
        } else {
          await completeSignIn(context, ref);
          return;
        }
      } catch (error) {
        if (!context.mounted) {
          return;
        }

        ImmichToast.show(
          context: context,
          msg: context.t.login_form_failed_login,
          toastType: ToastType.error,
          gravity: ToastGravity.TOP,
        );
      }
    }

    /// Back to the page the form was opened from: the welcome page, or the settings of a session without a server.
    /// When the form is the only page (a deep link opened it), the welcome page replaces it.
    void goBack() {
      if (context.router.canPop()) {
        unawaited(context.maybePop());
      } else {
        unawaited(context.router.replaceAll([const WelcomeRoute()]));
      }
    }

    String generateRandomString(int length) {
      const chars = 'AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz1234567890';
      final random = Random.secure();
      return String.fromCharCodes(Iterable.generate(length, (_) => chars.codeUnitAt(random.nextInt(chars.length))));
    }

    List<int> randomBytes(int length) {
      final random = Random.secure();
      return List<int>.generate(length, (i) => random.nextInt(256));
    }

    /// Per specification, the code verifier must be 43-128 characters long
    /// and consist of characters [A-Z, a-z, 0-9, "-", ".", "_", "~"]
    /// https://datatracker.ietf.org/doc/html/rfc7636#section-4.1
    String randomCodeVerifier() {
      return base64Url.encode(randomBytes(42));
    }

    Future<String> generatePKCECodeChallenge(String codeVerifier) async {
      final bytes = utf8.encode(codeVerifier);
      final digest = sha256.convert(bytes);
      return base64Url.encode(digest.bytes).replaceAll('=', '');
    }

    Future<void> oAuthLogin() async {
      final oAuthService = ref.read(oAuthServiceProvider);
      String? oAuthServerUrl;

      final state = generateRandomString(32);

      final codeVerifier = randomCodeVerifier();
      final codeChallenge = await generatePKCECodeChallenge(codeVerifier);

      try {
        oAuthServerUrl = await oAuthService.getOAuthServerUrl(
          normalizeServerUrl(serverEndpointController.text),
          state,
          codeChallenge,
        );

        // Invalidate all api repository provider instance to take into account new access token
        invalidateAllApiRepositoryProviders(ref);
      } catch (error, stack) {
        log.severe('Error getting OAuth server Url: $error', stack);

        if (!context.mounted) {
          return;
        }

        ImmichToast.show(
          context: context,
          msg: context.t.login_form_failed_get_oauth_server_config,
          toastType: ToastType.error,
          gravity: ToastGravity.TOP,
        );
        return;
      }

      if (oAuthServerUrl != null) {
        try {
          final loginResponseDto = await oAuthService.oAuthLogin(oAuthServerUrl, state, codeVerifier);

          if (loginResponseDto == null || !context.mounted) {
            return;
          }

          log.info("Finished OAuth login with response: ${loginResponseDto.userEmail}");

          final isSuccess = await ref
              .read(authProvider.notifier)
              .saveAuthInfo(accessToken: loginResponseDto.accessToken);

          if (isSuccess && context.mounted) {
            await completeSignIn(context, ref, connectWebsocket: false);
            return;
          }
        } catch (error, stack) {
          log.severe('Error logging in with OAuth: $error', stack);

          if (!context.mounted) {
            return;
          }

          ImmichToast.show(
            context: context,
            msg: error.toString(),
            toastType: ToastType.error,
            gravity: ToastGravity.TOP,
          );
        } finally {}
      } else {
        if (!context.mounted) {
          return;
        }

        ImmichToast.show(
          context: context,
          msg: context.t.login_form_failed_get_oauth_server_disable,
          toastType: ToastType.info,
          gravity: ToastGravity.TOP,
        );
        return;
      }
    }

    SingleChildRenderObjectWidget buildVersionCompatWarning() {
      unawaited(checkVersionMismatch());

      if (warningMessage.value == null) {
        return const SizedBox.shrink();
      }

      return Padding(
        padding: const EdgeInsets.only(bottom: 8.0),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: context.isDarkTheme ? Colors.amber.shade700 : Colors.amber.shade100,
            borderRadius: const BorderRadius.all(Radius.circular(12)),
            border: Border.all(color: context.isDarkTheme ? Colors.amber.shade800 : Colors.amber[200]!, width: 2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.amber.shade800),
              const SizedBox(width: 8),
              Expanded(
                child: Padding(padding: const EdgeInsets.only(top: 2), child: Text(warningMessage.value!)),
              ),
            ],
          ),
        ),
      );
    }

    final serverSelectionOrLogin = serverEndpoint.value == null
        ? Padding(
            padding: const EdgeInsets.only(top: ImmichSpacing.md),
            child: Column(
              mainAxisSize: MainAxisSize.max,
              children: [
                ImmichForm(
                  onSubmit: getServerAuthSettings,
                  submitText: context.t.next,
                  submitIcon: Icons.arrow_forward_rounded,
                  builder: (_, form) => TvTextEntry(
                    controller: serverEndpointController,
                    label: context.t.login_form_endpoint_url,
                    kind: TvTextKind.url,
                    // The server was chosen on the welcome page: on a TV the focus starts on its address
                    autofocus: true,
                    onSubmitted: (_) => form.submit(),
                    child: ImmichURLInput(
                      controller: serverEndpointController,
                      label: context.t.login_form_endpoint_url,
                      hintText: context.t.login_form_endpoint_hint,
                      validator: _validateUrl,
                      keyboardAction: .next,
                      onSubmit: (_) => form.submit(),
                    ),
                  ),
                ),
                ImmichTextButton(
                  labelText: context.t.settings,
                  icon: Icons.settings,
                  variant: ImmichVariant.ghost,
                  onPressed: () => context.pushRoute(const SettingsRoute()),
                ),
                ImmichTextButton(
                  labelText: context.t.back,
                  icon: Icons.arrow_back,
                  variant: ImmichVariant.ghost,
                  onPressed: goBack,
                ),
              ],
            ),
          )
        : AutofillGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.max,
              children: [
                buildVersionCompatWarning(),
                Padding(
                  padding: const EdgeInsets.only(bottom: ImmichSpacing.md),
                  child: Text(
                    normalizeServerUrl(serverEndpointController.text),
                    style: context.textTheme.displaySmall,
                    textAlign: TextAlign.center,
                  ),
                ),
                if (isPasswordLoginEnable.value)
                  ImmichForm(
                    onSubmit: login,
                    submitText: context.t.login,
                    submitIcon: Icons.login_rounded,
                    builder: (context, form) => Column(
                      spacing: ImmichSpacing.md,
                      children: [
                        TvTextEntry(
                          controller: emailController,
                          label: context.t.email,
                          kind: TvTextKind.email,
                          autofocus: true,
                          focusNode: emailEntryFocus,
                          onSubmitted: (_) => passwordEntryFocus.requestFocus(),
                          child: ImmichEmailInput(
                            controller: emailController,
                            label: context.t.email,
                            hintText: context.t.login_form_email_hint,
                            validator: _validateEmail,
                            keyboardAction: TextInputAction.next,
                            onSubmit: (_) => passwordFocusNode.requestFocus(),
                          ),
                        ),
                        TvTextEntry(
                          controller: passwordController,
                          label: context.t.password,
                          kind: TvTextKind.password,
                          focusNode: passwordEntryFocus,
                          onSubmitted: (_) => form.submit(),
                          child: ImmichPasswordInput(
                            controller: passwordController,
                            focusNode: passwordFocusNode,
                            label: context.t.password,
                            hintText: context.t.login_form_password_hint,
                            keyboardAction: TextInputAction.go,
                            onSubmit: (_) => form.submit(),
                          ),
                        ),
                      ],
                    ),
                  ),
                // OAuth signs in through a web page, which a TV cannot open (Play criterion TV-WB): a line says so
                if (isOauthEnable.value && (tvMode || !hasOauth))
                  Padding(
                    padding: const EdgeInsets.only(top: ImmichSpacing.md),
                    child: Text(
                      bigScreen
                          ? context.t.tv_oauth_use_phone(provider: oAuthButtonLabel.value)
                          : tvMode
                          ? context.t.tv_oauth_unavailable(provider: oAuthButtonLabel.value)
                          : context.t.desktop_oauth_unavailable(provider: oAuthButtonLabel.value),
                      textAlign: TextAlign.center,
                      style: context.textTheme.bodyMedium,
                    ),
                  )
                else if (isOauthEnable.value)
                  ImmichForm(
                    onSubmit: oAuthLogin,
                    submitText: oAuthButtonLabel.value,
                    submitIcon: Icons.pin_outlined,
                    builder: (context, _) => isPasswordLoginEnable.value
                        ? Padding(
                            padding: const EdgeInsets.only(left: 18.0, right: 18.0, top: 12.0),
                            child: Divider(color: context.isDarkTheme ? Colors.white : Colors.black, height: 5),
                          )
                        : const SizedBox.shrink(),
                  ),
                if (!isOauthEnable.value && !isPasswordLoginEnable.value) Center(child: Text(context.t.login_disabled)),
                ImmichTextButton(
                  labelText: context.t.back,
                  icon: Icons.arrow_back,
                  variant: ImmichVariant.ghost,
                  onPressed: () => serverEndpoint.value = null,
                ),
              ],
            ),
          );

    // A TV of 1080p shows 960 x 540 dp, less its overscan margins and the version line: the phone layout (the logo a
    // fifth of the height down, 100 dp tall) pushed the last action of the form below the screen. The TV gets a small
    // logo at the top, under the margin of the TV shell.
    final logoSize = tvMode ? 56.0 : 100.0;
    final titleSize = tvMode ? 28.0 : 48.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          padding: tvMode ? EdgeInsets.only(top: MediaQuery.paddingOf(context).top) : null,
          child: Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 300),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(height: tvMode ? ImmichSpacing.sm : constraints.maxHeight / 5),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      GestureDetector(
                        onDoubleTap: () => populateTestLoginInfo(),
                        onLongPress: () => populateTestLoginInfo1(),
                        // The Immuch360 icon carries text, so it is not spun like the Immich logo. Sized before the
                        // picture is decoded, so that nothing moves when it shows.
                        child: SizedBox.square(
                          dimension: logoSize,
                          child: ImmichLogo(size: logoSize),
                        ),
                      ),
                      Padding(
                        padding: EdgeInsets.only(top: 8.0, bottom: tvMode ? 8 : 16),
                        // The title picture is about four times as wide as high
                        child: SizedBox(
                          height: titleSize,
                          child: ImmichTitleText(fontSize: titleSize),
                        ),
                      ),
                    ],
                  ),

                  // Note: This used to have an AnimatedSwitcher, but was removed
                  // because of https://github.com/flutter/flutter/issues/120874
                  // The credentials step replaces the address or Next, which had the focus: Flutter then gives it
                  // back to the item focused before on the page (Logs under the form, once visited), and the
                  // autofocus of the email gives way. Keyed by the step, so that it acts once each time the step
                  // shows.
                  RemoteInitialFocus(
                    key: ValueKey(serverEndpoint.value != null),
                    enabled: tvMode && serverEndpoint.value != null,
                    child: Form(key: loginFormKey, child: serverSelectionOrLogin),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
