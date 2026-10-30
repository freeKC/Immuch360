// Writing new files on a share opened in the app, for the versions a computer makes next to their originals: WebDAV
// against a server of the test (PUT, MOVE without overwriting, DELETE, HEAD, Basic credentials, the refusals of the
// server in their words), SMB against a connection of the test (the paths libsmb2 takes, its errors in their words);
// the check of a folder, which leaves no file; and a version put under its name or the first free "name (n)", never
// over a file, through a hidden partial file that never stays.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/desktop/ai/creator/write_probe.dart';
import 'package:immich_mobile/desktop/network/share_writer.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:path/path.dart' as p;

/// A WebDAV server in memory: its files by their decoded path, each request recorded with its credentials; a method
/// in [refusals] is answered with that status
class _DavServer {
  _DavServer._(this._server) {
    _server.listen(_serve);
  }

  static Future<_DavServer> start() async => _DavServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final files = <String, Uint8List>{};
  final requests = <String>[];
  final authorizations = <String?>[];
  final refusals = <String, int>{};

  int get port => _server.port;

  Future<void> close() => _server.close(force: true);

  Future<void> _serve(HttpRequest request) async {
    final path = Uri.decodeComponent(request.uri.path);
    requests.add('${request.method} $path');
    authorizations.add(request.headers.value(HttpHeaders.authorizationHeader));
    final response = request.response;
    final refused = refusals[request.method];
    if (refused != null) {
      await request.drain<void>();
      response.statusCode = refused;
      await response.close();
      return;
    }
    switch (request.method) {
      case 'PUT':
        final body = await request.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
        response.statusCode = files.containsKey(path) ? HttpStatus.noContent : HttpStatus.created;
        files[path] = Uint8List.fromList(body);
      case 'HEAD':
        response.statusCode = files.containsKey(path) ? HttpStatus.ok : HttpStatus.notFound;
      case 'DELETE':
        response.statusCode = files.remove(path) != null ? HttpStatus.noContent : HttpStatus.notFound;
      case 'MOVE':
        final destination = Uri.decodeComponent(Uri.parse(request.headers.value('destination')!).path);
        final overwrite = request.headers.value('overwrite');
        if (!files.containsKey(path)) {
          response.statusCode = HttpStatus.notFound;
        } else if (files.containsKey(destination) && overwrite == 'F') {
          response.statusCode = HttpStatus.preconditionFailed;
        } else {
          files[destination] = files.remove(path)!;
          response.statusCode = HttpStatus.created;
        }
      default:
        response.statusCode = HttpStatus.methodNotAllowed;
    }
    await response.close();
  }
}

/// An SMB connection in memory: the files by the path libsmb2 takes; an operation in [errors] throws that error
class _SmbConnection implements SmbWriteConnection {
  final files = <String, Uint8List>{};
  final calls = <String>[];
  final errors = <String, Smb2Exception>{};
  var closed = false;

