// The settings of the AI features that only a computer has (design-final 2026-10-26, section 4.4): where the 3D photos
// go, what to do when one exists, the network folders the user allowed to receive them, and whether the virtual album
// of the generated photos was excluded from the backup once. Phases 2 and 3 add (design-final 2026-10-27, sections
// 7.4 and 9): the type last chosen in the dialog, the 3D version made after a panorama, the .glb copy of a scene, the
// folder the AI components were moved to, the integrated graphics allowed, the times measured per step, and the
// address of the ComfyUI of the user. The times of the steps start from the measures of the design (AiTimings) and follow
// the jobs this computer finished. Kept in desktop_ai.json of the support folder, beside
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
    this.lastType,
    this.alsoStereoPanorama = true,
    this.exportGlb = false,
    this.componentsFolder,
    this.integratedGpuAllowed = false,
    this.timings = const {},
    this.comfyUiUrl,
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

  /// The type the dialog chose last, by the name of its ConversionKind ("sceneFromPhoto"); kept by name so that a
  /// type of a later version reads as none here; null for the 3D photo, the first type
  final String? lastType;

  /// "Also make the 3D version" of a panorama, checked by default
  final bool alsoStereoPanorama;

  /// "Also save a .glb copy" of a scene, off by default
  final bool exportGlb;

  /// The folder the AI components were moved to ("Move the AI components"); null for the folder of the app
  final String? componentsFolder;

  /// "Try on integrated graphics (untested)", off by default
  final bool integratedGpuAllowed;

  /// The milliseconds each step took on this computer, by kind and by step (ConversionKind and ImmersiveStage names),
  /// which weigh the progress and give the time shown in the dialog
  final Map<String, Map<String, int>> timings;

  /// The address of the ComfyUI of the user, local only; null for the default, http://127.0.0.1:8188
  final String? comfyUiUrl;

  DesktopAiSettings copyWith({
    AiDestination? destination,
    String? Function()? folder,
    AiWhenExists? whenExists,
    bool? skipExisting,
    List<String>? networkRootsAllowed,
    Map<String, String>? rootFallbacks,
    AiGeneratedAlbumState? generatedAlbumState,
    String? Function()? lastType,
    bool? alsoStereoPanorama,
    bool? exportGlb,
    String? Function()? componentsFolder,
    bool? integratedGpuAllowed,
    Map<String, Map<String, int>>? timings,
    String? Function()? comfyUiUrl,
  }) => DesktopAiSettings(
    destination: destination ?? this.destination,
    folder: folder == null ? this.folder : folder(),
    whenExists: whenExists ?? this.whenExists,
    skipExisting: skipExisting ?? this.skipExisting,
    networkRootsAllowed: networkRootsAllowed ?? this.networkRootsAllowed,
    rootFallbacks: rootFallbacks ?? this.rootFallbacks,
    generatedAlbumState: generatedAlbumState ?? this.generatedAlbumState,
    lastType: lastType == null ? this.lastType : lastType(),
    alsoStereoPanorama: alsoStereoPanorama ?? this.alsoStereoPanorama,
    exportGlb: exportGlb ?? this.exportGlb,
    componentsFolder: componentsFolder == null ? this.componentsFolder : componentsFolder(),
    integratedGpuAllowed: integratedGpuAllowed ?? this.integratedGpuAllowed,
    timings: timings ?? this.timings,
    comfyUiUrl: comfyUiUrl == null ? this.comfyUiUrl : comfyUiUrl(),
  );

  Map<String, Object?> toJson() => {
    'destination': destination.name,
    'folder': folder,
    'whenExists': whenExists.name,
    'skipExisting': skipExisting,
    'networkRootsAllowed': networkRootsAllowed,
    'rootFallbacks': rootFallbacks,
    'generatedAlbumState': generatedAlbumState.name,
    'lastType': lastType,
    'alsoStereoPanorama': alsoStereoPanorama,
    'exportGlb': exportGlb,
    'componentsFolder': componentsFolder,
    'integratedGpuAllowed': integratedGpuAllowed,
    'timings': timings,
    'comfyUiUrl': comfyUiUrl,
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
    String? text(String key) => switch (json[key]) {
      final String value when value.isNotEmpty => value,
      _ => null,
    };
    bool flag(String key, bool fallback) => switch (json[key]) {
      final bool value => value,
      _ => fallback,
    };
    final timings = json['timings'];
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
      lastType: text('lastType'),
      alsoStereoPanorama: flag('alsoStereoPanorama', defaults.alsoStereoPanorama),
      exportGlb: flag('exportGlb', defaults.exportGlb),
      componentsFolder: text('componentsFolder'),
      integratedGpuAllowed: flag('integratedGpuAllowed', defaults.integratedGpuAllowed),
      timings: timings is Map
          ? Map.unmodifiable({
              for (final MapEntry(:key, :value) in timings.entries)
                if (key is String && value is Map)
                  key: Map<String, int>.unmodifiable({
                    for (final MapEntry(key: step, value: millis) in value.entries)
                      if (step is String && millis is int && millis >= 0) step: millis,
                  }),
            })
          : const {},
      comfyUiUrl: text('comfyUiUrl'),
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
      other.generatedAlbumState == generatedAlbumState &&
      other.lastType == lastType &&
      other.alsoStereoPanorama == alsoStereoPanorama &&
      other.exportGlb == exportGlb &&
      other.componentsFolder == componentsFolder &&
      other.integratedGpuAllowed == integratedGpuAllowed &&
      _sameTimings(other.timings, timings) &&
      other.comfyUiUrl == comfyUiUrl;

  @override
  int get hashCode => Object.hash(
    destination,
    folder,
    whenExists,
    skipExisting,
    Object.hashAll(networkRootsAllowed),
    Object.hashAllUnordered(rootFallbacks.entries.map((entry) => Object.hash(entry.key, entry.value))),
    generatedAlbumState,
    lastType,
    alsoStereoPanorama,
    exportGlb,
    componentsFolder,
    integratedGpuAllowed,
    Object.hashAllUnordered(timings.keys),
    comfyUiUrl,
  );
}

