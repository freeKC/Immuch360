import 'package:pigeon/pigeon.dart';

// Android only: the foreground service that keeps "Download" of a Plex film running while the screen is off (request
// 5 of the Plex films study). The copy itself runs in Dart, through the pinned client of the server with the token in
// its header: the service only keeps the process awake and shows the notification, with Pause and Cancel. iPhone and
// iPad copy while the app is open (decision 4 a), the computers need no service: neither calls this API.
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/film_download_api.g.dart',
    kotlinOut: 'android/app/src/main/kotlin/app/alextran/immich/filmdownload/FilmDownload.g.kt',
    kotlinOptions: KotlinOptions(package: 'app.alextran.immich.filmdownload'),
    dartOptions: DartOptions(),
    dartPackageName: 'immich_mobile',
  ),
)
/// What the notification of a copy shows, in the language of the app. [progress] is in thousandths, -1 while the size
/// is not known.
class FilmDownloadNotice {
  const FilmDownloadNotice({
    required this.channelName,
    required this.title,
    required this.text,
    required this.progress,
    required this.pauseLabel,
    required this.cancelLabel,
  });

  final String channelName;
  final String title;
  final String text;
  final int progress;
  final String pauseLabel;
  final String cancelLabel;
}

@HostApi()
abstract class FilmDownloadApi {
  /// Starts the foreground service with its notification, or updates it when it runs
  void startKeepAlive(FilmDownloadNotice notice);

  /// The notification of the running service; nothing when it does not run
  void updateKeepAlive(FilmDownloadNotice notice);

  void stopKeepAlive();

  /// The bytes free on the volume of [path], null when the system does not tell
  int? freeBytes(String path);
}

/// The actions of the notification, towards the engine of the app UI
@FlutterApi()
abstract class FilmDownloadEvents {
  void pauseRequested();

  void cancelRequested();
}
