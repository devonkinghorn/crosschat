/// The embedded sign-in window for bridgev2 `cookies` login steps.
///
/// A native window (macOS: WKWebView, Linux: WebKitGTK loaded at runtime,
/// Android: WebView dialog) with a fresh, throwaway cookie store, like a
/// private browser window. Dart drives it over the `app.crosschat/webauth`
/// channel and does all field matching ([CookieCollector]).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'cookie_login.dart';

class WebAuthCancelled implements Exception {
  const WebAuthCancelled();
  @override
  String toString() => 'The sign-in window was closed before sign-in finished.';
}

/// Opens sign-in windows. Replaceable in tests.
abstract class WebAuthLauncher {
  /// Whether this device can show the embedded sign-in window.
  Future<bool> isAvailable();

  /// Shows the window until every required field is captured (then closes
  /// it and returns the values) or the user closes it ([WebAuthCancelled]).
  Future<Map<String, String>> run(CookieLoginSpec spec, {String? title});

  /// Closes an open window (the pending [run] fails with [WebAuthCancelled]).
  Future<void> cancel();
}

WebAuthLauncher webAuthLauncher = PlatformWebAuth();

class PlatformWebAuth implements WebAuthLauncher {
  PlatformWebAuth({this.pollInterval = const Duration(milliseconds: 1500)});

  static const channel = MethodChannel('app.crosschat/webauth');
  final Duration pollInterval;
  bool? _available;
  _Session? _session;

  @override
  Future<bool> isAvailable() async {
    if (_available != null) return _available!;
    if (kIsWeb) return _available = false;
    try {
      _available = await channel.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      _available = false;
    } on PlatformException {
      _available = false;
    }
    return _available!;
  }

  @override
  Future<void> cancel() async => _session?.finish(error: const WebAuthCancelled());

  @override
  Future<Map<String, String>> run(CookieLoginSpec spec, {String? title}) async {
    await _session?.finish(error: const WebAuthCancelled());
    final s = _Session(spec, pollInterval);
    _session = s;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'event' && identical(_session, s)) {
        s.onEvent((call.arguments as Map).cast<String, dynamic>());
      }
      return null;
    });
    try {
      await s.open(title ?? 'Sign in to ${spec.displayHost}');
      return await s.done.future;
    } finally {
      if (identical(_session, s)) _session = null;
    }
  }
}

class _Session {
  _Session(this.spec, this.pollInterval) : collector = CookieCollector(spec), scripts = CookieLoginScripts(spec);

  final CookieLoginSpec spec;
  final Duration pollInterval;
  final CookieCollector collector;
  final CookieLoginScripts scripts;
  final done = Completer<Map<String, String>>();
  Timer? _timer;
  String? _url;
  bool _closing = false;
  bool _polling = false;

  MethodChannel get _ch => PlatformWebAuth.channel;

  Future<void> open(String title) async {
    await _ch.invokeMethod('open', {
      'url': spec.url,
      'userAgent': spec.userAgent,
      'allowedDomains': spec.allowedDomains,
      'cookieDomains': spec.cookieDomains,
      'documentStartScript': scripts.requestHook,
      'initialCookies': spec.initialCookies,
      'title': title,
      'hidden': spec.hidden,
    });
    _timer = Timer.periodic(pollInterval, (_) => _poll());
  }

  void onEvent(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'url':
        _url = e['url'] as String? ?? _url;
        _poll();
      case 'loaded':
        _url = e['url'] as String? ?? _url;
        final x = scripts.extract;
        if (x != null) _eval(x);
        _poll();
      case 'message':
        try {
          final m = jsonDecode(e['data'] as String);
          if (m is Map) collector.addMessage(m.cast<String, dynamic>());
        } catch (_) {}
        _check();
      case 'closed':
        // The step allows submitting when the user closes the window after
        // everything was captured, even if wait_for_url_pattern wasn't reached.
        finish(error: collector.hasAllRequired ? null : const WebAuthCancelled(), alreadyClosed: true);
      case 'error':
        finish(error: Exception('Sign-in window: ${e['message']}'));
    }
  }

  void _eval(String script) => _ch.invokeMethod('evaluate', {'script': script}).catchError((_) => null);

  Future<void> _poll() async {
    if (_polling || done.isCompleted) return;
    _polling = true;
    try {
      final ls = scripts.readLocalStorage;
      if (ls != null) _eval(ls);
      if (spec.cookieDomains.isNotEmpty) {
        final cookies = await _ch.invokeListMethod<Map>('getCookies', {'domains': spec.cookieDomains});
        collector.addCookies((cookies ?? const []).map((c) => c.cast<String, dynamic>()));
      }
    } catch (_) {
      // Window gone or transient; the next tick or the close event decides.
    } finally {
      _polling = false;
    }
    _check();
  }

  void _check() {
    if (!done.isCompleted && collector.isComplete(_url)) finish();
  }

  Future<void> finish({Object? error, bool alreadyClosed = false}) async {
    if (_closing) return;
    _closing = true;
    _timer?.cancel();
    if (!alreadyClosed) {
      try {
        await _ch.invokeMethod('close');
      } catch (_) {}
    }
    if (done.isCompleted) return;
    if (error != null) {
      done.completeError(error);
    } else {
      done.complete(collector.output);
    }
  }
}
