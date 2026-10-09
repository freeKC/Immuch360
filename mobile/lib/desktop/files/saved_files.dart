// Files the app writes into a folder of the user on a computer (downloads, "Save to a folder"): names Windows accepts,
// never an existing file of the user replaced, never half a file under the final name, and a message saying where
// they went.

import 'dart:async';
import 'dart:io';

import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

final _log = Logger('SavedFiles');

/// Characters Windows refuses in a file name (and / for the other systems), plus the control characters
final _forbiddenCharacters = RegExp(r'[<>:"/\\|?*\x00-\x1F]');

/// Names Windows keeps for devices, with or without an extension
final _reservedNames = RegExp(r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\..*)?$', caseSensitive: false);

/// The longest name kept, well under the 255 characters of a path component, so that " (12)" still fits
const _maxNameLength = 200;

/// [name] as a file name every desktop accepts: forbidden characters (folder separators included) replaced, no
/// trailing dot or space (Windows drops them), no device name, not empty, not too long (the extension kept)
String safeFileName(String name) {
  var safe = name.replaceAll(_forbiddenCharacters, '_').trim();
  safe = safe.replaceAll(RegExp(r'[. ]+$'), '');
  if (safe.isEmpty || safe == '.' || safe == '..') {
    safe = 'file';
  }
  if (_reservedNames.hasMatch(safe)) {
    safe = '_$safe';
  }
  if (safe.length > _maxNameLength) {
    final extension = p.extension(safe);
    final keep = extension.length < 20 ? extension : '';
    safe = '${safe.substring(0, _maxNameLength - keep.length)}$keep';
  }
  return safe;
}

/// Creates an empty file named [name] in [folder], or "name (1)", "name (2)" and so on when it is taken, so that no
/// file of the user is ever replaced; the reserved file
Future<File> reserveFileIn(Directory folder, String name) async {
  final base = p.basenameWithoutExtension(name);
  final extension = p.extension(name);
  for (var occurrence = 0; occurrence < 10000; occurrence++) {
    final candidate = File(p.join(folder.path, occurrence == 0 ? name : '$base ($occurrence)$extension'));
    try {
      return await candidate.create(exclusive: true);
    } on PathExistsException {
      continue;
    } on FileSystemException {
      // Windows answers "access denied" when a folder has that name: taken as well. Anything else (a folder that
      // cannot be written) fails the same way for every name.
      if (FileSystemEntity.typeSync(candidate.path, followLinks: false) != FileSystemEntityType.notFound) {
        continue;
      }
      rethrow;
    }
  }
  throw FileSystemException('No free name left', p.join(folder.path, name));
}

/// Moves [source] into [folder] as [name] (or the first free variant of it): a rename on the same drive, otherwise a
/// copy written beside the final name then renamed over it, and the source removed. The file kept.
Future<File> moveIntoFolder(File source, Directory folder, String name) async {
  final target = await reserveFileIn(folder, name);
  try {
    return await source.rename(target.path);
  } on FileSystemException {
    // Another drive: copied, then the source goes, as a move would
  }
  final kept = await _copyOver(source, target);
  try {
    await source.delete();
  } on FileSystemException catch (error) {
    _log.warning('The downloaded file stays in the temporary folder: ${error.message}');
  }
  return kept;
}

/// Copies [source] into [folder] as [name] (or the first free variant of it); the copy
Future<File> copyIntoFolder(File source, Directory folder, String name) async {
  final target = await reserveFileIn(folder, name);
  return _copyOver(source, target);
}

/// [source] copied over the reserved, empty [target] through a temporary name, so that a failed copy never leaves a
/// truncated file under the final name; on failure the reservation is removed too
Future<File> _copyOver(File source, File target) async {
  final partial = File('${target.path}.part');
  try {
    await source.copy(partial.path);
    return await partial.rename(target.path);
  } catch (_) {
    for (final leftover in [partial, target]) {
      try {
        await leftover.delete();
      } on FileSystemException {
        // already gone
      }
    }
    rethrow;
  }
}

/// Opens [folder] in the file manager of the system (Explorer, Finder, the Linux one)
Future<bool> openFolder(String folder) => launchUrl(Uri.directory(folder));

Timer? _announceTimer;
String? _announcedFolder;

/// "Saved in" and the folder, with a button that opens it, once for a burst of files saved within a second or two of each
/// other (a selection of thirty photos downloads in a row)
void announceSavedFolder(String folder, {Duration settle = const Duration(milliseconds: 1500)}) {
  _announcedFolder = folder;
  _announceTimer?.cancel();
  _announceTimer = Timer(settle, () {
    final shown = _announcedFolder;
    _announcedFolder = null;
    if (shown == null) {
      return;
    }
    snackbar.success(
      StaticTranslations.instance.desktop_download_folder_saved(folder: shown),
      action: SnackbarAction(label: StaticTranslations.instance.open, onPressed: () => openFolder(shown)),
    );
  });
}
