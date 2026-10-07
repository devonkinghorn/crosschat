// Opens the real embedded sign-in window (macOS WKWebView / Linux WebKitGTK)
// on the sign-in pages the bridges use and checks the providers accept it:
// the page loads and isn't rejected as an insecure browser. No credentials
// are entered.
//
//   cd app && flutter test integration_test/web_auth_test.dart -d macos \
//     --dart-define=CROSSCHAT_HOME=/tmp/cc-webauth
// Snapshots and a JSON report land in $CROSSCHAT_HOME/screenshots.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crosschat/src/webauth/cookie_login.dart';
import 'package:crosschat/src/webauth/web_auth.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _home = String.fromEnvironment('CROSSCHAT_HOME', defaultValue: '/tmp/cc-webauth');
const _ch = PlatformWebAuth.channel;

const _gmessages = {
  'url': 'https://accounts.google.com/AccountChooser?continue=https://messages.google.com/web/config',
  'fields': [
    {
      'id': 'SID',
      'required': true,
      'sources': [
        {'type': 'cookie', 'name': 'SID', 'cookie_domain': '.google.com'},
      ],
    },
    {
      'id': 'OSID',
      'required': true,
      'sources': [
        {'type': 'cookie', 'name': 'OSID', 'cookie_domain': 'messages.google.com'},
      ],
    },
  ],
};

const _slack = {
  'url': 'https://slack.com/signin',
  'fields': [
    {
      'id': 'cookie_token',
      'required': true,
      'sources': [
        {'type': 'cookie', 'name': 'd', 'cookie_domain': 'slack.com'},
      ],
    },
  ],
};

