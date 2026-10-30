// Writing new files on a share opened in the app, on a computer: the versions the AI makes next to their originals on
// an SMB or WebDAV share (FreeKC, 30 October 2026, "Make 3D (AI)" on a photo of a share). The file systems of the
// shares read only (domain/services/network_file_system.dart), and the phones never write on a share: the writer is
// desktop code, with a connection of its own that it closes once its files are written. DLNA and Plex take no file.
//
// It never writes over a file and never touches an original: a version goes first into a hidden partial file of its
// folder (".salon_3D.jpg.<id>.partial", a name the browser of the shares does not show), then is renamed onto its
// name, or onto the first free "name (n)" when that is taken, a rename that the server itself refuses over an existing
// file (SMB without ReplaceIfExists, WebDAV MOVE with "Overwrite: F"). A partial file left by a failure is deleted.
// The check of a folder writes an empty hidden file and deletes it at once; a share that keeps the file but does not
// let the app delete it (rights "without delete" of some NAS) would not let it rename a version either, so the check
// says read only, and the hidden files of the writer an earlier session left there (a crash during an upload) are
// deleted once an hour old.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:immich_mobile/desktop/ai/creator/destination.dart';
import 'package:immich_mobile/desktop/ai/creator/write_probe.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/infrastructure/network/smb_file_system.dart';
import 'package:immich_mobile/infrastructure/network/webdav_file_system.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('ShareWriter');

/// How long a connection may take beyond the timeout of libsmb2 before the writer gives up: a worker that dies before
/// it reports would otherwise be waited for ever (as SmbFileSystem waits for its own)
const _connectGrace = Duration(seconds: 15);

/// Why a file could not be written on a share
enum ShareWriteFailure {
  /// The share or the folder refuses new files (read only, or the account may not write)
  readOnly,

  /// No space left on the share
  diskFull,

  /// The folder is not there any more
  missing,

  /// The name is taken: a rename never goes over a file
  taken,

  /// Anything else, with the words of the server
  failed,
}

class ShareWriteException implements Exception {
  const ShareWriteException(this.failure, [this.message]);

  final ShareWriteFailure failure;
  final String? message;

  @override
  String toString() => 'ShareWriteException(${failure.name}${message == null ? '' : ': $message'})';
}

/// New files on a share. Paths are absolute inside the share, "/" separated, as the entries of its file system give
/// them.
abstract interface class ShareWriter {
  /// Whether something is at [path]
  Future<bool> exists(String path);

  /// Writes the bytes of [file] into a file at [path], created or emptied: the hidden partial files of the writer only
  Future<void> upload(String path, File file);

  /// Gives [from] the name [to], in the same folder; throws [ShareWriteFailure.taken] when [to] exists
  Future<void> rename(String from, String to);

  Future<void> delete(String path);

  /// Closes the connection of the writer
  Future<void> close();
}

/// The types of share the app writes versions into: those of the files of a NAS or a computer, not a media server
bool isWritableShareType(NetworkSourceType type) => type == NetworkSourceType.smb || type == NetworkSourceType.webdav;

/// Opens a writer on the share with this id, null for a share the app never writes into (DLNA, Plex, a camera)
typedef ShareWriterOpener = Future<ShareWriter?> Function(String sourceId);

/// Opens a writer with the address and the credentials of the share, as its file system connects; replaced in tests
final shareWriterOpenerProvider = Provider<ShareWriterOpener>(
  (ref) => (sourceId) async {
    final source = ref.read(networkSourceProvider(sourceId));
    if (source == null || !isWritableShareType(source.type)) {
      return null;
    }
    final password = await ref.read(networkSourcesProvider.notifier).readPassword(sourceId);
    return switch (source.type) {
      NetworkSourceType.smb => SmbShareWriter.open(source, password),
      _ => WebDavShareWriter(source, password),
    };
  },
);

