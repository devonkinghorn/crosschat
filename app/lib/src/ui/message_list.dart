import 'dart:async';

import 'package:flutter/material.dart';

import '../models.dart';
import '../state/timeline_fold.dart';
import 'media_view.dart';
import 'message_actions.dart';
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
    this.actions,
  });

  final List<Message> messages;

  /// Reactions, save for later, reply in thread (hover toolbar / long press).
  final MessageActions? actions;
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
        final newDay = prev == null || prev.time.day != m.time.day || prev.time.month != m.time.month || prev.time.year != m.time.year;
        final grouped = !newDay && prev.sender == m.sender && m.time.difference(prev.time).inMinutes < 5 && prev.thread == null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (newDay) _DayDivider(label: formatDay(m.time)),
            MessageTile(
              message: m,
              grouped: grouped,
              canThread: widget.canThread && widget.onOpenThread != null,
              onOpenThread: widget.onOpenThread == null ? null : () => widget.onOpenThread!(m),
              actions: widget.actions,
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
          child: Text(
            label,
            style: const TextStyle(color: CC.textMuted, fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        const Expanded(child: Divider(color: CC.divider)),
      ],
    ),
  );
}

class MessageTile extends StatefulWidget {
  const MessageTile({super.key, required this.message, this.grouped = false, this.canThread = true, this.onOpenThread, this.actions});
  final Message message;
  final bool grouped;
  final bool canThread;
  final VoidCallback? onOpenThread;
  final MessageActions? actions;

  @override
  State<MessageTile> createState() => _MessageTileState();
}

class _MessageTileState extends State<MessageTile> {
  bool _hover = false;
  bool _toolbarHover = false;
  final _link = LayerLink();
  final _toolbar = OverlayPortalController();

  bool get _hasActions => widget.actions != null && MessageActions.actionable(widget.message);

  /// "Reply in thread" applies to messages in the main timeline of chats
  /// whose network has threads.
  MessageActions? get _actions {
    final a = widget.actions;
    if (a == null) return null;
    final threadable = widget.canThread && widget.onOpenThread != null && widget.message.threadRoot == null;
    return MessageActions(
      toggleReaction: a.toggleReaction,
      isSaved: a.isSaved,
      toggleSaved: a.toggleSaved,
      nameOf: a.nameOf,
      replyInThread: threadable ? (_) => widget.onOpenThread!() : null,
      reactionsUnavailable: a.reactionsUnavailable,
    );
  }

  void _setHover({bool? tile, bool? toolbar}) {
    if (tile != null) _hover = tile;
    if (toolbar != null) _toolbarHover = toolbar;
    // Leaving the tile for the toolbar (an overlay) reports exit then enter
    // in the same pointer update; decide after both.
    scheduleMicrotask(() {
      if (!mounted) return;
      final show = (_hover || _toolbarHover) && _hasActions;
      if (show && !_toolbar.isShowing) _toolbar.show();
      if (!show && _toolbar.isShowing) _toolbar.hide();
      setState(() {});
    });
  }

