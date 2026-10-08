// Reading a file of the folder library while the user keeps working on it. dart:io opens files on Windows without
// FILE_SHARE_DELETE, so for as long as the app read a file, Explorer could not rename, move or delete it or its folder
// ("the file is open in immuch360.exe"), and a program writing it again (Insta360 Studio exporting over it) failed.
// The hasher reads a 4 GB video for about 40 s, an upload for minutes: on Windows those reads go through CreateFileW
// with every share mode instead. The other systems let a file open for reading be renamed and deleted, and keep
// dart:io.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:ffi/ffi.dart';
import 'package:immich_mobile/desktop/library/placeholder_check.dart';

/// A file opened for reading while other programs may still rename, move, delete or rewrite it. A file renamed or
/// deleted meanwhile is read to its end as it was opened; one rewritten meanwhile gives bytes of both versions, which
/// the size and date stored with a checksum tell (IndexedFile.currentChecksum).
abstract class SharedFileReader {
  /// Throws a [FileSystemException] when the file cannot be opened
  factory SharedFileReader.open(String path) => Platform.isWindows ? _WindowsFileReader(path) : _IoFileReader(path);

  /// Reads up to [length] bytes into [buffer]; 0 at the end of the file
  int readInto(Pointer<Uint8> buffer, int length);

  /// Moves to [position] bytes from the start of the file
  void seek(int position);

  void close();
}

/// Bytes read at once by [openSharedRead]
const sharedReadChunkLength = 512 * 1024;

/// The bytes of the file at [path] from [start] up to [end] (exclusive; the end of the file when null), as
/// File.openRead gives them, read through a [SharedFileReader]: what an upload sends from a folder of the library, so
/// that the user can still rename, move or delete the file meanwhile. The file is opened when the stream is listened
/// to, an error to open it is the first event, and cancelling the subscription closes it.
///
/// The reads run in an isolate of their own, one chunk ahead of the listener: they block the thread that makes them,
/// and a backup from a USB hard disk reads for as long as it sends, which would freeze the window.
Stream<List<int>> openSharedRead(String path, [int? start, int? end]) {
  late final StreamController<List<int>> controller;
  // Opened when the stream is listened to: a stream never listened to leaves nothing open
  late final replies = ReceivePort();
  late final exits = ReceivePort();
  final exited = Completer<void>();
  SendPort? reader;
  // A chunk asked and not received yet; the end of the file or an error reached; the listener gone
  var waiting = false;
  var finished = false;
  var cancelled = false;

  void askNext() {
    final port = reader;
    if (port != null && !waiting && !finished && !cancelled && !controller.isPaused) {
      waiting = true;
      port.send(true);
    }
  }

  void finish([Object? error, StackTrace? stackTrace]) {
    if (finished) {
      return;
    }
    finished = true;
    if (!cancelled) {
      if (error != null) {
        controller.addError(error, stackTrace);
      }
      unawaited(controller.close());
    }
  }

  // The ports stay open until the isolate ended, so that a stop sent before it was ready still reaches it
  void ended() {
    replies.close();
    exits.close();
    exited.complete();
  }

  void onReply(Object? message) {
    switch (message) {
      case final SendPort port:
        reader = port;
        if (cancelled) {
          port.send(false);
        }
        askNext();
      case final TransferableTypedData data:
        waiting = false;
        if (!cancelled) {
          controller.add(data.materialize().asUint8List());
        }
        askNext();
      case (final Object error, final String stackTrace):
        finish(error, StackTrace.fromString(stackTrace));
      default:
        // null: the end of the file
        finish();
    }
  }

  Future<void> spawn() async {
    try {
      await Isolate.spawn(
        _readShared,
        (path: path, start: start ?? 0, end: end, replies: replies.sendPort),
        onExit: exits.sendPort,
        debugName: 'shared-file-read',
      );
    } catch (error, stackTrace) {
      ended();
      finish(error, stackTrace);
    }
  }

  controller = StreamController<List<int>>(
    onListen: () {
      replies.listen(onReply);
      exits.listen((_) {
        ended();
        // The isolate's last message comes before its exit: an end without one is a read that died
        finish(FileSystemException('The read of the file stopped', path));
      });
      unawaited(spawn());
    },
    onResume: askNext,
    onCancel: () {
      cancelled = true;
      reader?.send(false);
      finish();
      // Done once the file is closed: whoever cancels can then delete it
      return exited.future;
    },
  );
  return controller.stream;
}

typedef _SharedRead = ({String path, int start, int? end, SendPort replies});

