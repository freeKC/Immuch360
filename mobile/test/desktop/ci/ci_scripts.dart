// Runs the Python scripts of .github/desktop (the CI gates and the Windows packaging of Immuch360 Desktop) on fixture
// trees, so that a gate is known to fail when it must before CI depends on it.

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// The folder of the CI scripts: .github/desktop of the repository, `flutter test` running in mobile/. The Windows
/// mirror of the owner's PC holds mobile/ and i18n/ only; IMMUCH360_CI_SCRIPTS points the tests at the scripts there.
final String ciScriptsDir =
    Platform.environment['IMMUCH360_CI_SCRIPTS'] ??
    p.normalize(p.join(Directory.current.path, '..', '.github', 'desktop'));

/// The repository the scripts belong to
final String repositoryRoot = p.dirname(p.dirname(ciScriptsDir));

/// The command of a Python 3, or null when none is installed
final List<String>? python = _findPython();

/// The skip reason of the tests that run a script, or false when they can run
final Object skipCiScripts = python == null
    ? 'no Python 3 to run the CI scripts with'
    : !File(p.join(ciScriptsDir, 'check_workflow.py')).existsSync()
    ? 'no CI scripts in $ciScriptsDir (set IMMUCH360_CI_SCRIPTS)'
    : false;

List<String>? _findPython() {
  // The Microsoft Store alias "python3" of a Windows without Python answers with an error, hence the version check
  for (final command in const [
    ['python3'],
    ['python'],
    ['py', '-3'],
  ]) {
    try {
      final result = Process.runSync(command.first, [...command.skip(1), '--version']);
      if (result.exitCode == 0 && '${result.stdout}${result.stderr}'.contains('Python 3.')) {
        return command;
      }
    } on ProcessException {
      continue;
    }
  }
  return null;
}

class ScriptRun {
  final int exitCode;
  final String output;

  const ScriptRun(this.exitCode, this.output);

  @override
  String toString() => 'exit $exitCode\n$output';
}

/// Runs the script [name] of .github/desktop with [arguments]; stdout and stderr together
ScriptRun runCiScript(String name, List<String> arguments) {
  final command = python!;
  final result = Process.runSync(
    command.first,
    [...command.skip(1), p.join(ciScriptsDir, name), ...arguments],
    environment: const {'PYTHONDONTWRITEBYTECODE': '1', 'PYTHONIOENCODING': 'utf-8'},
  );
  return ScriptRun(result.exitCode, '${result.stdout}${result.stderr}');
}

/// A throwaway folder; [files] maps paths with forward slashes to their text
Directory fixtureTree(Map<String, String> files) {
  final root = Directory.systemTemp.createTempSync('immuch360_ci_');
  writeFiles(root, files);
  return root;
}

void writeFiles(Directory root, Map<String, String> files) {
  for (final entry in files.entries) {
    File(p.joinAll([root.path, ...entry.key.split('/')]))
      ..createSync(recursive: true)
      ..writeAsStringSync(entry.value);
  }
}

