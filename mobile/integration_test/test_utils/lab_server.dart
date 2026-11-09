// What the lab tests of the Android lab share (immuch360-android-lab.yml): the fake Immich server the lab script starts
// on the runner (.github/android-lab/fake_immich.py), which the emulator reaches at 10.0.2.2; the commands that server
// runs on the emulator for the tests (LAB_HOST lines in logcat); the scenario lines that check_logcat.py reads; the
// start of the app as lib/main.dart does it; and the sign in through the redirects of the fake server. Emulator only,
// never a device of the owner.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/store.dart';
import 'package:immich_mobile/desktop/platform/desktop_apis.dart';
import 'package:immich_mobile/domain/services/background_worker.service.dart';
import 'package:immich_mobile/main.dart' as app;
import 'package:immich_mobile/pages/common/tab_shell.page.dart';
import 'package:immich_mobile/pages/login/login.page.dart';
import 'package:immich_mobile/pages/login/welcome.page.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_tile.widget.dart';
import 'package:immich_mobile/providers/auth.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/providers/sync_status.provider.dart';
import 'package:immich_mobile/utils/app_health.dart';
import 'package:immich_mobile/utils/bootstrap.dart';
import 'package:immich_mobile/utils/migration.dart';
import 'package:immich_mobile/utils/provider_utils.dart';
import 'package:immich_mobile/widgets/forms/login/sign_in_completion.dart';
import 'package:immich_mobile/wm_executor.dart';

/// The names of the photos of the fake server's timeline
const labTimelineNames = ['lab_jpeg.jpg', 'lab_heic.heic', 'lab_avif.avif'];

/// A line for both logcat (check_logcat.py and the LAB_HOST commands read it there) and the output of the test: the
/// print of a test is the test runner's, which never reaches logcat
void labLog(String line) {
  Zone.root.print(line);
  debugPrint(line);
}

/// Runs [body] as the scenario [name] of the lab: its start and its end in logcat, where check_logcat.py gives each
/// scenario the crashes, ANRs and process deaths that happen while it runs
Future<void> labScenario(String name, Future<void> Function() body) async {
  labLog('LAB_SCENARIO start $name');
  final watch = Stopwatch()..start();
  try {
    await body();
  } catch (error) {
    labLog('LAB_SCENARIO failed $name after ${watch.elapsed.inSeconds} s: ${'$error'.split('\n').first}');
    rethrow;
  }
  labLog('LAB_SCENARIO passed $name in ${watch.elapsed.inSeconds} s');
}

/// One request the fake server answered, as /lab/state lists it
class LabRequest {
  const LabRequest(this.json);

  final Map<String, dynamic> json;

  String get method => json['method'] as String? ?? '';
  String get path => json['path'] as String? ?? '';
  Object? get status => json['status'];
  int get seq => json['seq'] as int? ?? 0;

  @override
  String toString() => '$seq $method $path -> $status';
}

/// What the fake server saw: its requests, its sync streams, its uploads and the web socket
class LabState {
  const LabState(this.json);

  final Map<String, dynamic> json;

  List<LabRequest> get requests => [
    for (final entry in json['requests'] as List<dynamic>) LabRequest(entry as Map<String, dynamic>),
  ];

  List<Map<String, dynamic>> get streams => [
    for (final entry in json['streams'] as List<dynamic>) entry as Map<String, dynamic>,
  ];

  List<Map<String, dynamic>> get uploads => [
    for (final entry in json['uploads'] as List<dynamic>) entry as Map<String, dynamic>,
  ];

  Map<String, dynamic> get socket => json['socket'] as Map<String, dynamic>;

  /// The id of the photo named [name] on the fake server
  String assetId(String name) {
    for (final asset in json['assets'] as List<dynamic>) {
      final map = asset as Map<String, dynamic>;
      if (map['name'] == name) {
        return map['id'] as String;
      }
    }
    return fail('no photo $name on the fake server');
  }

  Map<String, dynamic> get user => json['user'] as Map<String, dynamic>;

  /// The requests of [method] on [path] with the answer [status], when given
  List<LabRequest> matching(String method, String path, {Object? status}) => [
    for (final request in requests)
      if (request.method == method && request.path == path && (status == null || request.status == status)) request,
  ];

