// The keys of a computer keyboard and the buttons of a mouse that the viewers read on top of those of a remote control
// (remote_keys.dart, design 4.1 and 4.2). The phones keep the remote sets as they are; on a computer the getters of
// remote_keys.dart hand over to the functions below, so that one key map serves both and no viewer gets a second set
// of handlers.
//
// Two rules make a keyboard differ from a remote:
// - the letters (J, L, I) are shortcuts only while no text field has the keyboard: the asset viewer holds the
//   description field of its details, and a key event that a viewer handles never reaches the text input, so a
//   shortcut would eat the letter typed there (Flutter's own text editing shortcuts only stop the space bar, Enter and
//   a few combinations from reaching the viewers);
// - plus and minus are matched by the character the key types, whatever the layout: "+" is Shift and the "=" key on
//   QWERTY and AZERTY, a key of its own on QWERTZ, and "-" is the "6" key of AZERTY, whose logical key the embedders
//   do not agree on. The number pad keys and the "=" key are matched as keys.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';

/// Zoom in on a computer: the remote keys, then + and = of the main row and + of the number pad
Set<LogicalKeyboardKey> desktopZoomInKeys(Set<LogicalKeyboardKey> remoteKeys) => {
  ...remoteKeys,
  LogicalKeyboardKey.add,
  LogicalKeyboardKey.equal,
  LogicalKeyboardKey.numpadAdd,
};

/// Zoom out on a computer: the remote keys, then - of the main row and of the number pad
Set<LogicalKeyboardKey> desktopZoomOutKeys(Set<LogicalKeyboardKey> remoteKeys) => {
  ...remoteKeys,
  LogicalKeyboardKey.minus,
  LogicalKeyboardKey.numpadSubtract,
};

/// "+" typed by any key combination of any layout, without Control, Alt or Meta (Control and + is left to the system)
const desktopZoomInCharacter = CharacterActivator('+');

/// "-" typed by any key combination of any layout, without Control, Alt or Meta
const desktopZoomOutCharacter = CharacterActivator('-');

/// Whether [event] types "+", see [desktopZoomInCharacter]
bool typesZoomInCharacter(KeyEvent event) => desktopZoomInCharacter.accepts(event, HardwareKeyboard.instance);

/// Whether [event] types "-", see [desktopZoomOutCharacter]
bool typesZoomOutCharacter(KeyEvent event) => desktopZoomOutCharacter.accepts(event, HardwareKeyboard.instance);

/// Whether the keyboard is typing into a text field now: the letters then belong to the text (see the top of this
/// file)
bool isTypingText() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) {
    return false;
  }
  return context.widget is EditableText || context.findAncestorStateOfType<EditableTextState>() != null;
}

final _keyL = {LogicalKeyboardKey.keyL};
final _keyJ = {LogicalKeyboardKey.keyJ};
final _keyI = {LogicalKeyboardKey.keyI};

/// [remoteKeys] plus [letters] while no text field has the keyboard, [remoteKeys] alone while one has it
Set<LogicalKeyboardKey> _withLetters(Set<LogicalKeyboardKey> remoteKeys, Set<LogicalKeyboardKey> letters) =>
    isTypingText() ? remoteKeys : {...remoteKeys, ...letters};

/// Seek forward on a computer: the remote keys, then L, as in most video players
Set<LogicalKeyboardKey> desktopSeekForwardKeys(Set<LogicalKeyboardKey> remoteKeys) => _withLetters(remoteKeys, _keyL);

/// Seek back on a computer: the remote keys, then J
Set<LogicalKeyboardKey> desktopSeekBackwardKeys(Set<LogicalKeyboardKey> remoteKeys) => _withLetters(remoteKeys, _keyJ);

/// The details panel on a computer: the info key of a remote, then I
Set<LogicalKeyboardKey> desktopDetailsKeys(Set<LogicalKeyboardKey> remoteKeys) => _withLetters(remoteKeys, _keyI);

/// The first item of a viewer on a computer, Home: a remote has no such key. The viewers read it only while they
/// have the focus themselves, so a text field keeps its Home.
final desktopFirstItemKeys = {LogicalKeyboardKey.home};

/// The last item of a viewer on a computer, End
final desktopLastItemKeys = {LogicalKeyboardKey.end};

