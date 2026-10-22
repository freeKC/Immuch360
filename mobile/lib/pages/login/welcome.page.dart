import 'dart:async';
import 'dart:math';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_focusable.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_focus_ring.widget.dart';
import 'package:immich_mobile/providers/feature_message.provider.dart';
import 'package:immich_mobile/providers/gallery_permission.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/pairing/screen_pairing.provider.dart';
import 'package:immich_mobile/providers/view_intent/view_intent_handler.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/widgets/common/immich_logo.dart';
import 'package:immich_mobile/widgets/common/immich_title_text.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:logging/logging.dart';

final _log = Logger('WelcomePage');

/// The first screen while no session exists: the app with or without a server. Three choices, the first one the
/// primary one: the photos and videos of this device without a server, a network share or a media server (the shares
/// page, in a session without a server), and an Immich server (the login form, whose Back comes here again).
///
/// The same page for touch, the Quest controller, the remote of a TV (the focus starts on the first choice) and the
/// mouse and keyboard of a computer, where a ring shows the focus that Tab moves, and where the first choice leads to
/// the folders to choose as long as there is none.
@RoutePage()
class WelcomePage extends HookConsumerWidget {
  const WelcomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tvMode = ref.watch(tvModeProvider);
    // A TV, the Quest window and a computer are signed in by a phone too; a phone signs them in
    final bigScreen = ref.watch(isBigScreenProvider);
    // One session start at a time: a second tap while the permission dialog shows would start another
    final starting = useRef(false);

    /// Starts a session without a server, then opens [then] above the tabs. The gallery is asked for when
    /// [askGallery], that is for the photos and videos of this device; a share, a media server or a camera do not need
    /// it, and the Photos tab asks again while it is not given. A file opened with the app shows once the device is
    /// indexed, as when a session without a server resumes.
    Future<void> startWithoutServer({required bool askGallery, PageRouteInfo? then}) async {
      if (starting.value) {
        return;
      }
      // Left set once the session started: the tabs replace this page
      starting.value = true;
      try {
        final localSession = ref.read(localSessionProvider.notifier);
        final refreshLocalSession = ref.read(localSessionRefreshProvider);
        final viewIntentHandler = ref.read(viewIntentHandlerProvider);
        final featureMessageService = ref.read(featureMessageServiceProvider);

        final gallery = askGallery
            ? await ref.read(galleryPermissionNotifier.notifier).requestGalleryPermission()
            : null;
        await localSession.enter();
        unawaited(
          refreshLocalSession(full: true).then((_) => viewIntentHandler.flushDeferredViewIntent()).catchError((
            Object e,
          ) {
            _log.severe('Failed to open a file shared with the app: $e');
          }),
        );
        unawaited(featureMessageService.markSeen());
        if (!context.mounted) {
          return;
        }

        // On a computer the photos and videos are those of the folders the user chooses: the folders page first, as
        // long as there is none (the gallery reads as granted once a folder is chosen)
        final chooseFolders = CurrentPlatform.isDesktop && gallery != null && !gallery.hasAccess;
        unawaited(context.router.replaceAll([const TabShellRoute(), ?then, if (chooseFolders) const FoldersRoute()]));
      } catch (_) {
        starting.value = false;
        rethrow;
      }
    }

    final choices = [
      _WelcomeChoice(
        key: const Key('welcome_without_server'),
        emphasis: _Emphasis.primary,
        icon: CurrentPlatform.isDesktop ? Icons.folder_outlined : Icons.photo_library_outlined,
        title: context.t.login_form_use_without_server,
        description: context.t.welcome_without_server_description,
        onTap: () => unawaited(startWithoutServer(askGallery: true)),
      ),
      _WelcomeChoice(
        key: const Key('welcome_shares'),
        emphasis: _Emphasis.tonal,
        icon: Icons.lan_outlined,
        title: context.t.welcome_shares_title,
        description: context.t.welcome_shares_description,
        onTap: () => unawaited(startWithoutServer(askGallery: false, then: const NetworkSharesRoute())),
      ),
      _WelcomeChoice(
        key: const Key('welcome_server'),
        emphasis: _Emphasis.outlined,
        icon: Icons.login_rounded,
        title: context.t.welcome_server_title,
        description: bigScreen
            ? context.t.welcome_server_description_big_screen
            : context.t.local_session_connect_server_subtitle,
        onTap: () => unawaited(context.pushRoute(const LoginRoute())),
      ),
    ];