  /// The paths the fake server did not know, for the report
  List<String> get unknownPaths => {
    for (final request in requests)
      if (request.json['unknown'] == true) '${request.method} ${request.path}',
  }.toList();
}

/// The fake Immich server of the lab script, at LAB_SERVER (10.0.2.2 is the runner seen from the emulator)
class LabServer {
  LabServer(this.url);

  factory LabServer.fromEnvironment() =>
      LabServer(const String.fromEnvironment('LAB_SERVER', defaultValue: 'http://10.0.2.2:2283'));

  final String url;
  final HttpClient _client = HttpClient()..connectionTimeout = const Duration(seconds: 10);

  Future<List<int>> _call(String method, String path) async {
    final request = await _client.openUrl(method, Uri.parse('$url$path'));
    final response = await request.close();
    final bytes = await response.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
    if (response.statusCode >= 400) {
      fail('fake server: $method $path answered ${response.statusCode}');
    }
    return bytes;
  }

  Future<LabState> state() async =>
      LabState(jsonDecode(utf8.decode(await _call('GET', '/lab/state'))) as Map<String, dynamic>);

  /// The next sync stream sends its events and stays open until the client closes it or [releaseSyncs]
  Future<void> holdNextSync() => _call('POST', '/lab/hold-next-sync');

  Future<void> releaseSyncs() => _call('POST', '/lab/release-syncs');

  /// The bytes of a file of mobile/test/fixtures/android_lab
  Future<Uint8List> fixture(String name) async => Uint8List.fromList(await _call('GET', '/lab/fixture/$name'));

  Future<Map<String, dynamic>> hostCommand(String id) async =>
      jsonDecode(utf8.decode(await _call('GET', '/lab/host/$id'))) as Map<String, dynamic>;
}

/// The commands the fake server runs on the emulator for the tests: they print `LAB_HOST id command` lines to logcat
/// and wait for the server to say it is done
class LabHost {
  LabHost(this.server);

  final LabServer server;
  final String _run = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  int _next = 0;

  String _newId() => '$_run-${++_next}';

