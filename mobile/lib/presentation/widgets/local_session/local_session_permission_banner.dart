import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/desktop/library/folders.page.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/gallery_permission.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/repositories/permission.repository.dart';

/// Shown at the top of the Photos tab of a session without a server while the app may not read the photos of the
/// device: without it, a refused permission left an empty gallery with no way back. "Allow access" asks again, or
/// opens the system settings when the system no longer asks; once granted, the device is indexed again.
class LocalSessionPermissionBanner extends ConsumerWidget {
  const LocalSessionPermissionBanner({super.key});

  Future<void> _allow(WidgetRef ref) async {
    final notifier = ref.read(galleryPermissionNotifier.notifier);
    var status = await notifier.requestGalleryPermission();
    if (status == DevicePermissionStatus.permanentlyDenied) {
      await ref.read(permissionRepositoryProvider).openSettings();
      status = await notifier.getGalleryPermissionStatus();
    }
    if (status.hasAccess) {
      unawaited(ref.read(localSessionRefreshProvider)(full: true));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A computer has no gallery permission: the folders the user chooses are the consent
    if (CurrentPlatform.isDesktop) {
      return const FoldersBanner();
    }
    final status = ref.watch(galleryPermissionNotifier);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Card(
        color: context.colorScheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.photo_library_outlined, color: context.colorScheme.onSecondaryContainer),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      context.t.local_session_permission_title,
                      style: context.textTheme.titleSmall?.copyWith(color: context.colorScheme.onSecondaryContainer),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                context.t.local_session_permission_body,
                style: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSecondaryContainer),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton.icon(
                    key: const Key('local_session_permission_allow'),
                    onPressed: () => unawaited(_allow(ref)),
                    icon: const Icon(Icons.check),
                    label: Text(
                      status == DevicePermissionStatus.permanentlyDenied
                          ? context.t.local_session_permission_settings
                          : context.t.local_session_permission_allow,
                    ),
                  ),
                  TextButton(
                    key: const Key('local_session_permission_settings'),
                    onPressed: () => unawaited(ref.read(permissionRepositoryProvider).openSettings()),
                    child: Text(context.t.local_session_permission_settings),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
