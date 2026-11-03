import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_webview_window/src/cookie.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'webview.dart';

class WebviewImpl extends Webview {
  final int viewId;

  final MethodChannel channel;

  final Map<String, JavaScriptMessageHandler> _javaScriptMessageHandlers = {};

  bool _closed = false;

  PromptHandler? _promptHandler;

  final _closeCompleter = Completer<void>();

  OnHistoryChangedCallback? _onHistoryChanged;

  final ValueNotifier<bool> _isNavigating = ValueNotifier<bool>(false);

  OnUrlRequestCallback? _onUrlRequestCallback;

  final Set<OnWebMessageReceivedCallback> _onWebMessageReceivedCallbacks = {};

  OnProcessFailedCallback? _onProcessFailed;

  WebviewImpl(this.viewId, this.channel);

  @override
  Future<void> get onClose => _closeCompleter.future;

  void onClosed() {
    _closed = true;
    if (!_closeCompleter.isCompleted) {
      _closeCompleter.complete();
    }
  }

  void notifyProcessFailed(String kind) {
    _onProcessFailed?.call(kind);
  }

  @override
  void setOnProcessFailedCallback(OnProcessFailedCallback? callback) {
    _onProcessFailed = callback;
  }

  void onJavaScriptMessage(String name, dynamic body) {
    assert(!_closed);
    final handler = _javaScriptMessageHandlers[name];
    assert(handler != null, "handler $name is not registed.");
    handler?.call(name, body);
  }

  String onRunJavaScriptTextInputPanelWithPrompt(
      String prompt, String defaultText) {
    assert(!_closed);
    return _promptHandler?.call(prompt, defaultText) ?? defaultText;
  }

  void onHistoryChanged(bool canGoBack, bool canGoForward) {
    assert(!_closed);
    _onHistoryChanged?.call(canGoBack, canGoForward);
  }

  void onNavigationStarted() {
    _isNavigating.value = true;
  }

  bool notifyUrlChanged(String url) {
    if (_onUrlRequestCallback != null) {
      return _onUrlRequestCallback!(url);
    } else {
      return true;
    }
  }

  void notifyWebMessageReceived(String message) {
    for (final callback in _onWebMessageReceivedCallbacks) {
      callback(message);
    }
  }

  void onNavigationCompleted() {
    _isNavigating.value = false;
  }

  @override
  ValueListenable<bool> get isNavigating => _isNavigating;

  @override
  void registerJavaScriptMessageHandler(
      String name, JavaScriptMessageHandler handler) {
    if (!Platform.isMacOS && !Platform.isLinux) {
      return;
    }
    assert(!_closed);
    if (_closed) {
      return;
    }
    assert(name.isNotEmpty);
    assert(!_javaScriptMessageHandlers.containsKey(name));
    _javaScriptMessageHandlers[name] = handler;
    channel.invokeMethod("registerJavaScriptInterface", {
      "viewId": viewId,
      "name": name,
    });
  }

  @override
  void unregisterJavaScriptMessageHandler(String name) {
    if (!Platform.isMacOS && !Platform.isLinux) {
      return;
    }
    if (_closed) {
      return;
    }
    channel.invokeMethod("unregisterJavaScriptInterface", {
      "viewId": viewId,
      "name": name,
    });
  }

  @override
  void setPromptHandler(PromptHandler? handler) {
    if (!Platform.isMacOS) {
      return;
    }
    _promptHandler = handler;
  }

  /// Immuch360: whether [error] is the plugin's answer for a window it no longer has, in the words of each system:
  /// "can not find webview window for id" on Windows, "can not found webview for viewId" on Linux, "can not find
  /// webview for id: N" on macOS (second review of 3 November 2026)
  static bool isWindowGone(PlatformException error) =>
      RegExp(r'^can not f(?:ind|ound) webview\b').hasMatch(error.message ?? '');

  /// Immuch360: [method] of a window that may be gone. A window the user closed while it opened is gone before the
  /// plugin answers its launch, and the answer for a window it no longer has (isWindowGone) of a method that returns
  /// nothing would reach no caller, only the zone's catch-all: such an answer, or any answer once the window closed,
  /// ends quietly; any other error still reaches the zone.
  Future<void> _invokeOnWindow(String method, Map<String, dynamic> arguments) async {
    try {
      await channel.invokeMethod(method, arguments);
    } on PlatformException catch (error) {
      if (_closed || isWindowGone(error)) {
        debugPrint('desktop_webview_window: $method of the window $viewId, which is gone: ${error.message}');
        return;
      }
      rethrow;
    }
  }