/// Checks a folder of a share for the destination of the versions (DestinationSession.shareProbe), through a writer
/// opened for the check and closed after it; replaced in tests
final shareFolderProbeProvider = Provider<Future<ProbeResult> Function(ShareFolder folder)>(
  (ref) => (folder) async {
    final ShareWriter? writer;
    try {
      writer = await ref.read(shareWriterOpenerProvider)(folder.sourceId);
    } on ShareWriteException catch (error) {
      return ProbeResult(
        error.failure == ShareWriteFailure.readOnly ? ProbeStatus.readOnly : ProbeStatus.failed,
        message: error.message,
      );
    }
    if (writer == null) {
      return const ProbeResult(ProbeStatus.readOnly);
    }
    try {
      return await checkShareFolder(
        writer,
        folder.path,
        // The hidden files an earlier session left, as the reads of the share list them
        list: (path) async => (await ref.read(networkConnectionsProvider).fileSystem(folder.sourceId)).list(path),
      );
    } finally {
      await writer.close();
    }
  },
);

/// "/" separated segments of [path], without empty, "." and ".." ones
List<String> _segmentsOf(String path) {
  final segments = <String>[];
  for (final segment in path.replaceAll(r'\', '/').split('/')) {
    if (segment.isEmpty || segment == '.') {
      continue;
    }
    if (segment == '..') {
      if (segments.isNotEmpty) {
        segments.removeLast();
      }
      continue;
    }
    segments.add(segment);
  }
  return segments;
}

/// [name] in [folder] of a share, "/" separated
String sharePathIn(String folder, String name) {
  final segments = _segmentsOf(folder);
  return '/${[...segments, name].join('/')}';
}

/// The folder of the share path [path], "/" for a file at its root
String shareFolderOfPath(String path) {
  final segments = _segmentsOf(path);
  return segments.length <= 1 ? '/' : '/${segments.sublist(0, segments.length - 1).join('/')}';
}

/// Where the file at [filePath] of the share [source] is, as the destination of its versions sees it, null for a share
/// the app never writes into: its folder in the share, its label (an address of Windows on Windows, [windows], else a
/// URL), and the root the share was added at, named as the root of that share mounted as a drive would be
/// (volume_id.dart: "net-//nas/photos:/pictures", case folded for SMB) so that one yes covers both
ShareFolder? shareFolderOf(NetworkSource source, String filePath, {bool? windows}) {
  if (!isWritableShareType(source.type)) {
    return null;
  }
  final folder = shareFolderOfPath(filePath);
  final inShare = _segmentsOf(folder);
  final root = _segmentsOf(source.rootPath);
  if (source.type == NetworkSourceType.smb) {
    // The address the reads connect to, without the default port
    // ignore: invalid_use_of_visible_for_testing_member
    var server = SmbFileSystem.serverAddressOf(source.host, source.port);
    const defaultPort = ':${SmbFileSystem.defaultPort}';
    final withPort = !server.endsWith(defaultPort);
    if (!withPort) {
      server = server.substring(0, server.length - defaultPort.length);
    }
    // ignore: invalid_use_of_visible_for_testing_member
    final share = SmbFileSystem.shareNameOf(source.share);
    String label(List<String> inside) => (windows ?? Platform.isWindows) && !withPort
        ? '\\\\${[server, share, ...inside].join(r'\')}'
        : 'smb://${[server, share, ...inside].join('/')}';
    return ShareFolder(
      sourceId: source.id,
      path: folder,
      label: label(inShare),
      rootKey: 'net-//$server/$share:/${root.join('/')}'.toLowerCase(),
      rootLabel: label(root),
    );
  }
  final base = WebDavFileSystem.baseUriOf(source);
  final basePath = base.pathSegments.where((segment) => segment.isNotEmpty).toList();
  String label(List<String> inside) => base.replace(pathSegments: [...basePath, ...inside]).toString();
  final host = base.hasPort ? '${base.host}:${base.port}' : base.host;
  return ShareFolder(
    sourceId: source.id,
    path: folder,
    label: label(inShare),
    rootKey: 'net-//${host.toLowerCase()}/${basePath.join('/')}:/${root.join('/')}',
    rootLabel: label(root),
  );
}

/// What an SMB writer asks of its connection, by the paths libsmb2 takes (relative to the share, "" for its root)
abstract interface class SmbWriteConnection {
  Future<bool> exists(String path);

  Future<void> write(String path, Stream<Uint8List> chunks);

  Future<void> rename(String from, String to);

  Future<void> delete(String path);

  Future<void> close();
}

/// The connection of an SMB writer: a pool of one worker of dart_smb2, apart from the reads of the share
class _PoolConnection implements SmbWriteConnection {
  _PoolConnection(this._pool);

  final Smb2Pool _pool;

  @override
  Future<bool> exists(String path) => _pool.exists(path);

  @override
  Future<void> write(String path, Stream<Uint8List> chunks) => _pool.streamWrite(path, chunks);

  @override
  Future<void> rename(String from, String to) => _pool.rename(from, to);

  @override
  Future<void> delete(String path) => _pool.deleteFile(path);

  @override
  Future<void> close() => _pool.disconnect();
}

/// New files on an SMB share
class SmbShareWriter implements ShareWriter {
  SmbShareWriter(this._connection);

  /// Connects to the share of [source] the way its file system does (SmbFileSystem.open): the same address, share,
  /// user, domain and password. Throws a [ShareWriteException] when it cannot.
  static Future<SmbShareWriter> open(NetworkSource source, String? password, {int timeoutSeconds = 20}) async {
    // The same address and logon as the reads of the share: the rules of its file system, not a copy of them
    // ignore: invalid_use_of_visible_for_testing_member
    final server = SmbFileSystem.serverAddressOf(source.host, source.port);
    // ignore: invalid_use_of_visible_for_testing_member
    final share = SmbFileSystem.shareNameOf(source.share);
    // ignore: invalid_use_of_visible_for_testing_member
    final (user, domain) = SmbFileSystem.splitUserName(source.username);
    try {
      // Loaded in this isolate first: a worker that fails to load it would never report
      Smb2Client.open();
      final pool = await Smb2Pool.connect(
        host: server,
        share: share,
        user: user,
        password: SmbFileSystem.logonPassword(user, password),
        domain: domain,
        workers: 1,
        timeoutSeconds: timeoutSeconds,
      ).timeout(Duration(seconds: timeoutSeconds) + _connectGrace);
      return SmbShareWriter(_PoolConnection(pool));
    } on Smb2Exception catch (error) {
      throw _failureOf(error);
    } on TimeoutException {
      throw ShareWriteException(ShareWriteFailure.failed, 'The server at $server did not answer in time');
    } catch (error) {
      throw ShareWriteException(ShareWriteFailure.failed, '$error');
    }
  }

  final SmbWriteConnection _connection;

  /// The path libsmb2 takes
  static String _smbPath(String path) => _segmentsOf(path).join('/');

  static ShareWriteException _failureOf(Smb2Exception error) => ShareWriteException(switch (error.type) {
    Smb2ErrorType.accessDenied || Smb2ErrorType.auth => ShareWriteFailure.readOnly,
    Smb2ErrorType.diskFull => ShareWriteFailure.diskFull,
    Smb2ErrorType.fileNotFound || Smb2ErrorType.notADirectory => ShareWriteFailure.missing,
    Smb2ErrorType.alreadyExists => ShareWriteFailure.taken,
    _ => ShareWriteFailure.failed,
  }, error.message);

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on Smb2Exception catch (error) {
      throw _failureOf(error);
    }
  }

  @override
  Future<bool> exists(String path) => _guard(() => _connection.exists(_smbPath(path)));

  @override
  Future<void> upload(String path, File file) =>
      _guard(() => _connection.write(_smbPath(path), file.openRead().map(Uint8List.fromList)));

  @override
  Future<void> rename(String from, String to) => _guard(() async {
    // The server refuses a rename over a file too; asked first, so that the answer does not depend on the server
    if (await _connection.exists(_smbPath(to))) {
      throw const ShareWriteException(ShareWriteFailure.taken);
    }
    await _connection.rename(_smbPath(from), _smbPath(to));
  });

  @override
  Future<void> delete(String path) => _guard(() => _connection.delete(_smbPath(path)));

  @override
  Future<void> close() async {
    try {
      await _connection.close();
    } catch (error) {
      _log.fine('The SMB connection of the writer did not close cleanly: $error');
    }
  }
}

