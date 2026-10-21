// The files of the network shares that were sent to the Immich server, kept in a small JSON file of the app per server
// and user: the browser marks them, and sending one of them again while it is unchanged on its share is skipped once
// the server confirms it still has its asset. A file that changed (another size or date) is a new file to send.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:logging/logging.dart';

final _log = Logger('UploadRecordStore');

/// A file of a share the server has: the asset it became, and when it was sent
class UploadRecord {
  const UploadRecord({required this.remoteId, required this.sentAt, this.inTrash = false});

  final String remoteId;
  final DateTime sentAt;

  /// The asset sits in the trash of the server, last time the app looked: the server will purge it, so the file is not
  /// shown as sent, and is offered again
  final bool inTrash;

  Map<String, Object?> toJson() => {'id': remoteId, 'at': sentAt.toUtc().toIso8601String(), if (inTrash) 'trash': true};

  static UploadRecord? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final id = json['id'];
    final at = json['at'] is String ? DateTime.tryParse(json['at'] as String) : null;
    if (id is! String || id.isEmpty || at == null) {
      return null;
    }
    return UploadRecord(remoteId: id, sentAt: at, inTrash: json['trash'] == true);
  }

  @override
  bool operator ==(Object other) =>
      other is UploadRecord && other.remoteId == remoteId && other.sentAt == sentAt && other.inTrash == inTrash;

  @override
  int get hashCode => Object.hash(remoteId, sentAt, inTrash);

  @override
  String toString() => 'UploadRecord($remoteId, $sentAt${inTrash ? ', in the trash' : ''})';
}

/// Whether [record] stands for a file the server keeps: recorded, and not in its trash
bool isKeptOnServer(UploadRecord? record) => record != null && !record.inTrash;

/// The record of the files sent from the shares, in the JSON file [file] gives; none when it gives null (no user signed
/// in): nothing is read nor written then. Read once, on first use; each change is written at once, one write after the
/// other.
class UploadRecordStore {
  UploadRecordStore(this._file);

  final Future<File?> Function() _file;

  Future<Map<String, UploadRecord>>? _loading;
  Future<void> _writing = Future.value();

  static const _version = 1;

  /// The key of [entry] in the record: its share, its path, its size and its date. A file changed on its share has
  /// another key, and is sent again.
  ///
  /// A file imported from a drone, a controller or a card (see NetworkEntry.isImported) by its name and its size: the
  /// picked folder and the ids of its files change with the cable, the card reader and each plug, its names and sizes
  /// do not. Its date is not trusted whole: a FAT card has no time zone (Android reads it with the offset of the phone,
  /// which changes abroad) and a device over MTP gives its own. A DJI name holds the second the file was made, so the
  /// name and the size are enough; any other name keeps the seconds of its date within the quarter hour, which no
  /// time zone offset changes.
  static String keyOf(NetworkEntry entry) {
    if (!entry.isImported) {
      return jsonEncode([entry.sourceId, entry.path, entry.size, entry.modified?.toUtc().millisecondsSinceEpoch]);
    }
    final modified = entry.modified;
    if (modified == null || _timestampedName.hasMatch(entry.name)) {
      return jsonEncode(['import', entry.name, entry.size]);
    }
    return jsonEncode(['import', entry.name, entry.size, (modified.millisecondsSinceEpoch ~/ 1000) % _quarterHour]);
  }

  /// "DJI_20261021143000_0001_D.JPG": the date and time the file was made, to the second
  static final _timestampedName = RegExp(r'^DJI_\d{14}_', caseSensitive: false);

  static const _quarterHour = 15 * 60;

  /// The name of the record file of the user [userId] of the server [server]. An asset id means something on its
  /// server and to its owner only: another server or another user signed in on this device has a record of its own.
  static String fileNameFor(String server, String userId) =>
      'network_uploads_${sha1.convert(utf8.encode(jsonEncode([server, userId])))}.json';

  /// Every file sent, by [keyOf]; read from the file the first time. The map is the store's own: do not change it.
  Future<Map<String, UploadRecord>> load() => _loading ??= _read();

  /// The record of [entry] while it is unchanged on its share, null when it was not sent
  Future<UploadRecord?> find(NetworkEntry entry) async => (await load())[keyOf(entry)];

  /// Records that [entry] is on the server as the asset [remoteId], from [sentAt] (now when null), in its trash when
  /// [inTrash]
  Future<void> add(NetworkEntry entry, String remoteId, {DateTime? sentAt, bool inTrash = false}) async {
    final records = await load();
    records[keyOf(entry)] = UploadRecord(
      remoteId: remoteId,
      sentAt: (sentAt ?? DateTime.now()).toUtc(),
      inTrash: inTrash,
    );
    await _save(records);
  }

  /// Marks the records of the assets of [trashed] as in the trash of the server, and those of [restored] as out of it;
  /// gives whether anything changed
  Future<bool> markTrash({Set<String> trashed = const {}, Set<String> restored = const {}}) async {
    final records = await load();
    var changed = false;
    for (final MapEntry(:key, value: record) in records.entries.toList()) {
      final inTrash = trashed.contains(record.remoteId) || (record.inTrash && !restored.contains(record.remoteId));
      if (inTrash != record.inTrash) {
        records[key] = UploadRecord(remoteId: record.remoteId, sentAt: record.sentAt, inTrash: inTrash);
        changed = true;
      }
    }
    if (changed) {
      await _save(records);
    }
    return changed;
  }

  /// Forgets [entry]: the server does not have its asset anymore
  Future<void> remove(NetworkEntry entry) async {
    final records = await load();
    if (records.remove(keyOf(entry)) != null) {
      await _save(records);
    }
  }

  Future<Map<String, UploadRecord>> _read() async {
    final records = <String, UploadRecord>{};
    try {
      final file = await _file();
      // ignore: avoid_slow_async_io
      if (file == null || !await file.exists()) {
        return records;
      }
      final json = jsonDecode(await file.readAsString());
      final files = json is Map ? json['files'] : null;
      if (files is Map) {
        for (final MapEntry(:key, :value) in files.entries) {
          final record = UploadRecord.fromJson(value);
          if (key is String && record != null) {
            records[key] = record;
          }
        }
      }
    } catch (error, stackTrace) {
      // A record that cannot be read only means files may be sent again; the server answers "duplicate" for them
      _log.warning('Could not read the record of the files sent from the shares', error, stackTrace);
    }
    return records;
  }

  /// Writes [records] as they are now, after the writes under way
  Future<void> _save(Map<String, UploadRecord> records) {
    final json = jsonEncode({
      'version': _version,
      'files': {for (final MapEntry(:key, :value) in records.entries) key: value.toJson()},
    });
    final write = _writing.then((_) => _write(json));
    _writing = write;
    return write;
  }

  Future<void> _write(String json) async {
    try {
      final file = await _file();
      if (file == null) {
        return;
      }
      await file.parent.create(recursive: true);
      // A temporary file renamed over the record: the app stopped in the middle of a write leaves the previous one
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(json, flush: true);
      await temporary.rename(file.path);
    } catch (error, stackTrace) {
      _log.warning('Could not write the record of the files sent from the shares', error, stackTrace);
    }
  }
}