/// The milliseconds each step of each kind of job takes before this computer finished one, by the names of
/// ConversionKind and ImmersiveStage: the 3D photo as phase 1 runs it (a few seconds a photo), the 3D scene as M2
/// measured it on ai1 (some 25 s, MoGe-2 4.1 s, LaMa 8.4 s to load and 3.1 s a region), the 360° panorama as M3
/// measured it on the RTX 4060 Laptop (at most 250 s, the generation some 200 s, the upscale 41 s, the photo pasted
/// back and the JPEG 3 s), the 360° 3D panorama as the design estimates it (some 10 s)
const aiDefaultTimings = <String, Map<String, int>>{
  'sbsFromPhoto': {'reading': 100, 'decoding': 500, 'depth': 1000, 'rightEye': 500, 'encoding': 600, 'writing': 100},
  'sceneFromPhoto': {
    'reading': 200,
    'decoding': 1500,
    'geometry': 4500,
    'layers': 1000,
    'inpaint': 12000,
    'mesh': 1000,
    'textures': 2500,
    'writing': 300,
  },
  'panoramaFromPhoto': {
    'reading': 100,
    'decoding': 1000,
    'fieldOfView': 3000,
    'projection': 500,
    'loadingModels': 10000,
    'generating': 195000,
    'seam': 1000,
    'upscale': 41000,
    'pasteBack': 2000,
    'encoding': 1000,
    'writing': 300,
  },
  'stereoPanoramaFromPanorama': {
    'reading': 200,
    'decoding': 2000,
    'panoramaDepth': 5000,
    'rightEye': 2000,
    'encoding': 1500,
    'writing': 300,
  },
};

/// The time the steps of the jobs take on this computer: those it measured (DesktopAiSettings.timings), else
/// [aiDefaultTimings]. They give the time left of a job and the time a photo takes in the dialog.
class AiTimings {
  const AiTimings([this.measured = const {}]);

  final Map<String, Map<String, int>> measured;

  /// The milliseconds the step [stage] of a job of [kind] takes, null when nothing tells it
  int? of(String kind, String stage) => measured[kind]?[stage] ?? aiDefaultTimings[kind]?[stage];

  /// [measured] with the steps of a job of [kind] that just ended well: each step the mean of what it was and what it
  /// took this time (the first time, what it took), so that one slow job weighs but half and a faster computer is
  /// soon told. The other kinds stay as they were.
  static Map<String, Map<String, int>> merged(
    Map<String, Map<String, int>> measured,
    String kind,
    Map<String, int> stepTimes,
  ) {
    final kept = measured[kind] ?? const {};
    return {
      ...measured,
      kind: {
        ...kept,
        for (final MapEntry(key: stage, value: millis) in stepTimes.entries)
          if (millis >= 0) stage: kept[stage] == null ? millis : (kept[stage]! + millis + 1) ~/ 2,
      },
    };
  }
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

bool _sameTimings(Map<String, Map<String, int>> a, Map<String, Map<String, int>> b) =>
    a.length == b.length &&
    a.entries.every((entry) {
      final other = b[entry.key];
      return other != null &&
          other.length == entry.value.length &&
          entry.value.entries.every((step) => other[step.key] == step.value);
    });
