import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show appFlavor;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/models/server_info/server_info.model.dart';
import 'package:immich_mobile/presentation/widgets/tv/open_url.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/utils/app_update_link.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode;

final _log = Logger('ServerUpdateNotification');

class ServerUpdateNotification extends HookConsumerWidget {
  const ServerUpdateNotification({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serverInfoState = ref.watch(serverInfoProvider);

    const Color errorColor = Color.fromARGB(85, 253, 97, 83);
    final Color infoColor = context.isDarkTheme
        ? context.primaryColor.withAlpha(55)
        : context.primaryColor.withAlpha(25);
    Future<bool> openUpdateLink() async {
      // The signing certificate tells the Horizon Store build of the Quest from the APK of GitHub (appUpdateLinkOf);
      // the other builds do not need it.
      String? signature;
      if (appFlavor == kQuestFlavor) {
        signature = (await PackageInfo.fromPlatform()).buildSignature;
      }
      if (!context.mounted) {
        return false;
      }
      final url = appUpdateLinkOf(
        status: serverInfoState.versionStatus,
        platform: defaultTargetPlatform,
        flavor: appFlavor,
        signature: signature,
      );
      _log.info('The update notice opens $url');
      return openUrl(context, Uri.parse(url), mode: LaunchMode.externalApplication);
    }

    return SizedBox(
      width: double.infinity,
      child: Container(
        decoration: BoxDecoration(
          color: serverInfoState.versionStatus == VersionStatus.error ? errorColor : infoColor,
          borderRadius: const BorderRadius.all(Radius.circular(8)),
          border: Border.all(
            color: serverInfoState.versionStatus == VersionStatus.error
                ? errorColor
                : context.primaryColor.withAlpha(50),
            width: 0.75,
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                serverInfoState.versionStatus.message,
                textAlign: TextAlign.start,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: context.textTheme.labelLarge,
              ),
            ),
            if (serverInfoState.versionStatus == VersionStatus.serverOutOfDate ||
                serverInfoState.versionStatus == VersionStatus.clientOutOfDate) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => unawaited(openUpdateLink()),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.all(4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: serverInfoState.versionStatus == VersionStatus.clientOutOfDate
                    ? Text(context.t.action_common_update)
                    : Text(context.t.view),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
