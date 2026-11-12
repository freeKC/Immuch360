import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/tiff_photos.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_client.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_server_breaker.dart';
import 'package:immich_mobile/presentation/pages/network/network_shares.page.dart';

/// What to tell the user of a failure to reach or read a share: the message of the file system when it gave one, the
/// status of the media bridge for an image it could not serve (rather than its URL)
String networkErrorMessage(Object error) => switch (error) {
  NetworkFileSystemException(:final message) => message,
  NetworkImageLoadException(:final statusCode) => 'HTTP $statusCode',
  _ => '$error',
};

/// What to tell of a failure of a Plex server that has words of its own in the app's languages, null for any other:
/// a server that stopped answering, a film whose file the server cannot read now
String? plexFailureText(BuildContext context, Object error) => switch (error) {
  PlexFileSystemException(failure: PlexFailure.stoppedAnswering) => context.t.plex_server_stopped_answering,
  PlexFileSystemException(failure: PlexFailure.fileUnreadable) => context.t.plex_film_file_unreadable,
  _ => null,
};

/// Lets every Plex server that stopped answering try one request at once: the user pressed Retry
void retryPlexServersNow() => PlexServerBreakers.probeAllNow();

/// A share being read: a spinner and [message], with [detail] below it and a Cancel button when [onCancel] is given
/// (a Plex server slow to send the start of a film)
class NetworkLoadingView extends StatelessWidget {
  const NetworkLoadingView({super.key, this.message, this.color, this.detail, this.onCancel});

  final String? message;

  /// A smaller line under [message]
  final String? detail;

  /// Stops what the spinner waits for; no button when null
  final VoidCallback? onCancel;

  /// For the text and the spinner, the theme's otherwise (white over the black of the viewers, for example)
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final message = this.message;
    final detail = this.detail;
    final onCancel = this.onCancel;
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
            if (detail != null) ...[
              const SizedBox(height: 8),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: context.textTheme.bodySmall?.copyWith(color: color),
              ),
            ],
            if (onCancel != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(
                key: const Key('network_loading_cancel'),
                onPressed: onCancel,
                child: Text(context.t.cancel),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Calls [onBack] once the Plex server that [error] says stopped answering answers again (its breaker closes, see
/// plex_server_breaker.dart); for any other error, or without [onBack], only shows [child]
class PlexServerBackListener extends StatefulWidget {
  const PlexServerBackListener({super.key, required this.error, required this.onBack, required this.child});

  final Object? error;
  final VoidCallback? onBack;
  final Widget child;

  @override
  State<PlexServerBackListener> createState() => _PlexServerBackListenerState();
}

class _PlexServerBackListenerState extends State<PlexServerBackListener> {
  PlexServerBreaker? _breaker;

  @override
  void initState() {
    super.initState();
    _watch();
  }

  @override
  void didUpdateWidget(PlexServerBackListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.error, widget.error) || (oldWidget.onBack == null) != (widget.onBack == null)) {
      _watch();
    }
  }

  @override
  void dispose() {
    _breaker?.removeListener(_onBreaker);
    super.dispose();
  }

  void _watch() {
    _breaker?.removeListener(_onBreaker);
    _breaker = null;
    final error = widget.error;
    final sourceId = error is PlexFileSystemException && error.isStoppedAnswering ? error.sourceId : null;
    if (sourceId == null || widget.onBack == null) {
      return;
    }
    final breaker = PlexServerBreakers.existing(sourceId);
    breaker?.addListener(_onBreaker);
    _breaker = breaker;
  }

  void _onBreaker() {
    final breaker = _breaker;
    if (breaker != null && !breaker.isOpen && mounted) {
      // The server answers again: the page reads what it showed the error for
      breaker.removeListener(_onBreaker);
      _breaker = null;
      scheduleMicrotask(() {
        if (mounted) {
          widget.onBack?.call();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// A file or folder of a share that could not be opened, with [error] told, and a button to try again when [onRetry]
/// is given. When the server refused the credentials of [source], a button opens its page on them. A Plex server that
/// stopped answering is tried again by itself once it answers (see [PlexServerBackListener]), and Retry lets one
/// request go to it at once.
class NetworkErrorView extends StatelessWidget {
  const NetworkErrorView({super.key, required this.error, this.onRetry, this.color, this.source});

  final Object error;
  final VoidCallback? onRetry;

  /// The share the error comes from, null when unknown
  final NetworkSource? source;

  /// For the text and the icon, the theme's otherwise (white over the black of the viewers, for example)
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final onRetry = this.onRetry;
    final source = this.source;
    final error = this.error;
    return PlexServerBackListener(
      error: error,
      onBack: onRetry,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 48, color: color ?? context.colorScheme.error),
              const SizedBox(height: 16),
              Text(
                // A TIFF this device could not decode says so, rather than the words of the decoder
                error is TiffDecodeException
                    ? context.t.tiff_cannot_decode
                    : plexFailureText(context, error) ??
                          context.t.network_share_open_error(error: networkErrorMessage(error)),
                key: const Key('network_error_text'),
                textAlign: TextAlign.center,
                style: context.textTheme.bodyMedium?.copyWith(color: color),
              ),
              if (onRetry != null) ...[
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  key: const Key('network_error_retry'),
                  onPressed: () {
                    if (error is PlexFileSystemException) {
                      retryPlexServersNow();
                    }
                    onRetry();
                  },
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(context.t.retry),
                ),
              ],
              if (source != null && error is NetworkFileSystemException && error.isAuthentication) ...[
                const SizedBox(height: 8),
                TextButton.icon(
                  key: const Key('network_error_edit_source'),
                  onPressed: () => context.pushRoute(networkSourceEditRoute(source, focusCredentials: true)),
                  icon: const Icon(Icons.edit_outlined),
                  label: Text(
                    source.type == NetworkSourceType.plex
                        ? context.t.plex_token_paste_new
                        : context.t.network_share_edit,
                  ),
                ),
              ],
            ],
          ),
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
