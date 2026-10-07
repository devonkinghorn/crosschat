import 'dart:async';
import 'dart:convert';

import 'package:crosschat/main.dart';
import 'package:crosschat/src/backend/demo_backend.dart';
import 'package:crosschat/src/platform.dart';
import 'package:crosschat/src/state/app_state.dart';
import 'package:crosschat/src/ui/bridge_login_dialog.dart';
import 'package:crosschat/src/ui/message_list.dart';
import 'package:crosschat/src/webauth/cookie_login.dart';
import 'package:crosschat/src/webauth/web_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const desktop = PlatformCapabilities(
  os: 'linux',
  canExtractAppleHardwareKey: false,
  hasPersistentSyncService: false,
  hasEmbeddedWebview: false,
  isMobile: false,
);

const android = PlatformCapabilities(
  os: 'android',
  canExtractAppleHardwareKey: false,
  hasPersistentSyncService: true,
  hasEmbeddedWebview: true,
  isMobile: true,
);

/// crosschatd that is down.
final offline = MockClient((_) async => http.Response('nope', 503));

/// A fake crosschatd with one running Google Messages bridge.
MockClient fakeDaemon(List<http.Request> seen) => MockClient((req) async {
  seen.add(req);
  final path = req.url.path;
  if (path == '/_crosschat/v1/health') return http.Response('{"status":"ok"}', 200);
  if (path == '/_crosschat/v1/networks') {
    return http.Response(
      jsonEncode({
        'bridges': [
          {
            'id': 'gmessages',
            'display_name': 'Google Messages',
            'network': 'gmessages',
            'enabled': true,
            'maturity': 'stable',
            'process': {'state': 'running', 'pid': 1, 'started_at_ms': 0},
            'health': {'live': true},
            'preflight': [],
            'requirements': [],
            'capabilities': {},
          },
        ],
      }),
      200,
    );
  }
  if (path == '/_crosschat/v1/search') {
    return http.Response(
      jsonEncode({
        'results': [
          {
            'bridge': 'gmessages',
            'network': 'gmessages',
            'id': '+15551234567',
            'name': 'Jess Climber',
            'identifiers': ['+15551234567'],
            'dm_room_mxid': '!climb:gmessages',
          },
        ],
        'errors': {},
      }),
      200,
    );
  }
  if (path.endsWith('/provision/v3/login/flows')) {
    return http.Response(
      jsonEncode({
        'flows': [
          {'id': 'google', 'name': 'Google account', 'description': 'Sign in with your Google account cookies'},
        ],
      }),
      200,
    );
  }
  if (path.endsWith('/provision/v3/login/start/google')) {
    // Shape captured from mautrix-gmessages v0.2609.0.
    return http.Response(
      jsonEncode({
        'login_id': 'L1',
        'type': 'cookies',
        'step_id': 'fi.mau.gmessages.google_account',
        'instructions': 'Enter a JSON object with your cookies.',
        'cookies': {
          'url': 'https://accounts.google.com/AccountChooser',
          'fields': [
            {
              'id': 'SID',
              'required': true,
              'sources': [
                {'type': 'cookie', 'name': 'SID', 'cookie_domain': '.google.com'},
              ],
            },
            {
              'id': '__Secure-1PSIDTS',
              'required': false,
              'sources': [
                {'type': 'cookie', 'name': '__Secure-1PSIDTS', 'cookie_domain': '.google.com'},
              ],
            },
          ],
        },
      }),
      200,
    );
  }
  if (path.endsWith('/provision/v3/login/step/L1/fi.mau.gmessages.google_account/cookies')) {
    return http.Response(jsonEncode({'login_id': 'L1', 'type': 'complete', 'step_id': 'done', 'complete': {}}), 200);
  }
  return http.Response('{"errcode":"M_NOT_FOUND"}', 404);
});

/// Stands in for the native sign-in window.
class FakeWebAuth implements WebAuthLauncher {
  final runs = <CookieLoginSpec>[];
  Completer<Map<String, String>>? pending;
  bool cancelled = false;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<Map<String, String>> run(CookieLoginSpec spec, {String? title}) {
    runs.add(spec);
    return (pending = Completer<Map<String, String>>()).future;
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
    pending?.completeError(const WebAuthCancelled());
  }
}

Future<AppState> pumpApp(WidgetTester tester, {Size size = const Size(1600, 900), PlatformCapabilities caps = desktop, http.Client? daemon}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final state = AppState(backend: DemoBackend(), capabilities: caps, daemonHttp: daemon ?? offline);
  await tester.pumpWidget(CrosschatApp(state: state));
  await state.init();
  await tester.pumpAndSettle();
  return state;
}

