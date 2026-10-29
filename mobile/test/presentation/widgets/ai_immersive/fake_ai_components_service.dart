// A components service in memory for the screens of the AI features (the tile, the install sheet, and the screens of
// lots A5c and A9b that hold them): states set by the test, installs and removals noted, no file touched. The real
// service is tested on files in test/desktop/ai/components.

import 'dart:async';
import 'dart:io';

import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_component_downloader.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:path/path.dart' as p;

class FakeAiComponentsService extends AiComponentsService {
  FakeAiComponentsService({Map<AiComponent, AiComponentState> states = const {}, this.space = 0})
    : super(folder: () async => Directory(p.join(Directory.systemTemp.path, 'no-ai-components'))) {
    for (final MapEntry(:key, :value) in states.entries) {
      _states[key.id] = AiComponentStatus(value);
    }
  }

  final _states = <String, AiComponentStatus>{};

  /// What spaceUsed answers
  int space;

  /// Whether a conversion runs: removals are refused while it does
  bool converting = false;

  /// Whether the components are being moved: setting it tells the screens
  bool get moving => _moving;
  set moving(bool value) {
    _moving = value;
    notifyListeners();
  }

  var _moving = false;

  @override
  bool get isMoving => _moving;

  /// The ids given to install, cancel and remove, in order; null in [removals] for Remove all
  final installs = <String>[];
  final cancels = <String>[];
  final removals = <String?>[];

  /// Run by install before the component becomes installed: a test holds or fails a download with it
  Future<void> Function(AiComponent component)? onInstall;

  /// What a removal that is not refused answers
  AiRemoveOutcome removeOutcome = AiRemoveOutcome.removed;

  /// The groups given to removeGroup, in order
  final groupRemovals = <AiFeatureGroup>[];

  /// What the drive lacks for an installation, and the components it was asked for
  AiSpaceShortage? shortage;
  final spaceAsked = <List<String>>[];

  /// The licence and notices files the dialogs read; a path with no file by default
  File? licence;
  File? notices;

  void setStatus(AiComponent component, AiComponentStatus status) => _set(component.id, status);

  void _set(String id, AiComponentStatus status) {
    _states[id] = status;
    notifyListeners();
  }

  @override
  Future<void> load() async {}

  @override
  AiComponentStatus statusOf(AiComponent component) =>
      _states[component.id] ?? const AiComponentStatus(AiComponentState.notInstalled);

  @override
  Future<int> spaceUsed() async => space;

  @override
  Future<void> install(AiComponent component) async {
    installs.add(component.id);
    try {
      await onInstall?.call(component);
    } on AiDownloadException catch (error) {
      setStatus(component, AiComponentStatus(AiComponentState.notInstalled, failure: error));
      rethrow;
    }
    space += AiComponentsService.diskBytesOf([component]);
    setStatus(component, const AiComponentStatus(AiComponentState.installed));
  }

  @override
  void cancel(AiComponent component) => cancels.add(component.id);

  @override
  Future<AiSpaceShortage?> spaceShortage(Iterable<AiComponent> components) async {
    spaceAsked.add([for (final component in components) component.id]);
    return shortage;
  }

  @override
  Future<AiRemoveOutcome> remove(AiComponent component) async {
    removals.add(component.id);
    if (converting) {
      return AiRemoveOutcome.busy;
    }
    if (removeOutcome == AiRemoveOutcome.removed) {
      space = (space - AiComponentsService.diskBytesOf([component])).clamp(0, space);
    }
    _removed(component.id);
    return removeOutcome;
  }

  @override
  Future<AiGroupRemoval> removeGroup(AiPlatform platform, AiFeatureGroup group) async {
    groupRemovals.add(group);
    if (converting) {
      return const AiGroupRemoval(AiRemoveOutcome.busy, []);
    }
    final entry = aiComponentGroupsFor(platform, catalogue: catalogue).firstWhere((entry) => entry.group == group);
    final kept = [
      for (final component in entry.all)
        if (groupsUsing(platform, component, besides: group).isNotEmpty) component,
    ];
    for (final component in entry.all.where((component) => !kept.contains(component))) {
      _removed(component.id);
    }
    return AiGroupRemoval(removeOutcome, kept);
  }

  @override
  Future<AiRemoveOutcome> removeAll() async {
    removals.add(null);
    if (converting) {
      return AiRemoveOutcome.busy;
    }
    if (removeOutcome == AiRemoveOutcome.removed) {
      space = 0;
    }
    for (final id in [..._states.keys]) {
      _removed(id);
    }
    return removeOutcome;
  }

  void _removed(String id) {
    switch (removeOutcome) {
      case AiRemoveOutcome.removed:
        _set(id, const AiComponentStatus(AiComponentState.notInstalled));
      case AiRemoveOutcome.nextStart:
        _set(id, const AiComponentStatus(AiComponentState.removedNextStart));
      case AiRemoveOutcome.busy || AiRemoveOutcome.writeFailed:
        break;
    }
  }

  @override
  Future<File> licenceOf(AiComponent component) async =>
      licence ?? File(p.join(Directory.systemTemp.path, 'no-ai-components', '${component.id}.txt'));

  @override
  Future<File?> noticesOf(AiComponent component) async => component.notices == null
      ? null
      : notices ?? File(p.join(Directory.systemTemp.path, 'no-ai-components', '${component.id}-notices.txt'));
}
