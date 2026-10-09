// Files kept online only by a cloud client, OneDrive first: Windows lists them with their size and dates, but reading
// one, or only opening some of them, makes the client download it. The Pictures folder of many Windows accounts is in
// OneDrive, so adding it would pull the user's whole cloud library onto a disk that may not hold it. A placeholder is
// therefore counted, never read, never hashed and never shown, unless the user chooses "Download and include" for its
// folder.
//
// Windows marks them with FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS (a file whose content is elsewhere) or
// FILE_ATTRIBUTE_RECALL_ON_OPEN (a folder whose listing is elsewhere), and older clients with FILE_ATTRIBUTE_OFFLINE
// ("File Attribute Constants", learn.microsoft.com). dart:io does not expose the attributes, hence GetFileAttributesW
// through dart:ffi. macOS iCloud Drive "dataless" files get the same rule once their flag is read.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// File attribute constants of Windows
const fileAttributeHidden = 0x2;
const fileAttributeDirectory = 0x10;
const fileAttributeReparsePoint = 0x400;
const fileAttributeOffline = 0x1000;
const fileAttributeRecallOnOpen = 0x40000;
const fileAttributeRecallOnDataAccess = 0x400000;

const _invalidFileAttributes = 0xffffffff;

/// Whether a file with the Windows [attributes] is kept online only: reading it would download it
bool isCloudPlaceholder(int attributes) =>
    attributes & (fileAttributeRecallOnDataAccess | fileAttributeRecallOnOpen | fileAttributeOffline) != 0;

/// Whether a folder with the Windows [attributes] is hidden from the user (AppData, the recycle bin). The system
/// attribute alone is not enough: Windows also sets it on folders that only carry a custom icon (desktop.ini).
bool isHiddenFolder(int attributes) => attributes & fileAttributeHidden != 0;

/// Reads the Windows attributes of a path; null when the path cannot be read
typedef FileAttributesReader = int? Function(String path);

typedef _GetFileAttributesNative = Uint32 Function(Pointer<Utf16>);
typedef _GetFileAttributes = int Function(Pointer<Utf16>);

_GetFileAttributes? _getFileAttributes;

/// GetFileAttributesW on Windows; null on the other systems, which have no such attributes
FileAttributesReader? systemFileAttributesReader() {
  if (!Platform.isWindows) {
    return null;
  }
  final getFileAttributes = _getFileAttributes ??= DynamicLibrary.open(
    'kernel32.dll',
  ).lookupFunction<_GetFileAttributesNative, _GetFileAttributes>('GetFileAttributesW');
  return (path) => using((arena) {
    final attributes = getFileAttributes(win32LongPath(path).toNativeUtf16(allocator: arena));
    return attributes == _invalidFileAttributes ? null : attributes;
  });
}

/// Whether the file at [path] is kept online only right now: checked again before a file is read, since the cloud
/// client may have freed its space after the last scan
bool isCloudPlaceholderFile(String path, {FileAttributesReader? reader}) {
  final read = reader ?? systemFileAttributesReader();
  final attributes = read?.call(path);
  return attributes != null && isCloudPlaceholder(attributes);
}

/// [path] in the form the wide Windows calls take beyond 260 characters ("\\?\C:\..." or "\\?\UNC\server\..."); kept as
/// it is when short, since that form turns off the usual path normalisation
String win32LongPath(String path) {
  if (path.length < 240 || path.startsWith(r'\\?\')) {
    return path;
  }
  final windows = path.replaceAll('/', r'\');
  return windows.startsWith(r'\\') ? '\\\\?\\UNC\\${windows.substring(2)}' : '\\\\?\\$windows';
}
