// The SMB file system against a fake dart_smb2 pool (always), then against a real Samba server (only on the machine
// that runs one: IMMUCH_NET_TESTS=1, SMB on localhost port 1445, share "media", user "tester", password "testpass").
//
// The real tests load libsmb2 from IMMUCH_LIBSMB2 when set, else from ~/.cache/immuch-net-tests/libsmb2.so, else from
// where the Linux build of dart_smb2 puts it. The prebuilt Linux library of dart_smb2 needs glibc 2.38; on an older
// system build one with the scripts of github.com/ales-drnz/libsmb2-scripts (DART_SMB2_ROOT=<the dart_smb2 package>
// ARCHS=x86_64 scripts/build_libsmb2_linux.sh, same libsmb2 and patches as the app) and copy it to
// ~/.cache/immuch-net-tests/libsmb2.so.

// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:dart_smb2/src/ffi/native_lib.dart';
import 'package:dart_smb2/src/pool/test_hooks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/infrastructure/network/smb_file_system.dart';

import 'libsmb2_test_path.dart';

/// An in memory share behind the [Smb2Pool] interface, reading at most [maxRead] bytes at once like a real server
class _FakePool extends Fake implements Smb2Pool {
  _FakePool({this.maxRead = 8 * 1024 * 1024});

  final int maxRead;
  final Map<String, Uint8List> files = {};
  final Set<String> folders = {''};
  final Map<String, DateTime> dates = {};

  /// (path, offset, length) of every read asked, on a path or on an open file
  final List<(String, int, int)> reads = [];
  final List<String> listed = [];
  int fileOpens = 0;
  int disconnects = 0;

  /// Thrown by the next call instead of answering
  Smb2Exception? failNext;

  /// Thrown by every call instead of answering
  Smb2Exception? failAlways;

  static final defaultDate = DateTime.utc(2026, 9, 30, 12);

  void _maybeFail() {
    final failure = failNext ?? failAlways;
    failNext = null;
    if (failure != null) {
      throw failure;
    }
  }

  Smb2Stat _statOf(String path) {
    if (folders.contains(path)) {
      return Smb2Stat(
        type: Smb2FileType.directory,
        size: 0,
        modified: dates[path] ?? defaultDate,
        created: defaultDate,
      );
    }
    final data = files[path];
    if (data == null) {
      throw const Smb2Exception('Stat failed: STATUS_OBJECT_NAME_NOT_FOUND', 2, Smb2ErrorType.fileNotFound);
    }
    return Smb2Stat(
      type: Smb2FileType.file,
      size: data.length,
      modified: dates[path] ?? defaultDate,
      created: defaultDate,
    );
  }

  Uint8List _read(String path, int offset, int length) {
    reads.add((path, offset, length));
    final data = files[path];
    if (data == null) {
      throw const Smb2Exception(
        'Open failed: Open failed with (0xc0000034) STATUS_OBJECT_NAME_NOT_FOUND.',
        2,
        Smb2ErrorType.fileNotFound,
      );
    }
    if (offset >= data.length) {
      return Uint8List(0);
    }
    return Uint8List.fromList(data.sublist(offset, min(data.length, offset + min(length, maxRead))));
  }

  @override
  Future<List<Smb2DirEntry>> listDirectory(String path) async {
    listed.add(path);
    _maybeFail();
    if (files.containsKey(path)) {
      throw const Smb2Exception(
        'Failed to list directory: Opendir failed with (0xc0000103) STATUS_NOT_A_DIRECTORY.',
        20,
        Smb2ErrorType.notADirectory,
      );
    }
    if (!folders.contains(path)) {
      throw const Smb2Exception(
        'Failed to list directory: Opendir failed with (0xc0000034) STATUS_OBJECT_NAME_NOT_FOUND.',
        2,
        Smb2ErrorType.fileNotFound,
      );
    }
    final prefix = path.isEmpty ? '' : '$path/';
    final children = {
      for (final child in [...folders, ...files.keys])
        if (child.isNotEmpty && child.startsWith(prefix) && !child.substring(prefix.length).contains('/')) child,
    };
    return [for (final child in children) Smb2DirEntry(name: child.substring(prefix.length), stat: _statOf(child))];
  }

