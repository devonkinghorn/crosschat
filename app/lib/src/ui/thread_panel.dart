import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'composer.dart';
import 'message_actions.dart';
import 'message_list.dart';
import 'theme.dart';

/// Slack-style thread side panel: root message, replies, thread composer.
class ThreadPanel extends StatelessWidget {
  const ThreadPanel({super.key, required this.state, required this.onClose});
  final AppState state;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final root = state.openThreadRoot;
    final room = state.selectedRoom;
    if (root == null || room == null) return const SizedBox.shrink();
    final msgs = state.threadMessages;
    final replies = msgs.where((m) => m.eventId != root).length;
    return Container(
      color: CC.panel,
      child: Column(
        children: [
          Container(
            height: 52,
            padding: const EdgeInsets.only(left: 16, right: 4),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFF26282C))),
            ),
            child: Row(
              children: [
                const Icon(Icons.forum_rounded, color: CC.textMuted, size: 20),
                const SizedBox(width: 8),
                const Text(
                  'Thread',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: Colors.white),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    '#${room.name}',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: CC.textMuted, fontSize: 13),
                  ),
                ),
                const Spacer(),
                IconButton(
                  key: const Key('close-thread'),
                  tooltip: 'Close thread',
                  icon: const Icon(Icons.close, color: CC.textMuted),
                  onPressed: onClose,
                ),
              ],
            ),
          ),
          Expanded(
            child: MessageList(
              // Root first, then a divider-like gap via the list itself.
              messages: msgs,
              canThread: false,
              actions: MessageActions.of(state),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Row(
              children: [
                Text('$replies ${replies == 1 ? 'reply' : 'replies'}', style: const TextStyle(color: CC.textFaint, fontSize: 12)),
                const SizedBox(width: 8),
                const Expanded(child: Divider(color: CC.divider)),
              ],
            ),
          ),
          Composer(
            key: ValueKey('thread-composer-$root'),
            hint: 'Reply in thread…',
            onSend: (t) => state.send(t, threadRoot: root),
          ),
        ],
      ),
    );
  }
}
