// Where the 3D photo of each photo of a selection goes (design-final 2026-10-26, section 2.5; spec 6.1), source by
// source:
//
// - A folder of the library on a local or external disk: next to the original. The folder is checked when the dialog
//   opens; a refusal preselects "A folder of my choice" with its reason, and is kept for that root.
// - A network folder mounted by the system (Z:, \\nas\photos, a mount point): next to the original, after a yes given
//   once for that root. Without it, nothing is written nor tried in that folder; with it, the same check. A refusal is
//   never tried again by itself.
// - A file kept online only (OneDrive): next to the original; the dialog says that reading it downloads it.
// - A file opened with the program: next to it when its volume is local, else as a network folder, the yes given for
//   its volume.
// - A share opened in the app that takes files (SMB, WebDAV): next to the original on the share, after the same yes as
//   a network folder, given once for the root the share was added at (named as that share mounted as a drive would
//   be, "net-//nas/photos:/", so that one yes covers both); the folder of the share is then checked by an empty
//   hidden file written there and deleted (share_writer.dart). The version is made on this computer and put there by
//   the writer of the shares, never over a file (share_publisher.dart). A refusal is kept for that root.
// - DLNA, Plex, the Immich server: a chosen folder, Downloads/Immuch360 by default. They are never written to.
//
// DestinationPlanner gives the plan of one photo from the settings, without touching any file. DestinationSession
// follows the conversion dialog from its opening to its launch or its closing: it plans every photo, checks the
// folders that may be tried through WriteProbe, falls back on the chosen folder with the reason, and keeps the yes and
// the refusals in desktop_ai.json.
//
// macOS: the library does not mark network roots there yet (volume_id.dart reads the mount point only), so the mount
// table of the system tells which folders are on a NAS, and those wait for the yes as on the other systems. The volume
// of such a folder is its own mount, wherever it is mounted (/Volumes/photos, /net/nas/photos): a yes given for a
// file opened from it never covers the boot disk.

import 'dart:io';

import 'package:immich_mobile/desktop/ai/creator/collisions.dart';
import 'package:immich_mobile/desktop/ai/creator/network_root_consent.dart';
import 'package:immich_mobile/desktop/ai/creator/safe_writer.dart';
import 'package:immich_mobile/desktop/ai/creator/write_probe.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/files/download_folder.dart';
import 'package:immich_mobile/desktop/library/folder_library.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/volume_id.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('AiDestination');

/// Where the original of a job is, as far as writing next to it goes
sealed class OriginalLocation {
  const OriginalLocation({required this.name});

  /// The name of the original, which names its 3D photo
  final String name;
}

/// A photo of a folder of the library
final class LibraryOriginal extends OriginalLocation {
  const LibraryOriginal({
    required super.name,
    required this.path,
    required this.rootId,
    required this.rootPath,
    required this.rootIsNetwork,
    this.cloudOnly = false,
  });

  /// The photo behind the local asset [assetId] of [library], null when the library does not have it
  static LibraryOriginal? of(FolderLibrary library, String assetId) {
    final file = library.file(assetId);
    final indexed = library.index.file(assetId);
    final root = indexed == null ? null : library.index.root(indexed.rootId);
    if (file == null || root == null) {
      return null;
    }
    return LibraryOriginal(
      name: file.name,
      path: file.path,
      rootId: root.id,
      rootPath: root.path,
      rootIsNetwork: root.isNetwork,
      cloudOnly: file.cloudOnly,
    );
  }

  final String path;

  /// The root of the library the photo is in: its id, where it is, and whether it is a network folder
  final String rootId;
  final String rootPath;
  final bool rootIsNetwork;

  /// Kept online only (OneDrive): reading it downloads it
  final bool cloudOnly;
}

/// A file opened with the program (Open with, a drop, the command line), outside the library
final class OpenedOriginal extends OriginalLocation {
  const OpenedOriginal({required super.name, required this.path});

  final String path;
}

/// A file of a share opened in the app (SMB, WebDAV, DLNA, Plex), read through a temporary copy. [folder] is where it
/// is on its share when the app may write there (SMB, WebDAV), null for a media server, which takes no file.
final class ShareOriginal extends OriginalLocation {
  const ShareOriginal({required super.name, this.folder});

  final ShareFolder? folder;
}