/// New files on a WebDAV share, with the Basic credentials of the share. Redirects are not followed: a server that
/// sends a write elsewhere fails it.
class WebDavShareWriter implements ShareWriter {
  WebDavShareWriter(NetworkSource source, String? password, {http.Client? client})
    : _base = WebDavFileSystem.baseUriOf(source),
      _authorization = source.username.isEmpty && (password == null || password.isEmpty)
          ? null
          : 'Basic ${base64.encode(utf8.encode('${source.username}:${password ?? ''}'))}',
      _client = client ?? IOClient(HttpClient()..connectionTimeout = const Duration(seconds: 15)),
      _ownsClient = client == null;

  final Uri _base;
  final String? _authorization;
  final http.Client _client;
  final bool _ownsClient;

  /// Longest wait for the answer of the server
  static const answerTimeout = Duration(seconds: 60);

  /// [path] on the server; with [folder], ended by a slash, as the servers that redirect a folder without it want it
  Uri _uriOf(String path, {bool folder = false}) => _base.replace(
    pathSegments: [..._base.pathSegments.where((segment) => segment.isNotEmpty), ..._segmentsOf(path), if (folder) ''],
  );

  Future<http.StreamedResponse> _send(
    String method,
    String path, {
    Map<String, String> headers = const {},
    Stream<List<int>>? body,
    int? length,
    bool folder = false,
  }) async {
    final request = http.StreamedRequest(method, _uriOf(path, folder: folder))
      ..followRedirects = false
      ..headers.addAll(headers);
    final authorization = _authorization;
    if (authorization != null) {
      request.headers[HttpHeaders.authorizationHeader] = authorization;
    }
    // A request without a body says so, rather than an empty chunked body some servers refuse
    request.contentLength = body == null ? 0 : length;
    final sending = _client.send(request);
    // A server that refuses a large body at once (507, 413) and drops the connection fails the request while the body
    // still streams: heard now, so that the failure never reaches the zone unheard, and told below. The client of
    // dart:io reads an answer only once the whole body went, so the status of such a server is not known then; the
    // words of the connection are given instead.
    unawaited(sending.then((_) {}, onError: (Object _) {}));
    if (body != null) {
      await request.sink.addStream(body);
    }
    unawaited(request.sink.close());
    try {
      final response = await sending.timeout(answerTimeout);
      // The body of an answer to a write tells nothing more than its status
      unawaited(response.stream.drain<void>().catchError((_) {}));
      return response;
    } on TimeoutException {
      throw ShareWriteException(ShareWriteFailure.failed, 'The server at ${_base.host} did not answer in time');
    } on Exception catch (error) {
      throw ShareWriteException(ShareWriteFailure.failed, '$error');
    }
  }