/// Opens [step] in the sign-in window, waits for the page, and returns what
/// it shows. Leaves a PNG snapshot behind.
Future<Map<String, dynamic>> _visit(String name, Map<String, dynamic> step, bool Function(String url) loadedHere) async {
  final spec = CookieLoginSpec.fromStep(step);
  final loaded = Completer<String>();
  final urls = <String>[];
  _ch.setMethodCallHandler((call) async {
    final e = (call.arguments as Map).cast<String, dynamic>();
    if (e['type'] == 'url') urls.add('${e['url']}');
    if (e['type'] == 'loaded' && loadedHere('${e['url']}') && !loaded.isCompleted) loaded.complete('${e['url']}');
    return null;
  });
  await _ch.invokeMethod('open', {
    'url': spec.url,
    'userAgent': spec.userAgent,
    'allowedDomains': spec.allowedDomains,
    'cookieDomains': spec.cookieDomains,
    'documentStartScript': CookieLoginScripts(spec).requestHook,
    'initialCookies': spec.initialCookies,
    'title': 'Sign in ($name test)',
    'hidden': false,
  });
  final url = await loaded.future.timeout(const Duration(seconds: 60));
  // Let client-side rendering settle.
  await Future<void>.delayed(const Duration(seconds: 4));
  final info = jsonDecode(
    await _ch.invokeMethod<String>('evaluate', {
          'script': 'JSON.stringify({url: location.href, title: document.title, ua: navigator.userAgent, size: [innerWidth, innerHeight], text: (document.body ? document.body.innerText : "").slice(0, 3000)})',
        }) ??
        '{}',
  ) as Map<String, dynamic>;
  List<Object?>? frame;
  try {
    frame = await _ch.invokeListMethod<Object?>('windowFrame');
  } on MissingPluginException {
    frame = null;
  }
  final cookies = await _ch.invokeListMethod<Map>('getCookies', {'domains': spec.cookieDomains}) ?? const [];
  final dir = Directory('$_home/screenshots')..createSync(recursive: true);
  final shot = await _ch.invokeMethod<bool>('snapshot', {'path': '${dir.path}/webauth-$name.png'}) ?? false;
  await _ch.invokeMethod('close');
  return {
    ...info,
    'loaded_url': url,
    'urls': urls,
    'snapshot': shot,
    'window_frame': frame,
    // Names only; values never leave the throwaway store.
    'cookie_names': [for (final c in cookies) '${c['name']}@${c['domain']}${c['http_only'] == true ? ' (HttpOnly)' : ''}'],
  };
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sign-in pages load in the embedded window and are not blocked', (tester) async {
    expect(await PlatformWebAuth().isAvailable(), isTrue, reason: 'embedded sign-in window unavailable on this platform');
    final report = <String, dynamic>{};

    final google = await _visit('google', _gmessages, (u) => Uri.parse(u).host == 'accounts.google.com');
    report['google'] = google;
    final gText = '${google['text']}'.toLowerCase();
    File('$_home/screenshots/webauth-report.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
    expect(Uri.parse('${google['url']}').host, 'accounts.google.com');
    expect(gText, isNot(contains('may not be secure')));
    expect(gText, isNot(contains("couldn't sign you in")));
    expect(gText, isNot(contains('browser or app')));
    expect(gText, anyOf(contains('sign in'), contains('choose an account'), contains('email or phone')));
    expect('${google['ua']}', contains('Safari/605.1.15'));
    expect('${google['ua']}', contains('Version/'));

    final slack = await _visit('slack', _slack, (u) => Uri.parse(u).host.endsWith('slack.com'));
    report['slack'] = slack;
    File('$_home/screenshots/webauth-report.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
    expect(Uri.parse('${slack['url']}').host, endsWith('slack.com'));
    final sText = '${slack['text']}'.toLowerCase();
    expect(sText, isNot(contains('not supported')));
    expect(sText, contains('sign in'));
  });

  testWidgets('captures every source type end to end (local test page)', (tester) async {
    // A stand-in sign-in site: sets an HttpOnly cookie, writes localStorage
    // and calls an "API" with a token in the body, like Slack's web client.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final res = req.response;
      if (req.uri.path == '/api/client.boot') {
        await utf8.decoder.bind(req).join();
        res.write('{"ok":true}');
      } else if (req.uri.path == '/signin') {
        res.headers.contentType = ContentType.html;
        res.headers.add('Set-Cookie', 'd=xoxd-abc%2Bdef%3D; Path=/; HttpOnly');
        res.write('''<html><body><h1>Signed in</h1><script>
          localStorage.setItem("team", "T123");
          setTimeout(() => {
            fetch("/api/client.boot", {method: "POST", headers: {"Content-Type": "application/x-www-form-urlencoded"}, body: "token=xoxc-from-request"});
          }, 300);
        </script></body></html>''');
      } else {
        res.statusCode = 404;
      }
      await res.close();
    });
    addTearDown(server.close);
    final base = 'http://localhost:${server.port}';
    final spec = CookieLoginSpec.fromStep({
      'url': '$base/signin',
      'fields': [
        {
          'id': 'auth_token',
          'required': true,
          'sources': [
            {'type': 'request_body', 'name': 'token', 'request_url_regex': r'^http://localhost:\d+/api/client\..+$'},
          ],
          'pattern': r'^xoxc-.+$',
        },
        {
          'id': 'cookie_token',
          'required': true,
          'sources': [
            {'type': 'cookie', 'name': 'd', 'cookie_domain': 'localhost'},
          ],
          'pattern': r'^xoxd-[a-zA-Z0-9/+=]+$',
        },
        {
          'id': 'team',
          'required': true,
          'sources': [
            {'type': 'local_storage', 'name': 'team'},
          ],
        },
        {
          'id': 'title',
          'required': true,
          'sources': [
            {'type': 'special', 'name': 'test.title'},
          ],
        },
      ],
      'extract_js': 'new Promise((resolve) => setTimeout(() => resolve({title: document.querySelector("h1").textContent}), 200))',
    });
    final out = await PlatformWebAuth(pollInterval: const Duration(milliseconds: 500)).run(spec).timeout(const Duration(seconds: 30));
    expect(out, {'auth_token': 'xoxc-from-request', 'cookie_token': 'xoxd-abc+def=', 'team': 'T123', 'title': 'Signed in'});
  });
}
