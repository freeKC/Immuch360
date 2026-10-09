// Which volume a folder of the library is on, so that its root id, and the ids of its files, do not depend on the
// drive letter or the mount point: an external drive that comes back as F: instead of E:, where 360° footage often
// lives, is found again with the same ids, instead of a full rescan, a rehash, and a delete plus an add of every file
// in the local tables.
//
// The volume is named by what it carries itself: the serial number of the file system on Windows
// (GetVolumeInformationW), the UUID of the file system on Linux (/dev/disk/by-uuid). Network folders have no such
// number and are named by their share or mount path; on Windows a mapped drive by the share it leads to
// (WNetGetConnectionW), so that a folder of the share keeps its ids whether it is reached as Z:, under another letter
// or by its \\server\share path. macOS reads the mount point for now (the volume UUID comes with the macOS runtime
// work).
//
// Every call here is synchronous: the scanner runs them in its own isolate.

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// The volume a folder is on and where the folder sits inside it
class VolumeIdentity {
  const VolumeIdentity({
    required this.volumeKey,
    required this.mountPoint,
    required this.pathInVolume,
    required this.isNetwork,
  });

  /// "win-1a2b3c4d" (serial number), "uuid-" and the file system UUID, "net-" and the share or mount path, "mnt-" and
  /// the mount point
  final String volumeKey;

  /// Where the volume is mounted now: "E:\", "/media/me/disk"
  final String mountPoint;

  /// The folder inside the volume, with "/" separators and a leading "/", in the case the file system gave
  final String pathInVolume;

  /// A share or a mapped network drive
  final bool isNetwork;

  /// The id of a root at this folder: the volume and the folder inside it, case folded where the file system ignores
  /// case, so that the same folder gives the same id whatever letter or mount point the volume has
  String rootId({required bool caseFold}) {
    final inside = pathInVolume.split('/').where((part) => part.isNotEmpty).join('/');
    return '$volumeKey:/${caseFold ? inside.toLowerCase() : inside}';
  }

  @override
  String toString() => 'VolumeIdentity($volumeKey, mount: $mountPoint, path: $pathInVolume, network: $isNetwork)';
}

/// Reads the volumes of this computer
abstract class VolumeProbe {
  const VolumeProbe();

  /// The probe of the operating system the app runs on
  factory VolumeProbe.thisComputer() {
    if (Platform.isWindows) {
      return WindowsVolumeProbe();
    }
    if (Platform.isLinux) {
      return MountTableVolumeProbe.fromSystem();
    }
    return const MountPathVolumeProbe();
  }

  /// The volume of the existing folder [absolutePath]; null when it cannot be read
  VolumeIdentity? identify(String absolutePath);

  /// Where the folder [pathInVolume] of the volume [volumeKey] is now; null when the volume is not connected or the
  /// folder is not on it any more
  String? locate(String volumeKey, String pathInVolume);

  /// Whether the folder [absolutePath] is on a drive the user ejects: a memory card, a USB or FireWire drive, a
  /// disc. The watcher leaves those alone (see library_watcher.dart). False where the system is not asked yet (Linux,
  /// macOS), whose watches do not hold the volume the way the Windows one does.
  bool isRemovable(String absolutePath) => false;
}

String _joinInside(String mountPoint, String pathInVolume, p.Context context) {
  final parts = pathInVolume.split('/').where((part) => part.isNotEmpty);
  return parts.isEmpty ? mountPoint : context.joinAll([mountPoint, ...parts]);
}

bool _isDirectory(String path) => FileSystemEntity.isDirectorySync(path);

// --- Windows ---------------------------------------------------------------------------------------------------------

typedef _GetVolumePathNameNative = Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32);
typedef _GetVolumePathName = int Function(Pointer<Utf16>, Pointer<Utf16>, int);
typedef _GetVolumeInformationNative =
    Int32 Function(
      Pointer<Utf16>,
      Pointer<Utf16>,
      Uint32,
      Pointer<Uint32>,
      Pointer<Uint32>,
      Pointer<Uint32>,
      Pointer<Utf16>,
      Uint32,
    );
