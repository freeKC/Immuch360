import 'package:immich_mobile/desktop/desktop_start.dart';
import 'package:immich_mobile/main.dart';

/// The entry point of Immuch360 Desktop on Windows, macOS and Linux, given to every desktop build and run with -t:
///   flutter run -d windows -t lib/main_desktop.dart
///   flutter build windows -t lib/main_desktop.dart
/// It sets up the window, then runs the start the phones use.
void main(List<String> args) => runImmich(beforeStart: () => startDesktop(args));
