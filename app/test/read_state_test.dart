import 'package:crosschat/main.dart';
import 'package:crosschat/src/backend/demo_backend.dart';
import 'package:crosschat/src/models.dart';
import 'package:crosschat/src/platform.dart';
import 'package:crosschat/src/state/app_state.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _desktop = PlatformCapabilities(
  os: 'linux',
  canExtractAppleHardwareKey: false,
  hasPersistentSyncService: false,
  hasEmbeddedWebview: false,
  isMobile: false,
);
const _android = PlatformCapabilities(
  os: 'android',
  canExtractAppleHardwareKey: false,
  hasPersistentSyncService: true,
  hasEmbeddedWebview: true,
  isMobile: true,
);

/// Like the real server: a read receipt only shows up in the unread count
/// after the next sync, so `markRead` doesn't change the room list here.
class LaggyServer extends DemoBackend {
  LaggyServer() : super(autoLogin: true);

  @override
  Future<void> markRead(String roomId, {String? eventId}) async => readCalls.add((roomId, eventId));

  @override
  Future<void> setMarkedUnread(String roomId, bool unread) async => markedUnreadCalls.add((roomId, unread));
}

Future<AppState> _pump(WidgetTester tester, DemoBackend backend, {Size size = const Size(1600, 900), PlatformCapabilities caps = _desktop}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final state = AppState(backend: backend, capabilities: caps, daemonHttp: MockClient((_) async => http.Response('nope', 503)), accountsPollInterval: null);
  await tester.pumpWidget(CrosschatApp(state: state));
  await state.init();
  await tester.pumpAndSettle();
  return state;
}

Room _room(AppState s, String id) => s.rooms.firstWhere((r) => r.roomId == id);

Message _incoming(String id, int ts) => Message(eventId: id, sender: '@imessage_mom:crosschat.app', senderName: 'Mom', body: 'one more thing', ts: ts);

void main() {
  testWidgets('opening the app does not mark the auto-selected chat read', (tester) async {
    final backend = LaggyServer();
    final state = await _pump(tester, backend);
    expect(state.selectedRoomId, isNotNull);
    expect(backend.readCalls, isEmpty);
  });

  testWidgets('clicking a chat marks it read: receipt sent, badge cleared at once', (tester) async {
    final backend = LaggyServer();
    final state = await _pump(tester, backend);
    expect(find.byKey(const Key('unread-!mom:imessage')), findsOneWidget);

    await tester.tap(find.byKey(const Key('room-!mom:imessage')));
    await tester.pump();
    // Bug: clicking used to send nothing, so the server count never cleared.
    expect(backend.readCalls, [('!mom:imessage', null)]);
    expect(find.byKey(const Key('unread-!mom:imessage')), findsNothing);
    expect(_room(state, '!mom:imessage').isUnread, isFalse);

    // The server still reports the old count until it syncs: stays cleared.
    await state.refreshRooms();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('unread-!mom:imessage')), findsNothing);
    expect(state.unreadFor('imessage'), 0);

    // A chat with nothing unread doesn't get a receipt on click.
    await tester.tap(find.byKey(const Key('room-!climb:gmessages')));
    await tester.pumpAndSettle();
    expect(backend.readCalls.length, 1);
  });

  testWidgets('new messages in the open, focused chat are marked read; not when unfocused', (tester) async {
    final backend = LaggyServer();
    final state = await _pump(tester, backend);
    await tester.tap(find.byKey(const Key('room-!mom:imessage')));
    await tester.pumpAndSettle();
    backend.readCalls.clear();

    final now = DateTime.now().millisecondsSinceEpoch;
    backend.addEvent('!mom:imessage', _incoming(r'$new1', now));
    backend.setRoom(_room(state, '!mom:imessage').copyWith(unread: 2));
    backend.emit(BackendUpdate.newMessage('!mom:imessage', _incoming(r'$new1', now)));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(backend.readCalls, [('!mom:imessage', r'$new1')]);
    expect(find.byKey(const Key('unread-!mom:imessage')), findsNothing);

    // Window in the background: nothing is marked read and the badge shows.
    backend.readCalls.clear();
    state.setAppFocused(false);
    backend.addEvent('!mom:imessage', _incoming(r'$new2', now + 1000));
    backend.setRoom(_room(state, '!mom:imessage').copyWith(unread: 3));
    backend.emit(BackendUpdate.newMessage('!mom:imessage', _incoming(r'$new2', now + 1000)));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(backend.readCalls, isEmpty);
    expect(find.byKey(const Key('unread-!mom:imessage')), findsOneWidget);

    // Coming back to the window marks it read.
    state.setAppFocused(true);
    await tester.pumpAndSettle();
    expect(backend.readCalls, [('!mom:imessage', null)]);
    expect(find.byKey(const Key('unread-!mom:imessage')), findsNothing);
  });

  testWidgets('right-click: mark as unread, then mark as read', (tester) async {
    final backend = LaggyServer();
    final state = await _pump(tester, backend);
    const id = '!climb:gmessages';
    expect(_room(state, id).isUnread, isFalse);

    await tester.tap(find.byKey(const Key('room-$id')), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('menu-mark-read')), findsNothing);
    await tester.tap(find.byKey(const Key('menu-mark-unread')));
    await tester.pumpAndSettle();
    expect(backend.markedUnreadCalls, [(id, true)]);
    expect(find.byKey(const Key('marked-unread-$id')), findsOneWidget);
    expect(_room(state, id).isUnread, isTrue);
    expect(state.unreadFor('gmessages'), 1, reason: 'marked-unread chats count in the rail badge');

    // Server echoes the flag: still shown.
    backend.setRoom(_room(state, id).copyWith(markedUnread: true));
    await state.refreshRooms();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('marked-unread-$id')), findsOneWidget);

    await tester.tap(find.byKey(const Key('room-$id')), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('menu-mark-read')));
    await tester.pumpAndSettle();
    expect(backend.readCalls.last, (id, null));
    expect(find.byKey(const Key('marked-unread-$id')), findsNothing);
  });

  testWidgets('marking the open chat unread keeps it unread while it stays open', (tester) async {
    final backend = LaggyServer();
    final state = await _pump(tester, backend);
    const id = '!climb:gmessages';
    await tester.tap(find.byKey(const Key('room-$id')));
    await tester.pumpAndSettle();
    await state.markUnread(id);
    await tester.pumpAndSettle();
    final now = DateTime.now().millisecondsSinceEpoch;
    final m = Message(eventId: r'$g9', sender: '@gmessages_2:crosschat.app', senderName: 'Tom', body: 'hi', ts: now);
    backend.addEvent(id, m);
    backend.emit(BackendUpdate.newMessage(id, m));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(backend.readCalls, isEmpty);
    expect(_room(state, id).isUnread, isTrue);
    // Opening it again marks it read.
    await tester.tap(find.byKey(const Key('room-$id')));
    await tester.pumpAndSettle();
    expect(backend.readCalls, [(id, null)]);
  });

  testWidgets('long-press opens the same menu on mobile', (tester) async {
    final backend = LaggyServer();
    await _pump(tester, backend, size: const Size(400, 800), caps: _android);
    await tester.longPress(find.byKey(const Key('room-!mom:imessage')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('menu-mark-read')));
    await tester.pumpAndSettle();
    expect(backend.readCalls, [('!mom:imessage', null)]);
  });
}
