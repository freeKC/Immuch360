// What the Linux probe reads of the app's share of an NVIDIA card through NVML (linux/runner/gpu_probe.cc, issue #13),
// against a libnvidia-ml.so.1 of the test (native/fake_nvml.c): a figure, the larger of the graphics and compute
// lists; nothing held when the app is in neither; and a share left unknown, not 0, when every entry of the app has no
// figure (NVML_VALUE_NOT_AVAILABLE). The probe and the library are built here with the computer's C and C++ compilers
// (the CI's Ubuntu has them); without them the test is skipped.
@TestOn('linux')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _mib = 1024 * 1024;

/// The first of [names] on the PATH
String? _compiler(List<String> names) {
  for (final name in names) {
    if (Process.runSync('which', [name]).exitCode == 0) {
      return name;
    }
  }
  return null;
}

void main() {
  final cc = _compiler(['cc', 'gcc', 'clang']);
  final cxx = _compiler(['c++', 'g++', 'clang++']);
  final Object skip = cc == null || cxx == null ? 'no C or C++ compiler on this computer' : false;
  late Directory build;
  late String probe;

  void compile(String compiler, List<String> arguments) {
    final result = Process.runSync(compiler, arguments);
    expect(result.exitCode, 0, reason: '$compiler ${arguments.join(' ')}\n${result.stdout}${result.stderr}');
  }

  setUpAll(() {
    if (skip != false) {
      return;
    }
    build = Directory.systemTemp.createTempSync('gpu_probe_nvml_test');
    probe = p.join(build.path, 'nvml-share-probe');
    final native = p.join('test', 'desktop', 'ai', 'gpu', 'native');
    final strict = ['-O1', '-Wall', '-Wextra', '-Werror'];
    compile(cc!, [
      ...strict,
      '-shared',
      '-fPIC',
      '-o',
      p.join(build.path, 'libnvidia-ml.so.1'),
      p.join(native, 'fake_nvml.c'),
    ]);
    compile(cxx!, [
      ...strict,
      '-std=c++14',
      '-I',
      p.join('linux', 'runner'),
      '-o',
      probe,
      p.join(native, 'nvml_share_probe.cc'),
      '-ldl',
    ]);
  });

  tearDownAll(() {
    if (skip == false) {
      build.deleteSync(recursive: true);
    }
  });

  /// What the probe wrote of the app's share with the lists of [scenario]
  String share(String scenario) {
    final result = Process.runSync(
      probe,
      const [],
      environment: {'LD_LIBRARY_PATH': build.path, 'FAKE_NVML': scenario},
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return (result.stdout as String).trim();
  }

  test('the app listed with a figure: its share', () => expect(share('measured'), 'app ${1402 * _mib}'), skip: skip);

  test('the app in neither list: it holds nothing of the card', () => expect(share('absent'), 'app 0'), skip: skip);

  test(
    'the app listed without a figure (NVML_VALUE_NOT_AVAILABLE): its share unknown, not 0',
    () => expect(share('unavailable'), 'app unknown'),
    skip: skip,
  );

  test(
    'without a figure in one list and with one in the other: the figure',
    () => expect(share('mixed'), 'app ${300 * _mib}'),
    skip: skip,
  );
}
