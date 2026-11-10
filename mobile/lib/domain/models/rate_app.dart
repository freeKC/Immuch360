// The invitation to rate the app (release 45, study of 10 November 2026 in the research notes, "Rating invitation"):
// what the app keeps of its use on this install, and the rule that says when the store of the build may be asked for
// a rating. Pure: no clock, no store, no platform, so that every condition is tested alone.
//
// The rule asks once a few viewings ended well over several days, never right after an update, the What's new notice
// or a crash of this build, never twice in a build, twice at most ever, 90 days apart, and never again once the user
// chose Rate or dismissed the invitation twice. Google Play and the App Store show their own card or prompt and never
// say whether it showed or what the user did: an ask there counts as asked, without an answer. On the Quest store
// build, where Meta offers no review API, the app shows a sentence of its own with Not now and Rate.

import 'dart:convert';

/// The store that can take a rating of this build (storeChannelOf in lib/utils/store_channel.dart)
enum RateAppChannel {
  /// The phone flavour installed from Google Play: the Play In-App Review card
  googlePlay,

  /// The App Store build of iOS and iPadOS: the StoreKit prompt
  appStore,

  /// The quest flavour signed with the key of the Meta Horizon Store: the app's own sentence, Rate opens the store page
  horizonStore,

  /// An APK of the GitHub releases: no store to rate in, nothing is asked
  github,

  /// A debug build, TestFlight, the phone APK on a Quest, an unknown signature, the computers: nothing is asked
  none;

  /// Whether the invitation exists in this build at all
  bool get canAsk => this == googlePlay || this == appStore || this == horizonStore;
}

/// What the user did with an invitation of the app's own (the Quest store build). Play and StoreKit never tell, so
/// their asks keep [none].
enum RateAppAnswer { none, notNow, rate }

/// A viewing that may end well, one of the success signals of the rule
enum RateAppViewing { immersive, sphericalVideo, spatialVideo, splat, panorama, film }

/// The fork's switch of the whole invitation: false and no build asks anything
const bool kRateAppInvite = true;

/// Opens of the app before the first ask, on at least [kRateAppMinDays] different local days
const int kRateAppMinOpens = 5;
const int kRateAppMinDays = 3;

/// Viewings that ended well before the first ask, the last of them being the moment
const int kRateAppMinSuccesses = 2;

/// A viewing counts when it stayed open so long at least
const Duration kRateAppMinViewing = Duration(seconds: 20);

/// A return to the foreground counts as an open after so long in the background
const Duration kRateAppReopenAfter = Duration(minutes: 30);

/// No ask within so long of the first open of a new build (an update), nor of the What's new notice
const Duration kRateAppQuietAfterUpdate = Duration(hours: 24);
const Duration kRateAppQuietAfterNotice = Duration(hours: 24);

/// Asks at most, ever, the second one at least [kRateAppSecondAskAfter] after the first
const int kRateAppMaxAsks = 2;
const Duration kRateAppSecondAskAfter = Duration(days: 90);

/// Dismissals of the app's own invitation after which it is never shown again
const int kRateAppMaxDismissals = 2;

/// The pause on a browse page, after the viewing that ended well, before the ask
const Duration kRateAppSettle = Duration(seconds: 2);

/// One ask: the [build] it was made in, when, through which store, and the answer when the app could know it
class RateAppAsk {
  const RateAppAsk({required this.build, required this.at, required this.channel, this.answer = RateAppAnswer.none});

  final int build;
  final DateTime at;
  final RateAppChannel channel;
  final RateAppAnswer answer;

  Map<String, Object?> toJson() => {
    'build': build,
    'at': at.millisecondsSinceEpoch,
    'channel': channel.name,
    'answer': answer.name,
  };

  static RateAppAsk fromJson(Map<String, Object?> json) => RateAppAsk(
    build: json['build']! as int,
    at: DateTime.fromMillisecondsSinceEpoch(json['at']! as int),
    channel: RateAppChannel.values.byName(json['channel']! as String),
    answer: RateAppAnswer.values.byName(json['answer']! as String),
  );

  @override
  bool operator ==(Object other) =>
      other is RateAppAsk &&
      other.build == build &&
      other.at == at &&
      other.channel == channel &&
      other.answer == answer;

  @override
  int get hashCode => Object.hash(build, at, channel, answer);
}

/// What the app keeps of its use on this install, one JSON object under StoreKey.rateAppState. Nothing of it leaves
/// the device.
class RateAppState {
  const RateAppState({
    this.opens = 0,
    this.days = 0,
    this.lastDay,
    this.successes = 0,
    this.build,
    this.buildSince,
    this.noticeAt,
    this.problemBuild,
    this.problemAt,
    this.foreground = false,
    this.asks = const [],
  });

  /// The version of the JSON object
  static const version = 1;

  /// Opens of the app (a start of the app's engine, or a return after [kRateAppReopenAfter] in the background)
  final int opens;

  /// Different local days with an open, and the last of them ("2026-11-10")
  final int days;
  final String? lastDay;

