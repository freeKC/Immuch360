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

import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  /// What happened, in English, for the log and the {reason} of ai_immersive_download_failed
  final String? detail;

  /// The text shown for this failure (i18n/en.json; aiDownloadFailureText of the install sheet gives the same)
  String get messageKey => switch (failure) {
    AiDownloadFailure.damaged => 'ai_immersive_download_damaged',
    AiDownloadFailure.diskFull => 'ai_immersive_failed_disk_full',
    AiDownloadFailure.cancelled => 'ai_immersive_state_cancelled',
    AiDownloadFailure.notFound => 'ai_immersive_download_not_found',
    AiDownloadFailure.network => 'ai_immersive_download_network',
    AiDownloadFailure.writeFailed => 'ai_immersive_download_write_failed',
    AiDownloadFailure.incomplete || AiDownloadFailure.insecureAddress => 'ai_immersive_download_failed',
  };

  /// The {reason} of ai_immersive_download_failed
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
    this.release = aiComponentsReleaseBase,
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

  /// The base of the release; another one only in the tests
  final String release;

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

  /// The addresses tried for [component], in order
  List<Uri> addressesOf(AiComponent component) {
    final mirror = mirrorBase;
    return [for (final url in component.urls(mirror: mirror, release: release)) Uri.parse(url)];
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
    final List<Uri> addresses;
    try {
      addresses = addressesOf(component);
    } on FormatException catch (error) {
      throw AiDownloadException(AiDownloadFailure.insecureAddress, 'not an address: ${error.message}');
    }
    AiDownloadException? failure;
    for (final address in addresses) {
      job.checkCancel();
      try {
        await _from(job, address);
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

  Future<void> _fromServer(_Job job, Uri address) async {
    final client = _createClient()
      ..connectionTimeout = connectTimeout
      ..autoUncompress = false;
    // A cancel closes the connection at once, whatever is awaited
    final closing = job.cancel.whenCancelled.then((_) => client.close(force: true));
    _Receiver? receiver;
    try {
      var url = address;
      var redirects = 0;
      final have = job.resumableBytes();
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
        // The .part is not a beginning of this file: start again from nothing
        await response.drain<void>().catchError((_) {});
        await job.discardPart();
        throw const _Cut('the server refused the range of the .part');
      }
      if (status != HttpStatus.ok && status != HttpStatus.partialContent) {
        await response.drain<void>().catchError((_) {});
        throw AiDownloadException(AiDownloadFailure.network, '$status $url');
      }
      final encoding = response.headers.value(HttpHeaders.contentEncodingHeader);
      if (encoding != null && encoding.toLowerCase() != 'identity') {
        throw AiDownloadException(AiDownloadFailure.network, 'unexpected Content-Encoding $encoding from $url');
      }
      int? total;
      var from = 0;
      if (status == HttpStatus.partialContent) {
        final range = RegExp(
          r'^bytes (\d+)-(\d+)/(\d+|\*)$',
        ).firstMatch(response.headers.value(HttpHeaders.contentRangeHeader) ?? '');
        from = int.tryParse(range?.group(1) ?? '') ?? -1;
        total = int.tryParse(range?.group(3) ?? '');
        if (from != have) {
          await job.discardPart();
          throw _Cut('the server answered another range than bytes=$have-');
        }
      } else if (response.contentLength >= 0) {
        total = response.contentLength;
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
