import 'dart:convert';
import 'dart:io';

import 'package:crosschat/main.dart';
import 'package:crosschat/src/backend/demo_backend.dart';
import 'package:crosschat/src/local/app_paths.dart';
import 'package:crosschat/src/local/local_server.dart';
import 'package:crosschat/src/models.dart';
import 'package:crosschat/src/platform.dart';
import 'package:crosschat/src/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const desktop = PlatformCapabilities(
  os: 'macos',
  canExtractAppleHardwareKey: true,
  hasPersistentSyncService: false,
  hasEmbeddedWebview: true,
  isMobile: false,
);

/// In-memory stand-in for crosschatd local mode.
class FakeLocalServer implements LocalServerController {
  FakeLocalServer({this.supported = true, this.owner, this.failStart});

  @override
  final bool supported;
  String? owner;
  String? failStart;
  final calls = <String>[];

  @override
  String get unsupportedReason => 'Runs in the desktop app (macOS or Linux). A phone can\'t host your server.';
  @override
  String homeserverUrl = LocalServerController.defaultHomeserverUrl;
  @override
  String daemonUrl = LocalServerController.defaultDaemonUrl;

  @override
  Future<String?> configuredOwner() async => owner;

  @override
  Future<String> dataDir() async => '/home/devon/.local/share/crosschat/server';

  @override
  Future<LocalServerStatus> start({void Function(LocalServerStatus status)? onProgress}) async {
    calls.add('start');
    onProgress?.call(const LocalServerStatus(phase: 'starting', detail: 'Downloading the Matrix server'));
    await Future<void>.value();
    if (failStart != null) throw LocalServerException(failStart!);
    const s = LocalServerStatus(phase: 'ready', detail: 'Ready');
    onProgress?.call(s);
    return s;
  }

  @override
  Future<String> createOwner(String username, String password) async {
    calls.add('owner:$username');
    if (username == 'taken') throw LocalServerException('That username is taken on this server.', errcode: 'M_USER_IN_USE');
    owner = '@$username:localhost';
    return owner!;
  }

  @override
  Future<void> stop() async => calls.add('stop');
}

/// Records which homeserver the app logged in to.
class RecordingBackend extends DemoBackend {
  String? homeserver;
  String? username;
  @override
  Future<Session> login({required String homeserver, required String username, required String password}) {
    this.homeserver = homeserver;
    this.username = username;
    return super.login(homeserver: homeserver, username: username, password: password);
  }
}