/// A folder of a share opened in the app that takes new files, as the destination sees it
class ShareFolder {
  const ShareFolder({
    required this.sourceId,
    required this.path,
    required this.label,
    required this.rootKey,
    required this.rootLabel,
  });

  /// The share, and the folder in it ("/2024", "/" for its top), "/" separated
  final String sourceId;
  final String path;

  /// The folder as the dialog names it: "\\nas\photos\2024" on Windows, "smb://nas/photos/2024",
  /// "https://nas:5006/dav/2024"
  final String label;

  /// What the yes for this network folder and a refusal are kept for: the root the share was added at, named as the
  /// root of a share mounted as a drive would be ("net-//nas/photos:/pictures")
  final String rootKey;

  /// That root, as the question of the network folder names it
  final String rootLabel;

  @override
  bool operator ==(Object other) =>
      other is ShareFolder &&
      other.sourceId == sourceId &&
      other.path == path &&
      other.label == label &&
      other.rootKey == rootKey &&
      other.rootLabel == rootLabel;

  @override
  int get hashCode => Object.hash(sourceId, path, label, rootKey, rootLabel);

  @override
  String toString() => 'ShareFolder($label, root: $rootKey)';
}

/// A photo of DLNA, Plex or the Immich server, read through a temporary copy
final class ServerOriginal extends OriginalLocation {
  const ServerOriginal({required super.name});
}

/// What the destination needs of the volume of a folder
class FolderVolume {
  const FolderVolume({
    required this.volumeKey,
    required this.folderKey,
    required this.mountPoint,
    required this.isNetwork,
  });

  /// The volume, what a yes given for a file opened with the program covers
  final String volumeKey;

  /// The folder named as a root of the library would be (VolumeIdentity.rootId): what a yes and a refusal kept are
  /// compared with
  final String folderKey;

  /// Where the volume is mounted, the folder the question of a network volume names
  final String mountPoint;
  final bool isNetwork;
}

/// The volumes of the folders of this computer
abstract interface class FolderVolumes {
  /// The volume of [folder], null when it cannot be read
  FolderVolume? of(String folder);

  /// Whether [folder] is on a network file system that the library does not mark as such: macOS, whose roots are
  /// never isNetwork yet
  bool isNetworkMount(String folder);
}

/// One line of the mount table of macOS
class MacMount {
  const MacMount(this.mountPoint, {required this.local});

  final String mountPoint;

  /// The file system says "local"; a share (smbfs, nfs, afpfs, webdav) does not
  final bool local;
}

final _macMountLine = RegExp(r'^(.*) on (/.*) \(([^()]*)\)$');

/// The file systems of [output], the text of /sbin/mount on macOS: "/dev/disk3s1s1 on / (apfs, sealed, local,
/// read-only, journaled)", "//me@nas._smb._tcp.local/photos on /Volumes/photos (smbfs, nodev, nosuid, mounted by me)".
/// The automounter's own lines are left out: what it mounts gets a line of its own.
List<MacMount> parseMacMounts(String output) => [
  for (final line in output.split('\n'))
    if (_macMountLine.firstMatch(line.trimRight()) case final match?)
      if (match.group(3)!.split(',').map((option) => option.trim()).toList() case final options
          when options.first != 'autofs')
        MacMount(match.group(2)!, local: options.contains('local')),
];

/// The network mount of [mounts] that holds [folder]: the deepest mount point that holds it, when it is not local;
/// null for a folder on a local disk. Case is ignored, as on the disks of macOS.
MacMount? networkMountOf(List<MacMount> mounts, String folder) {
  final path = p.posix.normalize(folder).toLowerCase();
  MacMount? deepest;
  for (final mount in mounts) {
    final point = p.posix.normalize(mount.mountPoint).toLowerCase();
    final holds = point == '/' || point == path || p.posix.isWithin(point, path);
    if (holds && (deepest == null || mount.mountPoint.length > deepest.mountPoint.length)) {
      deepest = mount;
    }
  }
  return deepest == null || deepest.local ? null : deepest;
}

/// Whether [folder] is on a network file system of [mounts]
bool isOnNetworkMount(List<MacMount> mounts, String folder) => networkMountOf(mounts, folder) != null;

