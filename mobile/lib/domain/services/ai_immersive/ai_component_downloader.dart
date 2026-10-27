// The download of one AI component (design-final 2026-10-26, section 2.2), shared by the computers and the Quest.
//
// The client is a bare dart:io HttpClient, made outside the HttpOverrides of the app (as _bareClient of
// pairing_client.dart): never the custom headers, the cookies or the certificates the user gave for an Immich server,
// and never the native client of the Quest, which adds those headers to every host. HTTPS only, the mirror included;
// a redirect is followed by hand so that an https address never leads to an http one. The bytes go to a .part file in
// the tmp folder of the components, resumed by Range after a cut or a cancel. The SHA-256 and the size of the
// installed file are counted while the bytes arrive (a gzip library is unpacked on the way), then the file is renamed
// to its final name. A wrong sum deletes what was received. The sums of the catalogue are required whatever the
// source, so the mirror of the tests (IMMUCH360_AI_COMPONENTS_MIRROR, an https URL or a local folder) can serve
// nothing else.
//
// Phases 2 and 3 (design-final 2026-10-27, section 7.1): each component comes from the release of its family. A file
// of 2 GiB or more comes in parts, assets of the release (or files of the mirror) put end to end in the one .part:
// the parts already there are checked again by their sums, the current one resumes by Range in its own asset, each is
// checked by its sum when it ends and the whole by the sum of the catalogue. A damaged part cuts the .part back to
// where it starts, so that the official source, which serves the whole file, resumes from there.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('AiComponentDownloader');

/// Why a component was not installed
enum AiDownloadFailure {
  /// The catalogue lacks the size or the sum (lot A3b fills those of ONNX Runtime): never downloaded
  incomplete,

  /// An address that is not https (or a local folder given as the mirror), or a redirect to one: refused before
  /// any connection to it
  insecureAddress,

  /// Every address answered that the file is not there
  notFound,

  /// No connection, TLS, a cut that did not resume, a timeout, or an error answered by the server
  network,

  /// The file received is not the one of the catalogue (size or SHA-256): what was received is deleted
  damaged,

  /// No space left on the disk: what was received is deleted to give the space back
  diskFull,

  /// The file could not be written for another reason
  writeFailed,

  /// Asked to stop; the bytes received stay in the .part for the next download
  cancelled,
}

class AiDownloadException implements Exception {
  const AiDownloadException(this.failure, [this.detail]);

  final AiDownloadFailure failure;

  /// What happened, in English, for the log
  final String? detail;

  /// The text shown for this failure (i18n/en.json; aiDownloadFailureText of the install sheet gives the same)
  String get messageKey => switch (failure) {
    AiDownloadFailure.damaged => 'ai_immersive_download_damaged',
    AiDownloadFailure.diskFull => 'ai_immersive_failed_disk_full',
    AiDownloadFailure.cancelled => 'ai_immersive_state_cancelled',
    AiDownloadFailure.notFound => 'ai_immersive_download_not_found',
    AiDownloadFailure.network => 'ai_immersive_download_network',
    AiDownloadFailure.writeFailed => 'ai_immersive_download_write_failed',
    AiDownloadFailure.incomplete => 'ai_immersive_download_incomplete',
    AiDownloadFailure.insecureAddress => 'ai_immersive_download_insecure',
  };

  /// The {reason} of ai_immersive_download_failed, for a screen that names the failure itself
  String get reason => detail ?? failure.name;

  @override
  String toString() => 'AiDownloadException(${failure.name}${detail == null ? '' : ': $detail'})';
}

/// Stops a download from anywhere: between two chunks, and at once by closing its connection
class AiDownloadCancel {
  final _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) {
      _cancelled.complete();
    }
  }
}

/// Where received bytes are written: a file opened for writing at its end. The tests replace it to fill the disk.
abstract class AiFileSink {
  Future<void> add(List<int> bytes);

  /// Flushes to the disk and closes
  Future<void> close();

  /// [file] opened at its end when [append], else emptied
  static Future<AiFileSink> open(File file, {required bool append}) async =>
      _RandomAccessSink(await file.open(mode: append ? FileMode.append : FileMode.write));
}

typedef AiFileSinkOpener = Future<AiFileSink> Function(File file, {required bool append});