  Future<String> _command(String id, String verb, String argument, Duration timeout) async {
    labLog('LAB_HOST $id $verb${argument.isEmpty ? '' : ' $argument'}');
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final answer = await server.hostCommand(id);
      if (answer['done'] == true) {
        final error = answer['error'];
        if (error != null) {
          fail('LAB_HOST $verb $argument: $error');
        }
        return '${answer['result'] ?? ''}';
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return fail('LAB_HOST $verb $argument: not done within ${timeout.inSeconds} s');
  }

  /// Grants the permissions the app would ask in a system dialog, which a test cannot answer
  Future<String> grant() => _command(_newId(), 'grant', '', const Duration(seconds: 60));

  /// The Home key: the app goes to the background (no frame is drawn until [open])
  Future<String> home() => _command(_newId(), 'home', '', const Duration(seconds: 30));

  /// The launcher intent of the app: it comes back to the foreground
  Future<String> open() => _command(_newId(), 'open', '', const Duration(seconds: 30));

  /// A place in logcat for [waitFor]
  Future<String> mark() async {
    final id = _newId();
    await _command(id, 'mark', '', const Duration(seconds: 30));
    return id;
  }

  /// The first logcat line after [mark] that matches [pattern] (a regular expression of Python), once it is there
  Future<String> waitFor(String mark, String pattern, {Duration timeout = const Duration(seconds: 60)}) =>
      _command(_newId(), 'wait', '$mark $pattern', timeout);
}

/// Pumps frames until [condition] holds, or fails after [timeout] with [reason] and what [describe] says
Future<void> pumpUntil(
  WidgetTester tester,
  FutureOr<bool> Function() condition, {
  required String reason,
  Duration timeout = const Duration(seconds: 60),
  FutureOr<String> Function()? describe,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      final details = describe == null ? '' : '\n${await describe()}';
      fail('$reason: not within ${timeout.inSeconds} s$details');
    }
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// Waits without frames until [condition] holds: the app in the background draws none, so a pump would wait forever
Future<void> waitUntil(
  FutureOr<bool> Function() condition, {
  required String reason,
  Duration timeout = const Duration(seconds: 60),
  FutureOr<String> Function()? describe,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      final details = describe == null ? '' : '\n${await describe()}';
      fail('$reason: not within ${timeout.inSeconds} s$details');
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}

/// The tile of the timeline that shows the photo [name]
Finder labTile(String name) =>
    find.byWidgetPredicate((widget) => widget is ThumbnailTile && widget.asset?.name == name);

/// Starts the app as runImmich of lib/main.dart does, without its binding and its runApp: the test binding is the app's
Future<void> startLabApp(WidgetTester tester) async {
  await BackgroundWorkerLockService(PlatformApis.backgroundWorkerLock()).lock();
  await EasyLocalization.ensureInitialized();
  final (dataController, apiService) = await Bootstrap.initDomain();
  // initApp sets the app's FlutterError.onError, which the test binding must keep: its own reports the failures of
  // the test (with the app's, a failure ended in an assertion of the binding and a wait until the test's timeout)
  final testOnError = FlutterError.onError;
  await app.initApp();
  FlutterError.onError = testOnError;
  await workerManagerPatch.init(dynamicSpawning: true, isolatesCount: max(Platform.numberOfProcessors - 1, 5));
  await migrateDatabaseIfNeeded(dataController.db, PlatformApis.nativeSync(), PlatformApis.permission());
  unawaited(AppHealthReports.listen());
  await tester.pumpWidget(
    ProviderScope(
      overrides: Store.overrideWith(dataController: dataController, apiService: apiService),
      child: const app.MainWidget(),
    ),
  );
}

final _firstPage = find.byWidgetPredicate((widget) => widget is WelcomePage || widget is LoginPage);

/// Signs in through the fake server as the login form does (the server URL, the server's settings, the credentials),
/// then completes the sign in as every sign in of the app does (completeSignIn: permission, sync, timeline). Returns
/// the API endpoint the app resolved.
Future<String> signInThroughLabServer(WidgetTester tester, LabServer server) async {
  await pumpUntil(tester, () => _firstPage.evaluate().isNotEmpty, reason: 'the welcome page after the splash');
  final user = (await server.state()).user;
  // The page is a consumer widget: its element is the WidgetRef its build gets
  WidgetRef pageRef() => tester.element(_firstPage.first) as ConsumerStatefulElement;
  final endpoint = await pageRef().read(authProvider.notifier).validateServerUrl(server.url);
  await pageRef().read(serverInfoProvider.notifier).getServerInfo();
  invalidateAllApiRepositoryProviders(pageRef());
  await pageRef().read(authProvider.notifier).login(user['email'] as String, user['password'] as String);
  final page = tester.element(_firstPage.first) as ConsumerStatefulElement;
  await completeSignIn(page, page);
  await pumpUntil(tester, () => find.byType(TabShellPage).evaluate().isNotEmpty, reason: 'the timeline page');
  return endpoint;
}

/// Waits until no sync of the app has run for [quiet]: a sync still running when the test ends is cancelled as the
/// providers are disposed, and that cancel leaves an error no one handles (BackgroundSyncManager.cancel)
Future<void> waitForQuietSyncs(WidgetTester tester, {Duration quiet = const Duration(seconds: 3)}) async {
  final container = labContainer(tester);
  DateTime? quietSince;
  await pumpUntil(
    tester,
    () {
      final status = container.read(syncStatusProvider);
      if (status.isRemoteSyncing || status.isLocalSyncing || status.isHashing || status.isCloudIdSyncing) {
        quietSince = null;
        return false;
      }
      final since = quietSince ??= DateTime.now();
      return DateTime.now().difference(since) >= quiet;
    },
    reason: 'the syncs of the app quiet for ${quiet.inSeconds} s',
    timeout: const Duration(seconds: 90),
  );
}

/// The provider container of the app, found from the timeline page
ProviderContainer labContainer(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(TabShellPage)));

/// Waits for the three photos of the fake server in the timeline
Future<void> waitForLabTimeline(WidgetTester tester, LabServer server) => pumpUntil(
  tester,
  () => labTimelineNames.every((name) => labTile(name).evaluate().isNotEmpty),
  reason: 'the three photos of the fake server in the timeline',
  timeout: const Duration(seconds: 90),
  describe: () async {
    final state = await server.state();
    final shown = [for (final name in labTimelineNames) '$name: ${labTile(name).evaluate().length}'];
    return 'tiles $shown; sync streams ${state.streams}; last requests ${state.requests.reversed.take(15).toList()}';
  },
);