typedef _GetVolumeInformation =
    int Function(
      Pointer<Utf16>,
      Pointer<Utf16>,
      int,
      Pointer<Uint32>,
      Pointer<Uint32>,
      Pointer<Uint32>,
      Pointer<Utf16>,
      int,
    );
typedef _GetDriveTypeNative = Uint32 Function(Pointer<Utf16>);
typedef _GetDriveType = int Function(Pointer<Utf16>);
typedef _GetLogicalDrivesNative = Uint32 Function();
typedef _GetLogicalDrives = int Function();
typedef _SetThreadErrorModeNative = Int32 Function(Uint32, Pointer<Uint32>);
typedef _SetThreadErrorMode = int Function(int, Pointer<Uint32>);
typedef _GetConnectionNative = Uint32 Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Uint32>);
typedef _GetConnection = int Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Uint32>);
typedef _GetVolumeNameForMountPointNative = Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32);
typedef _GetVolumeNameForMountPoint = int Function(Pointer<Utf16>, Pointer<Utf16>, int);
typedef _CreateFileNative =
    Pointer<Void> Function(Pointer<Utf16>, Uint32, Uint32, Pointer<Void>, Uint32, Uint32, Pointer<Void>);
typedef _CreateFile = Pointer<Void> Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, Pointer<Void>);
typedef _DeviceIoControlNative =
    Int32 Function(
      Pointer<Void>,
      Uint32,
      Pointer<Uint8>,
      Uint32,
      Pointer<Uint8>,
      Uint32,
      Pointer<Uint32>,
      Pointer<Void>,
    );
typedef _DeviceIoControl =
    int Function(Pointer<Void>, int, Pointer<Uint8>, int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>);
typedef _CloseHandleNative = Int32 Function(Pointer<Void>);
typedef _CloseHandle = int Function(Pointer<Void>);

// WNetGetConnectionW: a remembered mapping whose share does not answer now still names the share
const _errorConnectionUnavailable = 1201;

// GetDriveTypeW
const _driveUnknown = 0;
const _driveNoRootDir = 1;
const _driveRemovable = 2;
const _driveFixed = 3;
const _driveRemote = 4;
const _driveCdRom = 5;

// The device of a volume, opened with no access right at all, which is enough to ask it about itself and needs no
// administrator
const _fileShareRead = 0x1;
const _fileShareWrite = 0x2;
const _openExisting = 3;

// IOCTL_STORAGE_QUERY_PROPERTY with StorageDeviceProperty and PropertyStandardQuery; the answer is a
// STORAGE_DEVICE_DESCRIPTOR, with RemovableMedia at byte 10 and BusType at byte 28
const _ioctlStorageQueryProperty = 0x2d1400;
const _storagePropertyQueryLength = 12;
const _deviceDescriptorLength = 1024;
const _descriptorRemovableMedia = 10;
const _descriptorBusType = 28;

// STORAGE_BUS_TYPE of the drives a user unplugs: FireWire, USB, SD and MMC cards. A Thunderbolt enclosure reports the
// bus of the disk inside it (NVMe, SATA) and is watched like an internal disk.
const _removableBusTypes = {4, 7, 12, 13};

/// Whether a disk Windows describes by [busType] (STORAGE_BUS_TYPE) and [removableMedia] is one the user ejects
bool isRemovableStorage({required int busType, required bool removableMedia}) =>
    removableMedia || _removableBusTypes.contains(busType);

// SetThreadErrorMode: no "insert a disk" dialog for an empty card reader while the drives are probed
const _semFailCriticalErrors = 0x0001;
const _semNoOpenFileErrorBox = 0x8000;

const _maxPath = 32768;

/// The volumes of Windows: the serial number of the file system of each drive (GetVolumeInformationW), the drive
/// letters in use (GetLogicalDrives), and the volume a path is on (GetVolumePathNameW), all in kernel32; the share
/// behind a mapped drive (WNetGetConnectionW) in mpr
class WindowsVolumeProbe extends VolumeProbe {
  WindowsVolumeProbe() : _kernel32 = DynamicLibrary.open('kernel32.dll');