Future<void> login(WidgetTester tester) async {
  // First run shows the setup choice; pick "existing server".
  if (find.byKey(const Key('setup-existing')).evaluate().isNotEmpty) {
    await tester.tap(find.byKey(const Key('setup-existing')));
    await tester.pumpAndSettle();
  }
  await tester.enterText(find.byKey(const Key('homeserver')), 'https://matrix.crosschat.app');
  await tester.enterText(find.byKey(const Key('username')), 'devon');
  await tester.enterText(find.byKey(const Key('password')), 'hunter2');
  await tester.tap(find.byKey(const Key('login')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('login then Slack/Discord layout: rail, sidebar, channel', (tester) async {
    await pumpApp(tester);
    expect(find.byKey(const Key('setup-existing')), findsOneWidget);
    await login(tester);

    expect(find.byKey(const Key('rail-all')), findsOneWidget);
    for (final n in ['imessage', 'gmessages', 'slack', 'groupme', 'matrix']) {
      expect(find.byKey(Key('rail-$n')), findsOneWidget, reason: n);
    }
    expect(find.text('Mom'), findsWidgets);
    expect(find.text('eng-platform'), findsWidgets);
    expect(find.text('Matrix only'), findsOneWidget);
  });

  testWidgets('network filter narrows the sidebar', (tester) async {
    await pumpApp(tester);
    await login(tester);
    await tester.tap(find.byKey(const Key('rail-imessage')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('room-!mom:imessage')), findsOneWidget);
    expect(find.byKey(const Key('room-!eng:slack')), findsNothing);
  });

  testWidgets('thread summary opens the side panel and replies go to the thread', (tester) async {
    final state = await pumpApp(tester);
    await login(tester);
    await tester.tap(find.byKey(const Key('room-!eng:slack')));
    await tester.pumpAndSettle();

    expect(find.byType(ThreadSummaryRow), findsNWidgets(2));
    expect(find.text('3 replies'), findsOneWidget);
    await tester.tap(find.text('3 replies'));
    await tester.pumpAndSettle();

    expect(state.openThreadRoot, r'$s2');
    expect(find.text('Thread'), findsOneWidget);
    expect(find.text('Confirmed, promoting to 50%'), findsOneWidget);

    final threadComposer = find.descendant(of: find.byKey(const ValueKey(r'thread-composer-$s2')), matching: find.byType(TextField));
    await tester.enterText(threadComposer, 'Thanks all');
    await tester.tap(find.descendant(of: find.byKey(const ValueKey(r'thread-composer-$s2')), matching: find.byKey(const Key('send'))));
    await tester.pumpAndSettle();

    expect(state.threadMessages.last.body, 'Thanks all');
    expect(state.threadMessages.last.threadRoot, r'$s2');
    expect(find.text('4 replies'), findsWidgets);

    await tester.tap(find.byKey(const Key('close-thread')));
    await tester.pumpAndSettle();
    expect(state.openThreadRoot, isNull);
  });

  testWidgets('sending to the main timeline', (tester) async {
    final state = await pumpApp(tester);
    await login(tester);
    await tester.tap(find.byKey(const Key('room-!mom:imessage')));
    await tester.pumpAndSettle();
    expect(find.byType(ThreadSummaryRow), findsNothing);
    await tester.enterText(find.byKey(const Key('composer')), 'On my way!');
    await tester.tap(find.byKey(const Key('send')));
    await tester.pumpAndSettle();
    expect(state.messages.last.body, 'On my way!');
    expect(find.text('On my way!'), findsOneWidget);
  });

  testWidgets('new chat degrades to Matrix-only when crosschatd is down', (tester) async {
    await pumpApp(tester);
    await login(tester);
    await tester.tap(find.byKey(const Key('new-chat')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('daemon-unavailable')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('new-chat-search')), 'ali');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('@alice:matrix.org'), findsOneWidget);
  });

  testWidgets('new chat searches bridges through crosschatd and opens the portal', (tester) async {
    final seen = <http.Request>[];
    final state = await pumpApp(tester, daemon: fakeDaemon(seen));
    await login(tester);
    expect(state.daemonAvailable, isTrue);
    expect(find.text('crosschatd connected'), findsOneWidget);

    await tester.tap(find.byKey(const Key('new-chat')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('daemon-unavailable')), findsNothing);
    await tester.enterText(find.byKey(const Key('new-chat-search')), 'jess');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    final search = seen.firstWhere((r) => r.url.path == '/_crosschat/v1/search');
    expect(search.headers['Authorization'], 'Bearer demo');
    expect(jsonDecode(search.body), {'query': 'jess'});

    await tester.tap(find.text('Jess Climber'));
    await tester.pumpAndSettle();
    expect(state.selectedRoomId, '!climb:gmessages');
  });

  testWidgets('settings: networks list and generic login flow picker', (tester) async {
    final seen = <http.Request>[];
    await pumpApp(tester, daemon: fakeDaemon(seen));
    await login(tester);
    await tester.tap(find.byKey(const Key('open-settings')));
    await tester.pumpAndSettle();
    expect(find.text('Connected to crosschatd'), findsOneWidget);
    expect(find.text('Google Messages'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Connect').last);
    await tester.pumpAndSettle();
    expect(find.text('Connect Google Messages'), findsOneWidget);
    expect(find.text('Google account'), findsOneWidget);

    await tester.tap(find.text('Google account'));
    await tester.pumpAndSettle();
    expect(find.text('cookie SID (.google.com)'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('cookie-paste')), "curl 'https://x' -H 'cookie: SID=abc; HSID=zzz'");
    await tester.tap(find.text('Fill from paste'));
    await tester.pump();
    final submit = find.widgetWithText(FilledButton, 'Submit');
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    final step = seen.lastWhere((r) => r.url.path.contains('/login/step/'));
    expect(jsonDecode(step.body), {'SID': 'abc'});
    expect(find.textContaining('Connected!'), findsOneWidget);
  });

  testWidgets('cookies step opens the sign-in window and submits what it captures', (tester) async {
    final fake = FakeWebAuth();
    final previous = webAuthLauncher;
    webAuthLauncher = fake;
    addTearDown(() => webAuthLauncher = previous);
    final seen = <http.Request>[];
    await pumpApp(tester, daemon: fakeDaemon(seen));
    await login(tester);
    await tester.tap(find.byKey(const Key('open-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Connect').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Google account'));
    await tester.pump();
    await tester.pump();

    // Opened by itself, like Beeper; the paste UI is tucked away.
    expect(fake.runs, hasLength(1));
    expect(fake.runs.single.url, 'https://accounts.google.com/AccountChooser');
    expect(find.byKey(const Key('webauth-waiting')), findsOneWidget);
    expect(find.textContaining('in the window that just opened'), findsOneWidget);
    expect(find.text('Advanced: paste cookies'), findsOneWidget);
    expect(find.byKey(const Key('cookie-paste')), findsNothing);
    expect(find.text('Enter a JSON object with your cookies.'), findsNothing);

    // The user closes the window early: offer to reopen it.
    fake.pending!.completeError(const WebAuthCancelled());
    await tester.pumpAndSettle();
    expect(find.textContaining('closed before you finished'), findsOneWidget);
    await tester.tap(find.byKey(const Key('webauth-open')));
    await tester.pump();
    expect(fake.runs, hasLength(2));

    // Sign-in finished: cookies go to the bridge automatically.
    fake.pending!.complete({'SID': 'from-window', '__Secure-1PSIDTS': 'ts'});
    await tester.pumpAndSettle();
    final step = seen.lastWhere((r) => r.url.path.contains('/login/step/'));
    expect(jsonDecode(step.body), {'SID': 'from-window', '__Secure-1PSIDTS': 'ts'});
    expect(find.textContaining('Connected!'), findsOneWidget);
  });

  testWidgets('advanced paste stays available next to the sign-in window', (tester) async {
    final fake = FakeWebAuth();
    final previous = webAuthLauncher;
    webAuthLauncher = fake;
    addTearDown(() => webAuthLauncher = previous);
    final seen = <http.Request>[];
    await pumpApp(tester, daemon: fakeDaemon(seen));
    await login(tester);
    await tester.tap(find.byKey(const Key('open-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Connect').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Google account'));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('Advanced: paste cookies'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Enter a JSON object with your cookies.'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('cookie-paste')));
    await tester.enterText(find.byKey(const Key('cookie-paste')), 'SID=pasted');
    await tester.ensureVisible(find.text('Fill from paste'));
    await tester.pump();
    await tester.tap(find.text('Fill from paste'));
    await tester.pump();
    final submit = find.widgetWithText(FilledButton, 'Submit');
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(jsonDecode(seen.lastWhere((r) => r.url.path.contains('/login/step/')).body), {'SID': 'pasted'});
    expect(find.textContaining('Connected!'), findsOneWidget);
    // Leaving the step closes the window that was still open.
    expect(fake.runs, hasLength(1));
    expect(fake.cancelled, isTrue);
  });

  test('cookie paste parser', () {
    expect(parseCookiePaste('{"SID":"a","HSID":"b"}'), {'SID': 'a', 'HSID': 'b'});
    expect(parseCookiePaste('Cookie: SID=a; HSID=b=c'), {'SID': 'a', 'HSID': 'b=c'});
    expect(parseCookiePaste("curl 'u' -b 'd=xoxd-1; x=2'"), {'d': 'xoxd-1', 'x': '2'});
    expect(parseCookiePaste('curl "u" -H "Cookie: SID=a"'), {'SID': 'a'});
  });

  testWidgets('persistent sync toggle only enabled on Android', (tester) async {
    await pumpApp(tester);
    await login(tester);
    await tester.tap(find.byKey(const Key('open-settings')));
    await tester.pumpAndSettle();
    final sw = tester.widget<SwitchListTile>(find.byKey(const Key('persistent-sync')));
    expect(sw.onChanged, isNull);
  });

  testWidgets('android: toggle persists and narrow layout pushes the channel', (tester) async {
    final state = await pumpApp(tester, size: const Size(420, 860), caps: android);
    await login(tester);
    await tester.tap(find.byKey(const Key('room-!mom:imessage')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('composer')), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('persistent-sync')));
    await tester.pumpAndSettle();
    expect(state.settings.persistentSync, isTrue);
  });
}
