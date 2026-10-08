import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/desktop/files/download_folder.dart';
import 'package:immich_mobile/desktop/library/desktop_file_media_repository.dart';
import 'package:immich_mobile/repositories/download.repository.dart';
import 'package:immich_mobile/services/download.service.dart';
import 'package:path/path.dart' as p;

/// The callbacks DownloadService hangs on the repository, without a real downloader behind them
class _Downloads extends Fake implements DownloadRepository {
  @override
  void Function(TaskStatusUpdate)? onImageDownloadStatus;
  @override
  void Function(TaskStatusUpdate)? onVideoDownloadStatus;
  @override
  void Function(TaskStatusUpdate)? onLivePhotoDownloadStatus;
  @override
  void Function(TaskProgressUpdate)? onTaskProgress;
  @override
  void Function(TaskRecord)? onLivePhotoRecordComplete;

  @override
  Future<List<TaskRecord>> getLiveVideoTasks() async => const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // background_downloader keeps the base folders path_provider gave it the first time, for the whole run: the
  // temporary and documents folders are therefore the same for every test of this file, emptied between tests
  late Directory base;
  late Directory temporary;
  late Directory documents;
  late Directory root;
  late Directory settings;
  late Directory downloads;
  late DownloadFolder folder;
  late DesktopFileMediaRepository repository;

  File staged(String taskId, String name, String content) {
    final file = File(p.join(temporary.path, desktopDownloadStagingFolder, taskId, name))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
    return file;
  }

  String defaultFolder() => p.join(downloads.path, DownloadFolder.defaultFolderName);

