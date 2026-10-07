import 'dart:typed_data';

import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/services/secure_storage.service.dart';

/// The secure storage of the device, in memory
class FakeSecureStorage implements SecureStorageService {
  final Map<String, String> values = {};

  /// The keys written with deviceOnly, and those deleted with it
  final Set<String> writtenDeviceOnly = {};
  final Set<String> deletedDeviceOnly = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value, {bool deviceOnly = false}) async {
    values[key] = value;
    if (deviceOnly) {
      writtenDeviceOnly.add(key);
    }
  }

  @override
  Future<void> delete(String key, {bool deviceOnly = false}) async {
    values.remove(key);
    if (deviceOnly) {
      deletedDeviceOnly.add(key);
    }
  }
}

/// A share in memory: [entries] by folder path
class FakeFileSystem implements NetworkFileSystem {
  FakeFileSystem(this.source, {this.password, Map<String, List<NetworkEntry>>? entries, this.listError})
    : entries = entries ?? {};

  @override
  final NetworkSource source;
  final String? password;
  final Map<String, List<NetworkEntry>> entries;

  /// Thrown by [list] when set
  final Exception? listError;
  final List<String> listed = [];
  bool closed = false;

  @override
  Future<List<NetworkEntry>> list(String path) async {
    listed.add(path);
    final error = listError;
    if (error != null) {
      throw error;
    }
    final found = entries[path];
    if (found == null) {
      throw NetworkFileSystemException('No folder $path', isNotFound: true);
    }
    return found;
  }

  @override
  Future<NetworkEntry> stat(String path) async => NetworkEntry(sourceId: source.id, path: path, isDirectory: false);

  @override
  Future<Uint8List> readRange(String path, int offset, int length) async => Uint8List(0);

  @override
  Future<void> close() async => closed = true;
}

/// A media bridge that only remembers what it was told
class FakeMediaBridge implements MediaBridge {
  final Map<String, NetworkFileSystem> registered = {};
  final List<String> unregistered = [];
  int starts = 0;
  bool stopped = false;

  @override
  Future<void> start() async => starts++;

  @override
  void register(NetworkFileSystem fileSystem) => registered[fileSystem.source.id] = fileSystem;

  @override
  void unregister(String sourceId) {
    registered.remove(sourceId);
    unregistered.add(sourceId);
  }

  @override
  Uri urlFor(String sourceId, String path) => Uri.parse('http://127.0.0.1:1234/token/$sourceId$path');

  @override
  Future<void> stop() async => stopped = true;
}

NetworkEntry fakeEntry(String sourceId, String path, {bool isDirectory = false}) =>
    NetworkEntry(sourceId: sourceId, path: path, isDirectory: isDirectory);

const smbSource = NetworkSource(
  id: 'smb-1',
  type: NetworkSourceType.smb,
  name: 'NAS',
  host: 'nas.local',
  share: 'media',
  username: 'tester',
);

const webDavSource = NetworkSource(
  id: 'dav-1',
  type: NetworkSourceType.webdav,
  name: 'Cloud',
  host: 'cloud.example.com',
  share: '/remote.php/dav/files/alice',
  rootPath: '/Photos',
  username: 'alice',
  useTls: true,
);
