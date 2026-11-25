// The build hook of immuch_head_tracker: the macOS library of the head tracker, and nothing for any other target.
// Windows and Linux build theirs with CMake as an FFI plugin (windows/CMakeLists.txt, linux/CMakeLists.txt); the app
// on macOS builds its plugins with Swift Package Manager, which does not build FFI plugins, so the library comes from
// here: one dylib per processor (Flutter joins them into immuch_head_tracker.framework of the app), AVFoundation for
// the webcams (src/ht_macos.mm), the fake cameras of the tests, and libfacedetection linked in, with its NEON code on
// arm64. Without the early return the tracker would be compiled into the phone and Quest builds, which never call it.

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }
    final code = input.config.code;
    if (code.targetOS != OS.macOS) {
      return;
    }
    final arm = code.targetArchitecture == Architecture.arm64;
    const detector = 'third_party/libfacedetection/src';
    await CBuilder.library(
      name: 'immuch_head_tracker',
      assetName: 'immuch_head_tracker.dart',
      // No -x option: clang takes the .mm file as Objective-C++ and the others as C++
      language: Language.objectiveC,
      sources: [
        'src/ht_api.cpp',
        'src/ht_core.cpp',
        'src/ht_fake.cpp',
        'src/ht_macos.mm',
        'src/face_detect.cpp',
        '$detector/facedetectcnn.cpp',
        '$detector/facedetectcnn-model.cpp',
        '$detector/facedetectcnn-data.cpp',
      ],
      includes: ['src', detector],
      frameworks: ['AVFoundation', 'CoreMedia', 'CoreVideo', 'Foundation'],
      flags: ['-std=c++17', '-fobjc-arc', '-fvisibility=hidden', '-lc++'],
      defines: {'HT_STATIC_DETECTOR': null, 'FD_BUILD': arm ? '3' : '1', if (arm) '_ENABLE_NEON': null},
    ).run(input: input, output: output);
  });
}