  void _fail(String operation) {
    final error = errors[operation];
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<bool> exists(String path) async {
    calls.add('exists $path');
    _fail('exists');
    return files.containsKey(path);
  }

  @override
  Future<void> write(String path, Stream<Uint8List> chunks) async {
    calls.add('write $path');
    _fail('write');
    final bytes = <int>[];
    await for (final chunk in chunks) {
      bytes.addAll(chunk);
    }
    files[path] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> rename(String from, String to) async {
    calls.add('rename $from $to');
    _fail('rename');
    if (files.containsKey(to)) {
      throw const Smb2Exception('Rename failed', 17, Smb2ErrorType.alreadyExists);
    }
    files[to] = files.remove(from)!;
  }

  @override
  Future<void> delete(String path) async {
    calls.add('delete $path');
    _fail('delete');
    files.remove(path);
  }

  @override
  Future<void> close() async => closed = true;
}

void main() {
  late Directory root;
  late File version;

  setUp(() {
    root = Directory.systemTemp.createTempSync('share_writer');
    version = File(p.join(root.path, 'salon_3D_LRF_Full_SBS.jpg'))
      ..writeAsBytesSync(List.generate(70000, (i) => (i * 3) & 0xff));
  });

  tearDown(() => root.deleteSync(recursive: true));

  Matcher failsWith(ShareWriteFailure failure) =>
      throwsA(isA<ShareWriteException>().having((error) => error.failure, 'failure', failure));

  group('WebDAV', () {
    late _DavServer server;
    final client = http.Client();

    setUp(() async => server = await _DavServer.start());
    tearDown(() => server.close());
    tearDownAll(client.close);

    WebDavShareWriter writer({String share = 'dav/photos'}) => WebDavShareWriter(
      NetworkSource(
        id: 'dav',
        type: NetworkSourceType.webdav,
        name: 'NAS',
        host: '127.0.0.1',
        port: server.port,
        share: share,
        username: 'me',
      ),
      'secret',
      client: client,
    );

    test('a file written, renamed never over another, deleted, each with the credentials of the share', () async {
      final dav = writer();

      await dav.upload('/2024 été/.salon.partial', version);
      expect(server.files['/dav/photos/2024 été/.salon.partial'], version.readAsBytesSync());
      expect(await dav.exists('/2024 été/.salon.partial'), isTrue);
      expect(await dav.exists('/2024 été/salon_3D_LRF_Full_SBS.jpg'), isFalse);

      await dav.rename('/2024 été/.salon.partial', '/2024 été/salon_3D_LRF_Full_SBS.jpg');
      expect(server.files.keys, ['/dav/photos/2024 été/salon_3D_LRF_Full_SBS.jpg']);

      server.files['/dav/photos/2024 été/.other.partial'] = Uint8List(3);
      await expectLater(
        dav.rename('/2024 été/.other.partial', '/2024 été/salon_3D_LRF_Full_SBS.jpg'),
        failsWith(ShareWriteFailure.taken),
      );
      expect(server.files['/dav/photos/2024 été/salon_3D_LRF_Full_SBS.jpg'], version.readAsBytesSync());

      await dav.delete('/2024 été/.other.partial');
      expect(server.files.keys, ['/dav/photos/2024 été/salon_3D_LRF_Full_SBS.jpg']);
      expect(server.authorizations.toSet(), {'Basic ${base64.encode(utf8.encode('me:secret'))}'});
      await dav.close();
    });

    test('the refusals of the server in their words: read only, full, a folder gone, anything else', () async {
      final dav = writer();
      for (final (status, failure) in [
        (HttpStatus.forbidden, ShareWriteFailure.readOnly),
        (HttpStatus.unauthorized, ShareWriteFailure.readOnly),
        (HttpStatus.methodNotAllowed, ShareWriteFailure.readOnly),
        (HttpStatus.insufficientStorage, ShareWriteFailure.diskFull),
        (HttpStatus.conflict, ShareWriteFailure.missing),
        (HttpStatus.notFound, ShareWriteFailure.missing),
        (HttpStatus.internalServerError, ShareWriteFailure.failed),
      ]) {
        server.refusals['PUT'] = status;
        await expectLater(dav.upload('/2024/.salon.partial', version), failsWith(failure), reason: '$status');
      }
      await dav.close();
    });
  });

  group('SMB', () {
    test('the paths libsmb2 takes, relative to the share, and its errors in their words', () async {
      final connection = _SmbConnection();
      final smb = SmbShareWriter(connection);

      await smb.upload('/2024/./.salon.partial', version);
      expect(connection.files['2024/.salon.partial'], version.readAsBytesSync());
      await smb.rename('/2024/.salon.partial', '/2024/salon_3D_LRF_Full_SBS.jpg');
      expect(connection.files.keys, ['2024/salon_3D_LRF_Full_SBS.jpg']);
      expect(await smb.exists('/2024/salon_3D_LRF_Full_SBS.jpg'), isTrue);

      connection.files['2024/.other.partial'] = Uint8List(3);
      await expectLater(
        smb.rename('/2024/.other.partial', '/2024/salon_3D_LRF_Full_SBS.jpg'),
        failsWith(ShareWriteFailure.taken),
      );
      for (final (type, failure) in [
        (Smb2ErrorType.accessDenied, ShareWriteFailure.readOnly),
        (Smb2ErrorType.auth, ShareWriteFailure.readOnly),
        (Smb2ErrorType.diskFull, ShareWriteFailure.diskFull),
        (Smb2ErrorType.fileNotFound, ShareWriteFailure.missing),
        (Smb2ErrorType.notADirectory, ShareWriteFailure.missing),
        (Smb2ErrorType.io, ShareWriteFailure.failed),
      ]) {
        connection.errors['write'] = Smb2Exception('Write failed', null, type);
        await expectLater(smb.upload('/2024/.x.partial', version), failsWith(failure), reason: type.name);
      }
      await smb.close();
      expect(connection.closed, isTrue);
    });
  });

  group('the check of a folder of a share', () {
    test('a folder that takes a new file: ready, and the file of the check deleted', () async {
      final connection = _SmbConnection();

      final result = await checkShareFolder(SmbShareWriter(connection), '/2024');

      expect(result.status, ProbeStatus.ready);
      expect(connection.files, isEmpty, reason: 'no file left');
      expect(connection.calls.first, startsWith('write 2024/.immuch360-check-'));
      expect(connection.calls.last, startsWith('delete 2024/.immuch360-check-'));
    });

    test('a folder that refuses, is gone or fails, in the words of the check', () async {
      for (final (type, status) in [
        (Smb2ErrorType.accessDenied, ProbeStatus.readOnly),
        (Smb2ErrorType.diskFull, ProbeStatus.diskFull),
        (Smb2ErrorType.fileNotFound, ProbeStatus.missing),
        (Smb2ErrorType.io, ProbeStatus.failed),
      ]) {
        final connection = _SmbConnection()..errors['write'] = Smb2Exception('Open for write failed', null, type);
        final result = await checkShareFolder(SmbShareWriter(connection), '/2024');
        expect(result.status, status, reason: type.name);
        expect(result.accepted, isFalse);
      }
    });
  });

  group('a version put next to its original', () {
    test('under its name, through a hidden partial file', () async {
      final connection = _SmbConnection();

      final path = await publishShareVersion(
        SmbShareWriter(connection),
        version,
        folder: '/2024',
        name: 'salon_3D.jpg',
      );

      expect(path, '/2024/salon_3D.jpg');
      expect(connection.files.keys, ['2024/salon_3D.jpg']);
      final partial = connection.calls.firstWhere((call) => call.startsWith('write '));
      expect(partial, startsWith('write 2024/.salon_3D.jpg.'));
      expect(partial, endsWith('.partial'));
    });

    test('a name taken: the first free "name (n)", never over the file there', () async {
      final connection = _SmbConnection()
        ..files['2024/salon_3D.jpg'] = Uint8List(1)
        ..files['2024/salon_3D (1).jpg'] = Uint8List(2);

      final path = await publishShareVersion(
        SmbShareWriter(connection),
        version,
        folder: '/2024',
        name: 'salon_3D.jpg',
      );

      expect(path, '/2024/salon_3D (2).jpg');
      expect(connection.files['2024/salon_3D.jpg'], Uint8List(1));
      expect(connection.files['2024/salon_3D (1).jpg'], Uint8List(2));
      expect(connection.files['2024/salon_3D (2).jpg'], version.readAsBytesSync());
    });

    test('a name taken and skipped: nothing written', () async {
      final connection = _SmbConnection()..files['salon_3D.jpg'] = Uint8List(1);

      final path = await publishShareVersion(
        SmbShareWriter(connection),
        version,
        folder: '/',
        name: 'salon_3D.jpg',
        skipWhenTaken: true,
      );

      expect(path, isNull);
      expect(connection.files.keys, ['salon_3D.jpg']);
      expect(connection.calls.where((call) => call.startsWith('write')), isEmpty);
    });

    test('a write that fails leaves no partial file, and says why', () async {
      final connection = _SmbConnection()
        ..errors['rename'] = const Smb2Exception('Rename failed', 13, Smb2ErrorType.accessDenied);

      await expectLater(
        publishShareVersion(SmbShareWriter(connection), version, folder: '/2024', name: 'salon_3D.jpg'),
        failsWith(ShareWriteFailure.readOnly),
      );
      expect(connection.files, isEmpty);
    });
  });
}
