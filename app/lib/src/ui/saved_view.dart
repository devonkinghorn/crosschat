import 'package:flutter/material.dart';

import '../models.dart';
import '../state/app_state.dart';
import '../state/saved.dart';
import 'message_actions.dart';
import 'message_list.dart';
import 'networks.dart';
import 'theme.dart';
import 'widgets.dart';

/// "Saved for later": every saved message across chats, newest first.
/// Saved items live in account data, so they're the same on every device.
class SavedView extends StatelessWidget {
  const SavedView({super.key, required this.state, required this.onOpen, this.leading});
  final AppState state;
  final void Function(SavedItem item) onOpen;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final items = state.saved.items;
    return Column(
      key: const Key('saved-view'),
      children: [
        Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: const BoxDecoration(
            color: CC.channel,
            border: Border(bottom: BorderSide(color: Color(0xFF26282C))),
          ),
          child: Row(
            children: [
              ?leading,
              const Icon(Icons.bookmark_rounded, color: CC.textMuted, size: 20),
              const SizedBox(width: 8),
              const Text(
                'Saved for later',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: Colors.white),
              ),
              const SizedBox(width: 10),
              Text('${items.length}', style: const TextStyle(color: CC.textMuted)),
              const Spacer(),
              if (state.loadingSaved) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Nothing saved yet. Hover a message (or long-press it on a phone) and choose Save for later.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: CC.textMuted),
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: items.length,
                  itemBuilder: (context, i) => _SavedTile(state: state, item: items[i], onOpen: () => onOpen(items[i])),
                ),
        ),
      ],
    );
  }
}

class _SavedTile extends StatelessWidget {
  const _SavedTile({required this.state, required this.item, required this.onOpen});
  final AppState state;
  final SavedItem item;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final room = state.rooms.where((r) => r.roomId == item.roomId).firstOrNull;
    final m = state.savedMessage(item);
    final loaded = state.savedMessageLoaded(item);
    final style = networkStyle(room?.networkId);
    return Padding(
      key: Key('saved-${item.eventId}'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: CC.sidebar.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 6, 4, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: Row(
                    children: [
                      Icon(room?.isDm ?? false ? Icons.alternate_email_rounded : Icons.tag_rounded, size: 14, color: CC.textMuted),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                room?.name ?? 'Unknown chat',
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: CC.textMuted, fontSize: 12, fontWeight: FontWeight.w600),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(style.label, style: TextStyle(color: style.color, fontSize: 11)),
                          ],
                        ),
                      ),
                      IconButton(
                        key: Key('unsave-${item.eventId}'),
                        tooltip: 'Remove from saved items',
                        visualDensity: VisualDensity.compact,
                        iconSize: 18,
                        icon: const Icon(Icons.bookmark_remove_outlined, color: CC.textMuted),
                        onPressed: () => MessageActions.of(state, roomId: item.roomId).save(context, m ?? _placeholder(item)),
                      ),
                    ],
                  ),
                ),
                if (m != null)
                  IgnorePointer(child: MessageTile(message: m, canThread: false))
                else
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Text(
                      loaded ? 'This message is no longer available.' : 'Loading…',
                      style: const TextStyle(color: CC.textFaint, fontStyle: FontStyle.italic),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(left: 68),
                  child: Text(
                    'Saved ${formatRelative(DateTime.fromMillisecondsSinceEpoch(item.savedAt))}',
                    style: const TextStyle(color: CC.textFaint, fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Unsaving a message that can't be loaded only needs its id.
Message _placeholder(SavedItem i) => Message(eventId: i.eventId, sender: '', senderName: '', body: '', ts: i.savedAt);
