// The components service of a Meta Quest for the tests of the AI relief: the fake of the screens (states set by the
// test, a download without network), whose installed depth model is where the headset keeps it, the path of the
// stereoPair contract.

import 'dart:io';

import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:path/path.dart' as p;

import 'fake_ai_components_service.dart';

/// The files folder of the release package on the headset, where getApplicationSupportDirectory() points
const questFilesFolder = '/data/user/0/com.aprogsys.immuch360/files';

class InstalledModelService extends FakeAiComponentsService {
  /// Where the headset keeps the depth model once installed
  final modelPath = p.posix.join(questFilesFolder, aiComponentsFolderName, depthModelTfliteComponent.installPath);

  /// The file is gone again as soon as installed: verifiedFile never finds it
  bool lose = false;

  @override
  Future<File?> verifiedFile(AiComponent component) async =>
      !lose && statusOf(component).state == AiComponentState.installed ? File(modelPath) : null;
}
