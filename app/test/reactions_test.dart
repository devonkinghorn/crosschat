import 'package:crosschat/src/backend/demo_backend.dart';
import 'package:crosschat/src/daemon/daemon_client.dart';
import 'package:crosschat/src/state/app_state.dart';
import 'package:crosschat/src/models.dart';
import 'package:crosschat/src/state/saved.dart';
import 'package:crosschat/src/ui/emoji_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_test.dart' show android, login, pumpApp;

import 'package:crosschat/src/ui/message_actions.dart' show MessageActions;

const eng = '!eng:slack';
const me = DemoBackend.me;

Future<void> openEng(WidgetTester tester) async {
  await login(tester);
  await tester.tap(find.byKey(const Key('room-$eng')));
  await tester.pumpAndSettle();
}

/// Move a mouse over [finder] (desktop hover).
Future<TestGesture> hover(WidgetTester tester, Finder finder) async {
  final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await g.addPointer(location: Offset.zero);
  addTearDown(g.removePointer);
  await tester.pump();
  await g.moveTo(tester.getCenter(finder));
  await tester.pump();
  await tester.pump();
  return g;
}

/// "iMessage (this Mac)": its bridge can't send reactions.
final macMessages = BridgeInfo(
  id: 'imessage-mac',
  displayName: 'iMessage (this Mac)',
  network: 'imessage',
  enabled: true,
  maturity: 'beta',
  processState: 'running',
  live: true,
  preflight: const [],
  requirements: const [],
  capabilities: const {'reactions': 'no', 'edits': 'no'},
);

/// Opens Mom's iMessage chat (on [macMessages]) with a ❤️ from her.
Future<void> openMacChat(WidgetTester tester, AppState state, DemoBackend backend) async {
  final t = DateTime.now().millisecondsSinceEpoch;
  backend.replaceEvents('!mom:imessage', [
    Message(
      eventId: r'$hi',
      sender: '@mom:x',
      senderName: 'Mom',
      body: 'see you soon',
      ts: t - 60000,
      reactions: const [
        ReactionGroup(key: '❤️', senders: ['@mom:x']),
      ],
    ),
  ]);
  await login(tester);
  state.bridges = [macMessages];
  await state.refreshRooms();
  await tester.tap(find.byKey(const Key('room-!mom:imessage')));
  await tester.pumpAndSettle();
}

