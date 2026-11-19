// What a failure of a Jellyfin or Emby server says to the user, and the diagnostics line under it: the product and
// version, the step, the status, the route table, ranges and TLS, selectable for a report. No address, user, token
// or title is ever in it (as the line of the cameras, camera_live_diagnostics.dart).

import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_api.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_client.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_file_system.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_routes.dart';

/// The words of [failure] for the user
String jellyfinFailureMessage(BuildContext context, JellyfinFailure failure) => switch (failure) {
  JellyfinFailure.unreachable => context.t.jellyfin_error_unreachable,
  JellyfinFailure.notJellyfin => context.t.jellyfin_error_not_server,
  JellyfinFailure.otherServer => context.t.jellyfin_error_other_server,
  JellyfinFailure.setupNotDone => context.t.jellyfin_error_setup,
  JellyfinFailure.passwordRefused => context.t.jellyfin_error_password,
  JellyfinFailure.tokenRefused => context.t.jellyfin_error_session,
  JellyfinFailure.quickConnectOff => context.t.jellyfin_quick_connect_off,
  JellyfinFailure.quickConnectExpired => context.t.jellyfin_quick_connect_expired,
  JellyfinFailure.downloadForbidden => context.t.jellyfin_error_forbidden,
  JellyfinFailure.serverError => context.t.jellyfin_error_failed,
  JellyfinFailure.tlsRefused => context.t.jellyfin_error_tls,
};

/// The words of [error] when it is a failure of a Jellyfin or Emby server, null otherwise
String? jellyfinFailureText(BuildContext context, Object? error) =>
    error is JellyfinException ? jellyfinFailureMessage(context, error.failure) : null;

/// "jellyfin 12.4.0, step open, status 401, route items-v2, ranges yes, tls no": what a report needs, nothing of the
/// user's
String jellyfinDiagnosticsLine({
  required JellyfinProduct product,
  String? version,
  required String step,
  int? status,
  bool? ranges,
  required bool tls,
}) {
  final routes = JellyfinRoutes(Uri.parse('http://x'), product, version).tableName;
  return [
    '${product.name} ${version ?? '?'}',
    'step $step',
    'status ${status ?? '-'}',
    'route $routes',
    'ranges ${ranges == null ? '?' : (ranges ? 'yes' : 'no')}',
    'tls ${tls ? 'yes' : 'no'}',
  ].join(', ');
}

/// The diagnostics line of a failure of the source [source], from what its last open or listing told
String jellyfinDiagnosticsOf(NetworkSource source, Object? error, {JellyfinFileSystem? fileSystem}) {
  final info = source.jellyfin;
  final opened = fileSystem?.lastFailure;
  final open = JellyfinFileSystem.lastOpenFailure;
  return jellyfinDiagnosticsLine(
    product: (info?.isEmby ?? false) ? JellyfinProduct.emby : JellyfinProduct.jellyfin,
    version: fileSystem?.info.version ?? info?.version,
    step: opened?.step ?? (fileSystem == null ? 'open ${open?.step ?? '?'}' : '?'),
    status: opened?.status ?? (error is JellyfinException ? error.status : open?.status),
    ranges: fileSystem?.supportsRanges,
    tls: source.useTls,
  );
}

/// The diagnostics line, small and selectable
class JellyfinDiagnostics extends StatelessWidget {
  const JellyfinDiagnostics({super.key, required this.line, this.color});

  final String line;
  final Color? color;

  @override
  Widget build(BuildContext context) => SelectableText(
    context.t.jellyfin_diagnostics(line: line),
    key: const Key('jellyfin_diagnostics'),
    textAlign: TextAlign.center,
    style: context.textTheme.bodySmall?.copyWith(color: color ?? context.colorScheme.onSurfaceVariant),
  );
}