class _RandomAccessSink implements AiFileSink {
  _RandomAccessSink(this._file);

  final RandomAccessFile _file;

  @override
  Future<void> add(List<int> bytes) => _file.writeFrom(bytes);

  @override
  Future<void> close() async {
    try {
      await _file.flush();
    } finally {
      await _file.close();
    }
  }
}

/// No space left: ENOSPC (28) on Linux, macOS and Android, ERROR_DISK_FULL (112) and ERROR_HANDLE_DISK_FULL (39) on
/// Windows. [windows] tells how to read the code (28 is "out of paper" on Windows, 39 and 112 other errors elsewhere);
/// this system by default.
bool isDiskFull(FileSystemException error, {bool? windows}) =>
    ((windows ?? Platform.isWindows) ? const {112, 39} : const {28}).contains(error.osError?.errorCode);

/// The bare HTTP client: the default one, outside any HttpOverrides of the app. [context] only in the tests (their
/// own certificate authority).
HttpClient aiBareHttpClient({SecurityContext? context}) =>
    HttpOverrides.runWithHttpOverrides(() => HttpClient(context: context), _NoOverrides());

class _NoOverrides extends HttpOverrides {}

/// The connection ended before the whole file: resumed from where it stopped
class _Cut implements Exception {
  const _Cut(this.detail);

  final String detail;

  @override
  String toString() => detail;
}

/// Downloads the components, one call per component; see the top of this file
class AiComponentDownloader {
  AiComponentDownloader({
    HttpClient Function()? createClient,
    String? Function()? mirror,
    this.release,
    this.resumes = 3,
    this.retryDelay = const Duration(seconds: 2),
    this.connectTimeout = const Duration(seconds: 20),
    this.idleTimeout = const Duration(seconds: 60),
    @visibleForTesting AiFileSinkOpener? openSink,
  }) : _createClient = createClient ?? aiBareHttpClient,
       _mirror = mirror ?? (() => Platform.environment[aiComponentsMirrorVariable]),
       _openSink = openSink ?? AiFileSink.open;

  final HttpClient Function() _createClient;
  final String? Function() _mirror;
  final AiFileSinkOpener _openSink;

  /// The base of the release; null for the release of each component, another one only in the tests
  final String? release;

  /// How many times a cut connection is resumed at the same address before the next one is tried
  final int resumes;
  final Duration retryDelay;
  final Duration connectTimeout;

  /// The longest silence in the middle of a file
  final Duration idleTimeout;

  static const _maxRedirects = 10;

