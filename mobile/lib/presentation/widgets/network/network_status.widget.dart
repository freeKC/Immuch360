import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';

/// What to tell the user of a failure to reach or read a share: the message of the file system when it gave one, the
/// status of the media bridge for an image it could not serve (rather than its URL)
String networkErrorMessage(Object error) => switch (error) {
  NetworkFileSystemException(:final message) => message,
  NetworkImageLoadException(:final statusCode) => 'HTTP $statusCode',
  _ => '$error',
};

/// A share being read: a spinner and [message]
class NetworkLoadingView extends StatelessWidget {
  const NetworkLoadingView({super.key, this.message, this.color});

  final String? message;

  /// For the text and the spinner, the theme's otherwise (white over the black of the viewers, for example)
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final message = this.message;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: color),
            if (message != null) ...[
              const SizedBox(height: 16),
              Text(
                message,
                textAlign: TextAlign.center,
                style: context.textTheme.bodyMedium?.copyWith(color: color),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A file or folder of a share that could not be opened, with [error] told, and a button to try again when [onRetry]
/// is given
class NetworkErrorView extends StatelessWidget {
  const NetworkErrorView({super.key, required this.error, this.onRetry, this.color});

  final Object error;
  final VoidCallback? onRetry;

  /// For the text and the icon, the theme's otherwise (white over the black of the viewers, for example)
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final onRetry = this.onRetry;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline_rounded, size: 48, color: color ?? context.colorScheme.error),
            const SizedBox(height: 16),
            Text(
              context.t.network_share_open_error(error: networkErrorMessage(error)),
              textAlign: TextAlign.center,
              style: context.textTheme.bodyMedium?.copyWith(color: color),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(context.t.retry),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A folder of a share with no folder, photo or video in it
class NetworkEmptyFolderView extends StatelessWidget {
  const NetworkEmptyFolderView({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open_outlined, size: 64, color: context.colorScheme.onSurface.withAlpha(128)),
            const SizedBox(height: 16),
            Text(
              context.t.network_share_empty_folder,
              textAlign: TextAlign.center,
              style: context.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