  /// Viewings that ended well since the install
  final int successes;

  /// The build of the last open (PackageInfo.buildNumber) and the first open of that build
  final int? build;
  final DateTime? buildSince;

  /// When the What's new notice last showed
  final DateTime? noticeAt;

  /// The build that last crashed (a crash, a native crash or an ANR, never a kill for low memory), and when it was told
  final int? problemBuild;
  final DateTime? problemAt;

  /// Set while the app is in the foreground, cleared when it leaves: still set at the next start, the last process
  /// ended in the foreground (iOS, and Android before 11, which keeps no exit reasons)
  final bool foreground;

  /// Every ask made, oldest first
  final List<RateAppAsk> asks;

  /// The dismissals of the app's own invitation
  int get dismissals => asks.where((ask) => ask.answer == RateAppAnswer.notNow).length;

  /// Whether the user chose Rate once
  bool get rated => asks.any((ask) => ask.answer == RateAppAnswer.rate);

  RateAppState copyWith({
    int? opens,
    int? days,
    String? lastDay,
    int? successes,
    int? build,
    DateTime? buildSince,
    DateTime? noticeAt,
    int? problemBuild,
    DateTime? problemAt,
    bool? foreground,
    List<RateAppAsk>? asks,
  }) => RateAppState(
    opens: opens ?? this.opens,
    days: days ?? this.days,
    lastDay: lastDay ?? this.lastDay,
    successes: successes ?? this.successes,
    build: build ?? this.build,
    buildSince: buildSince ?? this.buildSince,
    noticeAt: noticeAt ?? this.noticeAt,
    problemBuild: problemBuild ?? this.problemBuild,
    problemAt: problemAt ?? this.problemAt,
    foreground: foreground ?? this.foreground,
    asks: asks ?? this.asks,
  );

  Map<String, Object?> toJson() => {
    'v': version,
    'opens': opens,
    'days': days,
    if (lastDay != null) 'lastDay': lastDay,
    'successes': successes,
    if (build != null) 'build': build,
    if (buildSince != null) 'buildSince': buildSince!.millisecondsSinceEpoch,
    if (noticeAt != null) 'noticeAt': noticeAt!.millisecondsSinceEpoch,
    if (problemBuild != null) 'problemBuild': problemBuild,
    if (problemAt != null) 'problemAt': problemAt!.millisecondsSinceEpoch,
    'foreground': foreground,
    'asks': [for (final ask in asks) ask.toJson()],
  };

  String encode() => jsonEncode(toJson());

  /// The state [text] holds; a fresh state when there is none, and when it does not read, which [onError] is told of
  static RateAppState decode(String? text, {void Function(Object error)? onError}) {
    if (text == null || text.isEmpty) {
      return const RateAppState();
    }
    try {
      final json = (jsonDecode(text) as Map).cast<String, Object?>();
      DateTime? time(String key) {
        final value = json[key];
        return value == null ? null : DateTime.fromMillisecondsSinceEpoch(value as int);
      }

      return RateAppState(
        opens: json['opens'] as int? ?? 0,
        days: json['days'] as int? ?? 0,
        lastDay: json['lastDay'] as String?,
        successes: json['successes'] as int? ?? 0,
        build: json['build'] as int?,
        buildSince: time('buildSince'),
        noticeAt: time('noticeAt'),
        problemBuild: json['problemBuild'] as int?,
        problemAt: time('problemAt'),
        foreground: json['foreground'] as bool? ?? false,
        asks: [
          for (final ask in (json['asks'] as List? ?? const []))
            RateAppAsk.fromJson((ask as Map).cast<String, Object?>()),
        ],
      );
    } catch (error) {
      onError?.call(error);
      return const RateAppState();
    }
  }

  @override
  bool operator ==(Object other) => other is RateAppState && other.encode() == encode();

  @override
  int get hashCode => encode().hashCode;
}

/// The local day of [time], "2026-11-10": the days of the rule are the user's
String rateAppDayOf(DateTime time) {
  final local = time.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year.toString().padLeft(4, '0')}-${two(local.month)}-${two(local.day)}';
}

/// [state] after an open of the app at [now] in [build]: one more open, one more day when the local day is a later one
/// (a day already counted, or an earlier one after a change of time zone, is not counted again), and the first open of
/// a new build starts its quiet period
RateAppState rateAppOpened(RateAppState state, {required DateTime now, required int build}) {
  final day = rateAppDayOf(now);
  final lastDay = state.lastDay;
  final newDay = lastDay == null || day.compareTo(lastDay) > 0;
  return state.copyWith(
    opens: state.opens + 1,
    days: newDay ? state.days + 1 : state.days,
    lastDay: newDay ? day : lastDay,
    build: build,
    buildSince: state.build == build && state.buildSince != null ? state.buildSince : now,
  );
}

/// [state] once [ask] was made
RateAppState rateAppAsked(RateAppState state, RateAppAsk ask) => state.copyWith(asks: [...state.asks, ask]);