// The reader isolate: opens the file, says where to ask for chunks, then sends one chunk per request (true) until the
// end of the file (null), an error, or a stop (false)
Future<void> _readShared(_SharedRead job) async {
  final SharedFileReader file;
  try {
    file = SharedFileReader.open(job.path);
  } catch (error, stackTrace) {
    job.replies.send((error, stackTrace.toString()));
    return;
  }
  final requests = ReceivePort();
  final buffer = malloc<Uint8>(sharedReadChunkLength);
  var position = job.start;
  final end = job.end;
  try {
    if (position > 0) {
      file.seek(position);
    }
    job.replies.send(requests.sendPort);
    await for (final more in requests) {
      if (more != true) {
        break;
      }
      final length = end == null ? sharedReadChunkLength : min(sharedReadChunkLength, end - position);
      final read = length <= 0 ? 0 : file.readInto(buffer, length);
      if (read <= 0) {
        job.replies.send(null);
        break;
      }
      position += read;
      job.replies.send(TransferableTypedData.fromList([buffer.asTypedList(read)]));
    }
  } catch (error, stackTrace) {
    job.replies.send((error, stackTrace.toString()));
  } finally {
    requests.close();
    malloc.free(buffer);
    file.close();
  }
}

class _IoFileReader implements SharedFileReader {
  _IoFileReader(String path) : _file = File(path).openSync();

  final RandomAccessFile _file;

  @override
  int readInto(Pointer<Uint8> buffer, int length) => _file.readIntoSync(buffer.asTypedList(length));

  @override
  void seek(int position) => _file.setPositionSync(position);

  @override
  void close() => _file.closeSync();
}

typedef _CreateFileNative =
    Pointer<Void> Function(Pointer<Utf16>, Uint32, Uint32, Pointer<Void>, Uint32, Uint32, Pointer<Void>);
typedef _CreateFile = Pointer<Void> Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, Pointer<Void>);
typedef _ReadFileNative = Int32 Function(Pointer<Void>, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>);
typedef _ReadFile = int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>);
typedef _SetFilePointerExNative = Int32 Function(Pointer<Void>, Int64, Pointer<Int64>, Uint32);
typedef _SetFilePointerEx = int Function(Pointer<Void>, int, Pointer<Int64>, int);
typedef _CloseHandleNative = Int32 Function(Pointer<Void>);
typedef _CloseHandle = int Function(Pointer<Void>);
typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastError = int Function();

const _genericRead = 0x80000000;
const _fileShareAll = 0x1 | 0x2 | 0x4;
const _openExisting = 3;
// The cache manager reads ahead for a file read from start to end
const _fileFlagSequentialScan = 0x08000000;
const _fileBegin = 0;

class _Kernel32Files {
  _Kernel32Files() {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    createFile = kernel32.lookupFunction<_CreateFileNative, _CreateFile>('CreateFileW');
    readFile = kernel32.lookupFunction<_ReadFileNative, _ReadFile>('ReadFile');
    setFilePointerEx = kernel32.lookupFunction<_SetFilePointerExNative, _SetFilePointerEx>('SetFilePointerEx');
    closeHandle = kernel32.lookupFunction<_CloseHandleNative, _CloseHandle>('CloseHandle');
    getLastError = kernel32.lookupFunction<_GetLastErrorNative, _GetLastError>('GetLastError');
  }

  static final instance = _Kernel32Files();

  late final _CreateFile createFile;
  late final _ReadFile readFile;
  late final _SetFilePointerEx setFilePointerEx;
  late final _CloseHandle closeHandle;
  late final _GetLastError getLastError;
}

/// CreateFileW with FILE_SHARE_READ, FILE_SHARE_WRITE and FILE_SHARE_DELETE, then ReadFile into the native buffer
class _WindowsFileReader implements SharedFileReader {
  factory _WindowsFileReader(String path) {
    final api = _Kernel32Files.instance;
    final handle = using(
      (arena) => api.createFile(
        win32LongPath(path).toNativeUtf16(allocator: arena),
        _genericRead,
        _fileShareAll,
        nullptr,
        _openExisting,
        _fileFlagSequentialScan,
        nullptr,
      ),
    );
    if (handle.address == -1) {
      throw FileSystemException('Cannot open file', path, OSError('CreateFileW failed', api.getLastError()));
    }
    return _WindowsFileReader._(api, handle, path);
  }

  _WindowsFileReader._(this._api, this._handle, this._path);

  final _Kernel32Files _api;
  final Pointer<Void> _handle;
  final String _path;
  final _read = malloc<Uint32>();

  @override
  int readInto(Pointer<Uint8> buffer, int length) {
    if (_api.readFile(_handle, buffer, length, _read, nullptr) == 0) {
      throw FileSystemException('Cannot read file', _path, OSError('ReadFile failed', _api.getLastError()));
    }
    return _read.value;
  }

  @override
  void seek(int position) {
    if (_api.setFilePointerEx(_handle, position, nullptr, _fileBegin) == 0) {
      throw FileSystemException('Cannot move in file', _path, OSError('SetFilePointerEx failed', _api.getLastError()));
    }
  }

  @override
  void close() {
    _api.closeHandle(_handle);
    malloc.free(_read);
  }
}
