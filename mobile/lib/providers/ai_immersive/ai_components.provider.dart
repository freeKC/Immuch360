// The AI components of this device: their folder and the service that installs and removes them (design-final
// 2026-10-26, section 2.2). The folder is ai-components in the support folder of the app, which the system keeps when
// the cache is emptied (the files folder on the Quest). The computers replace it in desktopOverrides() with
// desktopAiComponentsFolder, which does not roam on Windows; no platform test here.

import 'dart:io';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// ai-components in the support folder of the app
Future<Directory> supportAiComponentsFolder() async =>
    Directory(p.join((await getApplicationSupportDirectory()).path, aiComponentsFolderName));

/// Where the components are kept
final aiComponentsFolderProvider = Provider<Future<Directory> Function()>((ref) => supportAiComponentsFolder);

/// The components of this device; nothing is read before the first use, and nothing is downloaded unless asked
final aiComponentsServiceProvider = Provider<AiComponentsService>((ref) {
  final service = AiComponentsService(folder: ref.watch(aiComponentsFolderProvider));
  ref.onDispose(service.dispose);
  return service;
});
