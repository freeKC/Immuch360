// The settings of the AI features that only a computer has (design-final 2026-10-26, section 4.4): where the 3D photos
// go, what to do when one exists, the network folders the user allowed to receive them, and whether the virtual album
// of the generated photos was excluded from the backup once. Kept in desktop_ai.json of the support folder, beside
// desktop_files.json and written the same way: a whole new file renamed over the old one, so a crash never leaves half
// a setting. Keys this build does not know (a newer version) are kept as they are.
//
// The shared switches (the AI features on or off, the older headsets) are SettingsKey entries, see AiImmersiveConfig.

import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Where a 3D photo goes by default
enum AiDestination { nextToOriginal, folder }

/// What happens when the name of the 3D photo is taken
enum AiWhenExists {
  /// "name (1)", the default
  keepBoth,

  /// Only a file that carries our XMP and a DerivativeId, read again just before; any other file is kept, with both
  replace,
  skip,
}

/// Whether the virtual album "Immuch360 3D (AI)" was put in the excluded albums of the backup. Until it was, no
/// conversion writes into a folder of the library (design 4.3).
enum AiGeneratedAlbumState { pending, excluded }

/// The settings in desktop_ai.json
class DesktopAiSettings {
  const DesktopAiSettings({
    this.destination = AiDestination.nextToOriginal,
    this.folder,
    this.whenExists = AiWhenExists.keepBoth,
    this.skipExisting = true,
    this.networkRootsAllowed = const [],
    this.rootFallbacks = const {},
    this.generatedAlbumState = AiGeneratedAlbumState.pending,
  });

  final AiDestination destination;

  /// The folder chosen for [AiDestination.folder]; null for the download folder
  final String? folder;
  final AiWhenExists whenExists;

  /// Skip a photo that already has a version with the same settings
  final bool skipExisting;

  /// The roots or volumes of network folders where the user allowed the 3D photos next to the originals
  final List<String> networkRootsAllowed;

  /// The folder used instead, per root of the library whose folders refused a new file
  final Map<String, String> rootFallbacks;
  final AiGeneratedAlbumState generatedAlbumState;

  DesktopAiSettings copyWith({
    AiDestination? destination,
    String? Function()? folder,
    AiWhenExists? whenExists,
    bool? skipExisting,
    List<String>? networkRootsAllowed,
    Map<String, String>? rootFallbacks,
    AiGeneratedAlbumState? generatedAlbumState,
  }) => DesktopAiSettings(
    destination: destination ?? this.destination,
    folder: folder == null ? this.folder : folder(),
    whenExists: whenExists ?? this.whenExists,
    skipExisting: skipExisting ?? this.skipExisting,
    networkRootsAllowed: networkRootsAllowed ?? this.networkRootsAllowed,
    rootFallbacks: rootFallbacks ?? this.rootFallbacks,
    generatedAlbumState: generatedAlbumState ?? this.generatedAlbumState,
  );

  Map<String, Object?> toJson() => {
    'destination': destination.name,
    'folder': folder,
    'whenExists': whenExists.name,
    'skipExisting': skipExisting,
    'networkRootsAllowed': networkRootsAllowed,
    'rootFallbacks': rootFallbacks,
    'generatedAlbumState': generatedAlbumState.name,
  };