  static ShareWriteException _refusal(int status) => ShareWriteException(switch (status) {
    HttpStatus.unauthorized || HttpStatus.forbidden || HttpStatus.methodNotAllowed => ShareWriteFailure.readOnly,
    HttpStatus.insufficientStorage || HttpStatus.requestEntityTooLarge => ShareWriteFailure.diskFull,
    HttpStatus.notFound || HttpStatus.conflict => ShareWriteFailure.missing,
    HttpStatus.preconditionFailed => ShareWriteFailure.taken,
    _ => ShareWriteFailure.failed,
  }, 'The server answered $status');

  static bool _isSuccess(int status) => status >= 200 && status < 300;

  @override
  Future<bool> exists(String path) async {
    final response = await _send('HEAD', path);
    if (response.statusCode == HttpStatus.notFound) {
      return false;
    }
    if (_isSuccess(response.statusCode)) {
      return true;
    }
    throw _refusal(response.statusCode);
  }

  @override
  Future<void> upload(String path, File file) async {
    final response = await _send(
      'PUT',
      path,
      headers: {HttpHeaders.contentTypeHeader: 'application/octet-stream'},
      body: file.openRead(),
      length: await file.length(),
    );
    final status = response.statusCode;
    if (_isSuccess(status)) {
      return;
    }
    // A missing folder is 409 for a PUT (RFC 4918); rclone in read only, and the other servers built on the WebDAV of
    // Go, answer 404 to a PUT they refuse in a folder that is there: the folder asked for, read only when it is there
    if (status == HttpStatus.notFound && await _isFolder(shareFolderOfPath(path))) {
      throw ShareWriteException(ShareWriteFailure.readOnly, 'The server answered $status');
    }
    throw _refusal(status);
  }

