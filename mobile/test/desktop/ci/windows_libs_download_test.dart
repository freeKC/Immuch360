// The download of the libmpv and ANGLE archives of the Windows build (media_kit_libs_windows_video,
// windows/download_and_verify.cmake): a failed attempt, an error of the transfer or an archive with another SHA-256,
// is tried again after a pause and checked again, so that one error of the server does not stop the build, and only
// an archive with the right SHA-256 is left where the build takes it. Run through `cmake -P` on files of a temporary
// folder (file:// addresses), on any computer with a CMake.

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final String _function = p.join(
  Directory.current.path,
  'packages',
  'media_kit_libs_windows_video',
  'windows',
  'download_and_verify.cmake',
);

bool _hasCmake() {
  try {
    return Process.runSync('cmake', ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

final Object _skip = !File(_function).existsSync()
    ? 'no $_function'
    : !_hasCmake()
    ? 'needs cmake'
    : false;

void main() {
  late Directory root;
  late File script;

  String path(String name) => p.join(root.path, name);
  String url(String name) => Uri.file(path(name)).toString();
  String sha256Of(String text) => sha256.convert(text.codeUnits).toString();

  setUp(() {
    root = Directory.systemTemp.createTempSync('download_and_verify_test');
    File(path('good.7z')).writeAsStringSync('the archive');
    File(path('error-page.html')).writeAsStringSync('<html>502 Bad Gateway</html>');
    script = File(path('run.cmake'))
      ..writeAsStringSync(
        'include("${_function.replaceAll(r'\', '/')}")\n'
        'download_and_verify("\${URLS}" "\${SHA}" "\${OUT}")\n',
      );
  });

  tearDown(() => root.deleteSync(recursive: true));

  ProcessResult run(List<String> urls, String sha, {int attempts = 4, int pause = 0}) => Process.runSync('cmake', [
    '-DURLS=${urls.join(';')}',
    '-DSHA=$sha',
    '-DOUT=${path('archive.7z').replaceAll(r'\', '/')}',
    '-DIMMUCH360_DOWNLOAD_ATTEMPTS=$attempts',
    '-DIMMUCH360_DOWNLOAD_PAUSE=$pause',
    '-P',
    script.path,
  ]);

  /// What CMake printed, its lines joined: it wraps the text of a warning
  String output(ProcessResult result) => '${result.stdout}${result.stderr}'.replaceAll(RegExp(r'\s+'), ' ');

  test('an archive with the right SHA-256 at the first attempt', () {
    final result = run([url('good.7z')], sha256Of('the archive'));
    expect(result.exitCode, 0, reason: output(result));
    expect(File(path('archive.7z')).readAsStringSync(), 'the archive');
    expect(output(result), contains('attempt 1 of 4'));
    expect(output(result), isNot(contains('attempt 2 of 4')));
    expect(File(path('archive.7z.part')).existsSync(), isFalse);
  }, skip: _skip);

  test('an error page with another SHA-256 is tried again and the next attempt is checked too', () {
    // The second address stands for a second source, or for the same one answering at the next attempt
    final result = run([url('error-page.html'), url('good.7z')], sha256Of('the archive'));
    expect(result.exitCode, 0, reason: output(result));
    expect(File(path('archive.7z')).readAsStringSync(), 'the archive');
    expect(output(result), contains('Attempt 1 of 4'));
    expect(output(result), contains('SHA-256 ${sha256Of('<html>502 Bad Gateway</html>')}'));
    expect(output(result), contains('attempt 2 of 4'));
  }, skip: _skip);

  test('an error of the transfer is tried again, the addresses in turn', () {
    final result = run([url('missing.7z'), url('good.7z')], sha256Of('the archive'), attempts: 2);
    expect(result.exitCode, 0, reason: output(result));
    expect(output(result), contains('download error'));
    expect(File(path('archive.7z')).existsSync(), isTrue);
  }, skip: _skip);

  test('every attempt failed: the configure stops with each attempt and nothing is left as the archive', () {
    final result = run([url('error-page.html')], sha256Of('the archive'), attempts: 3);
    expect(result.exitCode, isNot(0));
    expect(output(result), contains('Integrity check failed after 3 attempts'));
    for (final attempt in [1, 2, 3]) {
      expect(output(result), contains('attempt $attempt, ${url('error-page.html')}'));
    }
    expect(File(path('archive.7z')).existsSync(), isFalse);
    expect(File(path('archive.7z.part')).existsSync(), isFalse);
  }, skip: _skip);

  test('the pause between two attempts is waited and doubles', () {
    final watch = Stopwatch()..start();
    final result = run([url('missing.7z')], sha256Of('the archive'), attempts: 3, pause: 1);
    watch.stop();
    expect(result.exitCode, isNot(0));
    expect(output(result), contains('trying again in 1 seconds'));
    expect(output(result), contains('trying again in 2 seconds'));
    expect(watch.elapsed, greaterThanOrEqualTo(const Duration(seconds: 3)));
  }, skip: _skip);

  test('an archive already there is kept when its SHA-256 is right, downloaded again when not', () {
    File(path('archive.7z')).writeAsStringSync('the archive');
    var result = run([url('missing.7z')], sha256Of('the archive'), attempts: 1);
    expect(result.exitCode, 0, reason: output(result));
    expect(output(result), isNot(contains('Downloading')));

    File(path('archive.7z')).writeAsStringSync('an older archive');
    result = run([url('good.7z')], sha256Of('the archive').toUpperCase(), attempts: 1);
    expect(result.exitCode, 0, reason: output(result));
    expect(output(result), contains('SHA-256 mismatch. File deleted.'));
    expect(File(path('archive.7z')).readAsStringSync(), 'the archive');
  }, skip: _skip);
}