  /// The mirror as a base address: an https URL or a file:// folder as given, a local folder path turned into its
  /// file:// address; anything else is kept as it is and refused when tried. Null when there is none.
  static String? mirrorAddress(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) {
      return null;
    }
    // Two letters at least: a Windows path (C:\...) is not a URL of the scheme "c"
    final hasScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]+:').hasMatch(text);
    if (!hasScheme && p.isAbsolute(text)) {
      return Uri.directory(text).toString();
    }
    return text;
  }

  /// The mirror this downloader uses, null for the release
  String? get mirrorBase => mirrorAddress(_mirror());

  /// The addresses tried for [component], in order; the first part stands for the parts of a file in parts
  List<Uri> addressesOf(AiComponent component) => [for (final source in _sourcesOf(component)) source.addresses.first];

  /// The sources of [component] in order: the whole file at an address, or its parts
  List<_Source> _sourcesOf(AiComponent component) {
    final mirror = mirrorBase;
    if (!component.isInParts) {
      return [
        for (final url in component.urls(mirror: mirror, release: release)) _Source([Uri.parse(url)]),
      ];
    }
    return [
      _Source([for (final url in component.partUrls(mirror: mirror, release: release)) Uri.parse(url)], parts: true),
      // The mirror alone when there is one, as for a file in one piece
      if (mirror == null)
        for (final url in component.officialUrls) _Source([Uri.parse(url)]),
    ];
  }

  /// Downloads [component] to [target] through [part], which keeps the bytes received so far: a download starts
  /// again where an earlier one stopped. Returns the address the file came from. [onProgress] gets the bytes received
  /// out of the bytes to download (null when unknown). Throws an [AiDownloadException].
  Future<Uri> download(
    AiComponent component, {
    required File target,
    required File part,
    AiDownloadCancel? cancel,
    void Function(int received, int? total)? onProgress,
  }) async {
    final size = component.size;
    final sum = component.sha256;
    if (size == null || sum == null) {
      throw AiDownloadException(AiDownloadFailure.incomplete, component.id);
    }
    final job = _Job(
      component: component,
      size: size,
      sha256: sum,
      target: target,
      part: part,
      cancel: cancel ?? AiDownloadCancel(),
      onProgress: onProgress,
    );
    final List<_Source> sources;
    try {
      sources = _sourcesOf(component);
    } on FormatException catch (error) {
      throw AiDownloadException(AiDownloadFailure.insecureAddress, 'not an address: ${error.message}');
    }
    AiDownloadException? failure;
    for (final source in sources) {
      final address = source.addresses.first;
      job.checkCancel();
      try {
        await (source.parts ? _fromParts(job, source.addresses) : _from(job, address));
        return address;
      } on AiDownloadException catch (error) {
        _log.warning('${component.id} from $address: $error');
        switch (error.failure) {
          case AiDownloadFailure.cancelled || AiDownloadFailure.diskFull || AiDownloadFailure.writeFailed:
            rethrow;
          default:
            // A damaged file says more than a later "not found"
            if (failure?.failure != AiDownloadFailure.damaged) {
              failure = error;
            }
        }
      }
    }
    throw failure ?? const AiDownloadException(AiDownloadFailure.notFound);
  }

  /// The file from [address], resumed after a cut
  Future<void> _from(_Job job, Uri address) async {
    final file = address.scheme == 'file';
    if (address.scheme != 'https' && !(file && mirrorBase != null)) {
      throw AiDownloadException(AiDownloadFailure.insecureAddress, address.toString());
    }
    var cuts = 0;
    while (true) {
      job.checkCancel();
      try {
        await (file ? _fromFile(job, address) : _fromServer(job, address));
        return;
      } on _Cut catch (cut) {
        job.checkCancel();
        if (cuts++ >= resumes) {
          throw AiDownloadException(AiDownloadFailure.network, cut.detail);
        }
        _log.info('${job.component.id}: $cut, resuming');
        await Future.any([Future<void>.delayed(retryDelay), job.cancel.whenCancelled]);
      }
    }
  }

  /// From the mirror's folder: the same resume from the .part
  Future<void> _fromFile(_Job job, Uri address) async {
    final source = File.fromUri(address);
    if (!source.existsSync()) {
      throw AiDownloadException(AiDownloadFailure.notFound, address.toString());
    }
    final receiver = await job.open(this, total: source.lengthSync());
    try {
      await receiver.receive(source.openRead(receiver.received));
    } on FileSystemException catch (error) {
      // The file of the mirror could not be read (the writes fail as AiDownloadException)
      throw AiDownloadException(AiDownloadFailure.network, '$error');
    } finally {
      await receiver.dispose();
    }
  }

  /// The answer of [client] to a GET of [address] from the byte [have] (from the start when 0): redirects followed by
  /// hand to https only, 404 and 410 as not found, another error status as a network failure. A 416 is given back to
  /// the caller, whose bytes do not begin this file. [range] is the byte the answer starts at, [total] the size of the
  /// file when the server says it.
  Future<({HttpClientResponse response, int from, int? total, Uri url})> _get(
    HttpClient client,
    Uri address,
    int have,
  ) async {
    var url = address;
    var redirects = 0;
    late HttpClientResponse response;
    while (true) {
      if (url.scheme != 'https') {
        throw AiDownloadException(AiDownloadFailure.insecureAddress, url.toString());
      }
      final request = await client.getUrl(url);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (have > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
      }
      // A server that takes the request and never answers counts as a silence too
      response = await request.close().timeout(idleTimeout);
      if (!response.isRedirect) {
        break;
      }
      final location = response.headers.value(HttpHeaders.locationHeader);
      await response.drain<void>().catchError((_) {});
      if (location == null || ++redirects > _maxRedirects) {
        throw AiDownloadException(AiDownloadFailure.network, 'redirect without end from $address');
      }
      url = url.resolve(location);
    }
    final status = response.statusCode;
    if (status == HttpStatus.notFound || status == HttpStatus.gone) {
      await response.drain<void>().catchError((_) {});
      throw AiDownloadException(AiDownloadFailure.notFound, '$status $url');
    }
    if (status == HttpStatus.requestedRangeNotSatisfiable && have > 0) {
      return (response: response, from: -1, total: null, url: url);
    }
    if (status != HttpStatus.ok && status != HttpStatus.partialContent) {
      await response.drain<void>().catchError((_) {});
      throw AiDownloadException(AiDownloadFailure.network, '$status $url');
    }
    final encoding = response.headers.value(HttpHeaders.contentEncodingHeader);
    if (encoding != null && encoding.toLowerCase() != 'identity') {
      throw AiDownloadException(AiDownloadFailure.network, 'unexpected Content-Encoding $encoding from $url');
    }
    if (status == HttpStatus.partialContent) {
      final range = RegExp(
        r'^bytes (\d+)-(\d+)/(\d+|\*)$',
      ).firstMatch(response.headers.value(HttpHeaders.contentRangeHeader) ?? '');
      return (
        response: response,
        from: int.tryParse(range?.group(1) ?? '') ?? -1,
        total: int.tryParse(range?.group(3) ?? ''),
        url: url,
      );
    }
    return (response: response, from: 0, total: response.contentLength >= 0 ? response.contentLength : null, url: url);
  }

  /// A client of this downloader, which a cancel closes at once, whatever is awaited
  ({HttpClient client, Future<void> closing}) _clientFor(_Job job) {
    final client = _createClient()
      ..connectionTimeout = connectTimeout
      ..autoUncompress = false;
    return (client: client, closing: job.cancel.whenCancelled.then((_) => client.close(force: true)));
  }

  Future<void> _fromServer(_Job job, Uri address) async {
    final (:client, :closing) = _clientFor(job);
    _Receiver? receiver;
    try {
      final have = job.resumableBytes();
      final (:response, :from, :total, url: _) = await _get(client, address, have);
      if (from < 0 && response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
        // The .part is not a beginning of this file: start again from nothing
        await response.drain<void>().catchError((_) {});
        await job.discardPart();
        throw const _Cut('the server refused the range of the .part');
      }
      if (response.statusCode == HttpStatus.partialContent && from != have) {
        await response.drain<void>().catchError((_) {});
        await job.discardPart();
        throw _Cut('the server answered another range than bytes=$have-');
      }
      receiver = await job.open(this, total: total, restart: from == 0);
      await receiver.receive(response.timeout(idleTimeout));
    } on AiDownloadException {
      rethrow;
    } on _Cut {
      rethrow;
    } on Object catch (error) {
      if (job.cancel.isCancelled) {
        throw const AiDownloadException(AiDownloadFailure.cancelled);
      }
      // The connection failed (the writes fail as AiDownloadException): the bytes received so far stay, and the next
      // try resumes them
      if (receiver != null && receiver.receivedHere > 0) {
        throw _Cut('$error');
      }
      throw AiDownloadException(AiDownloadFailure.network, '$error');
    } finally {
      await receiver?.dispose();
      client.close(force: true);
      unawaited(closing);
    }
  }

  /// The parts at [addresses] (of the release, or files of the mirror), put end to end in the .part; see the top of
  /// this file
  Future<void> _fromParts(_Job job, List<Uri> addresses) async {
    final parts = job.component.parts;
    if (addresses.length != parts.length || parts.fold<int>(0, (sum, part) => sum + part.size) != job.size) {
      throw AiDownloadException(AiDownloadFailure.damaged, 'the parts of ${job.component.id} do not make its file');
    }
    for (final address in addresses) {
      if (address.scheme != 'https' && !(address.scheme == 'file' && mirrorBase != null)) {
        throw AiDownloadException(AiDownloadFailure.insecureAddress, address.toString());
      }
    }
    final run = await _PartsRun.start(job, _openSink);
    try {
      while (run.index < parts.length) {
        final address = addresses[run.index];
        var cuts = 0;
        while (true) {
          job.checkCancel();
          try {
            await (address.scheme == 'file' ? _partFromFile(run, address) : _partFromServer(run, address));
            break;
          } on _Cut catch (cut) {
            job.checkCancel();
            if (cuts++ >= resumes) {
              throw AiDownloadException(AiDownloadFailure.network, cut.detail);
            }
            _log.info('${job.component.id}: $cut, resuming');
            await Future.any([Future<void>.delayed(retryDelay), job.cancel.whenCancelled]);
          }
        }
        await run.endPart();
      }
      await run.finish();
    } finally {
      await run.dispose();
    }
  }

  /// The rest of the current part from the mirror's folder
  Future<void> _partFromFile(_PartsRun run, Uri address) async {
    final source = File.fromUri(address);
    if (!source.existsSync()) {
      throw AiDownloadException(AiDownloadFailure.notFound, address.toString());
    }
    if (source.lengthSync() != run.part.size) {
      throw await run.damaged('${address.pathSegments.last} has ${source.lengthSync()} bytes, not ${run.part.size}');
    }
    try {
      await run.receive(source.openRead(run.inPart));
    } on FileSystemException catch (error) {
      throw AiDownloadException(AiDownloadFailure.network, '$error');
    }
  }

  /// The rest of the current part from its asset, by Range
  Future<void> _partFromServer(_PartsRun run, Uri address) async {
    final job = run.job;
    final (:client, :closing) = _clientFor(job);
    final before = run.received;
    try {
      final have = run.inPart;
      final (:response, :from, :total, :url) = await _get(client, address, have);
      if (from != have) {
        // A 416, or another range: this part starts again
        await response.drain<void>().catchError((_) {});
        await run.restartPart();
        throw _Cut('$url answered from byte $from, not $have');
      }
      if (total != null && total != run.part.size) {
        await response.drain<void>().catchError((_) {});
        throw await run.damaged('$url has $total bytes, not ${run.part.size}');
      }
      await run.receive(response.timeout(idleTimeout));
    } on AiDownloadException {
      rethrow;
    } on _Cut {
      rethrow;
    } on Object catch (error) {
      if (job.cancel.isCancelled) {
        throw const AiDownloadException(AiDownloadFailure.cancelled);
      }
      if (run.received > before) {
        throw _Cut('$error');
      }
      throw AiDownloadException(AiDownloadFailure.network, '$error');
    } finally {
      client.close(force: true);
      unawaited(closing);
    }
  }
}

