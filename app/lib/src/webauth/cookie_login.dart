/// Generic bridgev2 `cookies` login step: parse the step, collect field values
/// from a sign-in webview (cookies, local storage, request bodies/headers,
/// `extract_js` results), and decide when the login is complete.
///
/// Mirrors mautrix-manager's webview (github.com/mautrix/manager,
/// src/webview.ts) so any bridge that works there works here. Platform code
/// only shows the window and relays raw data; all matching lives here.
library;

import 'dart:convert';

class CookieSource {
  const CookieSource({required this.type, required this.name, this.cookieDomain, this.requestUrlRegex});

  factory CookieSource.fromJson(Map<String, dynamic> j) => CookieSource(
    type: j['type'] as String? ?? 'cookie',
    name: j['name'] as String? ?? '',
    cookieDomain: j['cookie_domain'] as String?,
    requestUrlRegex: j['request_url_regex'] as String?,
  );

  /// `cookie`, `local_storage`, `request_header`, `request_body` or `special`.
  final String type;
  final String name;
  final String? cookieDomain;
  final String? requestUrlRegex;
}

class CookieField {
  const CookieField({required this.id, required this.required, required this.sources, this.pattern});

  final String id;
  final bool required;
  final List<CookieSource> sources;
  final RegExp? pattern;

  bool accepts(String value) => value.isNotEmpty && (pattern == null || pattern!.hasMatch(value));
}

class CookieLoginSpec {
  CookieLoginSpec({
    required this.url,
    required this.fields,
    this.userAgent,
    this.extractJs,
    this.waitForUrlPattern,
    this.initialCookies = const [],
    this.hidden = false,
  });