  /// The settings of [json], a default for each value that is missing or not understood
  factory DesktopAiSettings.fromJson(Map<String, Object?> json) {
    T named<T extends Enum>(List<T> values, Object? value, T fallback) =>
        values.where((candidate) => candidate.name == value).firstOrNull ?? fallback;
    const defaults = DesktopAiSettings();
    final folder = json['folder'];
    final roots = json['networkRootsAllowed'];
    final fallbacks = json['rootFallbacks'];
    final skip = json['skipExisting'];
    return DesktopAiSettings(
      destination: named(AiDestination.values, json['destination'], defaults.destination),
      folder: folder is String && folder.isNotEmpty ? folder : null,
      whenExists: named(AiWhenExists.values, json['whenExists'], defaults.whenExists),
      skipExisting: skip is bool ? skip : defaults.skipExisting,
      networkRootsAllowed: roots is List ? List.unmodifiable(roots.whereType<String>()) : const [],
      rootFallbacks: fallbacks is Map
          ? Map.unmodifiable({
              for (final MapEntry(:key, :value) in fallbacks.entries)
                if (key is String && value is String) key: value,
            })
          : const {},
      generatedAlbumState: named(
        AiGeneratedAlbumState.values,
        json['generatedAlbumState'],
        defaults.generatedAlbumState,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DesktopAiSettings &&
      other.destination == destination &&
      other.folder == folder &&
      other.whenExists == whenExists &&
      other.skipExisting == skipExisting &&
      _sameList(other.networkRootsAllowed, networkRootsAllowed) &&
      _sameMap(other.rootFallbacks, rootFallbacks) &&
      other.generatedAlbumState == generatedAlbumState;

  @override
  int get hashCode => Object.hash(
    destination,
    folder,
    whenExists,
    skipExisting,
    Object.hashAll(networkRootsAllowed),
    Object.hashAllUnordered(rootFallbacks.entries.map((entry) => Object.hash(entry.key, entry.value))),
    generatedAlbumState,
  );
}

/// Reads and writes desktop_ai.json
class DesktopAiSettingsStore {
  DesktopAiSettingsStore({Future<Directory> Function()? settingsDirectory})
    : _settingsDirectory = settingsDirectory ?? getApplicationSupportDirectory;

  /// The one the app uses
  static final instance = DesktopAiSettingsStore();

  /// The name of the file in the support folder
  static const fileName = 'desktop_ai.json';
  static final _log = Logger('DesktopAiSettings');

  final Future<Directory> Function() _settingsDirectory;
  Future<void> _writing = Future.value();

  /// The settings kept, the defaults when there are none or the file cannot be read. In turn with the writes: on
  /// Windows a file being renamed over cannot be opened, and a file open for reading cannot be renamed over.
  Future<DesktopAiSettings> read() async {
    late DesktopAiSettings settings;
    await _queue(() async {
      settings = await _readSettings();
    });
    return settings;
  }

  Future<DesktopAiSettings> _readSettings() async => DesktopAiSettings.fromJson(await _readMap(await _file()));

  /// Keeps [settings], the keys of the file this build does not know left as they are
  Future<void> write(DesktopAiSettings settings) => _queue(() => _save(settings));

  /// Reads, changes with [change] and writes, one change after the other; the settings kept
  Future<DesktopAiSettings> update(DesktopAiSettings Function(DesktopAiSettings settings) change) async {
    late DesktopAiSettings changed;
    await _queue(() async {
      changed = change(await _readSettings());
      await _save(changed);
    });
    return changed;
  }

  Future<void> _save(DesktopAiSettings settings) async {
    final file = await _file();
    final map = await _readMap(file)
      ..addAll(settings.toJson());
    await file.parent.create(recursive: true);
    // A whole new file renamed over the old one: a crash while writing never leaves half a setting
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(const JsonEncoder.withIndent('  ').convert(map), flush: true);
    await temporary.rename(file.path);
  }

  Future<void> _queue(Future<void> Function() step) {
    final next = _writing.then((_) => step());
    _writing = next.catchError((Object _) {});
    return next;
  }

  Future<File> _file() async => File(p.join((await _settingsDirectory()).path, fileName));

  Future<Map<String, Object?>> _readMap(File file) async {
    try {
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, Object?> ? Map.of(decoded) : {};
    } on PathNotFoundException {
      return {};
    } on FormatException catch (error) {
      _log.warning('The AI settings cannot be read, the defaults are used: ${error.message}');
      return {};
    }
  }
}

bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

bool _sameMap(Map<String, String> a, Map<String, String> b) =>
    a.length == b.length && a.entries.every((entry) => b[entry.key] == entry.value);
