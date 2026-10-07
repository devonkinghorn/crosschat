// End-to-end: fresh profile -> setup screen -> "Start a new server on this
// computer" -> real crosschatd + Tuwunel -> logged in. Then a second launch
// reuses the running server and restores the session without asking.
//
// Run on a desktop with a throwaway profile (never your real one):
//   cargo build --release -p crosschatd
//   cd app && flutter test integration_test/local_server_test.dart -d linux \
//     --dart-define=CROSSCHAT_HOME=/tmp/cc-e2e
// Screenshots land in $CROSSCHAT_HOME/screenshots. The server is stopped at
// the end unless --dart-define=CROSSCHAT_E2E_KEEP=true.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:crosschat/main.dart';
import 'package:crosschat/src/backend/ffi_backend.dart';
import 'package:crosschat/src/local/app_paths.dart';
import 'package:crosschat/src/local/local_server.dart';
import 'package:crosschat/src/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _home = String.fromEnvironment('CROSSCHAT_HOME');
const _keep = bool.fromEnvironment('CROSSCHAT_E2E_KEEP');
const _user = String.fromEnvironment('CROSSCHAT_E2E_USER', defaultValue: 'e2e');
const _pass = String.fromEnvironment('CROSSCHAT_E2E_PASS', defaultValue: 'e2e-password-123');

final _shotKey = GlobalKey();

Future<void> _shot(WidgetTester tester, String name) async {
  await tester.pump();
  final boundary = _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 1.0);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final dir = Directory('$_home/screenshots')..createSync(recursive: true);
  File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
}

Future<void> _pumpUntil(WidgetTester tester, Finder f, {Duration timeout = const Duration(minutes: 45)}) async {
  final end = DateTime.now().add(timeout);
  while (f.evaluate().isEmpty) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('timed out waiting for $f');
    await tester.pump(const Duration(milliseconds: 500));
  }
}

class TimeoutException implements Exception {
  TimeoutException(this.message);
  final String message;
  @override
  String toString() => message;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('new local server end to end', (tester) async {
    expect(_home, isNotEmpty, reason: 'pass --dart-define=CROSSCHAT_HOME=<throwaway dir>');
    expect(await AppPaths.home(), _home);
    expect(Directory('$_home/server/data').existsSync(), isFalse, reason: 'use a fresh CROSSCHAT_HOME');

    final state = await createAppState();
    expect(state.localServerSupported, isTrue);
    await tester.pumpWidget(RepaintBoundary(key: _shotKey, child: CrosschatApp(state: state)));
    await state.init();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('setup-local')), findsOneWidget);
    await _shot(tester, '1-setup');
    await tester.tap(find.byKey(const Key('setup-local')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('local-username')), _user);
    await tester.enterText(find.byKey(const Key('local-password')), _pass);
    await tester.enterText(find.byKey(const Key('local-confirm')), _pass);
    await _shot(tester, '2-new-server');
    await tester.tap(find.byKey(const Key('local-create')));
    await tester.pump(const Duration(seconds: 2));
    await _shot(tester, '3-starting');

    // First run downloads (Linux) or builds (macOS, unless cached) Tuwunel.
    final end = DateTime.now().add(const Duration(minutes: 45));
    var lastDetail = '';
    while (find.byKey(const Key('rail-all')).evaluate().isEmpty && state.localError == null) {
      if (DateTime.now().isAfter(end)) throw TimeoutException('new server flow timed out');
      final d = state.localStatus?.detail ?? '';
      if (d != lastDetail) {
        debugPrint('local server: $d');
        lastDetail = d;
      }
      await tester.pump(const Duration(milliseconds: 500));
    }
    if (state.localError != null) await _shot(tester, '3-error');
    expect(state.localError, isNull, reason: state.localError);
    expect(state.session!.userId, '@$_user:localhost');
    expect(state.isLocalSession, isTrue);
    // crosschatd answers with the owner as admin, bridges listed.
    await _pumpUntil(tester, find.byKey(const Key('rail-all')), timeout: const Duration(seconds: 5));
    for (var i = 0; i < 40 && !state.daemonAvailable; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(state.daemonAvailable, isTrue);
    expect(state.bridges.map((b) => b.id), containsAll(['gmessages', 'slack']));
    await tester.pump(const Duration(seconds: 3));
    await _shot(tester, '4-logged-in');
    expect(await state.localServer!.configuredOwner(), '@$_user:localhost');

    // Second launch: reuses the running server, restores the session.
    final local2 = ProcessLocalServer();
    final state2 = AppState(backend: FfiBackend(), localServer: local2);
    await tester.pumpWidget(RepaintBoundary(key: _shotKey, child: CrosschatApp(state: state2)));
    await state2.init();
    await tester.pump(const Duration(seconds: 1));
    expect(state2.localError, isNull);
    expect(state2.session?.userId, '@$_user:localhost');
    expect(state2.isLocalSession, isTrue);
    await _pumpUntil(tester, find.byKey(const Key('rail-all')), timeout: const Duration(seconds: 20));

    if (!_keep) await local2.stop();
  }, timeout: const Timeout(Duration(minutes: 60)));
}
