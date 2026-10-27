// ONNX Runtime and the model under a folder with accents and other scripts, as under C:\Users\Frédéric on Windows,
// where the model path goes to ONNX Runtime in UTF-16 and the library through LoadLibraryW. A file of its own: the
// copy of the library is the only ONNX Runtime this test process loads (flutter test runs each file in its own process).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_depth_backend.dart';
import 'package:immich_mobile/desktop/ai/ort/ort_session.dart';
import 'package:path/path.dart' as p;

import 'ort_for_tests.dart';

void main() {
  final ort = ortForTests();

  test('loads the library and the model from a folder with accents', () {
    final folder = Directory(p.join(Directory.systemTemp.createTempSync('immuch360-ort-').path, 'Été à Noël 日本'))
      ..createSync();
    addTearDown(() {
      try {
        folder.parent.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows keeps the file of a loaded DLL until the process ends: the copy stays in the temporary folder
      }
    });
    final library = File(ort.library!).copySync(p.join(folder.path, p.basename(ort.library!)));
    final model = File(tinyDepthModelPath()).copySync(p.join(folder.path, 'modèle ñ.onnx'));
    final tiny = TinyDepthModel.load();

    final runtime = OrtRuntime.load(library.path);
    expect(runtime.libraryPath, library.path);
    final session = runtime.openSession(model.path);
    addTearDown(session.close);
    expect(session.run(tiny.sample, tiny.sampleShape).values, tiny.expected);

    final backend = OrtDepthBackend(libraryPath: library.path, modelPath: model.path, inputWidth: 5, inputHeight: 4);
    addTearDown(backend.close);
    expect(backend.estimate(tiny.sample).values, tiny.expected);
  }, skip: ort.skip);
}