/// What a key of the window does on a computer, whatever page is shown (DesktopShell); the viewers' own keys come
/// first, through remote_keys.dart
enum DesktopWindowKey {
  /// F11, and Control Command F on macOS, where F11 shows the desktop
  toggleFullScreen,

  /// F alone, in a viewer only, and never while typing
  toggleFullScreenInViewer,

  /// Escape: leaves full screen, else closes the viewer
  leaveFullScreenOrViewer,

  /// Command W on macOS: closes the viewer
  closeViewer,
}

/// The window key [event] stands for, if any. Presses only: a held key does not toggle full screen again and again.
DesktopWindowKey? desktopWindowKeyOf(KeyEvent event, {bool? typing}) {
  if (event is! KeyDownEvent) {
    return null;
  }
  final key = event.logicalKey;
  final keyboard = HardwareKeyboard.instance;
  final control = keyboard.isControlPressed;
  final meta = keyboard.isMetaPressed;
  final alt = keyboard.isAltPressed;
  if (key == LogicalKeyboardKey.f11) {
    return DesktopWindowKey.toggleFullScreen;
  }
  if (key == LogicalKeyboardKey.escape) {
    return DesktopWindowKey.leaveFullScreenOrViewer;
  }
  if (CurrentPlatform.isMacOS && meta) {
    if (key == LogicalKeyboardKey.keyF && control && !alt) {
      return DesktopWindowKey.toggleFullScreen;
    }
    if (key == LogicalKeyboardKey.keyW && !control && !alt) {
      return DesktopWindowKey.closeViewer;
    }
    return null;
  }
  if (key == LogicalKeyboardKey.keyF && !control && !meta && !alt && !(typing ?? isTypingText())) {
    return DesktopWindowKey.toggleFullScreenInViewer;
  }
  return null;
}

/// Whether [event] presses the back button of a mouse (the thumb button), which leaves full screen or goes back like
/// the Back button of a phone
bool isMouseBackButton(PointerDownEvent event) =>
    event.kind == PointerDeviceKind.mouse && event.buttons & kBackMouseButton != 0;

/// One notch of a mouse wheel, in logical pixels, as the Flutter embedders report it at the system's default setting
/// (their values come from Chromium): Windows sends 100 physical pixels, three lines of a third of a hundred, whatever
/// the scale of the screen, so 50 logical pixels on a screen at 200 %; Linux and macOS send 53 and 40 logical pixels.
double desktopWheelNotch(TargetPlatform platform, double devicePixelRatio) => switch (platform) {
  TargetPlatform.linux => 53,
  TargetPlatform.macOS => 40,
  _ => 100 / devicePixelRatio,
};

/// How much a mouse wheel move zooms the 360° photo viewer: below 1 zooms in, 10 % for one notch. In proportion to the
/// move rather than per event, since high resolution and free spinning wheels, and touchpads without a precision
/// driver, send several small moves for one notch; one move counts for three notches at most, so that a single large
/// jump does not cross the whole zoom range. Null for an event that is not a vertical wheel move (a horizontal scroll;
/// a trackpad pinch arrives as scale events instead). [notch] is for the tests; by default the notch of this computer
/// on the screen the event comes from.
double? wheelZoomFactor(PointerSignalEvent event, {double? notch}) {
  if (event is! PointerScrollEvent || event.scrollDelta.dy == 0) {
    return null;
  }
  final size = notch ?? desktopWheelNotch(defaultTargetPlatform, _devicePixelRatioOf(event));
  final notches = (event.scrollDelta.dy / size).clamp(-3.0, 3.0);
  return math.pow(1 / 0.9, notches).toDouble();
}

double _devicePixelRatioOf(PointerEvent event) =>
    WidgetsBinding.instance.platformDispatcher.view(id: event.viewId)?.devicePixelRatio ?? 1;

/// Whether the views must not move by themselves on this computer: the system asks for fewer animations (design 4.7),
/// so a sphere stops where it is released instead of turning on like after a flick. The phones keep their inertia.
bool desktopReducedMotion(BuildContext context) =>
    CurrentPlatform.isDesktop && (MediaQuery.maybeDisableAnimationsOf(context) ?? false);