/// The volumes of this computer, through volume_id.dart, and on macOS its mount table too
class SystemFolderVolumes implements FolderVolumes {
  SystemFolderVolumes({VolumeProbe? probe, LibraryPathRules? rules, bool? macOS, String Function()? readMacMounts})
    : _probe = probe ?? VolumeProbe.thisComputer(),
      _rules = rules ?? LibraryPathRules.thisComputer(),
      _macOS = macOS ?? Platform.isMacOS,
      _readMacMounts = readMacMounts ?? _systemMacMounts;

  final VolumeProbe _probe;
  final LibraryPathRules _rules;
  final bool _macOS;
  final String Function() _readMacMounts;
  List<MacMount>? _macMounts;
  // A selection often holds many photos of one folder: its volume is read once
  final _volumes = <String, FolderVolume?>{};

  static String _systemMacMounts() {
    try {
      final result = Process.runSync('/sbin/mount', const []);
      return result.exitCode == 0 ? '${result.stdout}' : '';
    } on ProcessException catch (error) {
      _log.warning('The mount table cannot be read: ${error.message}');
      return '';
    }
  }

  @override
  FolderVolume? of(String folder) => _volumes.putIfAbsent(folder, () => _identify(folder));

  FolderVolume? _identify(String folder) {
    final identity = _networkMountIdentity(folder) ?? _probe.identify(folder);
    if (identity == null) {
      return null;
    }
    return FolderVolume(
      volumeKey: identity.volumeKey,
      folderKey: identity.rootId(caseFold: _rules.caseFold),
      mountPoint: identity.mountPoint,
      isNetwork: identity.isNetwork,
    );
  }

  /// On macOS, the volume of a [folder] on a network mount, read from the mount table: "mnt-" and its mount point, as
  /// MountPathVolumeProbe names the volumes under /Volumes; null elsewhere
  VolumeIdentity? _networkMountIdentity(String folder) {
    final mount = _macOS ? networkMountOf(_mounts, folder) : null;
    if (mount == null) {
      return null;
    }
    final point = p.posix.normalize(mount.mountPoint);
    final path = p.posix.normalize(folder);
    final inside = path.length > point.length ? path.substring(point.length) : '';
    return VolumeIdentity(
      volumeKey: 'mnt-${mount.mountPoint}',
      mountPoint: mount.mountPoint,
      pathInVolume: inside.startsWith('/') ? inside : '/$inside',
      isNetwork: true,
    );
  }

  List<MacMount> get _mounts => _macMounts ??= parseMacMounts(_readMacMounts());

  @override
  bool isNetworkMount(String folder) => _macOS && isOnNetworkMount(_mounts, folder);
}

/// Where a 3D photo goes
enum DestinationKind {
  /// In the folder of its original
  nextToOriginal,

  /// In "A folder of my choice": the one of the settings, the download folder, or one chosen in the dialog
  chosenFolder,
}

/// Why a 3D photo does not go next to its original
enum DestinationReason {
  /// A share, a media server or the Immich server, never written to
  sourceReadOnly,

  /// The folder of the original refused a new file, now or at an earlier conversion (kept for its root)
  folderReadOnly,

  /// No space left next to the original
  diskFull,

  /// The folder of the original cannot be reached
  folderMissing,

  /// The folder of the original failed for another reason
  writeFailed,

  /// The user said no to the network folder
  networkDeclined,
}

/// Where the 3D photo of one photo goes, and what the dialog says about it
class PlannedDestination {
  const PlannedDestination({
    required this.kind,
    required this.folder,
    required this.isNetwork,
    this.reason,
    this.message,
    this.consentKey,
    this.consentFolder,
    this.rootKey,
    this.cloudDownload = false,
    this.shareHint = false,
    this.share,
  });

  final DestinationKind kind;

  /// The folder the 3D photo goes to. Next to an original on the network waiting for the yes, the folder of the
  /// original, which nothing touches before the yes.
  final String folder;

  /// Whether [folder] is on the network: no "saved on this computer only" after
  final bool isNetwork;

  /// Why the 3D photo does not go next to its original; null when it does, or when the settings say a chosen folder
  final DestinationReason? reason;

  /// The words of the system when the folder of the original failed its check, for destinationReasonText: the check
  /// of [folder] is then that of the chosen folder
  final String? message;

  /// The root or volume a "Yes, for this network folder" covers, while that yes is not given
  final String? consentKey;