/// A PE file reduced to what windows_bundle.py reads: the headers, one section holding the import and delay import
/// tables and the DLL names. [pe32] makes a 32 bit header, [machine] is 0x8664 (x64), 0xAA64 (arm64) or 0x14C (x86).
Uint8List fakePe({
  List<String> imports = const [],
  List<String> delayImports = const [],
  int machine = 0x8664,
  bool pe32 = false,
}) {
  const peOffset = 0x40;
  const sectionRva = 0x1000;
  const sectionRaw = 0x200;
  const imageBase = 0x140000000;
  final optionalSize = pe32 ? 96 + 16 * 8 : 112 + 16 * 8;
  const optionalOffset = peOffset + 24;
  final sectionTable = optionalOffset + optionalSize;

  final importSize = imports.isEmpty ? 0 : (imports.length + 1) * 20;
  final delaySize = delayImports.isEmpty ? 0 : (delayImports.length + 1) * 32;
  final namesOffset = importSize + delaySize;
  final names = [...imports, ...delayImports];
  final namesSize = names.fold<int>(0, (size, name) => size + name.length + 1);
  final sectionSize = ((namesOffset + namesSize + 0x1FF) ~/ 0x200) * 0x200;
  final bytes = ByteData(sectionRaw + (sectionSize == 0 ? 0x200 : sectionSize));

  bytes
    ..setUint8(0, 0x4D)
    ..setUint8(1, 0x5A)
    ..setUint32(0x3C, peOffset, Endian.little)
    ..setUint32(peOffset, 0x00004550, Endian.little)
    ..setUint16(peOffset + 4, machine, Endian.little)
    ..setUint16(peOffset + 6, 1, Endian.little)
    ..setUint16(peOffset + 20, optionalSize, Endian.little)
    ..setUint16(peOffset + 22, 0x2022, Endian.little)
    ..setUint16(optionalOffset, pe32 ? 0x10B : 0x20B, Endian.little);
  if (pe32) {
    bytes
      ..setUint32(optionalOffset + 28, 0x400000, Endian.little)
      ..setUint32(optionalOffset + 92, 16, Endian.little);
  } else {
    bytes
      ..setUint64(optionalOffset + 24, imageBase, Endian.little)
      ..setUint32(optionalOffset + 108, 16, Endian.little);
  }
  final directories = optionalOffset + (pe32 ? 96 : 112);
  if (importSize > 0) {
    bytes
      ..setUint32(directories + 8, sectionRva, Endian.little)
      ..setUint32(directories + 12, importSize, Endian.little);
  }
  if (delaySize > 0) {
    bytes
      ..setUint32(directories + 13 * 8, sectionRva + importSize, Endian.little)
      ..setUint32(directories + 13 * 8 + 4, delaySize, Endian.little);
  }

  const name = '.idata';
  for (var i = 0; i < name.length; i++) {
    bytes.setUint8(sectionTable + i, name.codeUnitAt(i));
  }
  bytes
    ..setUint32(sectionTable + 8, sectionSize, Endian.little)
    ..setUint32(sectionTable + 12, sectionRva, Endian.little)
    ..setUint32(sectionTable + 16, sectionSize, Endian.little)
    ..setUint32(sectionTable + 20, sectionRaw, Endian.little);

  var nameAt = namesOffset;
  final nameRvas = <int>[];
  for (final dll in names) {
    nameRvas.add(sectionRva + nameAt);
    for (var i = 0; i < dll.length; i++) {
      bytes.setUint8(sectionRaw + nameAt + i, dll.codeUnitAt(i));
    }
    nameAt += dll.length + 1;
  }
  for (var i = 0; i < imports.length; i++) {
    final descriptor = sectionRaw + i * 20;
    bytes
      ..setUint32(descriptor + 12, nameRvas[i], Endian.little)
      ..setUint32(descriptor + 16, nameRvas[i], Endian.little);
  }
  for (var i = 0; i < delayImports.length; i++) {
    final descriptor = sectionRaw + importSize + i * 32;
    bytes
      ..setUint32(descriptor, 1, Endian.little)
      ..setUint32(descriptor + 4, nameRvas[imports.length + i], Endian.little);
  }
  return bytes.buffer.asUint8List();
}

/// The fixed part of a version resource (VS_FIXEDFILEINFO) holding the file version [version], four numbers; appended
/// to a [fakePe], where windows_bundle.py finds it by its signature as in a real executable
Uint8List fakeVersionInfo(List<int> version) {
  final bytes = ByteData(52)
    ..setUint32(0, 0xFEEF04BD, Endian.little)
    ..setUint32(4, 0x00010000, Endian.little)
    ..setUint32(8, version[0] << 16 | version[1], Endian.little)
    ..setUint32(12, version[2] << 16 | version[3], Endian.little)
    ..setUint32(16, version[0] << 16 | version[1], Endian.little)
    ..setUint32(20, version[2] << 16 | version[3], Endian.little);
  return bytes.buffer.asUint8List();
}
