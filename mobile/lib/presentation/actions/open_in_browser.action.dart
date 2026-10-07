import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/actions/action.dart';
import 'package:immich_mobile/presentation/widgets/tv/open_url.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:url_launcher/url_launcher.dart' show canLaunchUrl;

class OpenInBrowserAction extends ActionBuilder {
  final String remoteId;
  final TimelineOrigin origin;

  const OpenInBrowserAction({required this.remoteId, required this.origin});

  @override
  ActionItem create(BuildContext context, WidgetRef ref) =>
      .new(icon: Icons.open_in_browser, label: context.t.open_in_browser, onAction: () => _open(context, ref));

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final serverEndpoint = ref.read(storeServiceProvider).get(.serverEndpoint).replaceFirst('/api', '');
    final url = Uri.parse('$serverEndpoint${webPathFor(origin)}/photos/$remoteId');

    // A TV shows the address to open elsewhere, whether or not it has something that opens it
    final tvMode = ref.read(tvModeProvider);
    if (tvMode) {
      await openUrl(context, url, tvMode: true);
      return;
    }
    // Bound before the wait: the menu that offered the action may be gone by then, and no context is read off a TV
    Future<bool> launch() => openUrl(context, url, mode: .externalApplication, tvMode: false);
    if (await canLaunchUrl(url)) {
      await launch();
    }
  }
}

@visibleForTesting
String webPathFor(TimelineOrigin origin) => switch (origin) {
  .favorite => '/favorites',
  .trash => '/trash',
  .archive => '/archive',
  _ => '',
};
