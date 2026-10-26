import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/creator/safe_writer.dart';
import 'package:immich_mobile/desktop/ai/creator/write_probe.dart';
import 'package:path/path.dart' as p;

import '../fakes/recording_creator_files.dart';

void main() {
  late Directory root;
  late Directory support;
  late RecordingCreatorFiles files;
  late SafeWriter writer;
  late WriteProbe probe;

  List<String> partsIn(String folder) => [
    for (final entity in Directory(folder).listSync())
      if (isPartFileName(p.basename(entity.path))) entity.path,
  ];
  Future<List<String>> noted() => InflightJournal(settingsDirectory: () async => support).paths();
  Directory folder(String name) => Directory(p.join(root.path, name))..createSync(recursive: true);

  setUp(() {
    root = Directory.systemTemp.createTempSync('ai_write_probe');
    support = Directory(p.join(root.path, 'support'))..createSync();
    files = RecordingCreatorFiles();
    writer = SafeWriter(
      files: files,
      journal: InflightJournal(settingsDirectory: () async => support),
    );
    probe = WriteProbe(writer);
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('the first job of each folder creates its partial file, which that job takes over', () async {
    final a = folder('A');
    final b = folder('B');

    final results = await probe.check([
      ProbeRequest(jobId: 'a1', folder: a.path, finalName: 'one_3D_LRF_Full_SBS.jpg'),
      ProbeRequest(jobId: 'a2', folder: a.path, finalName: 'two_3D_LRF_Full_SBS.jpg'),
      ProbeRequest(jobId: 'b1', folder: b.path, finalName: 'three_3D_LRF_Full_SBS.jpg'),
    ]);

    expect(results.values.map((result) => result.status), everyElement(ProbeStatus.ready));
    expect(partsIn(a.path), hasLength(1));
    expect(partsIn(b.path), hasLength(1));
    expect(probe.jobsWithParts, unorderedEquals(['a1', 'b1']));
    expect(await noted(), unorderedEquals([...partsIn(a.path), ...partsIn(b.path)]));
    // No test file: only the partial files of the jobs
    expect(files.calls.where((call) => call.startsWith('createNew')), hasLength(2));

    final part = probe.take('a1')!;
    expect(part.path, partsIn(a.path).single);
    expect(part.finalName, 'one_3D_LRF_Full_SBS.jpg');
    expect(probe.take('a1'), isNull);
    expect(probe.take('a2'), isNull);

    // The dialog launched: the part taken stays for its job, the other one goes
    await probe.release();
    expect(File(part.path).existsSync(), isTrue);
    expect(partsIn(b.path), isEmpty);
    expect(await noted(), [part.path]);
  });

  test('a folder checked once is not checked again', () async {
    final a = folder('A');
    await probe.check([ProbeRequest(jobId: 'a1', folder: a.path, finalName: 'one.jpg')]);
    files.calls.clear();

    final results = await probe.check([ProbeRequest(jobId: 'a2', folder: p.join(a.path, '.'), finalName: 'two.jpg')]);

    expect(results.values.single.status, ProbeStatus.ready);
    expect(files.calls, isEmpty);
  });

  test('closed without launching: every partial file is deleted and forgotten', () async {
    final a = folder('A');
    await probe.check([ProbeRequest(jobId: 'a1', folder: a.path, finalName: 'one.jpg')]);

    await probe.release();

    expect(a.listSync(), isEmpty);
    expect(await noted(), isEmpty);
  });

  test('fifty folders at most; beyond, the partial file of the job checks at its turn', () async {
    probe = WriteProbe(writer, maxFolders: 3);
    final requests = [
      for (var index = 0; index < 5; index++)
        ProbeRequest(jobId: 'job$index', folder: folder('F$index').path, finalName: 'p$index.jpg'),
    ];

    final results = await probe.check(requests);

    expect(
      [for (final request in requests) results[request.folder]!.status],
      [ProbeStatus.ready, ProbeStatus.ready, ProbeStatus.ready, ProbeStatus.notChecked, ProbeStatus.notChecked],
    );
    expect(results.values.every((result) => result.accepted), isTrue);
    expect(partsIn(requests[3].folder), isEmpty);
    expect(WriteProbe(writer).maxFolders, 50);
  });

  test('a folder that refuses, a full disk, a missing folder: told, nothing left behind', () async {
    final refusing = folder('Refusing');
    final full = folder('Full');
    files.failures[refusing.path] = OSError('Access denied', Platform.isWindows ? 5 : 13);
    files.failures[full.path] = OSError('No space left', Platform.isWindows ? 112 : 28);
    final missing = p.join(root.path, 'Unplugged');

    final results = await probe.check([
      ProbeRequest(jobId: 'r', folder: refusing.path, finalName: 'r.jpg'),
      ProbeRequest(jobId: 'f', folder: full.path, finalName: 'f.jpg'),
      ProbeRequest(jobId: 'm', folder: missing, finalName: 'm.jpg'),
    ]);

    expect(results[refusing.path]!.status, ProbeStatus.readOnly);
    expect(results[full.path]!.status, ProbeStatus.diskFull);
    expect(results[missing]!.status, ProbeStatus.missing);
    expect(results.values.any((result) => result.accepted), isFalse);
    expect(refusing.listSync(), isEmpty);
    expect(full.listSync(), isEmpty);
    expect(Directory(missing).existsSync(), isFalse);
    expect(probe.jobsWithParts, isEmpty);
    expect(await noted(), isEmpty);
  });

  test('a chosen folder that is missing is created, the folder of an original never', () async {
    final chosen = p.join(root.path, 'Downloads', 'Immuch360');

    final results = await probe.check([
      ProbeRequest(jobId: 'c', folder: chosen, finalName: 'c.jpg', createFolder: true),
    ]);

    expect(results[chosen]!.status, ProbeStatus.ready);
    expect(partsIn(chosen), hasLength(1));
  });

  test('a refusal is forgotten on demand, and checked again', () async {
    final refusing = folder('Refusing');
    files.failures[refusing.path] = OSError('Access denied', Platform.isWindows ? 5 : 13);
    final request = ProbeRequest(jobId: 'r', folder: refusing.path, finalName: 'r.jpg');
    await probe.check([request]);
    files.failures.clear();

    probe.forgetRefusals();
    final results = await probe.check([request]);

    expect(results[refusing.path]!.status, ProbeStatus.ready);
  });

  test(
    'a job that now writes elsewhere gives its partial file back, and the folder is checked through another',
    () async {
      final a = folder('A');
      final b = folder('B');
      await probe.check([
        ProbeRequest(jobId: 'a1', folder: a.path, finalName: 'one.jpg'),
        ProbeRequest(jobId: 'a2', folder: a.path, finalName: 'two.jpg'),
      ]);

      await probe.keepOnly({'a1': b.path, 'a2': a.path});
      expect(partsIn(a.path), isEmpty);
      expect(probe.resultOf(a.path), isNull);
      await probe.check([
        ProbeRequest(jobId: 'a1', folder: b.path, finalName: 'one.jpg'),
        ProbeRequest(jobId: 'a2', folder: a.path, finalName: 'two.jpg'),
      ]);

      expect(probe.jobsWithParts, unorderedEquals(['a1', 'a2']));
      expect(probe.take('a2')!.folder, a.path);
      expect(probe.take('a1')!.folder, b.path);
    },
  );
}