  final DynamicLibrary _kernel32;
  late final _getConnection = DynamicLibrary.open(
    'mpr.dll',
  ).lookupFunction<_GetConnectionNative, _GetConnection>('WNetGetConnectionW');
  late final _getVolumePathName = _kernel32.lookupFunction<_GetVolumePathNameNative, _GetVolumePathName>(
    'GetVolumePathNameW',
  );
  late final _getVolumeInformation = _kernel32.lookupFunction<_GetVolumeInformationNative, _GetVolumeInformation>(
    'GetVolumeInformationW',
  );
  late final _getDriveType = _kernel32.lookupFunction<_GetDriveTypeNative, _GetDriveType>('GetDriveTypeW');
  late final _getLogicalDrives = _kernel32.lookupFunction<_GetLogicalDrivesNative, _GetLogicalDrives>(
    'GetLogicalDrives',
  );
  late final _setThreadErrorMode = _kernel32.lookupFunction<_SetThreadErrorModeNative, _SetThreadErrorMode>(
    'SetThreadErrorMode',
  );
  late final _getVolumeNameForMountPoint = _kernel32
      .lookupFunction<_GetVolumeNameForMountPointNative, _GetVolumeNameForMountPoint>(
        'GetVolumeNameForVolumeMountPointW',
      );
  late final _createFile = _kernel32.lookupFunction<_CreateFileNative, _CreateFile>('CreateFileW');
  late final _deviceIoControl = _kernel32.lookupFunction<_DeviceIoControlNative, _DeviceIoControl>('DeviceIoControl');
  late final _closeHandle = _kernel32.lookupFunction<_CloseHandleNative, _CloseHandle>('CloseHandle');

  T _quietly<T>(T Function() probe) => using((arena) {
    final previous = arena<Uint32>();
    final changed = _setThreadErrorMode(_semFailCriticalErrors | _semNoOpenFileErrorBox, previous) != 0;
    try {
      return probe();
    } finally {
      if (changed) {
        _setThreadErrorMode(previous.value, arena<Uint32>());
      }
    }
  });

  String? _volumePathOf(String path) => using((arena) {
    final buffer = arena<Uint16>(_maxPath).cast<Utf16>();
    if (_getVolumePathName(path.toNativeUtf16(allocator: arena), buffer, _maxPath) == 0) {
      return null;
    }
    return buffer.toDartString();
  });

  int? _serialOf(String mountPoint) => using((arena) {
    final serial = arena<Uint32>();
    final ok = _getVolumeInformation(
      mountPoint.toNativeUtf16(allocator: arena),
      nullptr,
      0,
      serial,
      nullptr,
      nullptr,
      nullptr,
      0,
    );
    return ok == 0 ? null : serial.value;
  });

  int _driveTypeOf(String mountPoint) => using((arena) => _getDriveType(mountPoint.toNativeUtf16(allocator: arena)));

  /// The share a mapped drive ("Z:") leads to ("\\nas\photos"); null for a drive that is no mapping
  String? _shareOf(String drive) => using((arena) {
    final length = arena<Uint32>()..value = _maxPath;
    final buffer = arena<Uint16>(_maxPath).cast<Utf16>();
    final status = _getConnection(drive.toNativeUtf16(allocator: arena), buffer, length);
    if (status != 0 && status != _errorConnectionUnavailable) {
      return null;
    }
    final share = buffer.toDartString();
    return share.startsWith(r'\\') ? share : null;
  });

  @override
  VolumeIdentity? identify(String absolutePath) => _quietly(() {
    final drive = windowsDriveOf(absolutePath);
    if (drive != null && _driveTypeOf('$drive\\') == _driveRemote) {
      final share = _shareOf(drive);
      if (share != null) {
        return _identify(windowsPathThroughShare(absolutePath, share));
      }
    }
    return _identify(absolutePath);
  });

