// End-to-end, phone-style: the app as a client of a Crosschat server on
// another computer, reached through an HTTPS reverse proxy (homeserver URL
// host != server_name `localhost`). Real Rust core, no local server.
//
// Needs a throwaway test server with stand-in bridged chats (never Devon's
// real one), e.g. `crosschatd local` with [remote_access] behind Caddy:
//   cd app && flutter test integration_test/remote_server_test.dart -d linux \
//     --dart-define=CROSSCHAT_HOME=/tmp/cc-remote-e2e \
//     --dart-define=CROSSCHAT_E2E_URL=https://matrix.cc.test:8443 \
//     --dart-define=CROSSCHAT_E2E_PASS=<test password>
// Screenshots land in $CROSSCHAT_HOME/screenshots.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:crosschat/src/backend/ffi_backend.dart';
import 'package:crosschat/src/platform.dart';
import 'package:crosschat/src/rust/frb_generated.dart';
import 'package:crosschat/src/state/app_state.dart';
import 'package:crosschat/src/state/settings.dart';
import 'package:crosschat/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _home = String.fromEnvironment('CROSSCHAT_HOME');
const _url = String.fromEnvironment('CROSSCHAT_E2E_URL');
const _user = String.fromEnvironment('CROSSCHAT_E2E_USER', defaultValue: '@devon:localhost');
const _pass = String.fromEnvironment('CROSSCHAT_E2E_PASS');

final _shotKey = GlobalKey();

Future<void> _shot(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 300));
  final boundary = _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2.0);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final dir = Directory('$_home/screenshots')..createSync(recursive: true);
  File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() ok, String what, {Duration timeout = const Duration(minutes: 2)}) async {
  final end = DateTime.now().add(timeout);
  while (!ok()) {
    if (DateTime.now().isAfter(end)) throw StateError('timed out waiting for $what');
    await tester.pump(const Duration(milliseconds: 400));
  }
}

const _phone = PlatformCapabilities(os: 'android', canExtractAppleHardwareKey: false, hasPersistentSyncService: true, hasEmbeddedWebview: false, isMobile: true);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('phone: existing server through an HTTPS proxy', (tester) async {
    expect(_home, isNotEmpty);
    expect(_url, startsWith('https://'));
    tester.view.physicalSize = const Size(412 * 2, 900 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await RustLib.init();
    // Like the Android app: no local server on this device.
    final state = AppState(backend: FfiBackend(), settings: AppSettings() /* fresh install */, capabilities: _phone);
    await tester.pumpWidget(RepaintBoundary(key: _shotKey, child: CrosschatApp(state: state)));
    await state.init();
    await tester.pumpAndSettle();

    // Setup: the local option is off on a phone, "existing server" works.
    await tester.tap(find.byKey(const Key('setup-existing')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('homeserver')), _url);
    await tester.enterText(find.byKey(const Key('username')), _user);
    await tester.enterText(find.byKey(const Key('password')), _pass);
    await _shot(tester, '1-login');
    await tester.tap(find.byKey(const Key('login')));
    await _pumpUntil(tester, () => state.session != null || state.error != null, 'login');
    expect(state.error, isNull);
    expect(state.session!.userId, '@devon:localhost');
    expect(state.isLocalSession, isFalse);

    // Stand-in Slack, Google Messages and iMessage chats.
    await _pumpUntil(tester, () => state.rooms.where((r) => r.networkId != null).length >= 3, 'bridged rooms');
    for (final id in ['slack', 'gmessages', 'imessage']) {
      expect(state.rooms.any((r) => r.networkId == id), isTrue, reason: id);
    }
    // crosschatd answered through the same URL (networks, bridge sign-in).
    await _pumpUntil(tester, () => state.daemonAvailable, 'crosschatd through the proxy');
    await tester.pumpAndSettle();
    final unreadBefore = {for (final r in state.rooms) r.networkId: r.unread};
    expect(unreadBefore['imessage'], greaterThan(0));
    await _shot(tester, '2-chats');

    var n = 3;
    for (final id in ['imessage', 'gmessages', 'slack']) {
      final room = state.rooms.firstWhere((r) => r.networkId == id);
      await tester.tap(find.byKey(Key('room-${room.roomId}')));
      await tester.pumpAndSettle();
      await _pumpUntil(tester, () => find.textContaining('stand-in').evaluate().isNotEmpty, '$id messages');
      // Authenticated media through the proxy: the image decodes.
      await _pumpUntil(tester, () => find.byType(RawImage).evaluate().any((e) => (e.widget as RawImage).image != null), '$id image');
      await tester.pumpAndSettle();
      await _shot(tester, '${n++}-$id-chat');
      if (id == 'gmessages') {
        // Long-press sheet and a reaction (sent to the stand-in room only).
        final mine = find.textContaining('Hello from the phone test');
        await tester.longPress(mine);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('message-actions-sheet')), findsOneWidget);
        await _shot(tester, '${n++}-long-press-sheet');
        await tester.tap(find.byKey(const Key('sheet-react-😂')));
        await _pumpUntil(tester, () => find.byWidgetPredicate((w) => w.key is ValueKey && '${(w.key as ValueKey).value}'.endsWith('-😂')).evaluate().isNotEmpty, 'reaction chip');
        await tester.pumpAndSettle();
        await _shot(tester, '${n++}-reacted');
      }
      await tester.pageBack();
      await tester.pumpAndSettle();
    }
    // Read state: opening the chats marked them read.
    await _pumpUntil(tester, () => state.rooms.where((r) => r.networkId != null).every((r) => r.unread == 0), 'read state');
    await _shot(tester, '${n++}-chats-read');

    await tester.tap(find.byKey(const Key('open-settings')));
    await tester.pumpAndSettle();
    expect(find.text('Connected to crosschatd'), findsOneWidget);
    expect(find.byKey(const Key('local-server-info')), findsNothing);
    await _shot(tester, '${n++}-settings');
  });
}
