// The splat viewer of the Android phones and tablets (lot SV6): SplatViewerActivity opened and closed through pigeon,
// how it closed told back.
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/splat_viewer_host.dart';
import 'package:immich_mobile/infrastructure/splat/pigeon_splat_viewer_host.dart';
import 'package:immich_mobile/platform/splat_viewer_api.g.dart';

class _Api extends SplatViewerApi {
  _Api({this.fails = false, this.major = 133});

  final bool fails;
  final int major;
  final opened = <(String, String)>[];
  int closes = 0;

  @override
  Future<void> open(String pageUrl, String title) async {
    if (fails) {
      throw Exception('no activity');
    }
    opened.add((pageUrl, title));
  }

  @override
  Future<void> close() async => closes++;

  @override
  Future<int> webViewMajorVersion() async => fails ? throw Exception('no WebView') : major;
}

void main() {
  final page = Uri.parse('http://127.0.0.1:41000/token/0123456789abcdef0123456789abcdef/index.html');

  test('opens the activity on the page with the name of the file, and closes it', () async {
    final api = _Api();
    final host = PigeonSplatViewerHost(api: api, listen: false);
    await host.open(page, title: 'cactus.spz');
    await host.close();

    expect(api.opened, [(page.toString(), 'cactus.spz')]);
    expect(api.closes, 1);
  });

  test('how the activity closed comes out of closed', () async {
    final host = PigeonSplatViewerHost(api: _Api(), listen: false);
    final ends = <SplatHostClosed>[];
    final listening = host.closed.listen(ends.add);
    for (final reason in ['user', 'rendererGone', 'noWebView', 'error', 'something new']) {
      host.onActivityClosed(reason);
    }
    await Future<void>.delayed(Duration.zero);
    await listening.cancel();

    expect(ends, [
      SplatHostClosed.user,
      SplatHostClosed.rendererGone,
      SplatHostClosed.noWebView,
      SplatHostClosed.error,
      SplatHostClosed.user,
    ]);
  });

  test('an activity that does not open says error; a WebView that cannot be asked counts as none', () async {
    final host = PigeonSplatViewerHost(api: _Api(fails: true), listen: false);
    final closed = host.closed.first;
    await host.open(page, title: 'a.spz');

    expect(await closed, SplatHostClosed.error);
    expect(await host.webViewMajorVersion(), 0);
    expect(await PigeonSplatViewerHost(api: _Api(major: 91), listen: false).webViewMajorVersion(), 91);
  });
}