  /// Whether [folder] is there, by a PROPFIND of depth 0; false when the server does not say so
  Future<bool> _isFolder(String folder) async {
    const ask =
        '<?xml version="1.0" encoding="utf-8"?>'
        '<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>';
    final body = utf8.encode(ask);
    try {
      final response = await _send(
        'PROPFIND',
        folder,
        headers: {'Depth': '0', HttpHeaders.contentTypeHeader: 'application/xml; charset=utf-8'},
        body: Stream.value(body),
        length: body.length,
        folder: true,
      );
      return response.statusCode == 207 || response.statusCode == HttpStatus.ok;
    } on ShareWriteException catch (error) {
      _log.fine('The folder $folder could not be asked for: $error');
      return false;
    }
  }

  @override
  Future<void> rename(String from, String to) async {
    final response = await _send('MOVE', from, headers: {'Destination': _uriOf(to).toString(), 'Overwrite': 'F'});
    if (!_isSuccess(response.statusCode)) {
      throw _refusal(response.statusCode);
    }
  }

  @override
  Future<void> delete(String path) async {
    final response = await _send('DELETE', path);
    if (!_isSuccess(response.statusCode) && response.statusCode != HttpStatus.notFound) {
      throw _refusal(response.statusCode);
    }
  }

  @override
  Future<void> close() async {
    if (_ownsClient) {
      _client.close();
    }
  }
}

final _random = Random.secure();

/// A short random id for the hidden files of the writer
String _newId() => [for (var i = 0; i < 4; i++) _random.nextInt(1 << 16).toRadixString(16).padLeft(4, '0')].join();

/// The hidden files the writer makes in a folder of a share: the partial file of a version
/// (".salon_3D.jpg.0123456789abcdef.partial") and the file of a check (".immuch360-check-0123456789abcdef")
final _writerFile = RegExp(r'^\.(.+\.[0-9a-f]{16}\.partial|immuch360-check-[0-9a-f]{16})$');

/// How old a hidden file of the writer must be before a check deletes it: an upload of another window or computer is
/// never that long
const _leftoverAge = Duration(hours: 1);

/// Lists a folder of a share, as its file system reads it
typedef ShareFolderLister = Future<List<NetworkEntry>> Function(String folder);

