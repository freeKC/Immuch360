// The file system of the creator as the tests see it: every call written down with its path, on the real files of a
// temporary folder, and failures of the system played on chosen folders (a disk full, a folder that refuses).

import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/creator/safe_writer.dart';
import 'package:path/path.dart' as p;

class RecordingCreatorFiles implements CreatorFileSystem {
  RecordingCreatorFiles({this.inner = const IoCreatorFileSystem()});

  final CreatorFileSystem inner;

  /// Every call, as `operation path`
  final calls = <String>[];

  /// The error of the system each write in one of these folders fails with
  final failures = <String, OSError>{};

  /// The calls whose path is [folder] or lies under it
  List<String> callsUnder(String folder) => [
    for (final call in calls)
      if (_isUnder(call.substring(call.indexOf(' ') + 1), folder)) call,
  ];

  static bool _isUnder(String path, String folder) => p.equals(path, folder) || p.isWithin(folder, path);

  void _fail(String path) {
    for (final MapEntry(key: folder, value: error) in failures.entries) {
      if (_isUnder(path, folder)) {
        throw FileSystemException('Write refused', path, error);
      }
    }
  }

  @override
  Future<bool> isFolder(String path) {
    calls.add('isFolder $path');
    return inner.isFolder(path);
  }

  @override
  Future<void> createFolder(String path) {
    calls.add('createFolder $path');
    _fail(path);
    return inner.createFolder(path);
  }

  @override
  Future<void> createNew(String path) {
    calls.add('createNew $path');
    _fail(path);
    return inner.createNew(path);
  }

  @override
  Future<String> reserve(String folder, String name) {
    calls.add('reserve ${p.join(folder, name)}');
    _fail(folder);
    return inner.reserve(folder, name);
  }

  @override
  Future<bool> exists(String path) {
    calls.add('exists $path');
    return inner.exists(path);
  }

  @override
  Future<Uint8List> readHead(String path, int length) {
    calls.add('readHead $path');
    return inner.readHead(path, length);
  }

  @override
  Future<void> rename(String from, String to) {
    calls.add('rename $from');
    calls.add('renameTo $to');
    _fail(to);
    return inner.rename(from, to);
  }

  @override
  Future<void> delete(String path) {
    calls.add('delete $path');
    return inner.delete(path);
  }
}