  VolumeIdentity? _identify(String absolutePath) {
    final mountPoint = _volumePathOf(absolutePath);
    if (mountPoint == null ||
        !p.windows.isWithin(mountPoint, absolutePath) && !p.windows.equals(mountPoint, absolutePath)) {
      return null;
    }
    final inside =
        '/${p.windows.split(p.windows.relative(absolutePath, from: mountPoint)).where((part) => part != '.').join('/')}';
    final isUnc = mountPoint.startsWith(r'\\');
    if (isUnc || _driveTypeOf(mountPoint) == _driveRemote) {
      return VolumeIdentity(
        volumeKey: windowsNetworkVolumeKey(mountPoint),
        mountPoint: mountPoint,
        pathInVolume: inside,
        isNetwork: true,
      );
    }
    final serial = _serialOf(mountPoint);
    return VolumeIdentity(
      volumeKey: serial == null
          ? windowsNetworkVolumeKey(mountPoint).replaceFirst('net-', 'mnt-')
          : windowsSerialKey(serial),
      mountPoint: mountPoint,
      pathInVolume: inside,
      isNetwork: false,
    );
  }

  /// A memory card reader's drive (DRIVE_REMOVABLE), an optical disc or a mounted ISO image (DRIVE_CDROM, whose content
  /// never changes anyway), or a fixed drive whose disk sits on a bus a user unplugs: USB hard disks and SSDs are
  /// DRIVE_FIXED, so their bus is asked of the disk itself
  @override
  bool isRemovable(String absolutePath) => _quietly(() {
    final mountPoint = _volumePathOf(absolutePath);
    if (mountPoint == null || mountPoint.startsWith(r'\\')) {
      return false;
    }
    final type = _driveTypeOf(mountPoint);
    if (type == _driveRemovable || type == _driveCdRom) {
      return true;
    }
    if (type != _driveFixed) {
      return false;
    }
    final storage = _storageOfVolume(mountPoint);
    return storage != null && isRemovableStorage(busType: storage.busType, removableMedia: storage.removableMedia);
  });

  /// How Windows describes the disk under the local folder [absolutePath]: its STORAGE_BUS_TYPE, and whether its
  /// medium comes out. Null when it does not say: a share, a volume spread over several disks.
  ({int busType, bool removableMedia})? storageOf(String absolutePath) => _quietly(() {
    final mountPoint = _volumePathOf(absolutePath);
    return mountPoint == null || mountPoint.startsWith(r'\\') ? null : _storageOfVolume(mountPoint);
  });

  ({int busType, bool removableMedia})? _storageOfVolume(String mountPoint) {
    final device = _volumeDeviceOf(mountPoint);
    return device == null ? null : _storageOfDevice(device);
  }

