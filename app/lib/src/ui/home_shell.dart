import 'package:flutter/material.dart';

import '../models.dart';
import '../state/app_state.dart';
import 'channel_view.dart';
import 'networks.dart';
import 'new_chat_dialog.dart';
import 'settings_screen.dart';
import 'theme.dart';
import 'thread_panel.dart';
import 'widgets.dart';

const _railWidth = 72.0;
const _sidebarWidth = 260.0;
const _threadWidth = 380.0;

/// Slack/Discord layout: network rail | chat sidebar | channel | thread panel.
/// On narrow screens (phones) the channel and thread push as routes.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key, required this.state});
  final AppState state;

  void _openSettings(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SettingsScreen(state: state)));

  void _newChat(BuildContext context) => showDialog<void>(context: context, builder: (_) => NewChatDialog(state: state));

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final narrow = c.maxWidth < 720;
        final rail = NetworkRail(state: state, onSettings: () => _openSettings(context), onNewChat: () => _newChat(context));
        if (narrow) {
          return Scaffold(
            backgroundColor: CC.rail,
            body: SafeArea(
              child: Row(
                children: [
                  rail,
                  Expanded(
                    child: ChatSidebar(
                      state: state,
                      onNewChat: () => _newChat(context),
                      onSelect: (room) async {
                        await state.selectRoom(room.roomId);
                        if (context.mounted) {
                          Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _NarrowChannel(state: state)));
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        final showThread = state.openThreadRoot != null;
        final threadInline = showThread && c.maxWidth >= _railWidth + _sidebarWidth + 420 + _threadWidth;
        return Scaffold(
          backgroundColor: CC.channel,
          body: Row(
            children: [
              rail,
              SizedBox(
                width: _sidebarWidth,
                child: ChatSidebar(state: state, onNewChat: () => _newChat(context), onSelect: (r) => state.selectRoom(r.roomId)),
              ),
              Expanded(
                child: showThread && !threadInline
                    ? ThreadPanel(state: state, onClose: state.closeThread)
                    : ChannelView(state: state, onOpenThread: (m) => state.openThread(m.eventId)),
              ),
              if (threadInline) ...[
                Container(width: 1, color: const Color(0xFF26282C)),
                SizedBox(width: _threadWidth, child: ThreadPanel(state: state, onClose: state.closeThread)),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _NarrowChannel extends StatelessWidget {
  const _NarrowChannel({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) => Scaffold(
      backgroundColor: CC.channel,
      body: SafeArea(
        child: ChannelView(
          state: state,
          leading: const BackButton(color: CC.textMuted),
          onOpenThread: (m) async {
            await state.openThread(m.eventId);
            if (context.mounted) {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ListenableBuilder(
                    listenable: state,
                    builder: (context, _) => Scaffold(
                      body: SafeArea(
                        child: ThreadPanel(
                          state: state,
                          onClose: () => Navigator.of(context).pop(),
                        ),
                      ),
                    ),
                  ),
                ),
              );
              state.closeThread();
            }
          },
        ),
      ),
    ),
  );
}

class NetworkRail extends StatelessWidget {
  const NetworkRail({super.key, required this.state, required this.onSettings, required this.onNewChat});
  final AppState state;
  final VoidCallback onSettings;
  final VoidCallback onNewChat;

  @override
  Widget build(BuildContext context) {
    final total = state.rooms.fold<int>(0, (a, r) => a + r.unread);
    return Container(
      width: _railWidth,
      color: CC.rail,
      child: Column(
        children: [
          const SizedBox(height: 12),
          _RailItem(
            key: const Key('rail-all'),
            tooltip: 'All chats',
            selected: state.networkFilter == null,
            unread: total,
            color: CC.accent,
            onTap: () => state.setNetworkFilter(null),
            child: const Icon(Icons.forum_rounded, color: Colors.white),
          ),
          Container(margin: const EdgeInsets.symmetric(vertical: 8), width: 32, height: 2, color: CC.divider),
          Expanded(
            child: ListView(
              children: [
                for (final n in state.networks)
                  _RailItem(
                    key: Key('rail-$n'),
                    tooltip: networkStyle(n).label,
                    selected: state.networkFilter == n,
                    unread: state.unreadFor(n),
                    color: networkStyle(n).color,
                    onTap: () => state.setNetworkFilter(n),
                    child: Icon(networkStyle(n).icon, color: Colors.white),
                  ),
                _RailItem(
                  key: const Key('rail-add'),
                  tooltip: 'Connect a network',
                  selected: false,
                  unread: 0,
                  color: CC.sidebar,
                  onTap: onSettings,
                  child: const Icon(Icons.add, color: CC.success),
                ),
              ],
            ),
          ),
          IconButton(key: const Key('open-settings'), tooltip: 'Settings', onPressed: onSettings, icon: const Icon(Icons.settings, color: CC.textMuted)),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _RailItem extends StatefulWidget {
  const _RailItem({super.key, required this.tooltip, required this.selected, required this.unread, required this.color, required this.onTap, required this.child});
  final String tooltip;
  final bool selected;
  final int unread;
  final Color color;
  final VoidCallback onTap;
  final Widget child;

  @override
  State<_RailItem> createState() => _RailItemState();
}

class _RailItemState extends State<_RailItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.selected || _hover;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.centerLeft,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 4,
            height: widget.selected ? 40 : (_hover ? 20 : (widget.unread > 0 ? 8 : 0)),
            decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.horizontal(right: Radius.circular(4))),
          ),
          Center(
            child: Tooltip(
              message: widget.tooltip,
              preferBelow: false,
              child: MouseRegion(
                onEnter: (_) => setState(() => _hover = true),
                onExit: (_) => setState(() => _hover = false),
                child: GestureDetector(
                  onTap: widget.onTap,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: active ? widget.color : Color.lerp(widget.color, CC.sidebar, 0.45),
                          borderRadius: BorderRadius.circular(active ? 16 : 24),
                        ),
                        child: Center(child: widget.child),
                      ),
                      if (widget.unread > 0)
                        Positioned(right: -4, bottom: -2, child: UnreadBadge(count: widget.unread)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ChatSidebar extends StatelessWidget {
  const ChatSidebar({super.key, required this.state, required this.onSelect, required this.onNewChat});
  final AppState state;
  final void Function(Room room) onSelect;
  final VoidCallback onNewChat;

  @override
  Widget build(BuildContext context) {
    final rooms = state.visibleRooms;
    final groups = rooms.where((r) => !r.isDm).toList();
    final dms = rooms.where((r) => r.isDm).toList();
    final title = state.networkFilter == null ? 'All chats' : networkStyle(state.networkFilter).label;
    return Container(
      color: CC.sidebar,
      child: Column(
        children: [
          Container(
            height: 52,
            padding: const EdgeInsets.only(left: 16, right: 4),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFF1F2023)))),
            child: Row(
              children: [
                Expanded(child: Text(title, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: Colors.white))),
                IconButton(key: const Key('new-chat'), tooltip: 'New message', onPressed: onNewChat, icon: const Icon(Icons.edit_square, color: CC.textMuted, size: 20)),
              ],
            ),
          ),
          if (state.syncState == 'error')
            Container(
              width: double.infinity,
              color: CC.danger.withValues(alpha: 0.2),
              padding: const EdgeInsets.all(6),
              child: const Text('Sync error, retrying…', style: TextStyle(fontSize: 12)),
            ),
          Expanded(
            child: rooms.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('No chats yet. Connect a network or start a new message.', textAlign: TextAlign.center, style: TextStyle(color: CC.textMuted)),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    children: [
                      if (groups.isNotEmpty) const _SectionLabel('Channels & groups'),
                      for (final r in groups) _RoomTile(room: r, selected: r.roomId == state.selectedRoomId, showNetwork: state.networkFilter == null, onTap: () => onSelect(r)),
                      if (dms.isNotEmpty) const _SectionLabel('Direct messages'),
                      for (final r in dms) _RoomTile(room: r, selected: r.roomId == state.selectedRoomId, showNetwork: state.networkFilter == null, onTap: () => onSelect(r)),
                    ],
                  ),
          ),
          Container(
            color: const Color(0xFF232428),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                Avatar(name: state.session?.userId ?? '?', seed: state.session?.userId, size: 32),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(state.session?.userId ?? '', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white)),
                      Text(
                        state.daemonAvailable ? 'crosschatd connected' : 'Matrix only',
                        style: TextStyle(fontSize: 11, color: state.daemonAvailable ? CC.success : CC.textFaint),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
    child: Text(label.toUpperCase(), style: const TextStyle(color: CC.textMuted, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
  );
}

class _RoomTile extends StatelessWidget {
  const _RoomTile({required this.room, required this.selected, required this.showNetwork, required this.onTap});
  final Room room;
  final bool selected;
  final bool showNetwork;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final style = networkStyle(room.networkId);
    final bold = room.unread > 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: selected ? CC.selected : Colors.transparent,
        borderRadius: BorderRadius.circular(4),
        child: InkWell(
          key: Key('room-${room.roomId}'),
          borderRadius: BorderRadius.circular(4),
          hoverColor: CC.hover,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    room.isDm
                        ? Avatar(name: room.name, seed: room.roomId, size: 30)
                        : Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(color: CC.input, borderRadius: BorderRadius.circular(8)),
                            child: const Icon(Icons.tag_rounded, color: CC.textMuted, size: 18),
                          ),
                    if (showNetwork)
                      Positioned(
                        right: -4,
                        bottom: -4,
                        child: Container(
                          width: 16,
                          height: 16,
                          decoration: BoxDecoration(color: style.color, shape: BoxShape.circle, border: Border.all(color: CC.sidebar, width: 2)),
                          child: Icon(style.icon, size: 8, color: Colors.white),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        room.name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14.5, fontWeight: bold ? FontWeight.w700 : FontWeight.w500, color: bold || selected ? Colors.white : CC.textMuted),
                      ),
                      if (room.lastMessage != null)
                        Text(room.lastMessage!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: CC.textFaint)),
                    ],
                  ),
                ),
                if (room.unread > 0) UnreadBadge(count: room.unread),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
