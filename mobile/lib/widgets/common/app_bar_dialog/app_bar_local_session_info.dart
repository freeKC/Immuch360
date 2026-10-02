import 'package:flutter/material.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/theme_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';

/// Takes the place of the account, storage and server boxes of the profile dialog in a session without a server
class AppBarLocalSessionInfo extends StatelessWidget {
  const AppBarLocalSessionInfo({super.key});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      minLeadingWidth: 50,
      leading: CircleAvatar(
        radius: 20,
        backgroundColor: context.colorScheme.surfaceContainerHighest,
        child: Icon(Icons.smartphone_rounded, color: context.primaryColor),
      ),
      title: Text(
        context.t.local_session_title,
        style: context.textTheme.titleMedium?.copyWith(color: context.primaryColor, fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        context.t.local_session_description,
        style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceSecondary),
      ),
    );
  }
}