  Widget _buildToolbar(BuildContext context) {
    final actions = _actions;
    if (actions == null) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.topLeft,
      child: CompositedTransformFollower(
        link: _link,
        targetAnchor: Alignment.topRight,
        followerAnchor: Alignment.topRight,
        offset: const Offset(-14, -14),
        child: MouseRegion(
          onEnter: (_) => _setHover(toolbar: true),
          onExit: (_) => _setHover(toolbar: false),
          child: MessageHoverToolbar(message: widget.message, actions: actions),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    final tap = m.tapback;
    if (tap != null) return _TapbackLine(message: m, tapback: tap);
    final hover = _hover || _toolbarHover;
    final muted = m.kind == 'redacted' || m.kind == 'undecryptable' || m.kind == 'notice';
    final hasText = m.body.isNotEmpty || m.media == null;
    final actions = _hasActions ? _actions : null;
    final body = Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: m.kind == 'emote' ? '* ${m.senderName} ${m.body}' : m.body,
            style: TextStyle(color: muted ? CC.textMuted : CC.text, fontStyle: muted ? FontStyle.italic : FontStyle.normal, fontSize: 15, height: 1.35),
          ),
          if (m.edited)
            const TextSpan(
              text: '  (edited)',
              style: TextStyle(color: CC.textFaint, fontSize: 11),
            ),
        ],
      ),
    );
    final tile = Container(
      key: Key('message-${m.eventId}'),
      color: hover ? CC.hover.withValues(alpha: 0.45) : null,
      padding: EdgeInsets.fromLTRB(16, widget.grouped ? 1 : 8, 16, 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 40,
            child: widget.grouped
                ? (hover
                      ? Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(formatTime(m.time).replaceAll(' ', '\n'), style: const TextStyle(color: CC.textFaint, fontSize: 9)),
                        )
                      : null)
                : Avatar(name: m.senderName, seed: m.sender, mxc: m.senderAvatar),
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
                if (hasText) body,
                if (m.media != null) MediaView(message: m),
                if (m.reactions.isNotEmpty) ReactionRow(message: m, actions: actions),
                if (widget.canThread && m.thread != null && m.thread!.replyCount > 0) ThreadSummaryRow(summary: m.thread!, onTap: widget.onOpenThread),
              ],
            ),
          ),
        ],
      ),
    );
    if (actions == null) return tile;
    return OverlayPortal(
      controller: _toolbar,
      overlayChildBuilder: _buildToolbar,
      child: CompositedTransformTarget(
        link: _link,
        child: MouseRegion(
          onEnter: (_) => _setHover(tile: true),
          onExit: (_) => _setHover(tile: false),
          child: GestureDetector(
            // Phones: long-press for actions; a tap keeps its current meaning.
            onLongPress: () => showMessageActionsSheet(context, m, actions),
            child: tile,
          ),
        ),
      ),
    );
  }
}

/// An SMS/RCS tapback whose message isn't loaded: a compact muted line
/// ("Alex reacted ❤️ to “see you”") instead of a full message.
class _TapbackLine extends StatelessWidget {
  const _TapbackLine({required this.message, required this.tapback});
  final Message message;
  final TapbackInfo tapback;

  @override
  Widget build(BuildContext context) => Padding(
    key: Key('tapback-line-${message.eventId}'),
    padding: const EdgeInsets.fromLTRB(68, 2, 16, 2),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: message.isOwn ? 'You' : message.senderName,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          TextSpan(text: ' ${tapbackLine(tapback)}'),
          TextSpan(
            text: '  ${formatTime(message.time)}',
            style: const TextStyle(color: CC.textFaint, fontSize: 11),
          ),
        ],
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(color: CC.textMuted, fontSize: 13, fontStyle: FontStyle.italic),
    ),
  );
}

/// Reaction chips under a message ("👍 2"), highlighted where the user
/// reacted. With [actions], a click toggles the user's reaction and a
/// trailing button opens the emoji picker.
class ReactionRow extends StatelessWidget {
  const ReactionRow({super.key, required this.message, this.actions});
  final Message message;
  final MessageActions? actions;

  @override
  Widget build(BuildContext context) {
    final a = actions;
    // Chips toggle only where the user can react; elsewhere they just show
    // who reacted (and say why they can't).
    final canReact = a != null && a.canReact;
    final why = a?.reactionsUnavailable;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final r in message.reactions)
            Tooltip(
              message:
                  '${a?.reactedLabel(r) ?? '${r.count} ${r.count == 1 ? 'reaction' : 'reactions'}${r.own ? ' (including you)' : ''}'}${why == null ? '' : '\n$why'}',
              child: Material(
                color: r.own ? CC.accent.withValues(alpha: 0.22) : CC.input,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(color: r.own ? CC.accent : Colors.transparent),
                ),
                child: InkWell(
                  key: Key('reaction-${message.eventId}-${r.key}'),
                  borderRadius: BorderRadius.circular(10),
                  onTap: canReact ? () => a.react(context, message, r.key) : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: r.key, style: emojiStyle(14)),
                          TextSpan(
                            text: ' ${r.count}',
                            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: r.own ? const Color(0xFFC9CDFB) : CC.textMuted),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (canReact)
            Tooltip(
              message: 'Add reaction',
              child: Material(
                color: CC.input,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                child: InkWell(
                  key: Key('reaction-add-${message.eventId}'),
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => a.pickAndReact(context, message),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    child: Icon(Icons.add_reaction_outlined, size: 16, color: CC.textMuted),
                  ),
                ),
              ),
            ),
        ],
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
                Flexible(
                  child: Text(
                    'Last reply ${formatRelative(DateTime.fromMillisecondsSinceEpoch(summary.latestReplyTs!))}',
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: const TextStyle(color: CC.textFaint, fontSize: 12),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
