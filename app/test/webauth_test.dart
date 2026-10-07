import 'dart:convert';

import 'package:crosschat/src/webauth/cookie_login.dart';
import 'package:crosschat/src/webauth/web_auth.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The `cookies` step mautrix-gmessages (v0.2609) sends.
Map<String, dynamic> gmessagesStep() {
  Map<String, dynamic> f(String name, String domain, {bool required = true}) => {
    'id': name,
    'required': required,
    'sources': [
      {'type': 'cookie', 'name': name, 'cookie_domain': domain},
    ],
  };
  return {
    'url': 'https://accounts.google.com/AccountChooser?continue=https://messages.google.com/web/config',
    'fields': [
      f('SID', '.google.com'),
      f('HSID', '.google.com'),
      f('OSID', 'messages.google.com'),
      f('SSID', '.google.com'),
      f('APISID', '.google.com'),
      f('SAPISID', '.google.com'),
      f('__Secure-1PSIDTS', '.google.com', required: false),
    ],
  };
}

/// The token step mautrix-slack (v0.2609) sends.
Map<String, dynamic> slackStep() => {
  'url': 'https://slack.com/signin',
  'fields': [
    {
      'id': 'auth_token',
      'required': true,
      'sources': [
        {'type': 'special', 'name': 'fi.mau.slack.auth_token'},
        {'type': 'request_body', 'name': 'token', 'request_url_regex': r'^https://.+?\.slack\.com/api/(client|experiments|api|users|teams|conversations)\..+$'},
      ],
      'pattern': r'^xoxc-.+$',
    },
    {
      'id': 'cookie_token',
      'required': true,
      'sources': [
        {'type': 'cookie', 'name': 'd', 'cookie_domain': 'slack.com'},
      ],
      'pattern': r'^xoxd-[a-zA-Z0-9/+=]+$',
    },
  ],
  'extract_js': 'new Promise(resolve => resolve({auth_token: "xoxc-1"}))',
};

Map<String, dynamic> c(String name, String value, String domain) => {'name': name, 'value': value, 'domain': domain};

