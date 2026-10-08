import 'package:flutter/material.dart';

import '../contacts/people.dart';
import '../models.dart';
import '../state/app_state.dart';
import 'composer.dart';
import 'message_list.dart';
import 'networks.dart';
import 'theme.dart';

class ChannelView extends StatelessWidget {
  const ChannelView({super.key, required this.state, this.onOpenThread, this.leading});
  final AppState state;
  final void Function(Message root)? onOpenThread;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final room = state.selectedRoom;
    if (room == null) {
      return const Center(
        child: Text('Pick a conversation', style: TextStyle(color: CC.textMuted)),
      );
    }
    final style = networkStyle(room.networkId);
    final canThread = room.canThread;
    return Column(
      children: [
        Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: const BoxDecoration(
            color: CC.channel,
            border: Border(bottom: BorderSide(color: Color(0xFF26282C), width: 1)),
          ),
          child: Row(
            children: [
              ?leading,
              Icon(room.isDm ? Icons.alternate_email_rounded : Icons.tag_rounded, color: CC.textMuted, size: 22),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  room.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: Colors.white),
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: style.color.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(4)),
                child: Text(
                  style.label,
                  style: TextStyle(color: Color.lerp(style.color, Colors.white, 0.55), fontSize: 11, fontWeight: FontWeight.w600),
                ),
              ),
              if (room.topic != null) ...[
                const SizedBox(width: 12),
                Container(width: 1, height: 22, color: CC.divider),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    room.topic!,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: CC.textMuted, fontSize: 13),
                  ),
                ),
              ] else
                const Spacer(),
              if (!canThread)
                const Tooltip(
                  message: "This network has no threads, so replies stay inline.\nCrosschat never fakes threads that wouldn't reach the other side.",
                  child: Icon(Icons.info_outline_rounded, size: 18, color: CC.textFaint),
                ),
            ],
          ),
        ),
        Expanded(
          child: state.loadingMessages
              ? const Center(child: CircularProgressIndicator())
              : MessageList(messages: state.messages, canThread: canThread, onOpenThread: canThread ? onOpenThread : null),
        ),
        Composer(
          key: ValueKey('composer-${room.roomId}'),
          hint: 'Message ${room.isDm ? '@' : '#'}${room.name}',
          onSend: (t) => state.send(t),
          footer: NetworkSwitcher(state: state, room: room),
        ),
      ],
    );
  }
}

/// "Sending with iMessage ▾" under the composer of a DM opened from the
/// contact picker: switch this person to another network (opens that
/// network's DM and remembers the choice for them).
class NetworkSwitcher extends StatelessWidget {
  const NetworkSwitcher({super.key, required this.state, required this.room});
  final AppState state;
  final Room room;

  @override
  Widget build(BuildContext context) {
    final person = state.personForRoom(room);
    if (person == null) return const SizedBox.shrink();
    final candidates = candidateNetworks(person, state.usableBridges);
    if (candidates.length < 2) return const SizedBox.shrink();
    final current = networkStyle(room.networkId);
    return PopupMenuButton<String>(
      key: const Key('composer-network'),
      tooltip: 'Send with another network',
      onSelected: (b) async {
        try {
          await state.openPerson(person, bridge: b);
        } catch (e) {
          if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
        }
      },
      itemBuilder: (_) => [
        for (final b in candidates)
          PopupMenuItem(
            value: b,
            enabled: (state.bridge(b)?.network ?? b) != room.networkId,
            child: Row(
              children: [
                Icon(networkStyle(state.bridge(b)?.network ?? b).icon, color: networkStyle(state.bridge(b)?.network ?? b).color, size: 18),
                const SizedBox(width: 8),
                Flexible(child: Text(state.bridge(b)?.displayName ?? networkStyle(b).label, overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Sending with ', style: TextStyle(color: CC.textFaint, fontSize: 12)),
          Icon(current.icon, color: current.color, size: 14),
          const SizedBox(width: 3),
          Text(current.label, style: const TextStyle(color: CC.textMuted, fontSize: 12)),
          const Icon(Icons.arrow_drop_down, color: CC.textMuted, size: 16),
        ],
      ),
    );
  }
}