  @override
  Future<Smb2Stat> stat(String path) async {
    _maybeFail();
    return _statOf(path);
  }

  @override
  Future<Uint8List> readFileRange(String path, {int offset = 0, required int length}) async {
    _maybeFail();
    return _read(path, offset, length);
  }

  @override
  Future<T> withFile<T>(String path, FutureOr<T> Function(Smb2File file) body, {int? knownSize}) async {
    _maybeFail();
    fileOpens++;
    final size = _statOf(path).size;
    return body(_FakeFile(this, path, size));
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
  }
}

class _FakeFile extends Fake implements Smb2File {
  _FakeFile(this._pool, this._path, this.size);

  final _FakePool _pool;
  final String _path;

  @override
  final int size;

  @override
  Future<Uint8List> read({int offset = 0, required int length}) async => _pool._read(_path, offset, length);
}

typedef _Connection = ({String server, String share, String? user, String? password, String? domain, int timeout});

Uint8List _bytes(int length) => Uint8List.fromList(List.generate(length, (i) => (i * 7 + i ~/ 256) & 0xff));

NetworkSource _smbSource({
  String host = 'nas.local',
  int? port,
  String share = 'media',
  String rootPath = '/',
  String username = 'alice',
}) => NetworkSource(
  id: 'smb1',
  type: NetworkSourceType.smb,
  name: 'NAS',
  host: host,
  port: port,
  share: share,
  rootPath: rootPath,
  username: username,
);