void main() {
  group('reaction chips', () {
    testWidgets('clicking a chip toggles my reaction (redaction / annotation)', (tester) async {
      final backend = DemoBackend();
      final state = await pumpApp(tester, backend: backend);
      await openEng(tester);

      // 👀 is mine: highlighted, clicking removes it.
      expect(find.byKey(const Key(r'reaction-$s1-👀')), findsOneWidget);
      await tester.tap(find.byKey(const Key(r'reaction-$s1-👀')));
      await tester.pumpAndSettle();
      expect(backend.reactionCalls.last, (eng, r'$s1', '👀', false));
      expect(find.byKey(const Key(r'reaction-$s1-👀')), findsNothing);

      // 🚀 is others': clicking adds mine (count 2 -> 3, highlighted).
      await tester.tap(find.byKey(const Key(r'reaction-$s1-🚀')));
      await tester.pumpAndSettle();
      expect(backend.reactionCalls.last, (eng, r'$s1', '🚀', true));
      final s1 = state.messages.firstWhere((m) => m.eventId == r'$s1');
      final rocket = s1.reactions.firstWhere((r) => r.key == '🚀');
      expect(rocket.count, 3);
      expect(rocket.own, isTrue);
      expect(rocket.senders, contains(me));
    });

    testWidgets('the add button at the end of the chips opens the emoji picker', (tester) async {
      final backend = DemoBackend();
      await pumpApp(tester, backend: backend);
      await openEng(tester);
      await tester.tap(find.byKey(const Key(r'reaction-add-$s1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('emoji-picker')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('emoji-search')), 'tada');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('emoji-🎉')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('emoji-picker')), findsNothing);
      expect(backend.reactionCalls.last, (eng, r'$s1', '🎉', true));
      expect(find.byKey(const Key(r'reaction-$s1-🎉')), findsOneWidget);
    });

    testWidgets("a reaction sent from the phone as a tapback text can't be removed here", (tester) async {
      final backend = DemoBackend();
      final state = await pumpApp(tester, backend: backend);
      final t = DateTime.now().millisecondsSinceEpoch;
      backend.replaceEvents('!mom:imessage', [
        Message(eventId: r'$hi', sender: '@mom:x', senderName: 'Mom', body: 'see you soon', ts: t - 60000),
        Message(
          eventId: r'$tap',
          sender: me,
          senderName: 'Devon',
          body: 'Loved “see you soon”',
          ts: t - 30000,
          isOwn: true,
          tapback: const TapbackInfo(key: '❤️', targetText: 'see you soon'),
        ),
      ]);
      await login(tester);
      await tester.tap(find.byKey(const Key('room-!mom:imessage')));
      await tester.pumpAndSettle();
      // Folded into a chip on the quoted message, highlighted as mine.
      final hi = state.messages.firstWhere((m) => m.eventId == r'$hi');
      expect(hi.reactions.single.own, isTrue);
      expect(hi.reactions.single.ownFromText, isTrue);
      await tester.tap(find.byKey(const Key(r'reaction-$hi-❤️')));
      await tester.pumpAndSettle();
      expect(backend.reactionCalls.last, ('!mom:imessage', r'$hi', '❤️', false));
      expect(find.textContaining('sent from your phone as a text'), findsOneWidget);
      // Still shown: it really is there on the other side.
      expect(find.byKey(const Key(r'reaction-$hi-❤️')), findsOneWidget);
    });
  });

  group('desktop hover toolbar', () {
    testWidgets('appears on hover with quick reactions, picker, thread and save', (tester) async {
      final backend = DemoBackend();
      final state = await pumpApp(tester, backend: backend);
      await openEng(tester);
      expect(find.byKey(const Key('hover-toolbar')), findsNothing);

      final g = await hover(tester, find.byKey(const Key(r'message-$s2')));
      expect(find.byKey(const Key('hover-toolbar')), findsOneWidget);
      for (final e in quickReactions) {
        expect(find.byKey(Key('quick-react-$e')), findsOneWidget, reason: e);
      }
      expect(find.byKey(const Key('toolbar-pick-emoji')), findsOneWidget);
      expect(find.byKey(const Key('toolbar-thread')), findsOneWidget);
      expect(find.byKey(const Key('toolbar-save')), findsOneWidget);

      // Quick reaction.
      await tester.tap(find.byKey(const Key('quick-react-✅')));
      await tester.pumpAndSettle();
      expect(backend.reactionCalls.last, (eng, r'$s2', '✅', true));
      expect(find.byKey(const Key(r'reaction-$s2-✅')), findsOneWidget);
      // Same quick reaction again removes it (Slack behaviour).
      await tester.tap(find.byKey(const Key('quick-react-✅')));
      await tester.pumpAndSettle();
      expect(backend.reactionCalls.last, (eng, r'$s2', '✅', false));
      expect(find.byKey(const Key(r'reaction-$s2-✅')), findsNothing);

      // Save for later -> account data.
      await tester.tap(find.byKey(const Key('toolbar-save')));
      await tester.pumpAndSettle();
      expect(state.isSaved(eng, r'$s2'), isTrue);
      final stored = SavedMessages.fromJson(backend.accountDataStore[SavedMessages.eventType]);
      expect(stored.items.single.eventId, r'$s2');
      expect(stored.items.single.roomId, eng);
      expect(find.text('Saved for later'), findsOneWidget); // snackbar

      // Moving the mouse onto the toolbar keeps it open.
      await g.moveTo(tester.getCenter(find.byKey(const Key('toolbar-thread'))));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('hover-toolbar')), findsOneWidget);
      await tester.tap(find.byKey(const Key('toolbar-thread')));
      await tester.pumpAndSettle();
      expect(state.openThreadRoot, r'$s2');

      // Leaving hides it.
      await g.moveTo(const Offset(5, 5));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('hover-toolbar')), findsNothing);
    });

    testWidgets('picker from the toolbar; thread messages react too', (tester) async {
      final backend = DemoBackend();
      final state = await pumpApp(tester, backend: backend);
      await openEng(tester);
      final g = await hover(tester, find.byKey(const Key(r'message-$s1')));
      await tester.tap(find.byKey(const Key('toolbar-pick-emoji')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('emoji-group-Food')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('emoji-🍇')), findsOneWidget, reason: 'Food group shown');
      await tester.enterText(find.byKey(const Key('emoji-search')), 'pizza');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('emoji-🍕')));
      await tester.pumpAndSettle();
      expect(backend.reactionCalls.last, (eng, r'$s1', '🍕', true));

      await state.openThread(r'$s2');
      await tester.pumpAndSettle();
      final reply = state.threadMessages.firstWhere((m) => m.eventId != r'$s2');
      await g.moveTo(tester.getCenter(find.byKey(Key('message-${reply.eventId}'))));
      await tester.pump();
      await tester.pump();
      // No "Reply in thread" inside a thread.
      expect(find.byKey(const Key('toolbar-thread')), findsNothing);
      await tester.tap(find.byKey(const Key('quick-react-🙌')));
      await tester.pumpAndSettle();
      expect(backend.reactionCalls.last, (eng, reply.eventId, '🙌', true));
      expect(state.threadMessages.firstWhere((m) => m.eventId == reply.eventId).reactions.single.key, '🙌');
    });
  });

  group('saved for later', () {
    testWidgets('Saved sidebar entry lists saved messages and opens them', (tester) async {
      final backend = DemoBackend();
      backend.accountDataStore[SavedMessages.eventType] = {
        'version': 1,
        'items': [
          {'room_id': eng, 'event_id': r'$s4', 'saved_at': DateTime.now().millisecondsSinceEpoch},
          {'room_id': eng, 'event_id': r'$gone', 'saved_at': 1},
        ],
      };
      final state = await pumpApp(tester, backend: backend);
      await login(tester);
      expect(find.byKey(const Key('saved-count')), findsOneWidget);
      expect(find.text('2'), findsWidgets);

      await tester.tap(find.byKey(const Key('saved-entry')));
      await tester.pumpAndSettle();
      expect(state.showingSaved, isTrue);
      expect(find.byKey(const Key('saved-view')), findsOneWidget);
      expect(find.text('Reading it now. Love the provisioning proxy idea.'), findsOneWidget);
      expect(find.text('This message is no longer available.'), findsOneWidget);

      // Unsave the missing one.
      await tester.tap(find.byKey(const Key(r'unsave-$gone')));
      await tester.pumpAndSettle();
      expect(SavedMessages.fromJson(backend.accountDataStore[SavedMessages.eventType]).items.map((i) => i.eventId), [r'$s4']);

      // Opening an item goes to its chat.
      await tester.tap(find.byKey(const Key(r'saved-$s4')));
      await tester.pumpAndSettle();
      expect(state.showingSaved, isFalse);
      expect(state.selectedRoomId, eng);
      expect(find.byKey(const Key('saved-view')), findsNothing);
    });

    test('saved items round-trip through account data JSON', () {
      final s = SavedMessages([const SavedItem(roomId: '!a', eventId: r'$1', savedAt: 5), const SavedItem(roomId: '!b', eventId: r'$2', savedAt: 9)]);
      final back = SavedMessages.fromJson(s.toJson());
      expect(back.items.map((i) => i.eventId), [r'$2', r'$1'], reason: 'newest first');
      expect(back.contains('!a', r'$1'), isTrue);
      expect(SavedMessages.fromJson({'items': 'junk'}).items, isEmpty);
      expect(SavedMessages.fromJson(null).items, isEmpty);
    });
  });

  group('mobile', () {
    testWidgets('long-press opens the actions sheet; tap still opens threads', (tester) async {
      final backend = DemoBackend();
      final state = await pumpApp(tester, size: const Size(420, 860), caps: android, backend: backend);
      await login(tester);
      await tester.tap(find.byKey(const Key('room-$eng')));
      await tester.pumpAndSettle();

      // Tap on a message does nothing special; the thread summary still opens the thread.
      await tester.tap(find.byKey(const Key(r'message-$s4')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('message-actions-sheet')), findsNothing);

      await tester.longPress(find.byKey(const Key(r'message-$s4')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('message-actions-sheet')), findsOneWidget);
      for (final e in quickReactions) {
        expect(find.byKey(Key('sheet-react-$e')), findsOneWidget, reason: e);
      }
      expect(find.byKey(const Key('sheet-thread')), findsOneWidget);
      expect(find.byKey(const Key('sheet-save')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sheet-react-👍')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('message-actions-sheet')), findsNothing);
      expect(backend.reactionCalls.last, (eng, r'$s4', '👍', true));
      expect(find.byKey(const Key(r'reaction-$s4-👍')), findsOneWidget);

      await tester.longPress(find.byKey(const Key(r'message-$s4')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sheet-save')));
      await tester.pumpAndSettle();
      expect(state.isSaved(eng, r'$s4'), isTrue);

      await tester.longPress(find.byKey(const Key(r'message-$s4')));
      await tester.pumpAndSettle();
      expect(find.text('Remove from saved items'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sheet-thread')));
      await tester.pumpAndSettle();
      expect(state.openThreadRoot, r'$s4');
      expect(find.text('Thread'), findsOneWidget);
      await tester.tap(find.byKey(const Key('close-thread')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('3 replies'));
      await tester.pumpAndSettle();
      expect(state.openThreadRoot, r'$s2');
    });

    testWidgets('Saved is reachable from the phone sidebar', (tester) async {
      final backend = DemoBackend();
      final state = await pumpApp(tester, size: const Size(420, 860), caps: android, backend: backend);
      await login(tester);
      await tester.tap(find.byKey(const Key('saved-entry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('saved-view')), findsOneWidget);
      expect(find.textContaining('Nothing saved yet'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(state.showingSaved, isFalse);
    });
  });

  group('helpers', () {
    test('emoji search knows names and Slack shortcodes', () {
      expect(searchEmoji(':+1:').first, '👍');
      expect(searchEmoji('tada').first, '🎉');
      expect(searchEmoji('white_check_mark').first, '✅');
      expect(searchEmoji('pizza'), contains('🍕'));
      expect(searchEmoji('zzzzqqq'), isEmpty);
      expect(emojiName('👍'), 'thumbs up');
      expect(emojiName('❤'), 'red heart');
    });

    test('local echo of my reaction', () {
      const groups = [
        ReactionGroup(key: '👍', senders: ['@a']),
        ReactionGroup(key: '❤️', senders: [me], own: true),
      ];
      var g = applyOwnReaction(groups, '👍\uFE0F', me, add: true);
      expect(g.first.count, 2);
      expect(g.first.own, isTrue);
      g = applyOwnReaction(g, '❤', me, add: false);
      expect(g.map((r) => r.key), ['👍']);
      g = applyOwnReaction(g, '👍', me, add: false);
      expect(g.single.senders, ['@a']);
      expect(g.single.own, isFalse);
      // Tapback-text reactions stay (they can't be removed from here).
      const text = [
        ReactionGroup(key: '😂', senders: [me], own: true, ownFromText: true),
      ];
      expect(applyOwnReaction(text, '😂', me, add: false).single.own, isTrue);
    });
  });

  group("networks that can't send reactions", () {
    testWidgets('desktop: chips only show who reacted; the toolbar says why instead of offering reactions', (tester) async {
      final backend = DemoBackend();
      final state = await pumpApp(tester, backend: backend);
      await openMacChat(tester, state, backend);
      final why = state.reactionsUnavailable('!mom:imessage');
      expect(why, contains('iMessage (this Mac)'));
      expect(state.reactionsUnavailable(eng), isNull, reason: 'Slack still reacts');

      // Her ❤️ shows; clicking it does nothing, and there's no add button.
      expect(find.byKey(const Key(r'reaction-$hi-❤️')), findsOneWidget);
      await tester.tap(find.byKey(const Key(r'reaction-$hi-❤️')));
      await tester.pumpAndSettle();
      expect(backend.reactionCalls, isEmpty);
      expect(find.byKey(const Key(r'reaction-add-$hi')), findsNothing);

      final g = await hover(tester, find.byKey(const Key(r'message-$hi')));
      expect(find.byKey(const Key('hover-toolbar')), findsOneWidget);
      expect(find.byKey(const Key('toolbar-reactions-unavailable')), findsOneWidget);
      for (final e in quickReactions) {
        expect(find.byKey(Key('quick-react-$e')), findsNothing, reason: e);
      }
      expect(find.byKey(const Key('toolbar-pick-emoji')), findsNothing);
      expect(find.byKey(const Key('toolbar-save')), findsOneWidget, reason: 'saving still works');
      await tester.tap(find.byKey(const Key('toolbar-reactions-unavailable')));
      await tester.pumpAndSettle();
      expect(backend.reactionCalls, isEmpty);
      await g.moveTo(Offset.zero);
      await tester.pumpAndSettle();

      // Even a direct call is refused, without touching the network.
      final hi = state.messages.firstWhere((m) => m.eventId == r'$hi');
      expect(await state.toggleReaction(hi, '👍'), why);
      expect(backend.reactionCalls, isEmpty);
      expect(MessageActions.of(state).canReact, isFalse);
    });

    testWidgets('phone: the long-press sheet explains instead of offering reactions', (tester) async {
      final backend = DemoBackend();
      final state = await pumpApp(tester, size: const Size(420, 860), caps: android, backend: backend);
      await openMacChat(tester, state, backend);
      await tester.longPress(find.byKey(const Key(r'message-$hi')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('message-actions-sheet')), findsOneWidget);
      expect(find.byKey(const Key('sheet-reactions-unavailable')), findsOneWidget);
      for (final e in quickReactions) {
        expect(find.byKey(Key('sheet-react-$e')), findsNothing, reason: e);
      }
      expect(find.byKey(const Key('sheet-pick-emoji')), findsNothing);
      expect(find.byKey(const Key('sheet-save')), findsOneWidget);
    });

    test('a network waiting for its own sign-in counts as ready', () {
      final b = BridgeInfo.fromJson({
        'id': 'imessage-mac',
        'display_name': 'iMessage (this Mac)',
        'network': 'imessage',
        'enabled': true,
        'awaiting_setup': true,
      });
      expect(b.running, isFalse);
      expect(b.ready, isTrue);
      expect(BridgeInfo.fromJson({'id': 'x', 'display_name': 'X', 'network': 'x', 'enabled': true}).ready, isFalse);
    });
  });
}
