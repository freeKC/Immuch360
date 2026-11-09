import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/log.model.dart';
import 'package:immich_mobile/domain/services/log.service.dart';
import 'package:immich_mobile/utils/app_health.dart';
import 'package:logging/logging.dart';
import 'package:mocktail/mocktail.dart';

import '../infrastructure/repository.mock.dart';

class _FakeLogMessage extends Fake implements LogMessage {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<LogRecord> records;

  setUp(() {
    records = [];
    Logger.root.level = Level.ALL;
    final subscription = Logger.root.onRecord.where((record) => record.loggerName == 'AppHealth').listen(records.add);
    addTearDown(subscription.cancel);
  });

  test('writes a stall to the logs with the state of the image cache', () async {
    expect(AppHealthReports.write({'kind': 'stall', 'text': 'The main thread did not answer for 4.2 s'}), isTrue);
    await pumpEventQueue();

    expect(records.single.level, Level.WARNING);
    expect(
      records.single.message,
      startsWith('The main thread did not answer for 4.2 s\nImage cache: 0 pictures, 0 MB'),
    );
  });

  test('writes an end of the app as it comes', () async {
    AppHealthReports.write({'kind': 'exit', 'text': 'The app ended on 2026-10-21 12:03:04: not responding (ANR)'});
    await pumpEventQueue();

    expect(records.single.message, 'The app ended on 2026-10-21 12:03:04: not responding (ANR)');
  });

  test('writes a video the 360 player could not play as it comes', () async {
    AppHealthReports.write({'kind': 'video', 'text': 'The 360° player cannot play VID.mp4 from the server original'});
    await pumpEventQueue();

    expect(records.single.level, Level.WARNING);
    expect(records.single.message, 'The 360° player cannot play VID.mp4 from the server original');
  });

  test('ignores what is not a report', () async {
    expect(AppHealthReports.write('text'), isFalse);
    expect(AppHealthReports.write({'kind': 'stall'}), isFalse);
    await pumpEventQueue();

    expect(records, isEmpty);
  });

  test('the state Android keeps names the page and the foreground, nothing else', () {
    expect(AppHealthReports.stateText(page: 'AssetViewerRoute', foreground: true), 'page=AssetViewerRoute fg');
    expect(AppHealthReports.stateText(foreground: false), 'bg');
  });

  group('with Android', () {
    // What happens on the channel and in the database of the log, in order
    late List<String> events;
    late List<MethodCall> calls;
    late LogService logService;

    setUpAll(() async {
      registerFallbackValue(_FakeLogMessage());
      final logRepository = MockLogRepository();
      final settingsRepository = MockSettingsRepository();
      when(() => logRepository.truncate(limit: any(named: 'limit'))).thenAnswer((_) async {});
      when(() => logRepository.insertAll(any())).thenAnswer((_) async {
        events.add('log written');
        return true;
      });
      when(() => settingsRepository.appConfig).thenReturn(const AppConfig(logLevel: LogLevel.info));
      logService = await LogService.init(logRepository: logRepository, settingsRepository: settingsRepository);
    });

    tearDownAll(() => logService.dispose());

    /// Android as AppHealth.kt answers: [pending] for "takeReports"
    void android(List<Object?> pending) {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(AppHealthReports.channel, (call) async {
        calls.add(call);
        events.add(call.method);
        return call.method == 'takeReports' ? pending : null;
      });
    }

    setUp(() {
      events = [];
      calls = [];
      AppHealthReports.resetForTest();
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        AppHealthReports.channel,
        null,
      );
      AppHealthReports.resetForTest();
      debugDefaultTargetPlatformOverride = null;
    });

    test('tells Android which reports of ends the log holds, once it is written to the database', () async {
      android([
        {'kind': 'exit', 'text': 'The app ended on 2026-11-08 19:05:03: native crash', 'id': '1731089103000-4242.txt'},
        {'kind': 'stall', 'text': 'The main thread did not answer for 4.2 s'},
        {'kind': 'exit', 'id': '1731089104000-4243.txt'},
      ]);

      await AppHealthReports.listen();
      await pumpEventQueue();

      expect(records.map((record) => record.message), [
        'The app ended on 2026-11-08 19:05:03: native crash',
        startsWith('The main thread did not answer for 4.2 s'),
      ]);
      // The answer comes after the log reached its database; a report without an id, or without a text, is not in it
      expect(events, ['takeReports', 'log written', 'reportsWritten']);
      expect(calls.last.arguments, ['1731089103000-4242.txt']);
    });

    test('a report that comes later is answered as well, and none without an id', () async {
      android(const []);
      await AppHealthReports.listen();

      Future<void> report(Map<String, String> values) async {
        final message = const StandardMethodCodec().encodeMethodCall(MethodCall('report', values));
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
          AppHealthReports.channel.name,
          message,
          (_) {},
        );
        await pumpEventQueue();
      }

      await report({'kind': 'stall', 'text': 'The main thread did not answer for 3.1 s'});
      const id = '1731089160000-4300.txt';
      await report({'kind': 'exit', 'text': 'The app ended on 2026-11-08 19:06:00: crash', 'id': id});

      expect(records.map((record) => record.message).last, 'The app ended on 2026-11-08 19:06:00: crash');
      expect(events, ['takeReports', 'log written', 'reportsWritten']);
      expect(calls.last.arguments, [id]);
    });

    test('gives Android the page and the foreground once it listens, once per change', () async {
      android(const []);
      AppHealthReports.setPage('SplashScreenRoute');
      await AppHealthReports.listen();

      AppHealthReports.setPage('TabShellRoute');
      AppHealthReports.setPage('TabShellRoute');
      AppHealthReports.setForeground(false);
      AppHealthReports.setPage(null);
      await pumpEventQueue();

      final states = calls.where((call) => call.method == 'setState').map((call) => call.arguments);
      expect(states, ['page=TabShellRoute fg', 'page=TabShellRoute bg']);
    });
  });
}