  /// The folder the question names: the root of the library, or the volume of an opened file
  final String? consentFolder;

  /// What a refusal of the folder of the original is kept for: the id of its root, or the folder of an opened file
  final String? rootKey;

  /// Reading the original downloads it from OneDrive
  final bool cloudDownload;

  /// "Choose a folder" first, with the tip to add the share as a network drive
  final bool shareHint;

  /// The folder of a share opened in the app the version goes to, next to its original: [folder] is then its label,
  /// checked and written through the writer of the shares, never as a folder of this computer
  final ShareFolder? share;

  /// Whether nothing may be tried before the user answers the question of the network folder
  bool get waitsForConsent => consentKey != null;

  @override
  String toString() =>
      'PlannedDestination(${kind.name}, $folder${reason == null ? '' : ', ${reason!.name}'}'
      '${consentKey == null ? '' : ', waits for $consentKey'})';
}

/// The folder kept in [fallbacks] for [key]: its own, or that of a root around it, the deepest one
String? keptFallbackFor(Map<String, String> fallbacks, String key) {
  String? best;
  String? folder;
  for (final MapEntry(key: kept, value: target) in fallbacks.entries) {
    if ((kept == key || rootContains(kept, key)) && (best == null || kept.length > best.length)) {
      best = kept;
      folder = target;
    }
  }
  return folder;
}

/// The plan of each photo, from the settings, without touching any file
class DestinationPlanner {
  DestinationPlanner({
    required this.settings,
    required this.chosenFolder,
    required this.volumes,
    this.chosenInDialog = false,
    LibraryPathRules? rules,
  }) : _rules = rules ?? LibraryPathRules.thisComputer();

  final DesktopAiSettings settings;

  /// "A folder of my choice": the folder of the settings, else the download folder, or the one chosen in the dialog
  final String chosenFolder;

  /// Whether [chosenFolder] was chosen in this dialog: it then also takes the place of the folders kept for roots
  /// that refused
  final bool chosenInDialog;
  final FolderVolumes volumes;
  final LibraryPathRules _rules;
  final _networkFolders = <String, bool>{};

  /// Where the 3D photo of [original] goes
  PlannedDestination plan(OriginalLocation original) => switch (original) {
    ShareOriginal() => _share(original),
    ServerOriginal() => chosen(reason: DestinationReason.sourceReadOnly),
    LibraryOriginal() => _library(original),
    OpenedOriginal() => _opened(original),
  };

  PlannedDestination _library(LibraryOriginal original) {
    if (settings.destination == AiDestination.folder) {
      return chosen(cloudDownload: original.cloudOnly);
    }
    final kept = keptFallbackFor(settings.rootFallbacks, original.rootId);
    if (kept != null) {
      return chosen(
        folder: kept,
        reason: DestinationReason.folderReadOnly,
        rootKey: original.rootId,
        cloudDownload: original.cloudOnly,
      );
    }
    final network = original.rootIsNetwork || volumes.isNetworkMount(original.rootPath);
    final allowed = !network || consentGiven(settings.networkRootsAllowed, original.rootId);
    return PlannedDestination(
      kind: DestinationKind.nextToOriginal,
      folder: _rules.context.dirname(original.path),
      isNetwork: network,
      consentKey: allowed ? null : original.rootId,
      consentFolder: allowed ? null : original.rootPath,
      rootKey: original.rootId,
      cloudDownload: original.cloudOnly,
    );
  }

  PlannedDestination _share(ShareOriginal original) {
    final folder = original.folder;
    if (folder == null) {
      // A media server takes no file
      return chosen(reason: DestinationReason.sourceReadOnly);
    }
    if (settings.destination == AiDestination.folder) {
      return chosen();
    }
    final key = folder.rootKey;
    final kept = keptFallbackFor(settings.rootFallbacks, key);
    if (kept != null) {
      return chosen(folder: kept, reason: DestinationReason.folderReadOnly, rootKey: key);
    }
    final allowed = consentGiven(settings.networkRootsAllowed, key);
    return PlannedDestination(
      kind: DestinationKind.nextToOriginal,
      folder: folder.label,
      isNetwork: true,
      consentKey: allowed ? null : key,
      consentFolder: allowed ? null : folder.rootLabel,
      rootKey: key,
      share: folder,
    );
  }

