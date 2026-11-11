// Where a package of the app is, as `flutter pub get` resolved it (.dart_tool/package_config.json of mobile): in the
// pub cache for a git or hosted dependency (the media_kit packages of github.com/immuch360/media_kit_360, taken by git
// tag), in mobile/packages for a path one. The tests run from mobile.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The folder of the package [name]; throws a [StateError] when the app has no such package
String packageRoot(String name) {
  final config = File(p.join('.dart_tool', 'package_config.json'));
  final packages = (jsonDecode(config.readAsStringSync()) as Map<String, Object?>)['packages']! as List<Object?>;
  for (final package in packages.cast<Map<String, Object?>>()) {
    if (package['name'] == name) {
      final root = Uri.parse(package['rootUri']! as String);
      return root.hasScheme ? p.fromUri(root) : p.normalize(p.join(config.parent.absolute.path, p.fromUri(root)));
    }
  }
  throw StateError('$name is not a package of the app');
}
