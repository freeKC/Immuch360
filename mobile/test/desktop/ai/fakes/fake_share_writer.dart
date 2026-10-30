// A share in memory as the writer of the shares sees it (share_writer.dart), for the tests of the versions put next to
// their originals on a share

import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/desktop/network/share_writer.dart';

/// A share in memory as its writer sees it, every call written down; [failUpload] refuses the uploads
class FakeShareWriter implements ShareWriter {
  final files = <String, Uint8List>{};
  final calls = <String>[];
  ShareWriteFailure? failUpload;
  var opened = 0;
  var closed = 0;

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<void> upload(String path, File file) async {
    calls.add('upload $path');
    final failure = failUpload;
    if (failure != null) {
      throw ShareWriteException(failure, 'Access denied');
    }
    files[path] = file.readAsBytesSync();
  }

  @override
  Future<void> rename(String from, String to) async {
    calls.add('rename $from $to');
    if (files.containsKey(to)) {
      throw const ShareWriteException(ShareWriteFailure.taken);
    }
    files[to] = files.remove(from)!;
  }

  @override
  Future<void> delete(String path) async {
    calls.add('delete $path');
    files.remove(path);
  }

  @override
  Future<void> close() async => closed++;
}