  PlannedDestination _opened(OpenedOriginal original) {
    if (settings.destination == AiDestination.folder) {
      return chosen();
    }
    final folder = _rules.context.dirname(original.path);
    final volume = volumes.of(folder);
    if (volume == null) {
      return chosen(reason: DestinationReason.folderMissing);
    }
    final kept = keptFallbackFor(settings.rootFallbacks, volume.folderKey);
    if (kept != null) {
      return chosen(folder: kept, reason: DestinationReason.folderReadOnly, rootKey: volume.folderKey);
    }
    final allowed = !volume.isNetwork || consentGiven(settings.networkRootsAllowed, volume.folderKey);
    return PlannedDestination(
      kind: DestinationKind.nextToOriginal,
      folder: folder,
      isNetwork: volume.isNetwork,
      consentKey: allowed ? null : volume.volumeKey,
      consentFolder: allowed ? null : volume.mountPoint,
      rootKey: volume.folderKey,
    );
  }

  /// A 3D photo in the chosen folder, or in [folder] when one was kept for its root and none was chosen in the dialog
  PlannedDestination chosen({
    String? folder,
    DestinationReason? reason,
    String? message,
    String? rootKey,
    bool cloudDownload = false,
    bool shareHint = false,
  }) {
    final target = chosenInDialog || folder == null ? chosenFolder : folder;
    return PlannedDestination(
      kind: DestinationKind.chosenFolder,
      folder: target,
      isNetwork: _isNetworkFolder(target),
      reason: reason,
      message: message,
      rootKey: rootKey,
      cloudDownload: cloudDownload,
      shareHint: shareHint,
    );
  }

  /// [planned], which cannot go next to its original for [reason] (with the [message] of the system), in the chosen
  /// folder
  PlannedDestination fallBack(PlannedDestination planned, DestinationReason reason, {String? message}) {
    final key = planned.rootKey;
    return chosen(
      folder: key == null ? null : keptFallbackFor(settings.rootFallbacks, key),
      reason: reason,
      message: message,
      rootKey: key,
      cloudDownload: planned.cloudDownload,
      shareHint: planned.shareHint,
    );
  }

  bool _isNetworkFolder(String folder) =>
      _networkFolders[folder] ??= volumes.of(folder)?.isNetwork ?? volumes.isNetworkMount(folder);
}

/// A photo of the selection of the conversion dialog
class DestinationJob {
  const DestinationJob({required this.id, required this.original, this.kind = ImmersiveKind.stereoPhoto});

  /// The id its job takes in the queue
  final String id;
  final OriginalLocation original;

  /// What its job makes, the 3D photo by default: the folder is checked with the partial file of the name of that
  /// version, which the job then takes over
  final ImmersiveKind kind;

  /// The name its version takes: "salon_3D_LRF_Full_SBS.jpg", "salon_scene3D.jpg"
  String get finalName => versionTargetName(kind, original.name);
}

/// The destinations of a selection, from the opening of the conversion dialog to its launch or its closing. Its
/// gestures run one after the other, in the order they came, even when the dialog does not wait for each one: two
/// close clicks never check a folder twice, and the closing comes after the checks before it.
class DestinationSession {
  DestinationSession(
    this.jobs, {
    DesktopAiSettingsStore? store,
    SafeWriter? writer,
    FolderVolumes? volumes,
    Future<String> Function()? downloadFolder,
    LibraryPathRules? rules,
    int maxCheckedFolders = 50,
    this._shareProbe,
  }) : _store = store ?? DesktopAiSettingsStore.instance,
       _volumes = volumes ?? SystemFolderVolumes(rules: rules),
       _downloadFolder = downloadFolder ?? DownloadFolder.instance.currentPath,
       _rules = rules ?? LibraryPathRules.thisComputer(),
       _probe = WriteProbe(writer ?? SafeWriter.instance, maxFolders: maxCheckedFolders, rules: rules);

  final List<DestinationJob> jobs;
  final DesktopAiSettingsStore _store;
  final FolderVolumes _volumes;
  final Future<String> Function() _downloadFolder;
  final LibraryPathRules _rules;
  final WriteProbe _probe;

  /// Checks a folder of a share opened in the app (checkShareFolder through its writer); none: such a folder fails
  final Future<ProbeResult> Function(ShareFolder folder)? _shareProbe;

