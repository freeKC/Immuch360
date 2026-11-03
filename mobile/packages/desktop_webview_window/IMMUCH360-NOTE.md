Copy of `desktop_webview_window` 0.3.0 (Apache 2.0, MixinNetwork, https://pub.dev/packages/desktop_webview_window),
already in the app through `flutter_web_auth_2` 5.0.3, used by Immuch360 Desktop through `dependency_overrides` in
`mobile/pubspec.yaml` for the window of the splat viewer (`lib/desktop/splat/desktop_splat_viewer_host.dart`). Its
plugin platforms are linux, macos and windows only, as upstream. The `LICENSE` is upstream's. Copied without
`example/` and without `resolution: workspace` (upstream's repository is a pub workspace).

Patches, to apply again when a newer version is copied here (each marked "Immuch360" in the code):

1. P1, the three systems: no title bar engine and no title bar view when `titleBarHeight` is 0
   (`windows/webview_window.cc` `CreateAndShow`, `linux/webview_window.cc` constructor,
   `macos/.../WebViewLayoutController.swift` `loadView`). Upstream always starts a second Flutter engine for the
   title bar of each window, with the entry point arguments `web_view_title_bar <id>`; the app's `main` would run in
   it. `lib/main_desktop.dart` also hands those arguments to an empty widget, should a patch ever be lost.
2. P2, Windows: the keyboard focus to the page (`WebView::Focus`, `MoveFocus(PROGRAMMATIC)`) once the controller
   exists, on `WM_ACTIVATE` (but `WA_INACTIVE`) and on `WM_SETFOCUS`, so that the keys walk at once and again after
   Alt+Tab. macOS: the web view made first responder once shown.
3. P3, Windows: the developer tools off outside debug builds (`put_AreDevToolsEnabled`), and the browser's own keys
   off (`ICoreWebView2Settings3::put_AreBrowserAcceleratorKeysEnabled(false)`: F5, Ctrl+R, Ctrl+P, Ctrl+F, F12,
   Ctrl+Shift+I); a black default background (`ICoreWebView2Controller2`) rather than white while the page loads.
   Linux: WebGL on and the developer extras off in the WebKitGTK settings.
4. P4, Windows: `additionalBrowserArguments` in `CreateConfiguration` (Dart) and the `create` call, set as
   `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS` before the environment is made (`--force_high_performance_gpu`). The app
   gives an absolute user data folder (`userDataFolderWindows`, already absolute capable upstream), one per set of
   arguments, inside its own application support folder.
5. P5, the three systems: a process of the page that dies is told to Dart (`onProcessFailed` with a kind;
   `Webview.setOnProcessFailedCallback`): `ProcessFailed` of WebView2, `web-process-terminated` of WebKitGTK,
   `webViewWebContentProcessDidTerminate` of WKWebView.
6. Windows: a close asked by Dart (`close`) destroys the window as the user's close does, so that Dart is told
   (`onWindowClose`, `Webview.onClose`); upstream took it off its list without telling Dart.
7. Linux: `openMaximized` honoured (`gtk_window_maximize`).
8. Windows: the window of the viewer takes the app's icon (`IDI_APP_ICON`, 101) rather than the system's.
9. Dart: `launch` and `close` of a window that is gone end quietly (`WebviewImpl._invokeOnWindow`): a window closed by
   the user while it opened answered "can not find webview window for id" to a method that returns nothing, which
   reached the zone's catch-all (review of 2 November 2026); any other error still reaches the zone. Test:
   `mobile/test/desktop/splat/desktop_webview_window_gone_test.dart`.
10. Windows: `windows/WebView2-SDK-LICENSE.txt`, the licence of Microsoft's WebView2 SDK 1.0.992.28 (the `LICENSE.txt`
    of its NuGet package), which `WebView2.h`, `WebView2EnvironmentOptions.h` and `libs/x64/WebView2Loader.dll` (the
    same bytes as in that package) come from and whose headers point to; not in upstream's copy. wil keeps its own
    `wil/LICENSE` (MIT). Both are on the app's licence page on Windows (`lib/desktop/splat/splat_window_licenses.dart`).
11. Windows: a window closed while WebView2 still makes its environment or its controller (the user's close, a
    WM_CLOSE, the app's end, a few hundred milliseconds after the window showed) ended the app: the destruction of
    the host window made WebView2 end the creation at once, and its callback called `on_web_view_created_callback_`,
    a member already destroyed (`std::bad_function_call`, then `abort`, BEX64 c0000409 in the review replay of
    3 November 2026; the dump's stack runs from `WM_DESTROY` through `Controller::Close` into the callback). Each
    callback of the creation now holds `WebView::alive_`, cleared first by the destructor, and does nothing once it is
    false (a controller made for a WebView that is gone is closed); the plugin keeps the answer to `create` by window
    id (`pending_creates_`) and answers it at the window's close with the error "the window was closed while it
    opened" rather than never, which the app takes as the user's close (`splatWindowClosedWhileOpening`). Test of the
    Dart side: `mobile/test/desktop/splat/desktop_splat_viewer_host_test.dart`.