/// A whole file at one address, or the parts of a file at theirs
class _Source {
  const _Source(this.addresses, {this.parts = false});

  final List<Uri> addresses;
  final bool parts;
}

/// One download of the parts of a file into its .part: where it stands (the part, the bytes of it received), the sum
/// of the part and of the whole so far
class _PartsRun {
  _PartsRun._(this.job, this._openSink);

  final _Job job;
  final AiFileSinkOpener _openSink;
  AiFileSink? _sink;
  late _Digest _whole;
  late _Digest _current;

  /// The part being received, and the bytes of it already in the .part
  int index = 0;
  int inPart = 0;

  /// The bytes of the .part
  int received = 0;

  AiComponentPart get part => job.component.parts[index];

  int get _partStart => job.component.parts.take(index).fold<int>(0, (sum, part) => sum + part.size);

  /// Ready to receive: the .part read again, its complete parts checked by their sums (a damaged one is cut off with
  /// what follows it, and the reading starts over), the bytes of the current part counted
  static Future<_PartsRun> start(_Job job, AiFileSinkOpener openSink) async {
    final run = _PartsRun._(job, openSink);
    await job.part.parent.create(recursive: true);
    while (!await run._readPart()) {}
    try {
      run._sink = await openSink(job.part, append: true);
    } on FileSystemException catch (error) {
      throw await job.writeFailed(error);
    }
    run._report();
    return run;
  }

