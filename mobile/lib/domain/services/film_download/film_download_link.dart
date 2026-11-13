// The link of the notifications of the film downloads (release 47, FreeKC's request of 12 November 2026): a tap opens
// Downloaded films; Retry and Resume open it too and set the film going again. The Android notifications carry it to
// MainActivity as the data of their intent (FilmDownloadNoticeRules.safeLink accepts no other link), auto_route's deep
// links bring it to main.dart; the notification of iPhone and iPad carries it as its payload.

/// Downloaded films
const filmDownloadsLink = 'immuch360://downloads';

/// What a button of a notification asks for the film it names
enum FilmDownloadLinkAction { resume, retry }

/// The link of [action] for the film [filmId]
String filmDownloadActionLink(String filmId, FilmDownloadLinkAction action) =>
    '$filmDownloadsLink?film=$filmId&do=${action.name}';

/// A link of the notifications: the page, and the film to set going again when a button asked it
typedef FilmDownloadLink = ({String? filmId, FilmDownloadLinkAction? action});

final _filmId = RegExp(r'^[0-9a-f]{1,64}$');

/// [uri] read as a link of the notifications, null when it is not one. A film or an action the app does not make only
/// opens the page.
FilmDownloadLink? parseFilmDownloadLink(Uri uri) {
  if (uri.scheme != 'immuch360' || uri.host != 'downloads') {
    return null;
  }
  final filmId = uri.queryParameters['film'];
  final action = FilmDownloadLinkAction.values.asNameMap()[uri.queryParameters['do']];
  if (filmId == null || action == null || !_filmId.hasMatch(filmId)) {
    return (filmId: null, action: null);
  }
  return (filmId: filmId, action: action);
}
