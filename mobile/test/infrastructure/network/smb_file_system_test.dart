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
import 'package:dart_smb2/src/pool/worker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/media_bridge.service.dart';
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
  int handleCloses = 0;
  int disconnects = 0;

  /// The handles open, with their path
  final Map<int, String> openHandles = {};
  int _nextHandle = 1;

  /// Called before each read of an open file, may hold it
  Future<void> Function(String path)? beforeRead;

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
  Future<(Smb2PoolHandle, int)> openFileWithSize(String path) async {
    _maybeFail();
    fileOpens++;
    if (!files.containsKey(path)) {
      throw const Smb2Exception(
        'Open failed: Open failed with (0xc0000034) STATUS_OBJECT_NAME_NOT_FOUND.',
        2,
        Smb2ErrorType.fileNotFound,
      );
    }
    final handle = Smb2PoolHandle(_FakeWorker(), _nextHandle++, path);
    openHandles[handle.id] = path;
    return (handle, files[path]!.length);
  }

  @override
  Future<Uint8List> readFromHandle(Smb2PoolHandle handle, {int offset = 0, required int length}) async {
    _maybeFail();
    if (!openHandles.containsKey(handle.id)) {
      throw const Smb2Exception('Invalid handle');
    }
    await beforeRead?.call(handle.path);
    return _read(handle.path, offset, length);
  }

  @override
  Future<void> closeHandle(Smb2PoolHandle handle) async {
    handle.markClosed();
    if (openHandles.remove(handle.id) != null) {
      handleCloses++;
    }
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
  }
}

class _FakeWorker extends Fake implements Worker {}

/// Counts the reads the media bridge asks of a file system
class _CountingFileSystem implements NetworkFileSystem {
  _CountingFileSystem(this.inner);

  final NetworkFileSystem inner;
  int reads = 0;

  @override
  NetworkSource get source => inner.source;

  @override
  Future<List<NetworkEntry>> list(String path) => inner.list(path);

  @override
  Future<NetworkEntry> stat(String path) => inner.stat(path);

  @override
  Future<Uint8List> readRange(String path, int offset, int length) {
    reads++;
    return inner.readRange(path, offset, length);
  }

  @override
  Future<void> close() => inner.close();
}

/// A TCP relay to [port] on this machine that holds every packet [delay] long each way, like a Wi-Fi network between
/// the phone and its NAS
class _LatencyProxy {
  _LatencyProxy._(this._server);

  final ServerSocket _server;
  final _sockets = <Socket>[];

  int get port => _server.port;