  /// Reads the .part from its start; false when a damaged part was cut off, to read it again
  Future<bool> _readPart() async {
    _whole = _Digest();
    _current = _Digest();
    index = 0;
    inPart = 0;
    received = 0;
    final file = job.part;
    if (!file.existsSync()) {
      return true;
    }
    if (file.lengthSync() > job.size) {
      await job.discardPart();
      return true;
    }
    final parts = job.component.parts;
    await for (final chunk in file.openRead()) {
      var at = 0;
      while (at < chunk.length) {
        final take = min(chunk.length - at, part.size - inPart);
        final piece = chunk.sublist(at, at + take);
        _whole.add(piece);
        _current.add(piece);
        inPart += take;
        received += take;
        at += take;
        if (inPart == part.size) {
          if (_current.close() != part.sha256) {
            _log.warning('${job.component.id}: part ${index + 1} on the disk is damaged, received again');
            await _truncate(_partStart);
            return false;
          }
          index++;
          inPart = 0;
          _current = _Digest();
          if (index == parts.length) {
            // Every part is there: nothing more to receive
            return true;
          }
        }
      }
    }
    return true;
  }

  /// Cuts the .part to [length] bytes
  Future<void> _truncate(int length) async {
    await _closeSink();
    final file = await job.part.open(mode: FileMode.append);
    try {
      await file.truncate(length);
    } finally {
      await file.close();
    }
  }