  @override
  void launch(String url, {bool triggerOnUrlRequestEvent = true}) async {
    await _invokeOnWindow("launch", {
      "url": url,
      "viewId": viewId,
      "triggerOnUrlRequestEvent": triggerOnUrlRequestEvent,
    });
  }

  @override
  void setBrightness(Brightness? brightness) {
    /// -1 : system default
    /// 0 : dark
    /// 1 : light
    if (!Platform.isMacOS) {
      return;
    }
    channel.invokeMethod("setBrightness", {
      "viewId": viewId,
      "brightness": brightness?.index ?? -1,
    });
  }

  @override
  void addScriptToExecuteOnDocumentCreated(String javaScript) {
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return;
    }
    assert(javaScript.trim().isNotEmpty);
    channel.invokeMethod("addScriptToExecuteOnDocumentCreated", {
      "viewId": viewId,
      "javaScript": javaScript,
    });
  }

  @override
  Future<void> setApplicationNameForUserAgent(String applicationName) async {
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return;
    }
    await channel.invokeMethod("setApplicationNameForUserAgent", {
      "viewId": viewId,
      "applicationName": applicationName,
    });
  }

  @override
  Future<void> forward() {
    return channel.invokeMethod("forward", {"viewId": viewId});
  }

  @override
  Future<void> setWebviewWindowVisibility(bool visible) {
    return channel.invokeMethod("setWebviewWindowVisibility", {
      "viewId": viewId,
      "visible": visible,
    });
  }

  @override
  Future<void> moveWebviewWindow(int left, int top, int width, int height) {
    return channel.invokeMethod("moveWebviewWindow", {
      "viewId": viewId,
      "left": left,
      "top": top,
      "width": width,
      "height": height,
    });
  }

  @override
  Future<void> bringToForeground({bool maximized = false}) {
    return channel.invokeMethod("bringToForeground", {
      "viewId": viewId,
      "maximized": maximized,
    });
  }

  @override
  Future<Map<dynamic, dynamic>?> getPositionalParameters() async {
    return await channel.invokeMethod("getPositionalParameters", {
      "viewId": viewId,
    });
  }

  @override
  Future<void> back() {
    return channel.invokeMethod("back", {"viewId": viewId});
  }

  @override
  Future<void> reload() {
    return channel.invokeMethod("reload", {"viewId": viewId});
  }

  @override
  Future<void> stop() {
    return channel.invokeMethod("stop", {"viewId": viewId});
  }

  @override
  Future<void> openDevToolsWindow() {
    return channel.invokeMethod('openDevToolsWindow', {"viewId": viewId});
  }

  @override
  void setOnHistoryChangedCallback(OnHistoryChangedCallback? callback) {
    _onHistoryChanged = callback;
  }

  @override
  void setOnUrlRequestCallback(OnUrlRequestCallback? callback) {
    _onUrlRequestCallback = callback;
  }

  @override
  void addOnWebMessageReceivedCallback(OnWebMessageReceivedCallback callback) {
    _onWebMessageReceivedCallbacks.add(callback);
  }

  @override
  void removeOnWebMessageReceivedCallback(
    OnWebMessageReceivedCallback callback,
  ) {
    _onWebMessageReceivedCallbacks.remove(callback);
  }

  @override
  void removeAllWebMessageReceivedCallback() {
    _onWebMessageReceivedCallbacks.clear();
  }

  @override
  void close() {
    if (_closed) {
      return;
    }
    // Immuch360: a close of a window that is already gone ends quietly (see _invokeOnWindow)
    unawaited(_invokeOnWindow("close", {"viewId": viewId}));
  }

  @override
  Future<String?> evaluateJavaScript(String javaScript) async {
    final dynamic result = await channel.invokeMethod("evaluateJavaScript", {
      "viewId": viewId,
      "javaScriptString": javaScript,
    });
    if (result == null || result is String) {
      return result;
    }
    return json.encode(result);
  }

  @override
  Future<void> postWebMessageAsString(String webMessage) async {
    return channel.invokeMethod("postWebMessageAsString", {
      "viewId": viewId,
      "webMessage": webMessage,
    });
  }

  @override
  Future<void> postWebMessageAsJson(String webMessage) async {
    return channel.invokeMethod("postWebMessageAsJson", {
      "viewId": viewId,
      "webMessage": webMessage,
    });
  }

  @override
  Future<List<WebviewCookie>> getAllCookies() async {
    final result = await channel.invokeListMethod<Map>("getAllCookies", {
      "viewId": viewId,
    });

    return result
            ?.map((e) => WebviewCookie.fromJson(e.cast<String, dynamic>()))
            .toList() ??
        [];
  }
}