void main() {
  group('CookieLoginSpec', () {
    test('gmessages: sign-in host, continue target and allowed domains', () {
      final s = CookieLoginSpec.fromStep(gmessagesStep());
      expect(s.host, 'accounts.google.com');
      expect(s.continueUrl, 'https://messages.google.com/web/config');
      expect(s.allowedDomains, ['google.com']);
      expect(s.cookieDomains, ['.google.com', 'messages.google.com']);
      expect(s.displayHost, 'google.com');
      expect(s.userAgent, isNull);
      expect(s.extractJs, isNull);
      expect(s.fields.where((f) => f.required).map((f) => f.id), ['SID', 'HSID', 'OSID', 'SSID', 'APISID', 'SAPISID']);
    });

    test('legacy fields without sources are cookies on the sign-in host', () {
      final s = CookieLoginSpec.fromStep({
        'url': 'https://example.com/login',
        'fields': [
          {'type': 'cookie', 'name': 'session'},
        ],
      });
      expect(s.fields.single.id, 'session');
      expect(s.fields.single.sources.single.cookieDomain, 'example.com');
    });

    test('registrable domains', () {
      expect(registrableDomain('accounts.google.com'), 'google.com');
      expect(registrableDomain('.google.com'), 'google.com');
      expect(registrableDomain('app.slack.com'), 'slack.com');
      expect(registrableDomain('www.bbc.co.uk'), 'bbc.co.uk');
      expect(registrableDomain('localhost'), 'localhost');
    });

    test('cookie domain matching', () {
      expect(cookieDomainMatches('.google.com', '.google.com'), isTrue);
      expect(cookieDomainMatches('google.com', '.google.com'), isTrue);
      expect(cookieDomainMatches('messages.google.com', '.google.com'), isTrue);
      expect(cookieDomainMatches('.google.com', 'messages.google.com'), isFalse);
      expect(cookieDomainMatches('evilgoogle.com', 'google.com'), isFalse);
    });
  });

  group('CookieCollector', () {
    test('gmessages completes once all required cookies are present', () {
      final col = CookieCollector(CookieLoginSpec.fromStep(gmessagesStep()));
      col.addCookies([c('SID', 'sid', '.google.com'), c('HSID', 'h', '.google.com'), c('NID', 'x', '.google.com')]);
      expect(col.hasAllRequired, isFalse);
      expect(col.missing, ['OSID', 'SSID', 'APISID', 'SAPISID']);
      // OSID for accounts.google.com is not the one messages.google.com needs.
      col.addCookies([c('OSID', 'wrong', 'accounts.google.com')]);
      expect(col.output.containsKey('OSID'), isFalse);
      col.addCookies([
        c('OSID', 'osid', 'messages.google.com'),
        c('SSID', 's', '.google.com'),
        c('APISID', 'a/b', '.google.com'),
        c('SAPISID', 'sa%2Fpi', '.google.com'),
      ]);
      expect(col.isComplete('https://messages.google.com/web/config'), isTrue);
      expect(col.output, {'SID': 'sid', 'HSID': 'h', 'OSID': 'osid', 'SSID': 's', 'APISID': 'a/b', 'SAPISID': 'sa/pi'});
    });

    test('prefers the cookie set on the exact domain', () {
      final col = CookieCollector(CookieLoginSpec.fromStep(gmessagesStep()));
      col.addCookies([c('SID', 'sub', 'accounts.google.com'), c('SID', 'exact', '.google.com')]);
      expect(col.output['SID'], 'exact');
    });

    test('wait_for_url_pattern gates completion', () {
      final step = gmessagesStep()..['wait_for_url_pattern'] = r'^https://messages\.google\.com/';
      final col = CookieCollector(CookieLoginSpec.fromStep(step));
      col.addCookies([
        for (final n in ['SID', 'HSID', 'SSID', 'APISID', 'SAPISID']) c(n, 'v', '.google.com'),
        c('OSID', 'v', 'messages.google.com'),
      ]);
      expect(col.hasAllRequired, isTrue);
      expect(col.isComplete('https://accounts.google.com/x'), isFalse);
      expect(col.isComplete('https://messages.google.com/web/config'), isTrue);
    });

    test('slack: token from extract_js or request body, URL-decoded d cookie', () {
      final spec = CookieLoginSpec.fromStep(slackStep());
      expect(spec.usesRequests, isTrue);
      expect(spec.allowedDomains, ['slack.com']);
      final col = CookieCollector(spec);
      col.addCookies([c('d', 'xoxd-abc%2Bdef%3D', '.slack.com')]);
      expect(col.output['cookie_token'], 'xoxd-abc+def=');
      // Not matching the pattern / URL regex: ignored.
      col.addMessage({
        'kind': 'extract',
        'result': {'auth_token': 'nope'},
      });
      col.addMessage({
        'kind': 'request',
        'url': 'https://example.com/api/client.boot',
        'headers': <String, dynamic>{},
        'body': {'token': 'xoxc-bad'},
      });
      expect(col.hasAllRequired, isFalse);
      col.addMessage({
        'kind': 'request',
        'url': 'https://team.slack.com/api/client.boot?x=1',
        'headers': <String, dynamic>{},
        'body': {'token': 'xoxc-123'},
      });
      expect(col.output, {'cookie_token': 'xoxd-abc+def=', 'auth_token': 'xoxc-123'});
      col.addMessage({
        'kind': 'extract',
        'result': {'auth_token': 'xoxc-456'},
      });
      expect(col.output['auth_token'], 'xoxc-456');
      expect(col.isComplete(null), isTrue);
    });

    test('local storage and request header sources', () {
      final col = CookieCollector(
        CookieLoginSpec.fromStep({
          'url': 'https://example.com/',
          'fields': [
            {
              'id': 'tok',
              'sources': [
                {'type': 'local_storage', 'name': 'token'},
              ],
            },
            {
              'id': 'auth',
              'sources': [
                {'type': 'request_header', 'name': 'Authorization', 'request_url_regex': r'example\.com/api'},
              ],
            },
          ],
        }),
      );
      col.addMessage({
        'kind': 'local_storage',
        'values': {'tok': 'abc'},
      });
      col.addRequest('https://example.com/api/me', {'authorization': 'Bearer 1'}, null);
      expect(col.output, {'tok': 'abc', 'auth': 'Bearer 1'});
    });
  });

  group('CookieLoginScripts', () {
    test('only generated when the step needs them', () {
      final gm = CookieLoginScripts(CookieLoginSpec.fromStep(gmessagesStep()));
      expect(gm.requestHook, isNull);
      expect(gm.readLocalStorage, isNull);
      expect(gm.extract, isNull);
      final sl = CookieLoginScripts(CookieLoginSpec.fromStep(slackStep()));
      expect(sl.requestHook, contains(r'slack\\.com/api'));
      expect(sl.requestHook, contains('XMLHttpRequest'));
      expect(sl.extract, contains('new Promise(resolve => resolve({auth_token: "xoxc-1"}))'));
      expect(sl.extract, contains('kind: "extract"'));
      for (final s in [sl.requestHook!, sl.extract!]) {
        expect(s, contains('messageHandlers.crosschat'));
        expect(s, contains('CrosschatAndroid'));
        expect(s.trim(), endsWith('true;'));
      }
    });
  });

  group('PlatformWebAuth', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const ch = PlatformWebAuth.channel;

    Future<void> nativeEvent(Map<String, dynamic> e) =>
        messenger.handlePlatformMessage(ch.name, const StandardMethodCodec().encodeMethodCall(MethodCall('event', e)), (_) {});

    tearDown(() => messenger.setMockMethodCallHandler(ch, null));

    test('unavailable without the native side', () async {
      expect(await PlatformWebAuth().isAvailable(), isFalse);
    });

    test('gmessages: polls cookies, closes the window and returns them', () async {
      final calls = <MethodCall>[];
      var cookies = <Map<String, dynamic>>[c('SID', 'sid', '.google.com')];
      messenger.setMockMethodCallHandler(ch, (call) async {
        calls.add(call);
        return switch (call.method) {
          'isAvailable' => true,
          'getCookies' => cookies,
          _ => null,
        };
      });
      final auth = PlatformWebAuth(pollInterval: const Duration(milliseconds: 10));
      expect(await auth.isAvailable(), isTrue);
      final result = auth.run(CookieLoginSpec.fromStep(gmessagesStep()), title: 'Sign in to Google Messages');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final open = calls.firstWhere((c) => c.method == 'open').arguments as Map;
      expect(open['url'], startsWith('https://accounts.google.com/AccountChooser'));
      expect(open['allowedDomains'], ['google.com']);
      expect(open['cookieDomains'], ['.google.com', 'messages.google.com']);
      expect(open['title'], 'Sign in to Google Messages');
      expect(calls.any((c) => c.method == 'close'), isFalse);
      cookies = [
        for (final n in ['SID', 'HSID', 'SSID', 'APISID', 'SAPISID']) c(n, n.toLowerCase(), '.google.com'),
        c('OSID', 'osid', 'messages.google.com'),
      ];
      await nativeEvent({'type': 'url', 'url': 'https://messages.google.com/web/config'});
      final out = await result;
      expect(out['OSID'], 'osid');
      expect(out.length, 6);
      expect(calls.where((c) => c.method == 'close'), hasLength(1));
    });

    test('closing the window early cancels; slack extract result via message', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(ch, (call) async {
        calls.add(call);
        return call.method == 'getCookies' ? [c('d', 'xoxd-1', '.slack.com')] : null;
      });
      final auth = PlatformWebAuth(pollInterval: const Duration(milliseconds: 10));
      final early = auth.run(CookieLoginSpec.fromStep(gmessagesStep()));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final cancelled = expectLater(early, throwsA(isA<WebAuthCancelled>()));
      await nativeEvent({'type': 'closed'});
      await cancelled;
      expect(calls.where((c) => c.method == 'close'), isEmpty, reason: 'already closed by the user');

      calls.clear();
      final slack = auth.run(CookieLoginSpec.fromStep(slackStep()));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await nativeEvent({'type': 'loaded', 'url': 'https://app.slack.com/client'});
      expect(calls.where((c) => c.method == 'evaluate').map((c) => (c.arguments as Map)['script'] as String), contains(contains('xoxc-1')));
      await nativeEvent({
        'type': 'message',
        'data': jsonEncode({
          'kind': 'extract',
          'result': {'auth_token': 'xoxc-1'},
        }),
      });
      expect(await slack, {'cookie_token': 'xoxd-1', 'auth_token': 'xoxc-1'});
      final open = calls.firstWhere((c) => c.method == 'open').arguments as Map;
      expect(open['documentStartScript'], contains('XMLHttpRequest'));
    });
  });
}