  void _report() => job.onProgress?.call(received, job.size);

  /// Appends [bytes] to the .part, counted into the sums, until their end or the end of the part
  Future<void> receive(Stream<List<int>> bytes) async {
    _report();
    await for (final chunk in bytes) {
      job.checkCancel();
      if (inPart + chunk.length > part.size) {
        throw await damaged('more than the ${part.size} bytes of part ${index + 1}');
      }
      try {
        await _sink!.add(chunk);
      } on FileSystemException catch (error) {
        await _closeSink();
        throw await job.writeFailed(error);
      }
      _whole.add(chunk);
      _current.add(chunk);
      inPart += chunk.length;
      received += chunk.length;
      _report();
    }
    job.checkCancel();
    if (inPart < part.size) {
      throw _Cut('part ${index + 1} ended after $inPart of ${part.size} bytes');
    }
  }

  /// The current part is complete: its sum checked, the next one ready
  Future<void> endPart() async {
    if (_current.close() != part.sha256) {
      throw await damaged('part ${index + 1} is not the one of the catalogue');
    }
    index++;
    inPart = 0;
    _current = _Digest();
  }

  /// The current part starts again from its first byte
  Future<void> restartPart() async {
    await _truncate(_partStart);
    received -= inPart;
    inPart = 0;
    // The sum of the whole holds the bytes of this part: read the .part again
    while (!await _readPart()) {}
    _sink = await _openSink(job.part, append: true);
  }

  /// The current part is damaged: the .part is cut back to where it starts, for the next source
  Future<AiDownloadException> damaged(String detail) async {
    await _truncate(_partStart);
    return AiDownloadException(AiDownloadFailure.damaged, detail);
  }

  /// Every part received: the whole checked by the sum of the catalogue, then installed under its final name
  Future<void> finish() async {
    await _closeSink();
    final sum = _whole.close();
    if (received != job.size || sum != job.sha256) {
      throw await job.fail(
        AiDownloadFailure.damaged,
        '$received bytes of SHA-256 $sum, the catalogue says ${job.size} bytes of ${job.sha256}',
      );
    }
    try {
      await job.target.parent.create(recursive: true);
      await job.part.rename(job.target.path);
    } on FileSystemException catch (error) {
      throw await job.writeFailed(error);
    }
  }

  Future<void> _closeSink() async {
    final sink = _sink;
    _sink = null;
    if (sink != null) {
      try {
        await sink.close();
      } on FileSystemException catch (error) {
        throw await job.writeFailed(error);
      }
    }
  }

  /// Closes the .part when the run ends without installing; a failure to close is only logged
  Future<void> dispose() async {
    try {
      await _closeSink();
    } on AiDownloadException catch (error) {
      _log.warning('closing the .part of ${job.component.id}: $error');
    }
  }
}

/// A SHA-256 fed chunk by chunk
class _Digest {
  // Closed through _input
  // ignore: close_sinks
  final _sink = _DigestSink();
  late final ByteConversionSink _input = sha256.startChunkedConversion(_sink);

  void add(List<int> bytes) => _input.add(bytes);

  /// The sum in hexadecimal; nothing more can be added
  String close() {
    _input.close();
    return _sink.value.toString();
  }
}

/// One call of download()
class _Job {
  _Job({
    required this.component,
    required this.size,
    required this.sha256,
    required this.target,
    required this.part,
    required this.cancel,
    required this.onProgress,
  });

  final AiComponent component;
  final int size;
  final String sha256;
  final File target;
  final File part;
  final AiDownloadCancel cancel;
  final void Function(int received, int? total)? onProgress;

  bool get gzipped => component.compression == AiCompression.gzip;