  setUpAll(() {
    base = Directory.systemTemp.createTempSync('immuch360-downloads');
    temporary = Directory(p.join(base.path, 'Temp'))..createSync();
    documents = Directory(p.join(base.path, 'Documents'))..createSync();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => switch (call.method) {
        'getTemporaryDirectory' => temporary.path,
        'getApplicationDocumentsDirectory' => documents.path,
        _ => p.join(base.path, 'Other'),
      },
    );
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    base.deleteSync(recursive: true);
  });

  setUp(() {
    root = Directory(p.join(base.path, 'test'))..createSync();
    settings = Directory(p.join(root.path, 'support'))..createSync();
    downloads = Directory(p.join(root.path, 'Downloads'))..createSync();
    folder = DownloadFolder(
      settingsDirectory: () async => settings,
      downloadsDirectory: () async => downloads,
      temporaryDirectory: () async => temporary,
    );
    repository = DesktopFileMediaRepository(folder: folder, announce: false);
  });

  tearDown(() {
    root.deleteSync(recursive: true);
    for (final shared in [temporary, documents]) {
      for (final entity in shared.listSync()) {
        entity.deleteSync(recursive: true);
      }
    }
  });

  group('keeping a download', () {
    test('moves it into Downloads/Immuch360 under its title, the task folder removed', () async {
      final source = staged('asset-1', 'IMG_0001.JPG', 'photo');

      final entity = await repository.saveImageWithFile(
        source.path,
        title: 'IMG_0001.JPG',
        relativePath: 'DCIM/Immich',
      );

      expect(entity, isNotNull);
      expect(File(p.join(defaultFolder(), 'IMG_0001.JPG')).readAsStringSync(), 'photo');
      expect(source.existsSync(), isFalse, reason: 'nothing left for the finally block of DownloadService');
      expect(source.parent.existsSync(), isFalse);
      expect(Directory(p.join(defaultFolder(), 'DCIM')).existsSync(), isFalse, reason: 'the Android folder is ignored');
      expect(entity!.id, isNot(contains(root.path)), reason: 'no path in the id');
    });

    test('never replaces a file of the user: the next free "name (n)" instead', () async {
      Directory(defaultFolder()).createSync(recursive: true);
      File(p.join(defaultFolder(), 'IMG_0001.JPG')).writeAsStringSync('mine');

      await repository.saveImageWithFile(staged('a', 'IMG_0001.JPG', 'first').path, title: 'IMG_0001.JPG');
      await repository.saveImageWithFile(staged('b', 'IMG_0001.JPG', 'second').path, title: 'IMG_0001.JPG');

      expect(File(p.join(defaultFolder(), 'IMG_0001.JPG')).readAsStringSync(), 'mine');
      expect(File(p.join(defaultFolder(), 'IMG_0001 (1).JPG')).readAsStringSync(), 'first');
      expect(File(p.join(defaultFolder(), 'IMG_0001 (2).JPG')).readAsStringSync(), 'second');
    });

    test('a title Windows would refuse becomes a name it accepts', () async {
      await repository.saveVideo(staged('v', 'x.mp4', 'video'), title: 'trip: day 1/2?.mp4');
      expect(File(p.join(defaultFolder(), 'trip_ day 1_2_.mp4')).readAsStringSync(), 'video');
    });

    test('a live photo keeps its photo and its video side by side', () async {
      final entity = await repository.saveLivePhoto(
        image: staged('i', 'IMG_0002.HEIC', 'still'),
        video: staged('m', 'IMG_0002.MOV', 'motion'),
        title: 'IMG_0002.HEIC',
      );
      expect(entity, isNotNull);
      expect(File(p.join(defaultFolder(), 'IMG_0002.HEIC')).readAsStringSync(), 'still');
      expect(File(p.join(defaultFolder(), 'IMG_0002.MOV')).readAsStringSync(), 'motion');
    });

    test('nothing is kept when the downloaded file is missing', () async {
      expect(await repository.saveImageWithFile(p.join(temporary.path, 'none.jpg')), isNull);
      expect(Directory(defaultFolder()).existsSync(), isFalse);
    });
  });

  group('the download folder setting', () {
    test('a chosen folder is used and remembered', () async {
      final chosen = p.join(root.path, 'Library', 'From the server');
      await folder.choose(chosen);
      await repository.saveImageWithFile(staged('a', 'a.jpg', 'a').path, title: 'a.jpg');
      expect(File(p.join(chosen, 'a.jpg')).existsSync(), isTrue);

      final later = DownloadFolder(settingsDirectory: () async => settings, downloadsDirectory: () async => downloads);
      expect(await later.currentPath(), p.normalize(chosen));
      await later.choose(null);
      expect(await later.currentPath(), defaultFolder());
    });

    test('a chosen folder that cannot be made gives the default one for this download', () async {
      final blocker = File(p.join(root.path, 'not a folder'))..writeAsStringSync('');
      await folder.choose(p.join(blocker.path, 'inside'));
      await repository.saveImageWithFile(staged('a', 'a.jpg', 'a').path, title: 'a.jpg');
      expect(File(p.join(defaultFolder(), 'a.jpg')).existsSync(), isTrue);
      expect(folder.chosen.value, p.normalize(p.join(blocker.path, 'inside')), reason: 'the setting stays');
    });

    test('a damaged settings file gives the default', () async {
      File(p.join(settings.path, 'desktop_files.json')).writeAsStringSync('{not json');
      expect(await folder.currentPath(), defaultFolder());
    });
  });

  group('the transfer', () {
    test('a computer task lands in its own folder under the temporary folder, never in Documents', () async {
      final task = DownloadTask(
        taskId: 'remote-id-1',
        url: 'https://example.invalid/api/assets/remote-id-1/original',
        filename: 'IMG_0001.JPG',
        group: kDownloadGroupImage,
        updates: Updates.statusAndProgress,
      );
      expect(p.isWithin(documents.path, await task.filePath()), isTrue, reason: 'the default of the phones');

      final staged = desktopDownloadTask(task);
      final path = await staged.filePath();
      expect(path, p.join(temporary.path, desktopDownloadStagingFolder, 'remote-id-1', 'IMG_0001.JPG'));
      expect(p.isWithin(documents.path, path), isFalse);
      expect(
        (staged.taskId, staged.url, staged.filename, staged.group, staged.updates),
        (task.taskId, task.url, task.filename, task.group, task.updates),
      );
    });

    test(
      'DownloadService keeps the file in the download folder before its finally block deletes the download',
      () async {
        final repositoryOfTasks = _Downloads();
        // Hangs its callbacks on the tasks repository, as the app's provider does
        DownloadService(repository, repositoryOfTasks);
        final task = desktopDownloadTask(
          DownloadTask(taskId: 'remote-id-2', url: 'https://example.invalid/2', filename: 'IMG_0003.JPG'),
        );
        final file = File(await task.filePath())
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('from the server');
        // A file of the user with the same name in Documents, where the phones' default would have put the download
        final mine = File(p.join(documents.path, 'IMG_0003.JPG'))..writeAsStringSync('mine');

        repositoryOfTasks.onImageDownloadStatus!(TaskStatusUpdate(task, TaskStatus.complete));
        final kept = File(p.join(defaultFolder(), 'IMG_0003.JPG'));
        for (var wait = 0; wait < 100 && (file.existsSync() || !kept.existsSync()); wait++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        expect(kept.readAsStringSync(), 'from the server');
        expect(file.existsSync(), isFalse);
        expect(mine.readAsStringSync(), 'mine');
      },
    );
  });
}
