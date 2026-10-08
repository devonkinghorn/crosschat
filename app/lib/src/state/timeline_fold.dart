import '../models.dart';

/// How far back a tapback looks for the message it quotes.
const _searchDepth = 300;

String _norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

bool _kindMatches(String kind, String? target) => switch (target) {
  'image' => kind == 'image' || kind == 'sticker',
  'video' => kind == 'video',
  'audio' => kind == 'audio',
  'file' => kind == 'file' || kind == 'image' || kind == 'video' || kind == 'audio',
  _ => kind != 'redacted' && kind != 'undecryptable',
};

/// The message a tapback refers to, searching backwards from [before].
/// Prefers other people's messages (you usually react to someone else).
int? _findTarget(List<Message> msgs, int before, Message tap) {
  final t = tap.tapback!;
  bool matches(Message m) {
    if (m.tapback != null) return false;
    final text = t.targetText;
    if (text != null) {
      final body = _norm(m.body.isEmpty ? (m.media?.filename ?? '') : m.body);
      final want = _norm(text);
      if (want.isEmpty) return false;
      return body == want || (t.truncated && body.startsWith(want));
    }
    return _kindMatches(m.kind, t.targetKind) && (t.targetKind == null || t.targetKind == 'any' || m.media != null);
  }

  final start = before - 1;
  final stop = (before - _searchDepth).clamp(0, before);
  for (final pass in [0, 1]) {
    for (var i = start; i >= stop; i--) {
      final m = msgs[i];
      if (pass == 0 && m.sender == tap.sender) continue;
      if (matches(m)) return i;
    }
  }
  return null;
}

List<ReactionGroup> _addReaction(List<ReactionGroup> groups, String key, String sender, bool own) {
  final k = key.replaceAll('\uFE0F', '');
  final out = [...groups];
  final i = out.indexWhere((g) => g.key.replaceAll('\uFE0F', '') == k);
  if (i < 0) {
    out.add(ReactionGroup(key: key, senders: [sender], own: own));
  } else if (!out[i].senders.contains(sender)) {
    out[i] = ReactionGroup(key: out[i].key, senders: [...out[i].senders, sender], own: out[i].own || own);
  }
  return out;
}

List<ReactionGroup> _removeReaction(List<ReactionGroup> groups, String key, String sender) {
  final k = key.replaceAll('\uFE0F', '');
  return [
    for (final g in groups)
      if (g.key.replaceAll('\uFE0F', '') != k)
        g
      else if (g.senders.any((s) => s != sender))
        ReactionGroup(key: g.key, senders: g.senders.where((s) => s != sender).toList(), own: g.own && g.senders.length > 1),
  ];
}

/// Turn SMS/RCS tapback fallback texts ("Loved “see you”", "Laughed at an
/// image", Google Messages' "​👍​ to “see you”") into reactions on the
/// message they quote. Tapbacks whose message isn't loaded stay in the
/// list, rendered as a compact system line. Idempotent: folded tapbacks are
/// removed, so re-running on an appended list is safe.
List<Message> foldTapbacks(List<Message> input) {
  if (!input.any((m) => m.tapback != null)) return input;
  final msgs = [...input];
  final drop = <int>{};
  for (var i = 0; i < msgs.length; i++) {
    final tap = msgs[i];
    final t = tap.tapback;
    if (t == null) continue;
    final target = _findTarget(msgs, i, tap);
    if (target == null) continue;
    final m = msgs[target];
    msgs[target] = m.copyWith(reactions: t.removed ? _removeReaction(m.reactions, t.key, tap.sender) : _addReaction(m.reactions, t.key, tap.sender, tap.isOwn));
    drop.add(i);
  }
  return [
    for (var i = 0; i < msgs.length; i++)
      if (!drop.contains(i)) msgs[i],
  ];
}

/// "reacted ❤️ to “see you”" for a tapback shown on its own.
String tapbackLine(TapbackInfo t) {
  final what = t.targetText != null
      ? '“${t.targetText}${t.truncated ? '…' : ''}”'
      : switch (t.targetKind) {
          'image' => 'an image',
          'video' => 'a video',
          'audio' => 'an audio message',
          'file' => 'an attachment',
          _ => 'a message',
        };
  return t.removed ? 'removed ${t.key} from $what' : 'reacted ${t.key} to $what';
}