  /// The bytes to download when the catalogue knows them
  int? get expectedTransfer => gzipped ? component.downloadSize : size;

  /// The unpacked library, next to its .part
  File get unpacked => File('${part.path}.unpack');

  void checkCancel() {
    if (cancel.isCancelled) {
      throw const AiDownloadException(AiDownloadFailure.cancelled);
    }
  }

  /// The bytes of the .part that a request can resume
  int resumableBytes() {
    final have = part.existsSync() ? part.lengthSync() : 0;
    final expected = expectedTransfer;
    return expected != null && have >= expected ? 0 : have;
  }

  Future<void> discardPart() async {
    await _delete(part);
    await _delete(unpacked);
  }

  /// Everything received is deleted (no file of this job is open any more): a damaged file, or a full disk that
  /// wants its space back
  Future<AiDownloadException> fail(AiDownloadFailure failure, String detail) async {
    await discardPart();
    return AiDownloadException(failure, detail);
  }

  /// A write that failed, once the files of the job are closed
  Future<AiDownloadException> writeFailed(FileSystemException error) async {
    if (isDiskFull(error)) {
      return fail(AiDownloadFailure.diskFull, error.toString());
    }
    return AiDownloadException(AiDownloadFailure.writeFailed, error.toString());
  }

  /// Ready to receive the rest of a file of [total] bytes (null when unknown): the .part read again into the sum
  /// (and the unpacking), unless [restart] empties it first
  Future<_Receiver> open(AiComponentDownloader downloader, {required int? total, bool restart = false}) async {
    final expected = expectedTransfer;
    if (total != null && expected != null && total != expected) {
      throw await fail(AiDownloadFailure.damaged, 'the source has $total bytes, the catalogue $expected');
    }
    final receiver = _Receiver(this, total ?? expected, downloader._openSink);
    try {
      await part.parent.create(recursive: true);
      if (restart || (expected != null && part.existsSync() && part.lengthSync() > expected)) {
        await discardPart();
      }
      await receiver.start();
      return receiver;
    } on _WriteFailure catch (failure) {
      await receiver.dispose();
      throw await writeFailed(failure.error);
    } on FileSystemException catch (error) {
      await receiver.dispose();
      throw await writeFailed(error);
    } on _Damaged catch (damaged) {
      await receiver.dispose();
      throw await fail(AiDownloadFailure.damaged, damaged.detail);
    }
  }
}

/// A write to the files of the job failed (a read of the source fails as a FileSystemException of its own)
class _WriteFailure implements Exception {
  const _WriteFailure(this.error);

  final FileSystemException error;
}

/// What was received is not the file of the catalogue
class _Damaged implements Exception {
  const _Damaged(this.detail);

  final String detail;
}

/// The bytes of one attempt: appended to the .part, unpacked when gzip, counted into the size and the SHA-256 of the
/// installed file
class _Receiver {
  _Receiver(this._job, this._total, this._openSink);

  final _Job _job;
  final int? _total;
  final AiFileSinkOpener _openSink;
  AiFileSink? _part;
  AiFileSink? _unpackedSink;
  // Closed through _hash
  // ignore: close_sinks
  final _digest = _DigestSink();
  late final ByteConversionSink _hash = sha256.startChunkedConversion(_digest);
  ByteConversionSink? _gunzip;
  final _unpackedChunks = <List<int>>[];

  /// The bytes of the .part, the earlier ones included
  int received = 0;

  /// The bytes received by this attempt
  int receivedHere = 0;

  /// The bytes of the installed file so far
  int _installed = 0;

  Future<void> start() async {
    if (_job.gzipped) {
      _unpackedSink = await _open(_job.unpacked, append: false);
      _gunzip = gzip.decoder.startChunkedConversion(_UnpackedSink(this));
    }
    if (_job.part.existsSync()) {
      // The earlier bytes go through the sum (and the unpacking) again
      await for (final chunk in _job.part.openRead()) {
        await _count(chunk);
      }
    }
    _part = await _open(_job.part, append: true);
  }

  Future<AiFileSink> _open(File file, {required bool append}) async {
    try {
      return await _openSink(file, append: append);
    } on FileSystemException catch (error) {
      throw _WriteFailure(error);
    }
  }