  /// "\\?\Volume{...}", the volume mounted at [mountPoint], without the trailing separator: CreateFileW opens the
  /// volume under that name, and its root folder with the separator
  String? _volumeDeviceOf(String mountPoint) => using((arena) {
    const length = 64;
    final buffer = arena<Uint16>(length).cast<Utf16>();
    final withSeparator = mountPoint.endsWith(r'\') ? mountPoint : '$mountPoint\\';
    if (_getVolumeNameForMountPoint(withSeparator.toNativeUtf16(allocator: arena), buffer, length) == 0) {
      return null;
    }
    final name = buffer.toDartString();
    return name.endsWith(r'\') ? name.substring(0, name.length - 1) : name;
  });

  ({int busType, bool removableMedia})? _storageOfDevice(String device) => using((arena) {
    final handle = _createFile(
      device.toNativeUtf16(allocator: arena),
      0,
      _fileShareRead | _fileShareWrite,
      nullptr,
      _openExisting,
      0,
      nullptr,
    );
    if (handle.address == -1) {
      return null;
    }
    try {
      // StorageDeviceProperty (0) and PropertyStandardQuery (0): the query is all zeros
      final query = arena<Uint8>(_storagePropertyQueryLength);
      final descriptor = arena<Uint8>(_deviceDescriptorLength);
      final returned = arena<Uint32>();
      final ok = _deviceIoControl(
        handle,
        _ioctlStorageQueryProperty,
        query,
        _storagePropertyQueryLength,
        descriptor,
        _deviceDescriptorLength,
        returned,
        nullptr,
      );
      if (ok == 0 || returned.value < _descriptorBusType + 4) {
        return null;
      }
      final view = ByteData.sublistView(descriptor.asTypedList(_deviceDescriptorLength));
      return (
        busType: view.getUint32(_descriptorBusType, Endian.little),
        removableMedia: view.getUint8(_descriptorRemovableMedia) != 0,
      );
    } finally {
      _closeHandle(handle);
    }
  });

  @override
  String? locate(String volumeKey, String pathInVolume) => _quietly(() {
    if (!volumeKey.startsWith('win-')) {
      // A share, or a volume without a serial number: only where it was
      final mountPoint = volumeKey.substring(4).replaceAll('/', r'\');
      final path = _joinInside(mountPoint.endsWith(r'\') ? mountPoint : '$mountPoint\\', pathInVolume, p.windows);
      return _isDirectory(path) ? path : null;
    }
    final drives = _getLogicalDrives();
    for (var letter = 0; letter < 26; letter++) {
      if (drives & (1 << letter) == 0) {
        continue;
      }
      final mountPoint = '${String.fromCharCode(0x41 + letter)}:\\';
      final type = _driveTypeOf(mountPoint);
      if (type == _driveUnknown || type == _driveNoRootDir || type == _driveRemote) {
        continue;
      }
      final serial = _serialOf(mountPoint);
      if (serial != null && windowsSerialKey(serial) == volumeKey) {
        final path = _joinInside(mountPoint, pathInVolume, p.windows);
        if (_isDirectory(path)) {
          return path;
        }
      }
    }
    return null;
  });
}

/// The key of a Windows volume by the serial number of its file system
String windowsSerialKey(int serial) => 'win-${serial.toRadixString(16).padLeft(8, '0')}';

/// The drive letter of [path] ("Z:"), null for a path that starts otherwise (a share, a relative path)
String? windowsDriveOf(String path) {
  final match = RegExp(r'^([A-Za-z]:)(?:[\\/]|$)').firstMatch(path);
  return match?.group(1)!.toUpperCase();
}

/// [path] on a mapped drive, reached through the [share] the drive leads to: "Z:\2024" and "\\nas\photos" give
/// "\\nas\photos\2024"
String windowsPathThroughShare(String path, String share) {
  final rest = path.substring(2).replaceAll('/', r'\').split(r'\').where((part) => part.isNotEmpty);
  final base = share.endsWith(r'\') ? share.substring(0, share.length - 1) : share;
  return rest.isEmpty ? '$base\\' : [base, ...rest].join(r'\');
}

/// The key of a share or of a mapped drive: its path, lower case with "/" separators ("net-//nas/photos", "net-z:")
String windowsNetworkVolumeKey(String mountPoint) {
  var path = mountPoint.replaceAll(r'\', '/').toLowerCase();
  while (path.length > 1 && path.endsWith('/') && !path.endsWith(':/')) {
    path = path.substring(0, path.length - 1);
  }
  if (path.endsWith(':/')) {
    path = path.substring(0, path.length - 1);
  }
  return 'net-$path';
}

// --- Linux -----------------------------------------------------------------------------------------------------------

/// One line of /proc/self/mountinfo: where a file system is mounted, its type and its source
class MountEntry {
  const MountEntry({required this.mountPoint, required this.fsType, required this.source});

  final String mountPoint;
  final String fsType;
  final String source;
}

// File systems whose files live on another machine: not watched, rescanned on demand
const _networkFileSystems = {
  'nfs',
  'nfs4',
  'cifs',
  'smb3',
  'smbfs',
  'fuse.sshfs',
  'sshfs',
  'fuse.rclone',
  'davfs',
  'fuse.gvfsd-fuse',
  'afpfs',
};

/// The entries of [mountInfo], the text of /proc/self/mountinfo (proc(5)): the fifth field is the mount point, the
/// file system type and the source follow the " - " separator; spaces and tabs come escaped as octal (\040)
List<MountEntry> parseMountInfo(String mountInfo) {
  final entries = <MountEntry>[];
  for (final line in mountInfo.split('\n')) {
    final separator = line.indexOf(' - ');
    if (separator < 0) {
      continue;
    }
    final head = line.substring(0, separator).split(' ');
    final tail = line.substring(separator + 3).split(' ');
    if (head.length < 5 || tail.length < 2) {
      continue;
    }
    entries.add(MountEntry(mountPoint: _unescapeMount(head[4]), fsType: tail[0], source: _unescapeMount(tail[1])));
  }
  return entries;
}

String _unescapeMount(String field) => field.replaceAllMapped(
  RegExp(r'\\([0-7]{3})'),
  (match) => String.fromCharCode(int.parse(match.group(1)!, radix: 8)),
);

/// The volumes of Linux, from the mount table: the file system UUID of a block device, else the share or the mount
/// point. [uuidOfSource] maps a device path ("/dev/sdb1") to the UUID /dev/disk/by-uuid names it by.
class MountTableVolumeProbe extends VolumeProbe {
  const MountTableVolumeProbe({required this.readMounts, required this.uuidOfSource});

  factory MountTableVolumeProbe.fromSystem() => MountTableVolumeProbe(
    readMounts: () {
      try {
        return parseMountInfo(File('/proc/self/mountinfo').readAsStringSync());
      } on FileSystemException {
        return const [];
      }
    },
    uuidOfSource: _systemUuids,
  );

  final List<MountEntry> Function() readMounts;
  final Map<String, String> Function() uuidOfSource;

  static Map<String, String> _systemUuids() {
    final uuids = <String, String>{};
    try {
      for (final link in Directory('/dev/disk/by-uuid').listSync(followLinks: false).whereType<Link>()) {
        try {
          uuids[link.resolveSymbolicLinksSync()] = p.basename(link.path);
        } on FileSystemException {
          // A device that went away while listing
        }
      }
    } on FileSystemException {
      // No udev in a container: mount points only
    }
    return uuids;
  }

  MountEntry? _mountOf(String path, List<MountEntry> mounts) {
    MountEntry? best;
    for (final mount in mounts) {
      final fits = mount.mountPoint == '/' || mount.mountPoint == path || p.posix.isWithin(mount.mountPoint, path);
      if (fits && (best == null || mount.mountPoint.length > best.mountPoint.length)) {
        best = mount;
      }
    }
    return best;
  }

  String _keyOf(MountEntry mount, Map<String, String> uuids) {
    if (_networkFileSystems.contains(mount.fsType)) {
      return 'net-${mount.source}';
    }
    final uuid = uuids[mount.source];
    return uuid != null ? 'uuid-$uuid' : 'mnt-${mount.mountPoint}';
  }

  @override
  VolumeIdentity? identify(String absolutePath) {
    final path = p.posix.normalize(absolutePath);
    final mount = _mountOf(path, readMounts());
    if (mount == null) {
      return null;
    }
    final relative = p.posix.relative(path, from: mount.mountPoint);
    return VolumeIdentity(
      volumeKey: _keyOf(mount, uuidOfSource()),
      mountPoint: mount.mountPoint,
      pathInVolume: relative == '.' ? '/' : '/$relative',
      isNetwork: _networkFileSystems.contains(mount.fsType),
    );
  }

  @override
  String? locate(String volumeKey, String pathInVolume) {
    final uuids = uuidOfSource();
    // The most recent mount wins, as the kernel lists them in mount order
    for (final mount in readMounts().reversed) {
      if (_keyOf(mount, uuids) == volumeKey) {
        final path = _joinInside(mount.mountPoint, pathInVolume, p.posix);
        if (_isDirectory(path)) {
          return path;
        }
      }
    }
    return null;
  }
}

/// macOS for now: the mount point under /Volumes, or the system volume, names the volume; a renamed drive is a new
/// root until the volume UUID is read
class MountPathVolumeProbe extends VolumeProbe {
  const MountPathVolumeProbe();

  @override
  VolumeIdentity? identify(String absolutePath) {
    final parts = p.posix.split(p.posix.normalize(absolutePath));
    final onVolume = parts.length >= 3 && parts[1] == 'Volumes';
    final mountPoint = onVolume ? p.posix.joinAll(parts.take(3)) : '/';
    final inside = parts.skip(onVolume ? 3 : 1).join('/');
    return VolumeIdentity(
      volumeKey: 'mnt-$mountPoint',
      mountPoint: mountPoint,
      pathInVolume: '/$inside',
      isNetwork: false,
    );
  }

  @override
  String? locate(String volumeKey, String pathInVolume) {
    if (!volumeKey.startsWith('mnt-')) {
      return null;
    }
    final path = _joinInside(volumeKey.substring(4), pathInVolume, p.posix);
    return _isDirectory(path) ? path : null;
  }
}