Future<(AppState, RecordingBackend)> pump(
  WidgetTester tester,
  FakeLocalServer? local, {
  PlatformCapabilities caps = desktop,
  http.Client? daemon,
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final backend = RecordingBackend();
  final state = AppState(
    backend: backend,
    capabilities: caps,
    localServer: local,
    daemonHttp: daemon ?? MockClient((_) async => http.Response('down', 503)),
  );
  await tester.pumpWidget(CrosschatApp(state: state));
  await state.init();
  await tester.pumpAndSettle();
  return (state, backend);
}

Future<void> fillNewServer(WidgetTester tester, String user, String pass, [String? confirm]) async {
  await tester.enterText(find.byKey(const Key('local-username')), user);
  await tester.enterText(find.byKey(const Key('local-password')), pass);
  await tester.enterText(find.byKey(const Key('local-confirm')), confirm ?? pass);
  await tester.tap(find.byKey(const Key('local-create')));
  await tester.pumpAndSettle();
}

void main() {
  group('setup screen', () {
    testWidgets('offers a new local server (default) and an existing server', (tester) async {
      await pump(tester, FakeLocalServer());
      expect(find.text('Start a new server on this computer'), findsOneWidget);
      expect(find.text('Use an existing Matrix server'), findsOneWidget);
      expect(find.text('Recommended'), findsOneWidget);
      // Local comes first.
      final localY = tester.getTopLeft(find.byKey(const Key('setup-local'))).dy;
      final existingY = tester.getTopLeft(find.byKey(const Key('setup-existing'))).dy;
      expect(localY, lessThan(existingY));
    });

    testWidgets('new server: owner account, then logged in to localhost', (tester) async {
      final local = FakeLocalServer();
      final (state, backend) = await pump(tester, local);
      await tester.tap(find.byKey(const Key('setup-local')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('local-notice')), findsOneWidget);
      expect(find.textContaining('phone can\'t connect'), findsOneWidget);
      expect(find.textContaining('/home/devon/.local/share/crosschat/server'), findsOneWidget);

      await fillNewServer(tester, '@Devon', 'correct horse');
      expect(local.calls, ['start', 'owner:devon']);
      expect(backend.homeserver, 'http://127.0.0.1:6167');
      expect(backend.username, 'devon');
      expect(state.session, isNotNull);
      expect(state.localOwner, '@devon:localhost');
      expect(find.byKey(const Key('rail-all')), findsOneWidget);
    });

    testWidgets('new server: crosschatd is the local daemon after login', (tester) async {
      final seen = <Uri>[];
      final daemon = MockClient((req) async {
        seen.add(req.url);
        return http.Response('{"status":"ok"}', 200);
      });
      final local = FakeLocalServer();
      final (state, backend) = await pump(tester, local, daemon: daemon);
      await tester.tap(find.byKey(const Key('setup-local')));
      await tester.pumpAndSettle();
      // DemoBackend reports its own homeserver; make the session look local.
      local.homeserverUrl = 'https://matrix.crosschat.app';
      await fillNewServer(tester, 'devon', 'correct horse');
      expect(state.isLocalSession, isTrue);
      expect(seen.first.toString(), startsWith('http://127.0.0.1:29300/_crosschat/v1/'));
      expect(backend.homeserver, 'https://matrix.crosschat.app');

      // Settings show the local server instead of a crosschatd URL field.
      await tester.tap(find.byKey(const Key('open-settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('local-server-info')), findsOneWidget);
      expect(find.text('localhost · this computer only'), findsOneWidget);
      expect(find.byKey(const Key('daemon-url')), findsNothing);
      await tester.tap(find.byKey(const Key('local-restart')));
      await tester.pumpAndSettle();
      expect(local.calls, ['start', 'owner:devon', 'stop', 'start']);
    });

    testWidgets('new server: validation errors never reach crosschatd', (tester) async {
      final local = FakeLocalServer();
      await pump(tester, local);
      await tester.tap(find.byKey(const Key('setup-local')));
      await tester.pumpAndSettle();
      await fillNewServer(tester, 'Devon K', 'correct horse');
      expect(find.text('Use lowercase letters, digits and . _ = / - only.'), findsOneWidget);
      await fillNewServer(tester, 'devon', 'short');
      expect(find.text('Use at least 8 characters for the password.'), findsOneWidget);
      await fillNewServer(tester, 'devon', 'correct horse', 'correct horse!');
      expect(find.text('Passwords don\'t match.'), findsOneWidget);
      expect(local.calls, isEmpty);
    });

    testWidgets('new server: server errors are shown and the form stays', (tester) async {
      final local = FakeLocalServer();
      final (state, _) = await pump(tester, local);
      await tester.tap(find.byKey(const Key('setup-local')));
      await tester.pumpAndSettle();
      await fillNewServer(tester, 'taken', 'correct horse');
      expect(find.text('That username is taken on this server.'), findsOneWidget);
      expect(state.session, isNull);

      local.failStart = 'Downloading Tuwunel failed';
      await fillNewServer(tester, 'devon', 'correct horse');
      expect(find.text('Downloading Tuwunel failed'), findsOneWidget);
      expect(state.session, isNull);
    });

    testWidgets('phones: local server disabled with an explanation', (tester) async {
      const android = PlatformCapabilities(
        os: 'android',
        canExtractAppleHardwareKey: false,
        hasPersistentSyncService: true,
        hasEmbeddedWebview: true,
        isMobile: true,
      );
      await pump(tester, FakeLocalServer(supported: false), caps: android);
      expect(find.textContaining('A phone can\'t host your server.'), findsOneWidget);
      expect(find.text('Recommended'), findsNothing);
      await tester.tap(find.byKey(const Key('setup-local')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('local-username')), findsNothing);
      await tester.tap(find.byKey(const Key('setup-existing')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('homeserver')), findsOneWidget);
    });

    testWidgets('existing server: login form with a way back', (tester) async {
      await pump(tester, FakeLocalServer());
      await tester.tap(find.byKey(const Key('setup-existing')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('homeserver')), findsOneWidget);
      await tester.tap(find.byKey(const Key('login-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('setup-local')), findsOneWidget);
    });

    testWidgets('later launches start the configured server without asking again', (tester) async {
      final local = FakeLocalServer(owner: '@devon:localhost');
      final (state, _) = await pump(tester, local);
      expect(local.calls, ['start']);
      // DemoBackend has no stored session: local sign-in, prefilled.
      expect(find.byKey(const Key('local-login')), findsOneWidget);
      expect(find.text('http://127.0.0.1:6167'), findsOneWidget);
      expect(find.text('devon'), findsOneWidget);
      expect(state.localError, isNull);
    });

    testWidgets('later launches: a failed start offers retry', (tester) async {
      final local = FakeLocalServer(owner: '@devon:localhost', failStart: 'port 6167 in use');
      await pump(tester, local);
      expect(find.byKey(const Key('local-start-error')), findsOneWidget);
      expect(find.textContaining('port 6167 in use'), findsOneWidget);
      local.failStart = null;
      await tester.tap(find.byKey(const Key('local-retry')));
      await tester.pumpAndSettle();
      expect(local.calls, ['start', 'stop', 'start']);
      expect(find.byKey(const Key('local-start-error')), findsNothing);
    });
  });

  group('local server plumbing', () {
    test('validation mirrors crosschatd', () {
      expect(validateLocalpart('devon'), isNull);
      expect(validateLocalpart('d.k_1=x/y-z'), isNull);
      expect(validateLocalpart(''), isNotNull);
      expect(validateLocalpart('Devon'), isNotNull);
      expect(validateLocalpart('devon:localhost'), isNotNull);
      expect(validatePassword('1234567'), isNotNull);
      expect(validatePassword('12345678'), isNull);
    });

    test('app data paths per platform', () {
      expect(AppPaths.desktopHome(os: 'macos', env: {'HOME': '/Users/devon'}), '/Users/devon/Library/Application Support/Crosschat');
      expect(AppPaths.desktopHome(os: 'linux', env: {'HOME': '/home/d'}), '/home/d/.local/share/crosschat');
      expect(AppPaths.desktopHome(os: 'linux', env: {'HOME': '/home/d', 'XDG_DATA_HOME': '/data'}), '/data/crosschat');
      expect(AppPaths.desktopHome(os: 'android', env: {'HOME': '/x'}), isNull);
    });

    test('crosschatd lookup: override, app bundle, dev checkout, PATH', () {
      final files = {'/src/crosschat/Cargo.toml', '/src/crosschat/crates/crosschatd/Cargo.toml'};
      final c = crosschatdCandidates(
        env: {'CROSSCHATD_BIN': '/opt/cc/crosschatd', 'PATH': '/usr/local/bin:/usr/bin'},
        executable: '/src/crosschat/app/build/macos/Build/Products/Debug/crosschat.app/Contents/MacOS/crosschat',
        cwd: '/elsewhere',
        exists: files.contains,
      );
      expect(c.first, '/opt/cc/crosschatd');
      expect(c[1], '/src/crosschat/app/build/macos/Build/Products/Debug/crosschat.app/Contents/MacOS/crosschatd');
      expect(c[2], '/src/crosschat/app/build/macos/Build/Products/Debug/crosschat.app/Contents/Resources/crosschatd');
      expect(c.indexOf('/src/crosschat/target/release/crosschatd'), lessThan(c.indexOf('/src/crosschat/target/debug/crosschatd')));
      expect(c.sublist(c.length - 2), ['/usr/local/bin/crosschatd', '/usr/bin/crosschatd']);
    });

    test('reuses a running server for our data dir, refuses a foreign one', () async {
      final dir = await Directory.systemTemp.createTemp('cc-local');
      addTearDown(() => dir.delete(recursive: true));
      var dataDir = dir.path;
      var phase = 'starting';
      final client = MockClient((req) async {
        if (req.url.path == '/_crosschat/v1/local/status') {
          final body = {'phase': phase, 'detail': 'Downloading', 'data_dir': dataDir, 'homeserver_url': 'http://127.0.0.1:7000'};
          phase = 'ready';
          return http.Response(jsonEncode(body), 200);
        }
        return http.Response('{}', 404);
      });
      final srv = ProcessLocalServer(client: client, dir: dir.path, binary: '/nonexistent/crosschatd');
      final seen = <String>[];
      final s = await srv.start(onProgress: (s) => seen.add(s.phase));
      expect(s.ready, isTrue);
      expect(seen, ['starting', 'ready']);
      expect(srv.homeserverUrl, 'http://127.0.0.1:7000');

      dataDir = '/someone/else';
      await expectLater(srv.start(), throwsA(isA<LocalServerException>().having((e) => e.message, 'message', contains('/someone/else'))));
    });

    test('a failed setup is reported', () async {
      final client = MockClient((req) async => http.Response(jsonEncode({'phase': 'failed', 'error': 'downloading Tuwunel failed'}), 200));
      final srv = ProcessLocalServer(client: client, dir: '/tmp/x', binary: '/nonexistent');
      await expectLater(srv.start(), throwsA(isA<LocalServerException>().having((e) => e.message, 'message', 'downloading Tuwunel failed')));
    });

    test('createOwner sends the admin token and maps errors', () async {
      final dir = await Directory.systemTemp.createTemp('cc-local');
      addTearDown(() => dir.delete(recursive: true));
      await Directory('${dir.path}/data').create();
      await File('${dir.path}/data/admin.token').writeAsString('ADMIN\n');
      final reqs = <http.Request>[];
      final client = MockClient((req) async {
        reqs.add(req);
        final body = jsonDecode(req.body) as Map;
        if (body['username'] == 'taken') {
          return http.Response(jsonEncode({'errcode': 'M_USER_IN_USE', 'error': 'User ID already taken.'}), 409);
        }
        return http.Response(jsonEncode({'user_id': '@${body['username']}:localhost'}), 200);
      });
      final srv = ProcessLocalServer(client: client, dir: dir.path);
      expect(await srv.createOwner('devon', 'correct horse'), '@devon:localhost');
      expect(reqs.single.url.toString(), 'http://127.0.0.1:29300/_crosschat/v1/local/owner');
      expect(reqs.single.headers['Authorization'], 'Bearer ADMIN');
      await expectLater(
        srv.createOwner('taken', 'correct horse'),
        throwsA(isA<LocalServerException>().having((e) => e.errcode, 'errcode', 'M_USER_IN_USE')),
      );
    });

    test('configuredOwner reads local.json', () async {
      final dir = await Directory.systemTemp.createTemp('cc-local');
      addTearDown(() => dir.delete(recursive: true));
      final srv = ProcessLocalServer(dir: dir.path);
      expect(await srv.configuredOwner(), isNull);
      await File('${dir.path}/local.json').writeAsString('{"owner": "@devon:localhost"}');
      expect(await srv.configuredOwner(), '@devon:localhost');
    });
  });
}
