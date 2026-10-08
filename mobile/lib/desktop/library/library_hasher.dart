// Hashing of the files of the folder library for the backup, in a few isolates beside the one that asked. The digest
// itself runs at native speed (native_sha1.dart), so the disk sets the pace: a handful of readers saturate an SSD,
// and more would only make a spinning or network drive seek between files. The pool is the number of processors
// less two, at most four, and two for a network folder.

import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:immich_mobile/desktop/library/isolate_cancel.dart';
import 'package:immich_mobile/desktop/library/native_sha1.dart';
import 'package:immich_mobile/desktop/library/placeholder_check.dart';

/// A file to hash
typedef HashJob = ({String id, String path, int size});

/// The base64 SHA-1 of a file, or why there is none
typedef HashOutcome = ({String id, String? hash, String? error});

/// Thrown when the run was asked to stop
class HashRunCancelled implements Exception {
  const HashRunCancelled();
}

/// How many isolates hash [jobs] at once
int hashWorkerCount(int jobs, {bool network = false}) {
  final byProcessors = math.max(1, Platform.numberOfProcessors - 2);
  return math.max(1, math.min(jobs, math.min(byProcessors, network ? 2 : 4)));
}

/// Hashes [jobs] in [workers] isolates (see [hashWorkerCount]) and gives one outcome per job, in their order. A file
/// kept online only is refused, not read. [cancel] stops the run between chunks: it then throws [HashRunCancelled].
Future<List<HashOutcome>> hashFiles(List<HashJob> jobs, {int? workers, NativeCancelFlag? cancel}) async {
  if (jobs.isEmpty) {
    return const [];
  }
  final count = workers ?? hashWorkerCount(jobs.length);
  // The largest files first, each to the least loaded worker, so the workers end together
  final bins = List.generate(count, (_) => <HashJob>[]);
  final loads = List.filled(count, 0);
  for (final job in [...jobs]..sort((a, b) => b.size.compareTo(a.size))) {
    var lightest = 0;
    for (var i = 1; i < count; i++) {
      if (loads[i] < loads[lightest]) {
        lightest = i;
      }
    }
    bins[lightest].add(job);
    loads[lightest] += job.size + 1;
  }

  final ownFlag = cancel == null ? NativeCancelFlag() : null;
  final flag = cancel ?? ownFlag!;
  final address = flag.address;
  try {
    final results = await Future.wait([
      for (final bin in bins)
        if (bin.isNotEmpty) Isolate.run(() => _hashBin(bin, address), debugName: 'folder-library-hash'),
    ]);
    if (flag.isCancelled) {
      throw const HashRunCancelled();
    }
    final byId = {
      for (final list in results)
        for (final outcome in list) outcome.id: outcome,
    };
    return [for (final job in jobs) byId[job.id] ?? (id: job.id, hash: null, error: 'Not hashed')];
  } finally {
    ownFlag?.free();
  }
}

List<HashOutcome> _hashBin(List<HashJob> jobs, int cancelAddress) {
  final isCancelled = NativeCancelFlag.readerOf(cancelAddress);
  // Opened and closed here: the isolate ends with the bin, and a CNG provider left open would stay until the app quits
  final engine = Sha1Engine.open();
  final attributes = systemFileAttributesReader();
  final outcomes = <HashOutcome>[];
  try {
    for (final job in jobs) {
      if (isCancelled()) {
        break;
      }
      outcomes.add(hashOneFile(job, engine: engine, attributes: attributes, isCancelled: isCancelled));
    }
  } finally {
    engine.close();
  }
  return outcomes;
}

/// The outcome for one file, checked again for a cloud placeholder right before it is read
HashOutcome hashOneFile(
  HashJob job, {
  required Sha1Engine engine,
  FileAttributesReader? attributes,
  bool Function()? isCancelled,
}) {
  if (isCloudPlaceholderFile(job.path, reader: attributes ?? (_) => null)) {
    return (id: job.id, hash: null, error: 'The file is kept online only: not read');
  }
  try {
    return (id: job.id, hash: sha1OfFile(job.path, engine: engine, isCancelled: isCancelled), error: null);
  } on Sha1Cancelled {
    return (id: job.id, hash: null, error: 'Cancelled');
  } on FileSystemException catch (error) {
    return (id: job.id, hash: null, error: 'Failed to hash asset: ${error.message} ${error.osError?.message ?? ''}');
  } catch (error) {
    // A failure of the system library for one file must not lose the outcomes of the others
    return (id: job.id, hash: null, error: 'Failed to hash asset: $error');
  }
}
