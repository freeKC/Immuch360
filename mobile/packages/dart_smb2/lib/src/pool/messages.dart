// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Internal message types exchanged between [Smb2Pool] (main isolate) and
/// each worker isolate. None of these are part of the public API — they
/// live under `lib/src/pool/` and are package-private by convention.
library;

import 'dart:isolate';

import '../smb2_types.dart';

/// Connection parameters captured at [Smb2Pool.connect] time and reused
/// every time a worker has to be respawned after a connection failure.
///
/// Lives in the main isolate; copied across the isolate boundary when the
/// worker is spawned (wrapped in an [InitMsg]).
///
/// [testLibOverride] propagates the [debugLibSmb2PathOverride] value across
/// the isolate boundary. Static fields don't survive `Isolate.spawn`, so
/// the worker would otherwise see `null` and fall back to the platform
/// loader name — which fails in unit/integration tests that target a
/// specific `.dylib` / `.so` checkout. Production callers leave it at
/// `null` and the field is dead weight.
class ConnectParams {
  /// Target server host or IP.
  final String host;

  /// Share name to connect to.
  final String share;

  /// Optional username (empty/null = guest).
  final String? user;

  /// Optional password.
  final String? password;

  /// Optional NT domain / workgroup.
  final String? domain;

  /// Connection timeout in seconds.
  final int timeoutSeconds;

  /// Whether to require SMB3 encryption (seal).
  final bool seal;

  /// Whether to require SMB signing.
  final bool signing;

  /// SMB dialect to negotiate.
  final Smb2Version version;

  /// Test-only libsmb2 path override propagated across the isolate boundary.
  final String? testLibOverride;

  /// Build the connection parameters reused for every (re)spawn.
  const ConnectParams({
    required this.host,
    required this.share,
    this.user,
    this.password,
    this.domain,
    this.timeoutSeconds = 30,
    this.seal = false,
    this.signing = false,
    this.version = Smb2Version.any,
    this.testLibOverride,
  });
}

/// Bootstrap message sent to a freshly-spawned worker isolate. Carries
/// the [sendPort] the worker should reply to with its own command port,
/// plus all the connection parameters.
class InitMsg {
  /// Port the worker replies to with its command [SendPort] (or an error).
  final SendPort sendPort;

  /// Target server host or IP.
  final String host;

  /// Share name to connect to.
  final String share;

  /// Optional username (empty/null = guest).
  final String? user;

  /// Optional password.
  final String? password;

  /// Optional NT domain / workgroup.
  final String? domain;

  /// Connection timeout in seconds.
  final int timeoutSeconds;

  /// Whether to require SMB3 encryption (seal).
  final bool seal;

  /// Whether to require SMB signing.
  final bool signing;

  /// SMB dialect to negotiate.
  final Smb2Version version;

  /// Test-only libsmb2 path override propagated across the isolate boundary.
  final String? testLibOverride;

  /// Build the bootstrap message handed to a freshly-spawned worker.
  InitMsg({
    required this.sendPort,
    required this.host,
    required this.share,
    this.user,
    this.password,
    this.domain,
    this.timeoutSeconds = 30,
    this.seal = false,
    this.signing = false,
    this.version = Smb2Version.any,
    this.testLibOverride,
  });
}

/// Wire format for errors crossing the isolate boundary.
///
/// `Smb2Exception` itself contains an `Smb2ErrorType` enum that doesn't
/// survive a `SendPort.send` cleanly on every Dart runtime, so the worker
/// serialises it as the enum's index and the main isolate reconstructs
/// the typed exception on receipt.
class ErrorMsg {
  /// Human-readable error description.
  final String message;

  /// Optional native errno code.
  final int? errorCode;

  /// [Smb2ErrorType] index, reconstructed into the enum on receipt.
  final int? errorTypeIndex;

  /// Build a wire-format error from a message, optional errno, and type index.
  ErrorMsg(this.message, [this.errorCode, this.errorTypeIndex]);
}
