// A folder picked in the system picker, in memory, for the tests of DocumentTreeFileSystem and of the DJI drone page:
// the files by path from the folder picked ("/DCIM/DJI_001/DJI_0001.JPG"), each document id being its path.

import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:immich_mobile/platform/document_tree_api.g.dart';
import 'package:mocktail/mocktail.dart';

class FakeDocumentTreeApi extends Fake implements DocumentTreeApi {
  FakeDocumentTreeApi(
    this.files, {
    this.treeUri = 'content://com.android.externalstorage.documents/tree/1A2B-3C4D%3A',
    this.title = 'USB drive',
    this.kind = 'usb',
    this.dates = const {},
    this.thumbnailPaths = const {},
  });

  /// The files of the folder, by path
  final Map<String, Uint8List> files;
  final String treeUri;
  final String title;
  final String kind;

  /// The dates of the files that have one
  final Map<String, DateTime> dates;

  /// The files the provider makes a thumbnail of
  final Set<String> thumbnailPaths;

  /// The answer of the next pick: the folder, or null when the user goes back
  bool pickGivesFolder = true;
  bool unplugged = false;

  final listed = <String?>[];
  final reads = <(String, int, int)>[];
  final copies = <({String path, String name, String mimeType, String album, int takenAtMs})>[];
  final cancelled = <int>[];
  final closed = <String>[];
  final watching = <bool>[];

  TreePick get pick => TreePick(treeUri: treeUri, title: title, folderName: 'DCIM', kind: kind);

  PlatformException get _unplugged => PlatformException(code: 'unplugged', message: 'gone');

  @override
  Future<TreePick?> pickTree() async => pickGivesFolder ? pick : null;

  @override
  Future<TreePick?> reopen(String treeUri) async => unplugged || treeUri != this.treeUri ? null : pick;

  @override
  Future<List<DocEntry>> list(String treeUri, String? documentId) async {
    listed.add(documentId);
    if (unplugged) {
      throw _unplugged;
    }
    final folder = documentId ?? '';
    final children = <String, DocEntry>{};
    for (final path in files.keys) {
      if (!path.startsWith('$folder/')) {
        continue;
      }
      final rest = path.substring(folder.length + 1);
      final slash = rest.indexOf('/');
      final name = slash < 0 ? rest : rest.substring(0, slash);
      final id = '$folder/$name';
      children[name] = slash < 0
          ? _file(id)
          : DocEntry(documentId: id, name: name, isDirectory: true, supportsThumbnail: false);
    }
    return children.values.toList();
  }

  DocEntry _file(String path) => DocEntry(
    documentId: path,
    name: path.split('/').last,
    isDirectory: false,
    size: files[path]!.length,
    mimeType: 'application/octet-stream',
    lastModifiedMs: dates[path]?.millisecondsSinceEpoch,
    supportsThumbnail: thumbnailPaths.contains(path),
  );

  @override
  Future<DocEntry> stat(String treeUri, String? documentId) async {
    if (unplugged) {
      throw _unplugged;
    }
    if (documentId == null || !files.containsKey(documentId)) {
      return DocEntry(documentId: documentId ?? '', name: 'DCIM', isDirectory: true, supportsThumbnail: false);
    }
    return _file(documentId);
  }

  @override
  Future<Uint8List> read(String treeUri, String documentId, int offset, int length) async {
    reads.add((documentId, offset, length));
    if (unplugged) {
      throw _unplugged;
    }
    final bytes = files[documentId]!;
    final start = math.min(offset, bytes.length);
    return Uint8List.sublistView(bytes, start, math.min(bytes.length, start + length));
  }

  @override
  Future<Uint8List?> thumbnail(String treeUri, String documentId, int size) async =>
      thumbnailPaths.contains(documentId) ? Uint8List.fromList([0xff, 0xd8, 1, 2, 0xff, 0xd9]) : null;

  @override
  Future<String> copyToGallery(
    int copyId,
    String treeUri,
    String documentId,
    String name,
    String mimeType,
    String album,
    int takenAtMs,
  ) async {
    if (unplugged) {
      throw _unplugged;
    }
    copies.add((path: documentId, name: name, mimeType: mimeType, album: album, takenAtMs: takenAtMs));
    return 'content://media/external/${copies.length}';
  }

  @override
  Future<void> cancelCopy(int copyId) async => cancelled.add(copyId);

  @override
  Future<void> closeTree(String treeUri) async => closed.add(treeUri);

  @override
  Future<void> release(String treeUri) async {}

  @override
  Future<void> watchUsb(bool watch) async => watching.add(watch);
}