  /// The checks of the folders of the shares, by their label
  final _shareChecks = <String, ProbeResult>{};

  var _settings = const DesktopAiSettings();
  String? _defaultFolder;
  String? _folderChosenHere;
  AiDestination? _saveTo;
  final _declined = <String>{};
  var _plans = <String, PlannedDestination>{};
  Future<void> _gestures = Future.value();
  var _closed = false;

  /// Where each photo goes now, by job id
  Map<String, PlannedDestination> get destinations => Map.unmodifiable(_plans);

  /// The settings as the dialog leaves them (the yes given, the refusals kept)
  DesktopAiSettings get settings => _settings;

  /// The network folders waiting for a yes or a no: the key to answer with, and the folder the question names
  Map<String, String> get pendingConsents => {
    for (final plan in _plans.values) ?plan.consentKey: plan.consentFolder ?? plan.folder,
  };

  /// The check of the folder of [jobId]: null while it was not checked (a network folder before the yes)
  ProbeResult? checkOf(String jobId) {
    final plan = _plans[jobId];
    return plan == null ? null : _resultOf(plan);
  }

  /// The check of the folder of [plan]: through the writer of its share for a folder of a share
  ProbeResult? _resultOf(PlannedDestination plan) =>
      plan.share != null ? _shareChecks[plan.folder] : _probe.resultOf(plan.folder);

  /// The dialog opens: every photo planned, and the folders that may be tried now checked
  Future<void> open() => _inTurn(() async {
    _settings = await _store.read();
    _defaultFolder = await _downloadFolder();
    await _settle();
  });

  /// "Yes, for this network folder": kept for [key], then its folders checked
  Future<void> allowNetwork(String key) => _inTurn(() async {
    _settings = await NetworkRootConsent(store: _store).allow(key);
    _declined.remove(key);
    await _settle();
  });

  /// "No, choose a folder": the photos of [key] go to the chosen folder, and nothing is tried in the network folder
  Future<void> declineNetwork(String key) => _inTurn(() async {
    _declined.add(key);
    await _settle();
  });

  /// "Change": every photo that goes to a chosen folder goes to [folder], kept for the roots that refused
  Future<void> chooseFolder(String folder) => _inTurn(() async {
    _folderChosenHere = folder;
    await _settle();
  });

  /// "Save to" for the whole selection. Next to the original forgets the refusals kept for the roots of the selection
  /// and checks their folders again: the user asked for it.
  Future<void> saveTo(AiDestination destination) => _inTurn(() async {
    _saveTo = destination;
    if (destination == AiDestination.nextToOriginal) {
      final keys = {for (final plan in _plans.values) ?plan.rootKey};
      if (_settings.rootFallbacks.keys.any((kept) => keys.any((key) => kept == key || rootContains(kept, key)))) {
        _settings = await _store.update(
          (settings) => settings.copyWith(
            rootFallbacks: Map.unmodifiable({
              for (final MapEntry(:key, :value) in settings.rootFallbacks.entries)
                if (!keys.any((planned) => key == planned || rootContains(key, planned))) key: value,
            }),
          ),
        );
      }
      _probe.forgetRefusals();
      _shareChecks.removeWhere((_, result) => !result.accepted);
    }
    await _settle();
  });

  /// At the launch, once the last gesture is done: the partial file the check made for [jobId], which its job takes
  /// over; null when it has none
  PartFile? takePart(String jobId) => _probe.take(jobId);

  /// The dialog closed, launched or not: after the gestures before it, the partial files no job took are deleted, and
  /// the gestures after it check nothing
  Future<void> close() => _inTurn(() async {
    _closed = true;
    await _probe.release();
  });

