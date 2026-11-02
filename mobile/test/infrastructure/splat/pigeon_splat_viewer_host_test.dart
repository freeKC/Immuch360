// The splat viewer of the Android phones and tablets (lot SV6): SplatViewerActivity opened and closed through pigeon,
// how it closed told back.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/splat_viewer_host.dart';
import 'package:immich_mobile/infrastructure/splat/pigeon_splat_viewer_host.dart';
import 'package:immich_mobile/platform/splat_viewer_api.g.dart';

class _Api extends SplatViewerApi {
  _Api({this.fails = false, this.major = 133});

  final bool fails;
  final int major;
  final opened = <(String, String, int)>[];
  int closes = 0;

  @override
  Future<void> open(String pageUrl, String title, int viewing) async {
    if (fails) {
      throw Exception('no activity');
    }
    opened.add((pageUrl, title, viewing));
  }

  @override
  Future<void> close() async => closes++;

  @override
  Future<int> webViewMajorVersion() async => fails ? throw Exception('no WebView') : major;
}

void main() {
  final page = Uri.parse('http://127.0.0.1:41000/token/0123456789abcdef0123456789abcdef/index.html');

  test('opens the activity on the page with the name of the file and the number of the viewing', () async {
    final api = _Api();
    final host = PigeonSplatViewerHost(api: api, listen: false);
    final ended = host.open(page, title: 'cactus.spz');
    await pumpEventQueue();
    await host.close();
    host.onActivityClosed('user', 1);

    expect(await ended, SplatHostClosed.user);
    expect(api.opened, [(page.toString(), 'cactus.spz', 1)]);
    expect(api.closes, 1);
  });

  test('how the activity closed ends its viewing', () async {
    final host = PigeonSplatViewerHost(api: _Api(), listen: false);
    final ends = <SplatHostClosed>[];
    var viewing = 0;
    for (final reason in ['user', 'rendererGone', 'noWebView', 'error', 'something new']) {
      final ended = host.open(page, title: 'a.spz');
      await pumpEventQueue();
      host.onActivityClosed(reason, ++viewing);
      ends.add(await ended);
    }

    expect(ends, [
      SplatHostClosed.user,
      SplatHostClosed.rendererGone,
      SplatHostClosed.noWebView,
      SplatHostClosed.error,
      SplatHostClosed.user,
    ]);
  });

  test('a new viewing ends the one still open; a late closing of an earlier viewing never ends the new one', () async {
    final host = PigeonSplatViewerHost(api: _Api(), listen: false);
    final first = host.open(page, title: 'a.spz');
    await pumpEventQueue();
    var secondEnded = false;
    final second = host.open(page, title: 'b.spz');
    unawaited(second.then((_) => secondEnded = true));
    await pumpEventQueue();
    expect(await first, SplatHostClosed.user);

    // The first activity's onDestroy, told after the second opened
    host.onActivityClosed('rendererGone', 1);
    await pumpEventQueue();
    expect(secondEnded, isFalse);

    host.onActivityClosed('user', 2);
    expect(await second, SplatHostClosed.user);
  });

  test('an activity that does not open says error; a WebView that cannot be asked counts as none', () async {
    final host = PigeonSplatViewerHost(api: _Api(fails: true), listen: false);
    expect(await host.open(page, title: 'a.spz'), SplatHostClosed.error);
    expect(await host.webViewMajorVersion(), 0);
    expect(await PigeonSplatViewerHost(api: _Api(major: 91), listen: false).webViewMajorVersion(), 91);
  });
}
