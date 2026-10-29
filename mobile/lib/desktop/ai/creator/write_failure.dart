// Why a write of the AI features failed, as the user is told: the error codes of the systems sorted into a disk full
// (the queue pauses), a folder that refuses new files, a folder gone, and the rest. Apart from safe_writer.dart, which
// exports it, so that the engines read it without the writer and its plugins: the panorama engine also runs in a
// program compiled without Flutter (the measure of the 360° panoramas).

import 'dart:io';

import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';

/// Why a write failed, as the user is told
enum WriteFailure {
  /// No space left: ENOSPC (28) on Linux and macOS, ERROR_DISK_FULL (112) and ERROR_HANDLE_DISK_FULL (39) on Windows.
  /// The queue pauses until the user frees some space.
  diskFull,

  /// The folder does not accept new files: EPERM, EACCES, EROFS; ERROR_ACCESS_DENIED, ERROR_WRITE_PROTECT,
  /// ERROR_NETWORK_ACCESS_DENIED
  readOnly,

  /// The folder is not there: a drive unplugged, a share gone
  folderMissing,

  /// Anything else, with the message of the system
  other;

  /// The code a job ends with
  ImmersiveErrorCode get errorCode => switch (this) {
    WriteFailure.diskFull => ImmersiveErrorCode.diskFull,
    WriteFailure.readOnly => ImmersiveErrorCode.readOnly,
    WriteFailure.folderMissing || WriteFailure.other => ImmersiveErrorCode.writeFailed,
  };
}

const _posixDiskFull = {28};
const _windowsDiskFull = {112, 39};
const _posixReadOnly = {1, 13, 30};
const _windowsReadOnly = {5, 19, 65};
// ENOENT, ENOTDIR; ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND, ERROR_NOT_READY, ERROR_BAD_NETPATH, ERROR_BAD_NET_NAME
const _posixMissing = {2, 20};
const _windowsMissing = {2, 3, 21, 53, 67};

/// What [error], thrown by a write, means for the user. [windows] tells how to read the code of the system, since the
/// codes of Windows are not those of Linux and macOS (28 is ENOSPC there, "out of paper" on Windows); this computer by
/// default.
WriteFailure writeFailureOf(Object error, {bool? windows}) {
  final code = switch (error) {
    FileSystemException(osError: OSError(:final errorCode)) => errorCode,
    OSError(:final errorCode) => errorCode,
    _ => null,
  };
  if (code == null) {
    return WriteFailure.other;
  }
  final onWindows = windows ?? Platform.isWindows;
  if ((onWindows ? _windowsDiskFull : _posixDiskFull).contains(code)) {
    return WriteFailure.diskFull;
  }
  if ((onWindows ? _windowsReadOnly : _posixReadOnly).contains(code)) {
    return WriteFailure.readOnly;
  }
  if ((onWindows ? _windowsMissing : _posixMissing).contains(code)) {
    return WriteFailure.folderMissing;
  }
  return WriteFailure.other;
}