void main() {
  group('SmbFileSystem helpers', () {
    test('normalizes paths inside the share', () {
      expect(SmbFileSystem.normalizePath(''), '/');
      expect(SmbFileSystem.normalizePath('/'), '/');
      expect(SmbFileSystem.normalizePath('photos'), '/photos');
      expect(SmbFileSystem.normalizePath('/photos/2026/'), '/photos/2026');
      expect(SmbFileSystem.normalizePath('//photos//./2026'), '/photos/2026');
      expect(SmbFileSystem.normalizePath(r'\photos\2026'), '/photos/2026');
      expect(SmbFileSystem.normalizePath('/photos/../../etc'), '/etc');
      expect(SmbFileSystem.smbPathOf('/'), '');
      expect(SmbFileSystem.smbPathOf('/photos/a b.jpg'), 'photos/a b.jpg');
    });

    test('builds the server address with its port', () {
      expect(SmbFileSystem.serverAddressOf('nas.local', null), 'nas.local:445');
      expect(SmbFileSystem.serverAddressOf(' nas.local ', 1445), 'nas.local:1445');
      expect(SmbFileSystem.serverAddressOf('192.168.1.10:1445', null), '192.168.1.10:1445');
      expect(SmbFileSystem.serverAddressOf('192.168.1.10:1445', 2445), '192.168.1.10:2445');
      expect(SmbFileSystem.serverAddressOf('smb://nas.local/media', null), 'nas.local:445');
      expect(SmbFileSystem.serverAddressOf(r'\\NAS\media', null), 'NAS:445');
      expect(SmbFileSystem.serverAddressOf('fe80::1', null), '[fe80::1]:445');
      expect(SmbFileSystem.serverAddressOf('[::1]:1445', null), '[::1]:1445');
      expect(SmbFileSystem.serverAddressOf('[::1]', 1445), '[::1]:1445');
      expect(SmbFileSystem.hostOf('smb://nas.local:1445/media'), 'nas.local');
      expect(SmbFileSystem.hostOf('  '), '');
    });

    test('cleans the share name and splits the domain from the user name', () {
      expect(SmbFileSystem.shareNameOf(' /media/ '), 'media');
      expect(SmbFileSystem.shareNameOf(r'\Photos'), 'Photos');
      expect(SmbFileSystem.splitUserName(''), (null, null));
      expect(SmbFileSystem.splitUserName(' alice '), ('alice', null));
      expect(SmbFileSystem.splitUserName(r'WORKGROUP\alice'), ('alice', 'WORKGROUP'));
      expect(SmbFileSystem.splitUserName('alice@example.com'), ('alice@example.com', null));
    });

    // The messages below are the ones dart_smb2 and libsmb2 gave against Samba
    NetworkFileSystemException describe(String message, {Smb2ErrorType type = Smb2ErrorType.unknown, String? path}) =>
        SmbFileSystem.describeError(
          Smb2Exception(message, null, type),
          server: 'nas.local',
          share: 'media',
          path: path,
          connecting: path == null,
        );

    test('tells a refused logon', () {
      final wrongPassword = describe(
        'Worker failed to start: Smb2Exception(Smb2ErrorType.auth, errno=111): Connect failed: Session setup failed '
        'with (0xc000006d) STATUS_LOGON_FAILURE',
      );
      expect(wrongPassword.isAuthentication, isTrue);
      expect(wrongPassword.isNotFound, isFalse);

      // Samba takes an unknown user as a guest, then refuses the share to it
      final unknownUser = describe(
        'Worker failed to start: Smb2Exception(Smb2ErrorType.accessDenied, errno=13): Connect failed: Tree Connect '
        'failed with (0xc0000022) STATUS_ACCESS_DENIED. ',
      );
      expect(unknownUser.isAuthentication, isTrue);

      // Once connected, a refused file is not about the credentials
      final deniedFile = describe(
        'Open failed: STATUS_ACCESS_DENIED',
        type: Smb2ErrorType.accessDenied,
        path: '/x.jpg',
      );
      expect(deniedFile.isAuthentication, isFalse);
      expect(deniedFile.message, contains('media/x.jpg'));
    });

    test('tells a missing share, path or folder', () {
      final share = describe(
        'Worker failed to start: Smb2Exception(Smb2ErrorType.fileNotFound, errno=2): Connect failed: Tree Connect '
        'failed with (0xc00000cc) STATUS_BAD_NETWORK_NAME. ',
      );
      expect(share.isNotFound, isTrue);
      expect(share.message, contains('"media"'));

      final file = describe(
        'Stat failed: STATUS_OBJECT_NAME_NOT_FOUND',
        type: Smb2ErrorType.fileNotFound,
        path: '/nope.jpg',
      );
      expect(file.isNotFound, isTrue);
      expect(file.isAuthentication, isFalse);
      expect(file.message, contains('media/nope.jpg'));

      final notFolder = describe(
        'Failed to list directory: Opendir failed with (0xc0000103) STATUS_NOT_A_DIRECTORY.',
        type: Smb2ErrorType.notADirectory,
        path: '/a.mp4',
      );
      expect(notFolder.message, contains('not a folder'));
    });

    test('tells an unreachable server', () {
      final refused = describe(
        'Worker failed to start: Smb2Exception(Smb2ErrorType.connection, errno=0): Connect failed: smb2_service '
        'failed with : Socket connect failed with 111\n',
      );
      expect(refused.isAuthentication, isFalse);
      expect(refused.message, startsWith('Cannot reach nas.local'));

      final unknownHost = describe(
        'Worker failed to start: Smb2Exception(Smb2ErrorType.unknown, errno=0): Connect failed: Invalid '
        'address:nas.local  Can not resolve into IPv4/v6.',
      );
      expect(unknownHost.message, 'Cannot find the server nas.local');

      final silent = describe(
        'Worker failed to start: Smb2Exception(Smb2ErrorType.timeout, errno=0): Connect failed: Timeout expired and '
        'no connection exists\n',
      );
      expect(silent.message, contains('did not answer in time'));

      final other = describe('Read failed: something odd', path: '/a.mp4');
      expect(other.message, 'nas.local: Read failed: something odd');
    });

    test('tells a session the server ended', () {
      expect(SmbFileSystem.isSessionLost(const Smb2Exception('Stat failed: STATUS_USER_SESSION_DELETED')), isTrue);
      expect(SmbFileSystem.isSessionLost(const Smb2Exception('Stat failed: STATUS_NETWORK_SESSION_EXPIRED')), isTrue);
      expect(SmbFileSystem.isSessionLost(const Smb2Exception('Stat failed: STATUS_OBJECT_NAME_NOT_FOUND')), isFalse);
    });
  });

  group('SmbFileSystem', () {
    late _FakePool pool;
    late List<_Connection> connections;

    Future<Smb2Pool> connect({
      required String server,
      required String share,
      String? user,
      String? password,
      String? domain,
      required int timeoutSeconds,
    }) async {
      connections.add((
        server: server,
        share: share,
        user: user,
        password: password,
        domain: domain,
        timeout: timeoutSeconds,
      ));
      return pool;
    }

    Future<SmbFileSystem> open({NetworkSource? source, String? password = 'secret', int? maxRead}) {
      if (maxRead != null) {
        pool = _FakePool(maxRead: maxRead)
          ..files.addAll(pool.files)
          ..folders.addAll(pool.folders);
      }
      return SmbFileSystem.open(source ?? _smbSource(), password, connect: connect);
    }

    setUp(() {
      connections = [];
      pool = _FakePool()
        ..folders.addAll(['Sub', 'sub2', 'photos', 'photos/2026'])
        ..files.addAll({
          'b.jpg': _bytes(10),
          'A.mp4': _bytes(5000),
          'c.JPG': _bytes(20),
          'photos/x.jpg': _bytes(30),
          'photos/2026/y.mp4': _bytes(40),
        })
        ..dates['c.JPG'] = DateTime.utc(1970);
    });

    test('connects with the source settings and lists its start folder once', () async {
      final fileSystem = await open(
        source: _smbSource(
          host: 'smb://nas.local/',
          port: 1445,
          share: '/media/',
          rootPath: '/photos/',
          username: r'HOME\alice',
        ),
      );
      expect(connections, hasLength(1));
      final connection = connections.single;
      expect(connection.server, 'nas.local:1445');
      expect(connection.share, 'media');
      expect(connection.user, 'alice');
      expect(connection.domain, 'HOME');
      expect(connection.password, 'secret');
      expect(connection.timeout, SmbFileSystem.defaultTimeoutSeconds);
      expect(pool.listed, ['photos']);
      expect(fileSystem.source.id, 'smb1');
    });

    test('logs on anonymously without user name nor password', () async {
      await open(
        source: _smbSource(username: ''),
        password: '',
      );
      expect(connections.single.user, isNull);
      expect(connections.single.password, isNull);
    });

    test('refuses a source that is not SMB or misses its server or share', () async {
      const webdav = NetworkSource(id: 'w', type: NetworkSourceType.webdav, name: 'W', host: 'nas.local');
      await expectLater(open(source: webdav), throwsArgumentError);
      await expectLater(open(source: _smbSource(share: ' / ')), throwsA(isA<NetworkFileSystemException>()));
      await expectLater(open(source: _smbSource(host: ' ')), throwsA(isA<NetworkFileSystemException>()));
      expect(connections, isEmpty);
    });

    test('turns a refused logon into an authentication failure', () async {
      Future<Smb2Pool> refuse({
        required String server,
        required String share,
        String? user,
        String? password,
        String? domain,
        required int timeoutSeconds,
      }) => Future.error(
        const Smb2Exception(
          'Worker failed to start: Smb2Exception(Smb2ErrorType.auth, errno=111): Connect failed: Session setup '
          'failed with (0xc000006d) STATUS_LOGON_FAILURE',
        ),
      );
      await expectLater(
        SmbFileSystem.open(_smbSource(), 'wrong', connect: refuse),
        throwsA(isA<NetworkFileSystemException>().having((e) => e.isAuthentication, 'isAuthentication', isTrue)),
      );
    });

    test('closes the connection when the start folder is missing', () async {
      await expectLater(
        open(source: _smbSource(rootPath: '/nope')),
        throwsA(isA<NetworkFileSystemException>().having((e) => e.isNotFound, 'isNotFound', isTrue)),
      );
      expect(pool.disconnects, 1);
    });

    test('gives up on a server that never answers, and closes the late connection', () async {
      final previousGrace = SmbFileSystem.connectGrace;
      SmbFileSystem.connectGrace = const Duration(milliseconds: 50);
      addTearDown(() => SmbFileSystem.connectGrace = previousGrace);
      final answer = Completer<Smb2Pool>();
      Future<Smb2Pool> hang({
        required String server,
        required String share,
        String? user,
        String? password,
        String? domain,
        required int timeoutSeconds,
      }) => answer.future;

      await expectLater(
        SmbFileSystem.open(_smbSource(), 'secret', connect: hang, timeoutSeconds: 0),
        throwsA(isA<NetworkFileSystemException>().having((e) => e.message, 'message', contains('did not answer'))),
      );
      answer.complete(pool);
      await pumpEventQueue();
      expect(pool.disconnects, 1);
    });

    test('lists folders first, then files, by name without case', () async {
      final fileSystem = await open();
      final entries = await fileSystem.list('/');
      expect(entries.map((e) => e.path), ['/photos', '/Sub', '/sub2', '/A.mp4', '/b.jpg', '/c.JPG']);
      expect(entries.map((e) => e.isDirectory), [true, true, true, false, false, false]);
      expect(entries.every((e) => e.sourceId == 'smb1'), isTrue);

      final folder = entries.first;
      expect(folder.size, isNull);
      expect(folder.name, 'photos');

      final video = entries[3];
      expect(video.size, 5000);
      expect(video.modified, _FakePool.defaultDate);
      expect(video.isVideo, isTrue);
      expect(video.guessedMimeType, 'video/mp4');

      // A date the server does not know comes as the epoch
      expect(entries.last.modified, isNull);

      final nested = await fileSystem.list('/photos/');
      expect(nested.map((e) => e.path), ['/photos/2026', '/photos/x.jpg']);
      expect((await fileSystem.list('photos/2026')).single.path, '/photos/2026/y.mp4');
    });

    test('stats files and folders', () async {
      final fileSystem = await open();
      final file = await fileSystem.stat('/photos/x.jpg');
      expect(file.isDirectory, isFalse);
      expect(file.size, 30);
      expect(file.path, '/photos/x.jpg');

      final root = await fileSystem.stat('/');
      expect(root.isDirectory, isTrue);
      expect(root.path, '/');

      await expectLater(
        fileSystem.stat('/nope.jpg'),
        throwsA(isA<NetworkFileSystemException>().having((e) => e.isNotFound, 'isNotFound', isTrue)),
      );
      await expectLater(
        fileSystem.list('/A.mp4'),
        throwsA(isA<NetworkFileSystemException>().having((e) => e.message, 'message', contains('not a folder'))),
      );
    });

    test('reads a window in one call when the server gives it whole', () async {
      final fileSystem = await open();
      pool.reads.clear();
      final bytes = await fileSystem.readRange('/A.mp4', 100, 200);
      expect(bytes, pool.files['A.mp4']!.sublist(100, 300));
      expect(pool.reads, [('A.mp4', 100, 200)]);
      expect(pool.fileOpens, 0);
    });

    test('reads the end of a file, and nothing past it', () async {
      final fileSystem = await open();
      final data = pool.files['A.mp4']!;
      expect(await fileSystem.readRange('/A.mp4', 4990, 100), data.sublist(4990));
      expect(await fileSystem.readRange('/A.mp4', 5000, 100), isEmpty);
      expect(await fileSystem.readRange('/A.mp4', 9000, 100), isEmpty);
      expect(await fileSystem.readRange('/A.mp4', 0, 0), isEmpty);
      expect(() => fileSystem.readRange('/A.mp4', -1, 10), throwsRangeError);
      expect(() => fileSystem.readRange('/A.mp4', 0, -1), throwsRangeError);
    });

    test('goes on reading on one open file when the server gives less at once', () async {
      final fileSystem = await open(maxRead: 64);
      pool.reads.clear();
      final bytes = await fileSystem.readRange('/A.mp4', 10, 1000);
      expect(bytes, pool.files['A.mp4']!.sublist(10, 1010));
      expect(pool.fileOpens, 1);
      expect(pool.reads.first, ('A.mp4', 10, 1000));
      expect(pool.reads.skip(1).every((read) => read.$3 <= 1000 - 64), isTrue);
      // Never past the window
      expect(pool.reads.map((read) => read.$2 + min(read.$3, 64)).reduce(max), 1010);
    });

    test('asks a large window in parts', () async {
      pool.files['big.mp4'] = _bytes(SmbFileSystem.maxReadChunk * 2 + 100);
      final fileSystem = await open();
      pool.reads.clear();
      final bytes = await fileSystem.readRange('/big.mp4', 50, SmbFileSystem.maxReadChunk * 2);
      expect(bytes.length, SmbFileSystem.maxReadChunk * 2);
      expect(bytes, pool.files['big.mp4']!.sublist(50, 50 + SmbFileSystem.maxReadChunk * 2));
      expect(pool.reads.every((read) => read.$3 <= SmbFileSystem.maxReadChunk), isTrue);
    });

    test('reports a missing file to read as not found', () async {
      final fileSystem = await open();
      await expectLater(
        fileSystem.readRange('/nope.mp4', 0, 16),
        throwsA(isA<NetworkFileSystemException>().having((e) => e.isNotFound, 'isNotFound', isTrue)),
      );
    });

    test('maps a dropped connection that could not be opened again', () async {
      final fileSystem = await open();
      pool.failNext = const Smb2Exception(
        'Worker failed to start: Smb2Exception(Smb2ErrorType.connection, errno=0): Connect failed: smb2_service '
        'failed with : Socket connect failed with 111',
      );
      await expectLater(
        fileSystem.list('/'),
        throwsA(isA<NetworkFileSystemException>().having((e) => e.message, 'message', startsWith('Cannot reach'))),
      );
      // The next call goes through
      expect(await fileSystem.list('/'), hasLength(6));
    });

    test('opens a new connection once when the server ended the session', () async {
      final fileSystem = await open();
      final first = pool;
      first.failAlways = const Smb2Exception('Stat failed: STATUS_USER_SESSION_DELETED', 5, Smb2ErrorType.io);
      // The connector hands out a new connection from now on
      pool = _FakePool()
        ..folders.addAll(first.folders)
        ..files.addAll(first.files);
      final second = pool;

      final entries = await Future.wait([fileSystem.stat('/b.jpg'), fileSystem.stat('/A.mp4')]);
      expect(entries.map((e) => e.size), [10, 5000]);
      expect(connections, hasLength(2));
      await pumpEventQueue();
      expect(first.disconnects, 1);

      await fileSystem.list('/');
      expect(second.listed, ['']);
      await fileSystem.close();
      expect(second.disconnects, 1);
    });

    test('reports a session that could not be opened again', () async {
      final fileSystem = await open();
      pool.failAlways = const Smb2Exception('Read failed: STATUS_NETWORK_SESSION_EXPIRED', 5, Smb2ErrorType.io);
      await expectLater(fileSystem.readRange('/A.mp4', 0, 4), throwsA(isA<NetworkFileSystemException>()));
      expect(connections, hasLength(2));
    });

    test('closes once, then refuses the calls', () async {
      final fileSystem = await open();
      await fileSystem.close();
      await fileSystem.close();
      expect(pool.disconnects, 1);
      await expectLater(fileSystem.list('/'), throwsA(isA<NetworkFileSystemException>()));
      await expectLater(fileSystem.stat('/b.jpg'), throwsA(isA<NetworkFileSystemException>()));
      await expectLater(fileSystem.readRange('/b.jpg', 0, 4), throwsA(isA<NetworkFileSystemException>()));
    });
  });

  group('SmbFileSystem.listShares', () {
    late List<({String server, String? user, String? password, String? domain, int timeout})> calls;

    SmbShareEnumerator enumerator(List<Smb2ShareInfo> shares, {Exception? error}) =>
        ({required String server, String? user, String? password, String? domain, required int timeoutSeconds}) async {
          calls.add((server: server, user: user, password: password, domain: domain, timeout: timeoutSeconds));
          if (error != null) {
            throw error;
          }
          return shares;
        };

    setUp(() => calls = []);

    test('gives the disk shares sorted, without the hidden, administrative and printer ones', () async {
      final shares = await SmbFileSystem.listShares(
        _smbSource(host: 'smb://nas.local', port: 1445, share: '', username: r'HOME\alice'),
        'secret',
        connect: enumerator(const [
          Smb2ShareInfo(name: 'photos', type: Smb2ShareType.diskTree),
          Smb2ShareInfo(name: r'IPC$', type: Smb2ShareType.ipc | Smb2ShareType.hidden),
          Smb2ShareInfo(name: r'C$', type: Smb2ShareType.diskTree),
          Smb2ShareInfo(name: 'hidden', type: Smb2ShareType.diskTree | Smb2ShareType.hidden),
          Smb2ShareInfo(name: 'Laser', type: Smb2ShareType.printQueue),
          Smb2ShareInfo(name: 'Media', type: Smb2ShareType.diskTree),
          Smb2ShareInfo(name: 'archive', type: Smb2ShareType.diskTree),
        ]),
        timeoutSeconds: 7,
      );

      expect(shares, ['archive', 'Media', 'photos']);
      expect(calls.single, (server: 'nas.local:1445', user: 'alice', password: 'secret', domain: 'HOME', timeout: 7));
    });

    test('logs on as a guest without a user name nor a password', () async {
      await SmbFileSystem.listShares(_smbSource(username: ''), '', connect: enumerator(const []));

      expect(calls.single.user, isNull);
      expect(calls.single.password, isNull);
      expect(calls.single.server, 'nas.local:445');
    });

    test('reports the errors like a connection', () async {
      await expectLater(
        SmbFileSystem.listShares(
          _smbSource(),
          'wrong',
          connect: enumerator(const [], error: const Smb2Exception('Connect to IPC\$ failed: STATUS_LOGON_FAILURE')),
        ),
        throwsA(
          isA<NetworkFileSystemException>()
              .having((e) => e.isAuthentication, 'isAuthentication', isTrue)
              .having((e) => e.message, 'message', 'nas.local refused the user name or password'),
        ),
      );
      await expectLater(
        SmbFileSystem.listShares(_smbSource(host: ' '), null, connect: enumerator(const [])),
        throwsA(isA<NetworkFileSystemException>()),
      );
      expect(calls, hasLength(1));
    });
  });

  group('SmbFileSystem against Samba', () {
    const host = 'localhost';
    const port = 1445;
    const password = 'testpass';
    final enabled = Platform.environment['IMMUCH_NET_TESTS'] == '1';

    NetworkSource source({String share = 'media', String username = 'tester', String rootPath = '/', int p = port}) =>
        NetworkSource(
          id: 'samba',
          type: NetworkSourceType.smb,
          name: 'Samba',
          host: host,
          port: p,
          share: share,
          rootPath: rootPath,
          username: username,
        );

    late SmbFileSystem fileSystem;

    setUpAll(() async {
      if (!enabled) {
        return;
      }
      debugLibSmb2PathOverride = libsmb2TestPath();
      fileSystem = await SmbFileSystem.open(source(), password);
    });

    tearDownAll(() async {
      if (enabled) {
        await fileSystem.close();
      }
    });

    test('lists the root of the share', () async {
      final entries = await fileSystem.list('/');
      final names = entries.map((e) => e.name).toList();
      expect(names, contains('sub'));
      expect(names, contains('mono-video.mp4'));
      expect(entries.where((e) => e.isImage), isNotEmpty);
      expect(entries.where((e) => e.isVideo), isNotEmpty);

      final folders = entries.takeWhile((e) => e.isDirectory).length;
      expect(entries.skip(folders).every((e) => !e.isDirectory), isTrue, reason: 'folders first');
      final files = entries.skip(folders).map((e) => e.name.toLowerCase()).toList();
      expect(files, [...files]..sort(), reason: 'files by name');

      final video = entries.firstWhere((e) => e.name == 'mono-video.mp4');
      expect(video.path, '/mono-video.mp4');
      expect(video.size, greaterThan(1000));
      expect(video.modified, isNotNull);
      expect(entries.firstWhere((e) => e.name == 'sub').path, '/sub');

      await fileSystem.list('/sub');
    }, skip: !enabled);

    test('stats a file and the root', () async {
      final listed = (await fileSystem.list('/')).firstWhere((e) => e.name == 'mono-video.mp4');
      final file = await fileSystem.stat('/mono-video.mp4');
      expect(file.isDirectory, isFalse);
      expect(file.size, listed.size);
      expect(file.modified, listed.modified);
      expect((await fileSystem.stat('/')).isDirectory, isTrue);
      expect((await fileSystem.stat('/sub')).isDirectory, isTrue);
    }, skip: !enabled);

    test('reads the start of an MP4', () async {
      final head = await fileSystem.readRange('/mono-video.mp4', 0, 16);
      expect(head, hasLength(16));
      expect(ascii.decode(head.sublist(4, 8)), 'ftyp');
    }, skip: !enabled);

    test('reads windows near the end', () async {
      final size = (await fileSystem.stat('/mono-video.mp4')).size!;
      final tail = await fileSystem.readRange('/mono-video.mp4', size - 100, 100);
      expect(tail, hasLength(100));
      final inner = await fileSystem.readRange('/mono-video.mp4', size - 60, 40);
      expect(inner, tail.sublist(40, 80));
      final across = await fileSystem.readRange('/mono-video.mp4', size - 10, 4096);
      expect(across, tail.sublist(90));
      expect(await fileSystem.readRange('/mono-video.mp4', size, 16), isEmpty);
    }, skip: !enabled);

    test('reads a window larger than one request', () async {
      final size = (await fileSystem.stat('/mono-video.mp4')).size!;
      const offset = 1000;
      final length = min(size - offset, SmbFileSystem.maxReadChunk + 300000);
      final window = await fileSystem.readRange('/mono-video.mp4', offset, length);
      expect(window, hasLength(length));
      expect(window.sublist(0, 32), await fileSystem.readRange('/mono-video.mp4', offset, 32));
      expect(window.sublist(length - 32), await fileSystem.readRange('/mono-video.mp4', offset + length - 32, 32));
    }, skip: !enabled);

    test('opens the connection again once it dropped', () async {
      Smb2Pool? opened;
      Future<Smb2Pool> connect({
        required String server,
        required String share,
        String? user,
        String? password,
        String? domain,
        required int timeoutSeconds,
      }) async => opened = await Smb2Pool.connect(
        host: server,
        share: share,
        user: user,
        password: password,
        domain: domain,
        workers: 1,
        timeoutSeconds: timeoutSeconds,
      );
      final own = await SmbFileSystem.open(source(), password, connect: connect);
      addTearDown(own.close);
      poolWorkers(opened!).single.killForTest();
      expect(await own.list('/'), isNotEmpty);
      expect(await own.readRange('/mono-video.mp4', 4, 4), ascii.encode('ftyp'));
    }, skip: !enabled);

    test('reports a wrong password or an unknown user as an authentication failure', () async {
      await expectLater(
        SmbFileSystem.open(source(), 'wrong'),
        throwsA(isA<NetworkFileSystemException>().having((e) => e.isAuthentication, 'isAuthentication', isTrue)),
      );
      await expectLater(
        SmbFileSystem.open(source(username: 'nobody'), 'wrong'),
        throwsA(isA<NetworkFileSystemException>().having((e) => e.isAuthentication, 'isAuthentication', isTrue)),
      );
    }, skip: !enabled);

    test('reports a missing path, folder or share as not found', () async {
      final notFound = throwsA(isA<NetworkFileSystemException>().having((e) => e.isNotFound, 'isNotFound', isTrue));
      await expectLater(fileSystem.stat('/nope.jpg'), notFound);
      await expectLater(fileSystem.stat('/nope/x.jpg'), notFound);
      await expectLater(fileSystem.list('/nope'), notFound);
      await expectLater(fileSystem.readRange('/nope.mp4', 0, 16), notFound);
      await expectLater(SmbFileSystem.open(source(rootPath: '/nope'), password), notFound);
      await expectLater(SmbFileSystem.open(source(share: 'nope'), password), notFound);
    }, skip: !enabled);

    test('lists the shares of the server', () async {
      final shares = await SmbFileSystem.listShares(source(share: ''), password);
      expect(shares, contains('media'));
      expect(shares.where((name) => name.endsWith(r'$')), isEmpty);
    }, skip: !enabled);

    test('reports a server that does not listen', () async {
      await expectLater(
        SmbFileSystem.open(source(p: 1446), password),
        throwsA(
          isA<NetworkFileSystemException>()
              .having((e) => e.isAuthentication, 'isAuthentication', isFalse)
              .having((e) => e.message, 'message', startsWith('Cannot reach localhost:1446')),
        ),
      );
    }, skip: !enabled);
  });
}
