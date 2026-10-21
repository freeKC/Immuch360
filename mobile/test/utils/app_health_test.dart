import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/app_health.dart';
import 'package:logging/logging.dart';

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
    AppHealthReports.write({'kind': 'stall', 'text': 'The main thread did not answer for 4.2 s'});
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
    AppHealthReports.write('text');
    AppHealthReports.write({'kind': 'stall'});
    await pumpEventQueue();

    expect(records, isEmpty);
  });
}