  /// [gesture] once the gestures before it are done; a gesture that fails does not stop the next ones
  Future<void> _inTurn(Future<void> Function() gesture) {
    final next = _gestures.then((_) => gesture());
    _gestures = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> _settle() async {
    if (_closed) {
      return;
    }
    for (var pass = 0; ; pass++) {
      _plans = _planAll();
      await _probe.keepOnly({
        for (final MapEntry(:key, :value) in _plans.entries)
          if (!value.waitsForConsent && value.share == null) key: value.folder,
      });
      final requests = _requests();
      final shares = {
        for (final plan in _plans.values)
          if (plan.share case final folder? when !plan.waitsForConsent && !_shareChecks.containsKey(plan.folder))
            plan.folder: folder,
      };
      if (pass == 3 || (shares.isEmpty && requests.every((request) => _probe.resultOf(request.folder) != null))) {
        break;
      }
      await _probe.check(requests);
      for (final MapEntry(key: label, value: folder) in shares.entries) {
        _shareChecks[label] = await _checkShare(folder);
      }
    }
    await _keepRefusals();
  }

  Map<String, PlannedDestination> _planAll() {
    final settings = _saveTo == null ? _settings : _settings.copyWith(destination: _saveTo);
    final planner = DestinationPlanner(
      settings: settings,
      chosenFolder: _folderChosenHere ?? settings.folder ?? _defaultFolder ?? '',
      chosenInDialog: _folderChosenHere != null,
      volumes: _volumes,
      rules: _rules,
    );
    return {for (final job in jobs) job.id: _refine(planner, planner.plan(job.original))};
  }

  /// The check of a folder of a share; one that cannot be made fails it with its words
  Future<ProbeResult> _checkShare(ShareFolder folder) async {
    final probe = _shareProbe;
    if (probe == null) {
      return const ProbeResult(ProbeStatus.failed);
    }
    try {
      return await probe(folder);
    } catch (error) {
      _log.warning('The folder ${folder.label} could not be checked: $error');
      return ProbeResult(ProbeStatus.failed, message: '$error');
    }
  }

  /// [plan] after the answers and the checks of this dialog
  PlannedDestination _refine(DestinationPlanner planner, PlannedDestination plan) {
    if (plan.consentKey case final key? when _declined.contains(key)) {
      return planner.fallBack(plan, DestinationReason.networkDeclined);
    }
    if (plan.kind == DestinationKind.nextToOriginal) {
      final result = _resultOf(plan);
      if (result != null && !result.accepted) {
        return planner.fallBack(plan, _reasonOf(result.status), message: result.message);
      }
    }
    return plan;
  }

  static DestinationReason _reasonOf(ProbeStatus status) => switch (status) {
    ProbeStatus.readOnly => DestinationReason.folderReadOnly,
    ProbeStatus.diskFull => DestinationReason.diskFull,
    ProbeStatus.missing => DestinationReason.folderMissing,
    ProbeStatus.failed || ProbeStatus.ready || ProbeStatus.notChecked => DestinationReason.writeFailed,
  };

  List<ProbeRequest> _requests() => [
    for (final job in jobs)
      if (_plans[job.id] case final plan? when !plan.waitsForConsent && plan.share == null)
        ProbeRequest(
          jobId: job.id,
          folder: plan.folder,
          finalName: job.finalName,
          createFolder: plan.kind == DestinationKind.chosenFolder,
        ),
  ];

  /// The roots whose folder refused, and the folder their photos went to instead, kept in desktop_ai.json: the next
  /// dialog goes to that folder at once, without trying the refused one again
  Future<void> _keepRefusals() async {
    final keep = <String, String>{};
    for (final plan in _plans.values) {
      final key = plan.rootKey;
      if (key != null &&
          plan.reason == DestinationReason.folderReadOnly &&
          keptFallbackFor(_settings.rootFallbacks, key) != plan.folder) {
        keep[key] = plan.folder;
      }
    }
    if (keep.isEmpty) {
      return;
    }
    _settings = await _store.update(
      (settings) => settings.copyWith(rootFallbacks: Map.unmodifiable({...settings.rootFallbacks, ...keep})),
    );
  }
}

/// The words the dialog shows for [reason], null when there is nothing to explain; [message] is the one of the
/// system for a folder that failed otherwise
String? destinationReasonText(Translations t, DestinationReason? reason, {String? message}) => switch (reason) {
  null || DestinationReason.networkDeclined => null,
  DestinationReason.sourceReadOnly => t.ai_immersive_source_read_only,
  DestinationReason.folderReadOnly => t.ai_immersive_original_folder_read_only,
  DestinationReason.diskFull => t.ai_immersive_failed_disk_full,
  DestinationReason.folderMissing => t.ai_immersive_failed_source,
  DestinationReason.writeFailed => t.ai_immersive_failed_write(message: message ?? ''),
};