    // A ring for the focus of Tab on a computer, as its own pages have: Material only tints a focused card, too faintly
    // to follow. The remote control layout has the ring of the whole app already.
    return TvFocusRing(
      enabled: CurrentPlatform.isDesktop && !tvMode,
      child: Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Side by side on a TV, a computer, a tablet and a phone held sideways, the choices wider than the
              // header so that their text wraps less (a 1080p TV is 540 dp high); one above the other on a phone
              final wide = constraints.maxWidth >= 720;
              final header = _WelcomeHeader(small: tvMode || constraints.maxHeight < 600);
              final list = RemoteInitialFocus(
                enabled: tvMode,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: ImmichSpacing.md,
                  children: [
                    ...choices,
                    // A phone signs the big screens in once it has a server: the way there
                    if (!bigScreen)
                      TextButton.icon(
                        key: const Key('welcome_pairing'),
                        icon: const Icon(Icons.qr_code_scanner_rounded),
                        label: Text(context.t.pairing_welcome_link),
                        onPressed: () => unawaited(_explainPairing(context)),
                      ),
                  ],
                ),
              );
              const padding = ImmichSpacing.lg;
              return SingleChildScrollView(
                padding: const EdgeInsets.all(padding),
                child: ConstrainedBox(
                  // Centred while it fits, scrolled when it does not (large text)
                  constraints: BoxConstraints(minHeight: max(0, constraints.maxHeight - 2 * padding)),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: wide ? 960 : 480),
                      child: wide
                          ? Row(
                              children: [
                                Expanded(flex: 2, child: header),
                                const SizedBox(width: ImmichSpacing.xxl),
                                Expanded(flex: 3, child: list),
                              ],
                            )
                          : Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                header,
                                const SizedBox(height: ImmichSpacing.xxl),
                                list,
                              ],
                            ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// What a phone needs to sign a TV or a computer in: a server first, then the scan
Future<void> _explainPairing(BuildContext context) async {
  final connect = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      icon: const Icon(Icons.qr_code_scanner_rounded),
      title: Text(context.t.pairing_connect_title),
      content: Text(context.t.pairing_welcome_explainer),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text(context.t.cancel)),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(context.t.welcome_server_title),
        ),
      ],
    ),
  );
  if (connect == true && context.mounted) {
    unawaited(context.pushRoute(const LoginRoute()));
  }
}

/// The icon and the name of the app, and its promise
class _WelcomeHeader extends StatelessWidget {
  const _WelcomeHeader({required this.small});

  /// A TV, or a short screen: smaller pictures, so that the three choices show at once
  final bool small;

  @override
  Widget build(BuildContext context) {
    final logoSize = small ? 64.0 : 96.0;
    final titleSize = small ? 32.0 : 44.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Sized before the pictures are decoded, so that nothing moves when they show
        SizedBox.square(
          dimension: logoSize,
          child: ImmichLogo(size: logoSize),
        ),
        const SizedBox(height: ImmichSpacing.md),
        // The title picture is about four times as wide as high
        SizedBox(
          height: titleSize,
          child: ImmichTitleText(fontSize: titleSize),
        ),
        const SizedBox(height: ImmichSpacing.lg),
        Text(
          context.t.welcome_tagline,
          textAlign: TextAlign.center,
          style: context.textTheme.titleMedium?.copyWith(color: context.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

enum _Emphasis { primary, tonal, outlined }

/// One choice of the welcome page: a large card that a tap, a click, Enter or OK opens
class _WelcomeChoice extends StatelessWidget {
  const _WelcomeChoice({
    super.key,
    required this.emphasis,
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  final _Emphasis emphasis;
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final (background, foreground, iconColor, side) = switch (emphasis) {
      _Emphasis.primary => (scheme.primary, scheme.onPrimary, scheme.onPrimary, BorderSide.none),
      _Emphasis.tonal => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
        scheme.onSecondaryContainer,
        BorderSide.none,
      ),
      _Emphasis.outlined => (Colors.transparent, scheme.onSurface, scheme.primary, BorderSide(color: scheme.outline)),
    };
    // Read out as a button, its title then its description
    return Semantics(
      button: true,
      child: Material(
        color: background,
        shape: RoundedRectangleBorder(borderRadius: const BorderRadius.all(Radius.circular(20)), side: side),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          // A tint of the card's own text: the focus colour of the theme is the opaque primary colour out of the remote
          // control layout, and the text of the tonal and outlined cards would no longer read on it
          focusColor: foreground.withAlpha(40),
          hoverColor: foreground.withAlpha(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Row(
              children: [
                Icon(icon, size: 32, color: iconColor),
                const SizedBox(width: ImmichSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: context.textTheme.titleMedium?.copyWith(color: foreground, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: ImmichSpacing.xs),
                      Text(description, style: context.textTheme.bodyMedium?.copyWith(color: foreground)),
                    ],
                  ),
                ),
                const SizedBox(width: ImmichSpacing.sm),
                Icon(Icons.chevron_right_rounded, color: foreground),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