/// Checks that [folder] of the share takes new files: an empty hidden file written there and deleted at once (see
/// WriteProbe for the folders of this computer). A file the share keeps but does not let the app delete makes the
/// check say read only: a version could not be renamed there either. The words of the check: ready, read only, full,
/// gone, or failed with the words of the server. Once the folder takes files, the hidden files of the writer that
/// [list] finds there and that are an hour old are deleted: what a crash during an upload left.
Future<ProbeResult> checkShareFolder(
  ShareWriter writer,
  String folder, {
  ShareFolderLister? list,
  DateTime Function()? now,
}) async {
  final path = sharePathIn(folder, '.immuch360-check-${_newId()}');
  final empty = File('${Directory.systemTemp.path}${Platform.pathSeparator}.immuch360-check-${_newId()}');
  try {
    await empty.writeAsBytes(const []);
    await writer.upload(path, empty);
    try {
      await writer.delete(path);
    } on ShareWriteException catch (error) {
      _log.warning('The file of the check of $folder stays on its share: $error');
      if (error.failure == ShareWriteFailure.readOnly) {
        return ProbeResult(ProbeStatus.readOnly, message: error.message);
      }
    }
    if (list != null) {
      await _deleteLeftovers(writer, folder, list, (now ?? DateTime.now)());
    }
    return const ProbeResult(ProbeStatus.ready);
  } on ShareWriteException catch (error) {
    return ProbeResult(switch (error.failure) {
      ShareWriteFailure.readOnly => ProbeStatus.readOnly,
      ShareWriteFailure.diskFull => ProbeStatus.diskFull,
      ShareWriteFailure.missing => ProbeStatus.missing,
      ShareWriteFailure.taken || ShareWriteFailure.failed => ProbeStatus.failed,
    }, message: error.message);
  } on FileSystemException catch (error) {
    return ProbeResult(ProbeStatus.failed, message: error.message);
  } finally {
    try {
      if (empty.existsSync()) {
        empty.deleteSync();
      }
    } on FileSystemException {
      // A file of the temporary folder of the system
    }
  }
}

/// Deletes the hidden files of the writer in [folder] that are older than an hour; never fails
Future<void> _deleteLeftovers(ShareWriter writer, String folder, ShareFolderLister list, DateTime now) async {
  try {
    for (final entry in await list(folder)) {
      final modified = entry.modified;
      if (entry.isDirectory || modified == null || !_writerFile.hasMatch(entry.name)) {
        continue;
      }
      if (now.difference(modified) < _leftoverAge) {
        continue;
      }
      try {
        await writer.delete(sharePathIn(folder, entry.name));
        _log.info('${entry.name}, left in $folder by an earlier session, deleted');
      } on ShareWriteException catch (error) {
        _log.fine('${entry.name} stays in $folder: $error');
      }
    }
  } catch (error) {
    _log.fine('The hidden files of $folder could not be listed: $error');
  }
}

/// "salon_3D.jpg", then "salon_3D (1).jpg", "salon_3D (2).jpg": the names [name] takes when it is taken, as a version
/// of this computer takes them
String _numbered(String name, int occurrence) {
  if (occurrence == 0) {
    return name;
  }
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? '$name ($occurrence)' : '${name.substring(0, dot)} ($occurrence)${name.substring(dot)}';
}

/// Puts the version [file] in [folder] of the share under [name], or under the first free "name (n)" when [name] is
/// taken, never over a file; with [skipWhenTaken], nothing is written when [name] is taken. The file goes first into a
/// hidden partial file of the folder, renamed once whole, and deleted when anything fails. Gives the path of the file
/// written on the share, null when it was skipped. Throws a [ShareWriteException].
Future<String?> publishShareVersion(
  ShareWriter writer,
  File file, {
  required String folder,
  required String name,
  bool skipWhenTaken = false,
}) async {
  if (skipWhenTaken && await writer.exists(sharePathIn(folder, name))) {
    return null;
  }
  final partial = sharePathIn(folder, '.$name.${_newId()}.partial');
  try {
    await writer.upload(partial, file);
    for (var occurrence = 0; occurrence < 1000; occurrence++) {
      final target = sharePathIn(folder, _numbered(name, occurrence));
      if (await writer.exists(target)) {
        continue;
      }
      try {
        await writer.rename(partial, target);
        return target;
      } on ShareWriteException catch (error) {
        // Taken meanwhile: the next name
        if (error.failure != ShareWriteFailure.taken) {
          rethrow;
        }
      }
    }
    throw const ShareWriteException(ShareWriteFailure.taken, 'No free name left');
  } catch (_) {
    try {
      await writer.delete(partial);
    } catch (error) {
      _log.warning('The partial file $partial stays on its share: $error');
    }
    rethrow;
  }
}