  /// Parses `step['cookies']`. Older bridges sent fields as `{type, name}`
  /// without `sources`; those are treated as cookies on the sign-in host.
  factory CookieLoginSpec.fromStep(Map<String, dynamic> p) {
    final url = p['url'] as String? ?? '';
    final host = Uri.tryParse(url)?.host ?? '';
    RegExp? re(Object? s) {
      if (s is! String || s.isEmpty) return null;
      try {
        return RegExp(s);
      } on FormatException {
        return null;
      }
    }

    final fields = <CookieField>[];
    for (final f in ((p['fields'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
      final id = (f['id'] ?? f['name']) as String;
      var sources = ((f['sources'] as List?) ?? const []).cast<Map<String, dynamic>>().map(CookieSource.fromJson).toList();
      if (sources.isEmpty) {
        sources = [CookieSource(type: f['type'] as String? ?? 'cookie', name: f['name'] as String? ?? id, cookieDomain: host)];
      }
      fields.add(CookieField(id: id, required: f['required'] as bool? ?? true, sources: sources, pattern: re(f['pattern'])));
    }
    final ua = p['user_agent'] as String?;
    final js = p['extract_js'] as String?;
    return CookieLoginSpec(
      url: url,
      fields: fields,
      userAgent: ua == null || ua.isEmpty ? null : ua,
      extractJs: js == null || js.trim().isEmpty ? null : js,
      waitForUrlPattern: re(p['wait_for_url_pattern']),
      initialCookies: ((p['initial_cookies'] as List?) ?? const []).cast<Map<String, dynamic>>(),
      hidden: p['hidden'] as bool? ?? false,
    );
  }

  final String url;
  final List<CookieField> fields;
  final String? userAgent;
  final String? extractJs;
  final RegExp? waitForUrlPattern;
  final List<Map<String, dynamic>> initialCookies;
  final bool hidden;

  Iterable<CookieSource> _sources(String type) => fields.expand((f) => f.sources).where((s) => s.type == type);

  bool get usesLocalStorage => _sources('local_storage').isNotEmpty;
  bool get usesRequests => _sources('request_header').isNotEmpty || _sources('request_body').isNotEmpty;

  /// Domains whose cookies are needed (as given, e.g. `.google.com`).
  List<String> get cookieDomains => {
    for (final s in _sources('cookie'))
      if ((s.cookieDomain ?? '').isNotEmpty) s.cookieDomain!,
  }.toList();

  /// Host of the sign-in page.
  String get host => Uri.tryParse(url)?.host ?? '';

  /// Where the sign-in page sends you afterwards (`?continue=`), if given.
  String? get continueUrl => Uri.tryParse(url)?.queryParameters['continue'];

  /// Sites the user may click through to in the window (registrable domains
  /// of the sign-in page, its continue target and the cookie domains). Other
  /// link clicks are blocked; redirects and form posts are not (SSO).
  List<String> get allowedDomains {
    final out = <String>{};
    void add(String? h) {
      if (h != null && h.isNotEmpty) out.add(registrableDomain(h));
    }

    add(host);
    add(Uri.tryParse(continueUrl ?? '')?.host);
    for (final d in cookieDomains) {
      add(d);
    }
    return out.toList()..sort();
  }

  String get displayHost {
    final d = registrableDomain(host);
    return d.isEmpty ? url : d;
  }
}

const _secondLevel = {'co', 'com', 'net', 'org', 'gov', 'ac', 'edu', 'ne', 'or'};

/// `accounts.google.com` -> `google.com`, `www.bbc.co.uk` -> `bbc.co.uk`.
/// A small heuristic (no public-suffix list); good enough to keep the user
/// on the sign-in site.
String registrableDomain(String host) {
  final parts = host.toLowerCase().replaceFirst(RegExp(r'^\.+'), '').split('.').where((p) => p.isNotEmpty).toList();
  if (parts.length <= 2) return parts.join('.');
  final n = parts.length;
  final take = parts[n - 1].length == 2 && _secondLevel.contains(parts[n - 2]) ? 3 : 2;
  return parts.sublist(n - take).join('.');
}

/// Whether a cookie set on `cookieDomain` is the one a field asks for on
/// `wanted` (same domain or a subdomain of it, leading dots ignored).
bool cookieDomainMatches(String cookieDomain, String wanted) {
  final c = cookieDomain.toLowerCase().replaceFirst(RegExp(r'^\.+'), '');
  final w = wanted.toLowerCase().replaceFirst(RegExp(r'^\.+'), '');
  return c == w || c.endsWith('.$w');
}

String _decode(String v) {
  try {
    return Uri.decodeComponent(v);
  } catch (_) {
    return v;
  }
}

/// Accumulates field values from everything the webview reports.
class CookieCollector {
  CookieCollector(this.spec);

  final CookieLoginSpec spec;
  final Map<String, String> _values = {};

  Map<String, String> get output => Map.unmodifiable(_values);

  void _set(CookieField f, Object? raw) {
    if (raw == null) return;
    final v = switch (raw) {
      String s => s,
      num n => '$n',
      bool b => b ? 'true' : 'false',
      _ => null,
    };
    if (v != null && f.accepts(v)) _values[f.id] = v;
  }

  /// `cookies`: `{name, value, domain}` maps from the webview's cookie store.
  void addCookies(Iterable<Map<String, dynamic>> cookies) {
    final list = cookies.toList();
    for (final f in spec.fields) {
      for (final s in f.sources.where((s) => s.type == 'cookie')) {
        final wanted = s.cookieDomain ?? spec.host;
        final matches = list.where((c) => c['name'] == s.name && cookieDomainMatches('${c['domain'] ?? wanted}', wanted)).toList();
        if (matches.isEmpty) continue;
        // Prefer the cookie set exactly on the requested domain.
        matches.sort((a, b) {
          int score(Map<String, dynamic> c) => '${c['domain']}'.replaceFirst(RegExp(r'^\.+'), '') == wanted.replaceFirst(RegExp(r'^\.+'), '') ? 0 : 1;
          return score(a) - score(b);
        });
        _set(f, _decode('${matches.first['value'] ?? ''}'));
      }
    }
  }

  /// `values`: field id -> localStorage value (see [CookieLoginScripts.readLocalStorage]).
  void addLocalStorage(Map<String, dynamic> values) {
    for (final f in spec.fields) {
      if (f.sources.any((s) => s.type == 'local_storage')) _set(f, values[f.id]);
    }
  }

  /// Result of `extract_js`: an object keyed by field id.
  void addExtractResult(Object? result) {
    if (result is! Map) return;
    for (final f in spec.fields) {
      _set(f, result[f.id]);
    }
  }

  /// A request the page made (captured by [CookieLoginScripts.requestHook]).
  void addRequest(String url, Map<String, dynamic> headers, Object? body) {
    final lowerHeaders = {for (final e in headers.entries) e.key.toLowerCase(): e.value};
    for (final f in spec.fields) {
      for (final s in f.sources) {
        if (s.type != 'request_header' && s.type != 'request_body') continue;
        final re = s.requestUrlRegex;
        if (re == null || !RegExp(re).hasMatch(url)) continue;
        if (s.type == 'request_header') {
          _set(f, lowerHeaders[s.name.toLowerCase()]);
        } else if (body is Map) {
          _set(f, body[s.name]);
        }
      }
    }
  }

  /// One `{kind: ...}` message posted by the injected scripts.
  void addMessage(Map<String, dynamic> m) {
    switch (m['kind']) {
      case 'local_storage':
        addLocalStorage((m['values'] as Map?)?.cast<String, dynamic>() ?? const {});
      case 'extract':
        addExtractResult(m['result']);
      case 'request':
        addRequest('${m['url']}', (m['headers'] as Map?)?.cast<String, dynamic>() ?? const {}, m['body']);
    }
  }

  List<String> get missing => [
    for (final f in spec.fields)
      if (f.required && !_values.containsKey(f.id)) f.id,
  ];

  bool get hasAllRequired => missing.isEmpty;

  /// All required values are in and, if the step asks for it, the window
  /// has reached `wait_for_url_pattern`.
  bool isComplete(String? currentUrl) {
    if (!hasAllRequired) return false;
    final w = spec.waitForUrlPattern;
    return w == null || (currentUrl != null && w.hasMatch(currentUrl));
  }
}

/// JavaScript run inside the sign-in page. Every script posts JSON strings
/// through `window.webkit.messageHandlers.crosschat` (WKWebView, WebKitGTK)
/// or `window.CrosschatAndroid` (Android WebView).
class CookieLoginScripts {
  CookieLoginScripts(this.spec);

  final CookieLoginSpec spec;

  static const _post = '''
const __ccPost = (m) => {
  const s = JSON.stringify(m);
  try {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.crosschat) {
      window.webkit.messageHandlers.crosschat.postMessage(s);
    } else if (window.CrosschatAndroid) {
      window.CrosschatAndroid.postMessage(s);
    }
  } catch (e) {}
};''';

  static String _wrap(String body) => '(function(){\n$_post\n$body\n})();\ntrue;';

  /// Injected at document start (if the step has request sources): reports
  /// fetch/XHR requests whose URL matches a `request_url_regex`.
  String? get requestHook {
    final regexes = {
      for (final f in spec.fields)
        for (final s in f.sources)
          if ((s.type == 'request_header' || s.type == 'request_body') && s.requestUrlRegex != null) s.requestUrlRegex!,
    }.toList();
    if (regexes.isEmpty) return null;
    return _wrap('''
if (window.__ccHooked) return;
window.__ccHooked = true;
const res = ${jsonEncode(regexes)}.map((r) => new RegExp(r));
const toObj = (b) => {
  try {
    if (!b) return null;
    if (typeof b === "string") {
      try { return JSON.parse(b); } catch (e) { return Object.fromEntries(new URLSearchParams(b)); }
    }
    if (b instanceof URLSearchParams) return Object.fromEntries(b);
    if (b instanceof FormData) { const o = {}; b.forEach((v, k) => { if (typeof v === "string") o[k] = v; }); return o; }
  } catch (e) {}
  return null;
};
const report = (url, headers, body) => {
  try {
    const u = new URL(url, location.href).href;
    if (!res.some((r) => r.test(u))) return;
    __ccPost({ kind: "request", url: u, headers: headers || {}, body: toObj(body) });
  } catch (e) {}
};
const origFetch = window.fetch;
window.fetch = function (input, init) {
  try {
    const url = typeof input === "string" ? input : (input && input.url);
    const h = {};
    if (init && init.headers) new Headers(init.headers).forEach((v, k) => { h[k] = v; });
    report(url, h, init && init.body);
  } catch (e) {}
  return origFetch.apply(this, arguments);
};
const X = XMLHttpRequest.prototype, open = X.open, send = X.send, setH = X.setRequestHeader;
X.open = function (m, u) { this.__ccUrl = u; this.__ccH = {}; return open.apply(this, arguments); };
X.setRequestHeader = function (k, v) { try { this.__ccH[k.toLowerCase()] = v; } catch (e) {} return setH.apply(this, arguments); };
X.send = function (b) { report(this.__ccUrl, this.__ccH, b); return send.apply(this, arguments); };''');
  }

  /// Reads the local_storage sources (run periodically).
  String? get readLocalStorage {
    final keys = {
      for (final f in spec.fields)
        for (final s in f.sources)
          if (s.type == 'local_storage') f.id: s.name,
    };
    if (keys.isEmpty) return null;
    return _wrap('''
const keys = ${jsonEncode(keys)};
const values = {};
for (const [id, k] of Object.entries(keys)) { try { values[id] = window.localStorage.getItem(k); } catch (e) {} }
__ccPost({ kind: "local_storage", values });''');
  }

  /// Runs the step's `extract_js` (a promise) after each page load.
  String? get extract {
    final js = spec.extractJs;
    if (js == null) return null;
    return _wrap('''
if (window.__ccExtracting) return;
window.__ccExtracting = true;
Promise.resolve((
$js
)).then(
  (result) => __ccPost({ kind: "extract", result }),
  (e) => __ccPost({ kind: "extract_error", error: String(e) }),
);''');
  }
}
