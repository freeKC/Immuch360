// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Package-internal accessors that surface pool internals to the
/// concurrency regression suite. Deliberately NOT re-exported by
/// `lib/dart_smb2.dart` — consumers of the package never see this file.
///
/// Each entry here is annotated `@internal` so the analyzer warns if it
/// ever escapes the package boundary.
library;

import 'package:meta/meta.dart';

import 'pool.dart';
import 'worker.dart';

/// Internal accessor that exposes the [Worker] instances backing [pool].
/// Used by the concurrency tests to drive fault injection and
/// [Worker.killForTest] without making `_workers` public on [Smb2Pool].
@internal
List<Worker> poolWorkers(Smb2Pool pool) => pool.workersForTest;
