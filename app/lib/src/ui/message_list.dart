import 'package:flutter/material.dart';

import '../models.dart';
import 'theme.dart';
import 'widgets.dart';

/// Dense, Slack-style message list. Consecutive messages from the same
/// sender within 5 minutes collapse their header.
class MessageList extends StatefulWidget {
  const MessageList({
    super.key,
    required this.messages,
    this.onOpenThread,
    this.canThread = true,
    this.padding = const EdgeInsets.only(bottom: 12),
  });

  final List<Message> messages;
  final void Function(Message root)? onOpenThread;
  final bool canThread;
  final EdgeInsets padding;

  @override
  State<MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<MessageList> {
  @override
  Widget build(BuildContext context) {
    final msgs = widget.messages;
    // reverse: true keeps the list pinned to the newest message.
    return ListView.builder(
      reverse: true,
      padding: widget.padding,
      itemCount: msgs.length,
      itemBuilder: (context, i) {
        final idx = msgs.length - 1 - i;
        final m = msgs[idx];
        final prev = idx > 0 ? msgs[idx - 1] : null;
        final newDay = prev == null ||
            prev.time.day != m.time.day ||
            prev.time.month != m.time.month ||
            prev.time.year != m.time.year;
        final grouped = !newDay &&
            prev.sender == m.sender &&
            m.time.difference(prev.time).inMinutes < 5 &&
            prev.thread == null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (newDay) _DayDivider(label: formatDay(m.time)),
            MessageTile(
              message: m,
              grouped: grouped,
              canThread: widget.canThread && widget.onOpenThread != null,
              onOpenThread: widget.onOpenThread == null ? null : () => widget.onOpenThread!(m),
            ),
          ],
        );
      },
    );
  }
}

class _DayDivider extends StatelessWidget {
  const _DayDivider({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Row(
      children: [
        const Expanded(child: Divider(color: CC.divider)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(label, style: const TextStyle(color: CC.textMuted, fontSize: 12, fontWeight: FontWeight.w600)),
        ),
        const Expanded(child: Divider(color: CC.divider)),
      ],
    ),
  );
}

class MessageTile extends StatefulWidget {
  const MessageTile({super.key, required this.message, this.grouped = false, this.canThread = true, this.onOpenThread});
  final Message message;
  final bool grouped;
  final bool canThread;
  final VoidCallback? onOpenThread;

  @override
  State<MessageTile> createState() => _MessageTileState();
}

class _MessageTileState extends State<MessageTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    final muted = m.kind == 'redacted' || m.kind == 'undecryptable' || m.kind == 'notice';
    final body = Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: m.kind == 'emote' ? '* ${m.senderName} ${m.body}' : m.body,
            style: TextStyle(
              color: muted ? CC.textMuted : CC.text,
              fontStyle: muted ? FontStyle.italic : FontStyle.normal,
              fontSize: 15,
              height: 1.35,
            ),
          ),
          if (m.edited) const TextSpan(text: '  (edited)', style: TextStyle(color: CC.textFaint, fontSize: 11)),
        ],
      ),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        color: _hover ? CC.hover.withValues(alpha: 0.45) : null,
        padding: EdgeInsets.fromLTRB(16, widget.grouped ? 1 : 8, 16, 1),
        child: Stack(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 40,
                  child: widget.grouped
                      ? (_hover
                            ? Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(formatTime(m.time).replaceAll(' ', '\n'), style: const TextStyle(color: CC.textFaint, fontSize: 9)),
                              )
                            : null)
                      : Avatar(name: m.senderName, seed: m.sender),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (!widget.grouped)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            Flexible(
                              child: Text(
                                m.senderName,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: Colors.white),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(formatTime(m.time), style: const TextStyle(color: CC.textFaint, fontSize: 11.5)),
                          ],
                        ),
                      body,
                      if (widget.canThread && m.thread != null && m.thread!.replyCount > 0)
                        ThreadSummaryRow(summary: m.thread!, onTap: widget.onOpenThread),
                    ],
                  ),
                ),
              ],
            ),
            if (_hover && widget.canThread)
              Positioned(
                right: 0,
                top: 0,
                child: Material(
                  color: CC.sidebar,
                  elevation: 2,
                  borderRadius: BorderRadius.circular(6),
                  child: IconButton(
                    tooltip: 'Reply in thread',
                    visualDensity: VisualDensity.compact,
                    iconSize: 18,
                    icon: const Icon(Icons.forum_outlined, color: CC.textMuted),
                    onPressed: widget.onOpenThread,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// "▣▣ 3 replies   Last reply 2h ago" under a thread root.
class ThreadSummaryRow extends StatelessWidget {
  const ThreadSummaryRow({super.key, required this.summary, this.onTap});
  final ThreadSummary summary;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final n = summary.replyCount;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: InkWell(
        key: const Key('thread-summary'),
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final p in summary.participants.take(4))
                Padding(
                  padding: const EdgeInsets.only(right: 3),
                  child: Avatar(name: p.replaceFirst('@', '').split(':').first, seed: p, size: 20),
                ),
              const SizedBox(width: 4),
              Text(
                '$n ${n == 1 ? 'reply' : 'replies'}',
                style: const TextStyle(color: CC.link, fontWeight: FontWeight.w700, fontSize: 13),
              ),
              if (summary.latestReplyTs != null) ...[
                const SizedBox(width: 8),
                Text(
                  'Last reply ${formatRelative(DateTime.fromMillisecondsSinceEpoch(summary.latestReplyTs!))}',
                  style: const TextStyle(color: CC.textFaint, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
