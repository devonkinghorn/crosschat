import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../state/app_state.dart';
import 'emoji_picker.dart';
import 'theme.dart';

/// What the user can do with a message: react, reply in thread, save for
/// later. Shared by the desktop hover toolbar, the mobile long-press sheet
/// and the reaction chips.
class MessageActions {
  const MessageActions({
    required this.toggleReaction,
    required this.isSaved,
    required this.toggleSaved,
    this.replyInThread,
    this.nameOf,
    this.reactionsUnavailable,
  });

  /// From [AppState] for messages of [roomId] (default: the open chat).
  /// Without [replyInThread] there's no "Reply in thread" (thread panel,
  /// networks without threads).
  factory MessageActions.of(AppState state, {String? roomId, void Function(Message m)? replyInThread}) {
    final room = roomId ?? state.selectedRoomId;
    return MessageActions(
      toggleReaction: (m, key) => state.toggleReaction(m, key, roomId: room),
      isSaved: (m) => room != null && state.isSaved(room, m.eventId),
      toggleSaved: (m) => state.toggleSaved(m, roomId: room),
      replyInThread: replyInThread,
      nameOf: (id) => id == state.session?.userId ? 'You' : _nameIn(state, id),
      reactionsUnavailable: state.reactionsUnavailable(room),
    );
  }

  static String _nameIn(AppState state, String userId) {
    for (final m in [...state.messages, ...state.threadMessages]) {
      if (m.sender == userId && m.senderName.isNotEmpty) return m.senderName;
    }
    return userId.replaceFirst('@', '').split(':').first;
  }

  /// Returns a problem to show, or null.
  final Future<String?> Function(Message m, String key) toggleReaction;
  final bool Function(Message m) isSaved;
  final Future<String?> Function(Message m) toggleSaved;
  final void Function(Message m)? replyInThread;
  final String Function(String userId)? nameOf;

  /// Set when reactions can't be sent in this chat (why): the quick
  /// reactions and picker are replaced by a disabled button explaining it,
  /// and chips only show who reacted.
  final String? reactionsUnavailable;
  bool get canReact => reactionsUnavailable == null;

  /// Messages that take reactions / actions at all.
  static bool actionable(Message m) => m.tapback == null && m.kind != 'redacted' && m.kind != 'undecryptable';

  // The toolbar that started an action may be gone by the time it finishes
  // (the pointer left it for the picker), so report through the messenger
  // captured up front rather than the caller's context.

  Future<void> react(BuildContext context, Message m, String key) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    _report(messenger, await toggleReaction(m, key));
  }

  Future<void> pickAndReact(BuildContext context, Message m) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final e = await showEmojiPicker(context);
    if (e != null) _report(messenger, await toggleReaction(m, e));
  }

  Future<void> save(BuildContext context, Message m) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final wasSaved = isSaved(m);
    final problem = await toggleSaved(m);
    if (problem != null) return _report(messenger, problem);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(wasSaved ? 'Removed from Saved' : 'Saved for later'), duration: const Duration(seconds: 2)));
  }

  void _report(ScaffoldMessengerState? messenger, String? problem) {
    if (problem == null) return;
    messenger?.showSnackBar(SnackBar(content: Text(problem)));
  }

  /// "You, Priya and 2 others reacted with 👍".
  String reactedLabel(ReactionGroup r) {
    final names = [for (final s in r.senders) nameOf?.call(s) ?? s];
    if (r.own && !names.contains('You')) names.insert(0, 'You');
    names.sort((a, b) => a == 'You' ? -1 : (b == 'You' ? 1 : 0));
    final who = switch (names.length) {
      0 => 'Nobody',
      1 => names[0],
      2 => '${names[0]} and ${names[1]}',
      3 => '${names[0]}, ${names[1]} and ${names[2]}',
      _ => '${names[0]}, ${names[1]} and ${names.length - 2} others',
    };
    final name = emojiName(r.key);
    return '$who reacted with ${r.key}${name == null ? '' : ' ($name)'}';
  }
}

/// Slack's hover toolbar: quick reactions, emoji picker, reply in thread,
/// save for later. Shown at the top-right of the hovered message (desktop).
class MessageHoverToolbar extends StatelessWidget {
  const MessageHoverToolbar({super.key, required this.message, required this.actions});
  final Message message;
  final MessageActions actions;