  static Future<void> _write(AiFileSink sink, List<int> bytes) async {
    try {
      await sink.add(bytes);
    } on FileSystemException catch (error) {
      throw _WriteFailure(error);
    }
  }

  /// Takes the bytes of the installed file, from the unpacking or straight from the .part
  void _take(List<int> bytes) {
    _installed += bytes.length;
    if (_installed > _job.size) {
      throw _Damaged('more than the ${_job.size} bytes of the catalogue');
    }
    _hash.add(bytes);
  }

  Future<void> _count(List<int> chunk) async {
    received += chunk.length;
    final gunzip = _gunzip;
    if (gunzip == null) {
      _take(chunk);
      return;
    }
    try {
      gunzip.add(chunk);
    } on FormatException catch (error) {
      throw _Damaged('not a gzip file: ${error.message}');
    }
    for (final unpacked in _unpackedChunks) {
      await _write(_unpackedSink!, unpacked);
    }
    _unpackedChunks.clear();
  }

  /// Receives [bytes] until their end, then checks and installs the file. A read of [bytes] that fails is thrown as
  /// it is: the caller tells a cut from the rest.
  Future<void> receive(Stream<List<int>> bytes) async {
    _report();
    try {
      await for (final chunk in bytes) {
        _job.checkCancel();
        await _write(_part!, chunk);
        receivedHere += chunk.length;
        await _count(chunk);
        final expected = _total;
        if (expected != null && received > expected) {
          throw _Damaged('more than the $expected bytes announced');
        }
        _report();
      }
      _job.checkCancel();
      final expected = _total;
      if (expected != null && received < expected) {
        throw _Cut('the source ended after $received of $expected bytes');
      }
      await _finish();
    } on _WriteFailure catch (failure) {
      await dispose();
      throw await _job.writeFailed(failure.error);
    } on _Damaged catch (damaged) {
      await dispose();
      throw await _job.fail(AiDownloadFailure.damaged, damaged.detail);
    }
  }

  void _report() => _job.onProgress?.call(received, _total);

  Future<void> _finish() async {
    try {
      _gunzip?.close();
    } on FormatException catch (error) {
      throw _Damaged('truncated gzip file: ${error.message}');
    }
    for (final unpacked in _unpackedChunks) {
      await _write(_unpackedSink!, unpacked);
    }
    _unpackedChunks.clear();
    await _closeSinks();
    _hash.close();
    final sum = _digest.value.toString();
    if (_installed != _job.size || sum != _job.sha256) {
      throw _Damaged('$_installed bytes of SHA-256 $sum, the catalogue says ${_job.size} bytes of ${_job.sha256}');
    }
    try {
      await _job.target.parent.create(recursive: true);
      await (_job.gzipped ? _job.unpacked : _job.part).rename(_job.target.path);
    } on FileSystemException catch (error) {
      throw _WriteFailure(error);
    }
    if (_job.gzipped) {
      await _delete(_job.part);
    }
  }

  Future<void> _closeSinks() async {
    final sinks = [?_part, ?_unpackedSink];
    _part = null;
    _unpackedSink = null;
    FileSystemException? failed;
    for (final sink in sinks) {
      try {
        await sink.close();
      } on FileSystemException catch (error) {
        failed ??= error;
      }
    }
    if (failed != null) {
      throw _WriteFailure(failed);
    }
  }

  /// Closes the files when the attempt ends without installing; a failure to close is only logged
  Future<void> dispose() async {
    try {
      await _closeSinks();
    } on _WriteFailure catch (failure) {
      _log.warning('closing the files of ${_job.component.id}: ${failure.error}');
    }
  }
}

/// Receives the unpacked bytes of the gzip decoder, synchronously: they are counted at once and written after
class _UnpackedSink implements Sink<List<int>> {
  _UnpackedSink(this._receiver);

  final _Receiver _receiver;

  @override
  void add(List<int> data) {
    _receiver._take(data);
    _receiver._unpackedChunks.add(data);
  }

  @override
  void close() {}
}

class _DigestSink implements Sink<Digest> {
  Digest? _value;

  Digest get value => _value!;

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}
}

Future<void> _delete(File file) async {
  try {
    await file.delete();
  } on PathNotFoundException {
    // Already gone
  } on FileSystemException catch (error) {
    _log.warning('could not delete ${file.path}: $error');
  }
}
