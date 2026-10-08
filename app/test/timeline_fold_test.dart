import 'package:crosschat/src/models.dart';
import 'package:crosschat/src/state/timeline_fold.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/gmessages_events.dart';

void main() {
  test('SMS tapback texts become reactions on the quoted message', () {
    final folded = foldTapbacks(familyChat());
    Message byId(String id) => folded.firstWhere((m) => m.eventId == id);
    // Folded tapbacks are gone from the timeline...
    for (final id in [r'$tb1', r'$tb2', r'$tb3']) {
      expect(folded.any((m) => m.eventId == id), isFalse, reason: id);
    }
    // ...and show up as reactions.
    final dinner = byId(r'$t1');
    final keys = {for (final r in dinner.reactions) r.key: r};
    expect(keys['❤️']!.senders, [alex]);
    // Google's "​👍​ to “…”" merges with the real RCS 👍 reaction from the same person.
    expect(keys['👍']!.senders, [sam, me]);
    expect(keys['👍']!.own, isTrue);
    // "Laughed at an image": the latest image from someone else.
    expect(byId(r'$gif1').reactions.single.key, '😂');
    expect(byId(r'$gif1').reactions.single.senders, [alex]);
  });

  test("a tapback whose message isn't loaded stays as a compact line", () {
    final folded = foldTapbacks(familyChat());
    final orphan = folded.firstWhere((m) => m.eventId == r'$tb4');
    expect(orphan.tapback, isNotNull);
    expect(tapbackLine(orphan.tapback!), "reacted ‼️ to “a message we don't have anymore”");
    // Ordinary text that happens to start with "Loved" is untouched.
    expect(folded.firstWhere((m) => m.eventId == r'$t2').tapback, isNull);
  });

  test('folding is idempotent and handles removals and truncated quotes', () {
    final once = foldTapbacks(familyChat());
    expect(identical(foldTapbacks(once), once) || foldTapbacks(once).length == once.length, isTrue);

    final removal = Message(
      eventId: r'$rm',
      sender: alex,
      senderName: 'Alex Rivera',
      body: 'Removed a heart from “Dinner at 7 on Sunday?”',
      ts: t0 + 9000,
      tapback: const TapbackInfo(key: '❤️', removed: true, targetText: 'Dinner at 7 on Sunday?'),
    );
    final after = foldTapbacks([...once, removal]);
    final dinner = after.firstWhere((m) => m.eventId == r'$t1');
    expect(dinner.reactions.where((r) => r.key == '❤️'), isEmpty);
    expect(after.any((m) => m.eventId == r'$rm'), isFalse);

    final truncated = Message(
      eventId: r'$tr',
      sender: sam,
      senderName: 'Sam',
      body: 'Liked “Dinner at 7…”',
      ts: t0 + 9100,
      tapback: const TapbackInfo(key: '👍', targetText: 'Dinner at 7', truncated: true),
    );
    final t = foldTapbacks([...once, truncated]);
    expect(t.any((m) => m.eventId == r'$tr'), isFalse);
  });
}