  @override
  Widget build(BuildContext context) {
    final m = message;
    final saved = actions.isSaved(m);
    final reacted = {
      for (final r in m.reactions)
        if (r.own) normalizeReactionKey(r.key),
    };
    return Material(
      key: const Key('hover-toolbar'),
      color: CC.sidebar,
      elevation: 3,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Color(0xFF3A3C42)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!actions.canReact)
              _ToolButton(
                key: const Key('toolbar-reactions-unavailable'),
                tooltip: actions.reactionsUnavailable!,
                onPressed: null,
                child: const Icon(Icons.add_reaction_outlined, size: 19, color: CC.textFaint),
              ),
            for (final e in actions.canReact ? quickReactions : const <String>[])
              _ToolButton(
                key: Key('quick-react-$e'),
                tooltip: reacted.contains(normalizeReactionKey(e)) ? 'Remove $e' : 'React with $e',
                selected: reacted.contains(normalizeReactionKey(e)),
                onPressed: () => actions.react(context, m, e),
                child: Text(e, style: emojiStyle(17)),
              ),
            if (actions.canReact)
              _ToolButton(
                key: const Key('toolbar-pick-emoji'),
                tooltip: 'Find another reaction',
                onPressed: () => actions.pickAndReact(context, m),
                child: const Icon(Icons.add_reaction_outlined, size: 19, color: CC.textMuted),
              ),
            if (actions.replyInThread != null)
              _ToolButton(
                key: const Key('toolbar-thread'),
                tooltip: 'Reply in thread',
                onPressed: () => actions.replyInThread!(m),
                child: const Icon(Icons.forum_outlined, size: 19, color: CC.textMuted),
              ),
            _ToolButton(
              key: const Key('toolbar-save'),
              tooltip: saved ? 'Remove from saved items' : 'Save for later',
              onPressed: () => actions.save(context, m),
              child: Icon(saved ? Icons.bookmark : Icons.bookmark_border, size: 19, color: saved ? CC.danger : CC.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({super.key, required this.tooltip, required this.onPressed, required this.child, this.selected = false});
  final String tooltip;

  /// Null: disabled (the tooltip says why).
  final VoidCallback? onPressed;
  final Widget child;
  final bool selected;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    waitDuration: const Duration(milliseconds: 400),
    child: InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(6),
      hoverColor: CC.selected,
      child: Container(
        width: 32,
        height: 30,
        alignment: Alignment.center,
        decoration: selected ? BoxDecoration(color: CC.accent.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(6)) : null,
        child: child,
      ),
    ),
  );
}

/// The long-press sheet on phones: the toolbar's actions, finger-sized.
Future<void> showMessageActionsSheet(BuildContext context, Message m, MessageActions actions) async {
  unawaited(HapticFeedback.mediumImpact());
  final saved = actions.isSaved(m);
  final reacted = {
    for (final r in m.reactions)
      if (r.own) normalizeReactionKey(r.key),
  };
  final choice = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: CC.panel,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        key: const Key('message-actions-sheet'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!actions.canReact)
            Padding(
              key: const Key('sheet-reactions-unavailable'),
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Row(
                children: [
                  const Icon(Icons.block, size: 18, color: CC.textFaint),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(actions.reactionsUnavailable!, style: const TextStyle(color: CC.textMuted, fontSize: 13)),
                  ),
                ],
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final e in quickReactions)
                    _SheetEmoji(
                      key: Key('sheet-react-$e'),
                      selected: reacted.contains(normalizeReactionKey(e)),
                      onTap: () => Navigator.of(context).pop('react:$e'),
                      child: Text(e, style: emojiStyle(26)),
                    ),
                  _SheetEmoji(
                    key: const Key('sheet-pick-emoji'),
                    onTap: () => Navigator.of(context).pop('pick'),
                    child: const Icon(Icons.add_reaction_outlined, color: CC.textMuted),
                  ),
                ],
              ),
            ),
          const Divider(height: 1),
          if (actions.replyInThread != null)
            ListTile(
              key: const Key('sheet-thread'),
              leading: const Icon(Icons.forum_outlined),
              title: const Text('Reply in thread'),
              onTap: () => Navigator.of(context).pop('thread'),
            ),
          ListTile(
            key: const Key('sheet-save'),
            leading: Icon(saved ? Icons.bookmark : Icons.bookmark_border, color: saved ? CC.danger : null),
            title: Text(saved ? 'Remove from saved items' : 'Save for later'),
            onTap: () => Navigator.of(context).pop('save'),
          ),
          if (m.body.isNotEmpty)
            ListTile(
              key: const Key('sheet-copy'),
              leading: const Icon(Icons.copy_rounded),
              title: const Text('Copy text'),
              onTap: () => Navigator.of(context).pop('copy'),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  if (choice.startsWith('react:')) {
    await actions.react(context, m, choice.substring(6));
  } else if (choice == 'pick') {
    await actions.pickAndReact(context, m);
  } else if (choice == 'thread') {
    actions.replyInThread?.call(m);
  } else if (choice == 'save') {
    await actions.save(context, m);
  } else if (choice == 'copy') {
    final messenger = ScaffoldMessenger.maybeOf(context);
    await Clipboard.setData(ClipboardData(text: m.body));
    messenger?.showSnackBar(const SnackBar(content: Text('Copied'), duration: Duration(seconds: 1)));
  }
}

class _SheetEmoji extends StatelessWidget {
  const _SheetEmoji({super.key, required this.onTap, required this.child, this.selected = false});
  final VoidCallback onTap;
  final Widget child;
  final bool selected;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? CC.accent.withValues(alpha: 0.3) : CC.input,
    shape: const CircleBorder(),
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: SizedBox(width: 44, height: 44, child: Center(child: child)),
    ),
  );
}