/// What the rule reads besides the state, at the moment of a possible ask
class RateAppContext {
  const RateAppContext({
    required this.channel,
    required this.build,
    required this.now,
    this.enabled = kRateAppInvite,
    this.screenshotMode = false,
    this.kioskActive = false,
    this.versionWarning = false,
  });

  final RateAppChannel channel;
  final int build;
  final DateTime now;

  /// [kRateAppInvite]
  final bool enabled;

  /// The store captures (kScreenshotMode)
  final bool screenshotMode;

  /// The kiosk mode of the Quest is on (KioskConfig.isActive)
  final bool kioskActive;

  /// The version warning of the profile menu is present (versionWarningPresentProvider)
  final bool versionWarning;
}

/// Why the app does not ask now, the words of its log line ("not yet, opens 4 of 5, days 2 of 3"), or null when it
/// may ask
String? rateAppBlocker(RateAppState state, RateAppContext context) {
  if (!context.enabled) {
    return 'off in this build';
  }
  if (!context.channel.canAsk) {
    return 'no store to rate this build in (${context.channel.name})';
  }
  if (context.screenshotMode) {
    return 'store captures';
  }
  if (context.kioskActive) {
    return 'kiosk mode';
  }
  if (state.rated) {
    return 'rated already';
  }
  if (state.dismissals >= kRateAppMaxDismissals) {
    return 'dismissed ${state.dismissals} times';
  }
  if (state.asks.length >= kRateAppMaxAsks) {
    return 'asked ${state.asks.length} times';
  }
  if (state.asks.any((ask) => ask.build == context.build)) {
    return 'asked in this build';
  }
  final lastAsk = state.asks.isEmpty ? null : state.asks.last;
  if (lastAsk != null && context.now.difference(lastAsk.at) < kRateAppSecondAskAfter) {
    return 'asked ${context.now.difference(lastAsk.at).inDays} days ago';
  }
  if (state.problemBuild == context.build) {
    return 'a crash in this build';
  }
  if (state.opens < kRateAppMinOpens || state.days < kRateAppMinDays) {
    return 'not yet, opens ${state.opens} of $kRateAppMinOpens, days ${state.days} of $kRateAppMinDays';
  }
  if (state.successes < kRateAppMinSuccesses) {
    return 'not yet, viewings ${state.successes} of $kRateAppMinSuccesses';
  }
  final buildSince = state.build == context.build ? state.buildSince : null;
  if (buildSince == null || context.now.difference(buildSince) < kRateAppQuietAfterUpdate) {
    return 'this build is new';
  }
  final noticeAt = state.noticeAt;
  if (noticeAt != null && context.now.difference(noticeAt) < kRateAppQuietAfterNotice) {
    return 'the What\'s new notice showed';
  }
  if (context.versionWarning) {
    return 'the version warning shows';
  }
  return null;
}

/// Whether the viewing that stayed open [open] counts as one that ended well
bool rateAppViewingCounts(Duration open, {bool normal = true}) => normal && open >= kRateAppMinViewing;

// The first line of an exit report of AppHealth.kt (describeExit): "The app ended on 2026-11-10 22:40:01: crash, in
// the foreground, memory PSS 312 MB, RSS 401 MB [Immuch360 3030043 quest]"
final _exitLine = RegExp(r'^The app ended on [0-9-]+ [0-9:]+: (.*)$');

// The reasons of AppHealth.reasonName and signalName that are a defect the user saw: a Java crash, a native crash,
// not responding, and the signals 4 (SIGILL), 6 (SIGABRT), 7 (SIGBUS), 8 (SIGFPE) and 11 (SIGSEGV). A kill for low
// memory, by SIGKILL, or for excessive resource use is not: frequent on a Quest with large splats, and no crash seen.
final _crashReason = RegExp(
  r'^(crash|native crash|not responding \(ANR\)|a native abort \(signal 6|a native crash \(signal 11|'
  r'killed by signal [478])(?![0-9])',
);

// Where the app stood (AppHealth.importanceName): in the foreground, with the screen on or off, or visible
final _whereSaid = RegExp(
  r', (in the foreground|visible|in the background|running a foreground service|gone|importance -?[0-9]+)',
);
final _buildOfExit = RegExp(r'\[Immuch360 ([0-9]+) ');

/// Whether the exit report [text] of AppHealth.kt tells of a crash the rule counts: a crash, a native crash or an ANR
/// in the foreground or visible (or where Android did not say where the app stood)
bool rateAppExitIsCrash(String text) {
  final line = _exitLine.firstMatch(text.split('\n').first);
  if (line == null) {
    return false;
  }
  final rest = line.group(1)!;
  if (!_crashReason.hasMatch(rest)) {
    return false;
  }
  final where = _whereSaid.firstMatch(rest)?.group(1);
  return where == null || where == 'in the foreground' || where == 'visible';
}

/// The build that ran when the process of the exit report [text] ended, null when it was not recorded
int? rateAppExitBuild(String text) {
  final match = _buildOfExit.firstMatch(text.split('\n').first);
  return match == null ? null : int.tryParse(match.group(1)!);
}
