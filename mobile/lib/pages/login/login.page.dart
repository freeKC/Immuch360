import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/pairing/pairing_panel.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_focusable.widget.dart';
import 'package:immich_mobile/providers/pairing/screen_pairing.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/widgets/forms/login/login_form.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

@RoutePage()
class LoginPage extends HookConsumerWidget {
  const LoginPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appVersion = useState('0.0.0');
    // A TV, the Quest window and a computer are signed in by a phone too (sign in with your phone)
    final bigScreen = ref.watch(isBigScreenProvider);

    Future<void> getAppInfo() async {
      final PackageInfo packageInfo = await PackageInfo.fromPlatform();
      appVersion.value = packageInfo.version;
    }

    useEffect(() {
      unawaited(getAppInfo());
      return null;
    });

    return Scaffold(
      body: bigScreen ? const _BigScreenLogin() : LoginForm(),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 16.0),
          child: SizedBox(
            height: 50,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'v${appVersion.value}',
                  style: TextStyle(
                    color: context.colorScheme.onSurfaceSecondary,
                    fontWeight: FontWeight.bold,
                    fontFamily: "GoogleSansCode",
                  ),
                ),
                const Text(' '),
                RemoteFocusable(
                  onTap: () {
                    unawaited(context.pushRoute(const AppLogRoute()));
                  },
                  child: Text(
                    'Logs',
                    style: TextStyle(
                      color: context.primaryColor,
                      fontWeight: FontWeight.bold,
                      fontFamily: "GoogleSansCode",
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The sign-in page of a big screen: the pairing panel beside the address form when the window is wide enough (a TV,
/// the Quest window, most computer windows), else a button above the form that opens it
class _BigScreenLogin extends StatelessWidget {
  const _BigScreenLogin();

  /// The narrowest window that holds the panel and the form side by side
  static const wideLayout = 720.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < wideLayout) {
          return Column(
            children: [
              SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.only(top: ImmichSpacing.md),
                  child: OutlinedButton.icon(
                    key: const Key('pairing_open_panel'),
                    icon: const Icon(Icons.qr_code_2_rounded),
                    label: Text(context.t.pairing_screen_title),
                    onPressed: () => unawaited(_openPanel(context)),
                  ),
                ),
              ),
              Expanded(child: LoginForm()),
            ],
          );
        }
        final padding = MediaQuery.paddingOf(context);
        return Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  padding.left + ImmichSpacing.lg,
                  padding.top + ImmichSpacing.sm,
                  ImmichSpacing.lg,
                  ImmichSpacing.sm,
                ),
                child: const Center(child: PairingPanel()),
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: Column(
                children: [
                  // One line under the top margin, which the form then leaves out: it keeps its place on a TV
                  Padding(
                    padding: EdgeInsets.only(top: padding.top, left: ImmichSpacing.md, right: ImmichSpacing.md),
                    child: Text(
                      context.t.pairing_screen_or_type,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceVariant),
                    ),
                  ),
                  Expanded(
                    child: MediaQuery.removePadding(context: context, removeTop: true, child: LoginForm()),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  static Future<void> _openPanel(BuildContext context) => showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      content: const SingleChildScrollView(child: PairingPanel(compact: true)),
      actions: [TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text(context.t.close))],
    ),
  );
}