  static Future<_LatencyProxy> start(int port, Duration delay) async {
    final proxy = _LatencyProxy._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));
    proxy._server.listen((client) async {
      final Socket upstream;
      try {
        upstream = await Socket.connect(InternetAddress.loopbackIPv4, port);
      } catch (_) {
        client.destroy();
        return;
      }
      proxy._sockets.addAll([client, upstream]);
      for (final socket in [client, upstream]) {
        socket.setOption(SocketOption.tcpNoDelay, true);
        // A side that resets the connection fails the writes to it: nothing to report
        unawaited(socket.done.then<void>((_) {}, onError: (Object _) {}));
      }
      void relay(Socket from, Socket to) => from.listen(
        (data) => Future<void>.delayed(delay, () {
          try {
            to.add(data);
          } catch (_) {
            // The other side is gone
          }
        }),
        onDone: () => Future<void>.delayed(delay, to.destroy),
        onError: (Object _) => to.destroy(),
        cancelOnError: true,
      );
      relay(client, upstream);
      relay(upstream, client);
    });
    return proxy;
  }

  Future<void> close() async {
    await _server.close();
    for (final socket in _sockets) {
      socket.destroy();
    }
  }
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

    test('logs on with an empty password when a user name is given (Freebox Server)', () async {
      await open(
        source: _smbSource().copyWith(username: 'freebox'),
        password: '',
      );
      expect(connections.single.user, 'freebox');
      expect(connections.single.password, '');
    });

    test('logs on with an empty password when the password is missing but a user name is given', () async {
      await open(source: _smbSource().copyWith(username: 'freebox'), password: null);
      expect(connections.single.password, '');
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

    test('reads a window in one request when the server gives it whole', () async {
      final fileSystem = await open();
      pool.reads.clear();
      final bytes = await fileSystem.readRange('/A.mp4', 100, 200);
      expect(bytes, pool.files['A.mp4']!.sublist(100, 300));
      expect(pool.reads, [('A.mp4', 100, 200)]);
      expect(pool.fileOpens, 1);
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

    group('open files', () {
      late Duration previousIdle;

      setUp(() {
        previousIdle = SmbFileSystem.openFileIdle;
        pool.files['v1.mp4'] = _bytes(100000);
      });

      tearDown(() => SmbFileSystem.openFileIdle = previousIdle);

      test('reads in sequence on one open file, and a seek reads on it as well', () async {
        final fileSystem = await open();
        final data = pool.files['v1.mp4']!;
        for (var offset = 0; offset < 30000; offset += 10000) {
          expect(await fileSystem.readRange('/v1.mp4', offset, 10000), data.sublist(offset, offset + 10000));
        }
        expect(await fileSystem.readRange('/v1.mp4', 90000, 10000), data.sublist(90000));
        expect(await fileSystem.readRange('/v1.mp4', 5, 10), data.sublist(5, 15));
        expect(pool.fileOpens, 1);
        expect(pool.handleCloses, 0);
        expect(fileSystem.fileOpens, 1);
      });

      test('reads of the same file at the same time open it once', () async {
        final fileSystem = await open();
        final data = pool.files['v1.mp4']!;
        final windows = await Future.wait([
          for (var offset = 0; offset < 50000; offset += 10000) fileSystem.readRange('/v1.mp4', offset, 10000),
        ]);
        expect(windows.expand((window) => window), data.sublist(0, 50000));
        expect(pool.fileOpens, 1);
      });

      test('closes a file not read for a while', () async {
        SmbFileSystem.openFileIdle = const Duration(milliseconds: 50);
        final fileSystem = await open();
        await fileSystem.readRange('/v1.mp4', 0, 10);
        await fileSystem.readRange('/b.jpg', 0, 10);
        expect(pool.openHandles, hasLength(2));
        for (var i = 0; i < 100 && pool.openHandles.isNotEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(pool.openHandles, isEmpty);
        expect(fileSystem.openFileCount, 0);

        await fileSystem.readRange('/v1.mp4', 10, 10);
        expect(pool.fileOpens, 3);
      });

      test('keeps at most four files open, the least recently read closed first', () async {
        final fileSystem = await open();
        final paths = ['/v1.mp4', '/A.mp4', '/b.jpg', '/c.JPG', '/photos/x.jpg', '/photos/2026/y.mp4'];
        for (final path in paths) {
          await fileSystem.readRange(path, 0, 4);
        }
        await pumpEventQueue();
        expect(fileSystem.openFileCount, SmbFileSystem.maxOpenFiles);
        expect(pool.openHandles.values.toSet(), {'b.jpg', 'c.JPG', 'photos/x.jpg', 'photos/2026/y.mp4'});

        // Still open
        await fileSystem.readRange('/b.jpg', 4, 4);
        expect(pool.fileOpens, paths.length);
      });

      test('closes the open files with the connection', () async {
        final fileSystem = await open();
        await fileSystem.readRange('/v1.mp4', 0, 10);
        await fileSystem.readRange('/A.mp4', 0, 10);
        await fileSystem.close();
        await pumpEventQueue();
        expect(pool.openHandles, isEmpty);
        expect(pool.disconnects, 1);
      });

      test('opens a file again when its handle was lost', () async {
        final fileSystem = await open();
        await fileSystem.readRange('/v1.mp4', 0, 10);
        // A worker replaced after a transport failure forgets the handles of the old one
        pool.openHandles.clear();
        expect(await fileSystem.readRange('/v1.mp4', 10, 10), pool.files['v1.mp4']!.sublist(10, 20));
        expect(pool.fileOpens, 2);
      });

      test('a failed read does not keep its file open', () async {
        final fileSystem = await open();
        await fileSystem.readRange('/v1.mp4', 0, 10);
        pool.failAlways = const Smb2Exception('Read failed: something odd');
        await expectLater(fileSystem.readRange('/v1.mp4', 10, 10), throwsA(isA<NetworkFileSystemException>()));
        pool.failAlways = null;
        await pumpEventQueue();
        expect(fileSystem.openFileCount, 0);
        expect(await fileSystem.readRange('/v1.mp4', 10, 10), pool.files['v1.mp4']!.sublist(10, 20));
      });
    });

    group('stream connection', () {
      late List<_FakePool> pools;
      late Duration previousHold;

      // The first connection is [pool], each next one a new pool of the same files
      Future<SmbFileSystem> openWithPools() {
        pools = [];
        Future<Smb2Pool> connectNew({
          required String server,
          required String share,
          String? user,
          String? password,
          String? domain,
          required int timeoutSeconds,
        }) async {
          final next = pools.isEmpty
              ? pool
              : (_FakePool()
                  ..files.addAll(pool.files)
                  ..folders.addAll(pool.folders));
          pools.add(next);
          return next;
        }

        return SmbFileSystem.open(_smbSource(), 'secret', connect: connectNew);
      }

      setUp(() {
        previousHold = SmbFileSystem.streamHoldIdle;
        pool.files['v1.mp4'] = _bytes(100000);
        pool.files['v2.mkv'] = _bytes(100000);
        pool.files['pano.jpg'] = _bytes(100000);
      });

      tearDown(() => SmbFileSystem.streamHoldIdle = previousHold);

      test('a video read in sequence moves to a connection of its own, the listings stay on the first', () async {
        final fileSystem = await openWithPools();
        final data = pool.files['v1.mp4']!;
        final read = BytesBuilder();
        read.add(await fileSystem.readRange('/v1.mp4', 0, 10000));
        expect(pools, hasLength(1));
        // In sequence: the stream connection opens meanwhile
        read.add(await fileSystem.readRange('/v1.mp4', 10000, 10000));
        await pumpEventQueue();
        expect(pools, hasLength(2));
        expect(fileSystem.hasStreamConnection, isTrue);
        final general = pools[0];
        final stream = pools[1];

        for (var offset = 20000; offset < 60000; offset += 10000) {
          read.add(await fileSystem.readRange('/v1.mp4', offset, 10000));
        }
        expect(read.takeBytes(), data.sublist(0, 60000));
        expect(fileSystem.streamedPath, '/v1.mp4');
        expect(stream.reads.map((r) => r.$2), [20000, 30000, 40000, 50000]);
        expect(stream.fileOpens, 1);
        // The file was closed on the first connection
        await pumpEventQueue();
        expect(general.openHandles, isEmpty);

        // A seek stays on the stream connection
        expect(await fileSystem.readRange('/v1.mp4', 90000, 100), data.sublist(90000, 90100));
        expect(stream.reads.last, ('v1.mp4', 90000, 100));

        // Listings, stats and photos go to the first connection
        await fileSystem.list('/');
        await fileSystem.stat('/b.jpg');
        await fileSystem.readRange('/b.jpg', 0, 5);
        await fileSystem.readRange('/b.jpg', 5, 5);
        expect(general.listed, ['', '']);
        expect(stream.listed, isEmpty);
        expect(stream.reads.where((r) => r.$1 != 'v1.mp4'), isEmpty);

        await fileSystem.close();
        expect(general.disconnects, 1);
        expect(stream.disconnects, 1);
      });

      test('the photos read in sequence stay on the first connection', () async {
        final fileSystem = await openWithPools();
        for (var offset = 0; offset < 100000; offset += 10000) {
          await fileSystem.readRange('/pano.jpg', offset, 10000);
        }
        await pumpEventQueue();
        expect(pools, hasLength(1));
        expect(fileSystem.streamedPath, isNull);
      });

      test('one video at a time has the stream connection, another takes it once the first is idle', () async {
        final fileSystem = await openWithPools();
        Future<void> readTwice(String path, int from) async {
          await fileSystem.readRange(path, from, 1000);
          await fileSystem.readRange(path, from + 1000, 1000);
        }

        await readTwice('/v1.mp4', 0);
        await pumpEventQueue();
        await readTwice('/v1.mp4', 2000);
        expect(fileSystem.streamedPath, '/v1.mp4');
        final stream = pools[1];

        // The first video was read just now: the second stays on the first connection
        await readTwice('/v2.mkv', 0);
        await readTwice('/v2.mkv', 2000);
        expect(fileSystem.streamedPath, '/v1.mp4');
        expect(stream.reads.where((r) => r.$1 == 'v2.mkv'), isEmpty);

        SmbFileSystem.streamHoldIdle = Duration.zero;
        await fileSystem.readRange('/v2.mkv', 4000, 1000);
        expect(fileSystem.streamedPath, '/v2.mkv');
        expect(stream.reads.last, ('v2.mkv', 4000, 1000));
        // The first video, read again, goes to the first connection
        await fileSystem.readRange('/v1.mp4', 0, 1000);
        expect(pools[0].reads.last, ('v1.mp4', 0, 1000));
        expect(pools, hasLength(2));
      });

      test('the reads share the first connection when the stream one cannot open', () async {
        var calls = 0;
        Future<Smb2Pool> failSecond({
          required String server,
          required String share,
          String? user,
          String? password,
          String? domain,
          required int timeoutSeconds,
        }) async {
          calls++;
          if (calls > 1) {
            throw const Smb2Exception('Worker failed to start: too many connections');
          }
          return pool;
        }

        final fileSystem = await SmbFileSystem.open(_smbSource(), 'secret', connect: failSecond);
        final data = pool.files['v1.mp4']!;
        for (var offset = 0; offset < 50000; offset += 10000) {
          expect(await fileSystem.readRange('/v1.mp4', offset, 10000), data.sublist(offset, offset + 10000));
          await pumpEventQueue();
        }
        expect(calls, 2);
        expect(fileSystem.hasStreamConnection, isFalse);
        expect(pool.fileOpens, 1);
      });

      test('a stream connection the server ended is opened again', () async {
        final fileSystem = await openWithPools();
        await fileSystem.readRange('/v1.mp4', 0, 1000);
        await fileSystem.readRange('/v1.mp4', 1000, 1000);
        await pumpEventQueue();
        await fileSystem.readRange('/v1.mp4', 2000, 1000);
        final stream = pools[1];
        stream.failAlways = const Smb2Exception('Read failed: STATUS_USER_SESSION_DELETED', 5, Smb2ErrorType.io);
        expect(await fileSystem.readRange('/v1.mp4', 3000, 1000), pool.files['v1.mp4']!.sublist(3000, 4000));
        expect(pools, hasLength(3));
        expect(pools[2].reads.single, ('v1.mp4', 3000, 1000));
        await pumpEventQueue();
        expect(stream.disconnects, 1);
        expect(pools[0].disconnects, 0);
      });
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

    test('lists the shares with an empty password when a user name is given', () async {
      await SmbFileSystem.listShares(_smbSource(username: 'freebox'), '', connect: enumerator(const []));
      expect(calls.single.user, 'freebox');
      expect(calls.single.password, '');
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

  group('Smb2ContextLock', () {
    const limit = Duration(seconds: 5);

    test('runs the actions one at a time, in the order they came', () async {
      final events = <String>[];
      Future<int> action(String name, int value) async {
        events.add('$name start');
        await Future<void>.delayed(const Duration(milliseconds: 30));
        events.add('$name end');
        return value;
      }

      final results = await Future.wait([
        Smb2ContextLock.run(() => action('a', 1), limit: limit),
        Smb2ContextLock.run(() => action('b', 2), limit: limit),
        Smb2ContextLock.run(() => action('c', 3), limit: limit),
      ]);

      expect(results, [1, 2, 3]);
      expect(events, ['a start', 'a end', 'b start', 'b end', 'c start', 'c end']);
    });

    test('an action that runs again under the lock it holds goes on at once', () async {
      final events = <String>[];
      final outer = Smb2ContextLock.run(() async {
        events.add('outer');
        // A pool that spawns its worker inside the connect of the file system
        final inner = await Smb2ContextLock.run(() async {
          events.add('inner');
          return 2;
        }, limit: limit);
        return inner + 1;
      }, limit: limit);
      final next = Smb2ContextLock.run(() async => events.add('next'), limit: limit);

      expect(await outer.timeout(const Duration(seconds: 1)), 3);
      await next;
      expect(events, ['outer', 'inner', 'next']);
    });

    test('an action that fails, or runs past its limit, no longer holds the others', () async {
      await expectLater(
        Smb2ContextLock.run<void>(() async => throw StateError('no context'), limit: limit),
        throwsStateError,
      );
      expect(await Smb2ContextLock.run(() async => 1, limit: limit).timeout(const Duration(seconds: 1)), 1);

      final never = Completer<void>();
      unawaited(Smb2ContextLock.run(() => never.future, limit: const Duration(milliseconds: 100)));
      final watch = Stopwatch()..start();
      expect(await Smb2ContextLock.run(() async => 2, limit: limit).timeout(const Duration(seconds: 2)), 2);
      expect(watch.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 90)));
      never.complete();
    });

    test('the limit counts from the start of the action, not from its call', () async {
      final events = <String>[];
      final first = Smb2ContextLock.run(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        events.add('first');
      }, limit: limit);
      // Queued behind the first one for 300 ms, it runs for 200 ms within its limit of 250 ms
      final second = Smb2ContextLock.run(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        events.add('second');
      }, limit: const Duration(milliseconds: 250));
      final third = Smb2ContextLock.run(() async => events.add('third'), limit: limit);

      await Future.wait([first, second, third]);
      expect(events, ['first', 'second', 'third']);
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

  // Streams videos of the Samba test server through the media bridge the way the players read them, straight and
  // through a relay that adds the latency of a Wi-Fi network, alone and while the browser loads photos and lists the
  // folder, and prints the throughput and the number of files opened on the server.
  group('SmbFileSystem streaming through the media bridge against Samba', () {
    final enabled = Platform.environment['IMMUCH_NET_TESTS'] == '1';
    late LocalMediaBridge bridge;
    final proxies = <_LatencyProxy>[];

    setUpAll(() {
      if (enabled) {
        debugLibSmb2PathOverride = libsmb2TestPath();
      }
    });

    setUp(() async {
      bridge = LocalMediaBridge();
      await bridge.start();
    });

    tearDown(() async {
      await bridge.stop();
      for (final proxy in proxies) {
        await proxy.close();
      }
      proxies.clear();
    });

    Future<SmbFileSystem> connect({Duration? latency}) async {
      var port = 1445;
      if (latency != null) {
        final proxy = await _LatencyProxy.start(port, latency);
        proxies.add(proxy);
        port = proxy.port;
      }
      return SmbFileSystem.open(
        NetworkSource(
          id: 'samba-${latency?.inMilliseconds ?? 0}',
          type: NetworkSourceType.smb,
          name: 'Samba',
          host: 'localhost',
          port: port,
          share: 'media',
          username: 'tester',
        ),
        'testpass',
      );
    }

    Future<Uint8List> get(Uri url, {String? range}) async {
      final client = HttpClient();
      try {
        final request = await client.getUrl(url);
        if (range != null) {
          request.headers.set(HttpHeaders.rangeHeader, range);
        }
        final response = await request.close();
        final body = BytesBuilder(copy: false);
        await response.forEach(body.add);
        return body.takeBytes();
      } finally {
        client.close();
      }
    }

    Future<void> measure(String path, {Duration? latency, bool browsing = false}) async {
      final smb = await connect(latency: latency);
      final counted = _CountingFileSystem(smb);
      bridge.register(counted);
      addTearDown(smb.close);
      final expected = await smb.readRange(path, 0, (await smb.stat(path)).size!);
      final opensBefore = smb.fileOpens;

      // The browser meanwhile: photos loaded whole through the bridge, and the folder listed
      var browsingDone = false;
      var photos = 0;
      final browser = browsing
          ? () async {
              while (!browsingDone) {
                await get(bridge.urlFor(smb.source.id, '/mono-photo.jpg'));
                await smb.list('/');
                photos++;
              }
            }()
          : Future<void>.value();

      final watch = Stopwatch()..start();
      // As the players do: the first two bytes, then the file from its start to its end
      await get(bridge.urlFor(smb.source.id, path), range: 'bytes=0-1');
      final body = await get(bridge.urlFor(smb.source.id, path), range: 'bytes=0-');
      watch.stop();
      browsingDone = true;
      await browser;

      expect(body, expected);
      final megabytes = body.length / (1024 * 1024);
      final seconds = watch.elapsedMicroseconds / 1e6;
      // ignore: avoid_print
      print(
        'MEASURE $path${latency == null ? '' : ' latency ${latency.inMilliseconds} ms each way'}'
        '${browsing ? ' while browsing ($photos photos)' : ''}: ${megabytes.toStringAsFixed(1)} MiB in '
        '${seconds.toStringAsFixed(2)} s = ${(megabytes / seconds).toStringAsFixed(1)} MiB/s, '
        '${counted.reads} reads asked by the bridge, ${smb.fileOpens - opensBefore} files opened on the server, '
        'stream connection ${smb.hasStreamConnection}',
      );
    }

    test('mono-video.mp4 straight', () => measure('/mono-video.mp4'), skip: !enabled);

    test('stereo-tb-video.mp4 straight', () => measure('/stereo-tb-video.mp4'), skip: !enabled);

    test(
      'stereo-tb-video.mp4 with 3 ms of latency each way',
      () => measure('/stereo-tb-video.mp4', latency: const Duration(milliseconds: 3)),
      skip: !enabled,
    );

    test(
      'stereo-tb-video.mp4 with 3 ms of latency each way, while browsing',
      () => measure('/stereo-tb-video.mp4', latency: const Duration(milliseconds: 3), browsing: true),
      skip: !enabled,
    );
  });
}
