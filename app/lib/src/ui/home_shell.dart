import 'dart:async';

import 'package:flutter/material.dart';

import '../daemon/daemon_client.dart';
import '../models.dart';
import '../state/app_state.dart';
import '../state/network_groups.dart';
import 'add_network_dialog.dart';
import 'bridge_login_dialog.dart';
import 'channel_view.dart';
import 'networks.dart';
import 'saved_view.dart';
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

  void _openSettings(BuildContext context) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SettingsScreen(state: state)));

  void _newChat(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => NewChatDialog(state: state),
  );

  /// Phones: Saved is its own screen; opening an item pushes its chat.
  Future<void> _openSavedNarrow(BuildContext context) async {
    unawaited(state.openSaved());
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ListenableBuilder(
          listenable: state,
          builder: (context, _) => Scaffold(
            backgroundColor: CC.channel,
            body: SafeArea(
              child: SavedView(
                state: state,
                leading: const BackButton(color: CC.textMuted),
                onOpen: (item) async {
                  await state.selectRoom(item.roomId);
                  if (context.mounted) {
                    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _NarrowChannel(state: state)));
                  }
                },
              ),
            ),
          ),
        ),
      ),
    );
    state.closeSaved();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final narrow = c.maxWidth < 720;
        final rail = NetworkRail(
          state: state,
          onSettings: () => _openSettings(context),
          onNewChat: () => _newChat(context),
          onAddNetwork: () => state.daemonAvailable ? showAddNetwork(context, state) : _openSettings(context),
        );
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
                      onOpenSaved: () => _openSavedNarrow(context),
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
                child: ChatSidebar(state: state, onNewChat: () => _newChat(context), onOpenSaved: state.openSaved, onSelect: (r) => state.selectRoom(r.roomId)),
              ),
              Expanded(
                child: state.showingSaved
                    ? SavedView(state: state, onOpen: state.openSavedItem)
                    : showThread && !threadInline
                    ? ThreadPanel(state: state, onClose: state.closeThread)
                    : ChannelView(state: state, onOpenThread: (m) => state.openThread(m.eventId)),
              ),
              if (threadInline) ...[
                Container(width: 1, color: const Color(0xFF26282C)),
                SizedBox(
                  width: _threadWidth,
                  child: ThreadPanel(state: state, onClose: state.closeThread),
                ),
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
                        child: ThreadPanel(state: state, onClose: () => Navigator.of(context).pop()),
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
  const NetworkRail({super.key, required this.state, required this.onSettings, required this.onNewChat, this.onAddNetwork});
  final AppState state;
  final VoidCallback onSettings;
  final VoidCallback onNewChat;
  final VoidCallback? onAddNetwork;

  @override
  Widget build(BuildContext context) {
    final total = state.rooms.fold<int>(0, (a, r) => a + r.badgeCount);
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
                for (final g in state.networkGroups)
                  _RailItem(
                    key: Key('rail-${g.key}'),
                    tooltip: [g.label, if (g.subtitle?.isNotEmpty ?? false) g.subtitle!, if (g.status != null) g.status!].join('\n'),
                    selected: state.networkFilter == g.key,
                    unread: g.unread,
                    color: networkStyle(g.networkId).color,
                    busy: g.busy,
                    failing: g.failing,
                    onTap: () => state.setNetworkFilter(g.key),
                    child: Icon(networkStyle(g.networkId).icon, color: Colors.white),
                  ),
                _RailItem(
                  key: const Key('rail-add'),
                  tooltip: 'Add a network',
                  selected: false,
                  unread: 0,
                  color: CC.sidebar,
                  onTap: onAddNetwork ?? onSettings,
                  child: const Icon(Icons.add, color: CC.success),
                ),
              ],
            ),
          ),
          IconButton(
            key: const Key('open-settings'),
            tooltip: 'Settings',
            onPressed: onSettings,
            icon: const Icon(Icons.settings, color: CC.textMuted),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _RailItem extends StatefulWidget {
  const _RailItem({
    super.key,
    required this.tooltip,
    required this.selected,
    required this.unread,
    required this.color,
    required this.onTap,
    required this.child,
    this.busy = false,
    this.failing = false,
  });
  final String tooltip;
  final bool busy;
  final bool failing;
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
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.horizontal(right: Radius.circular(4)),
            ),
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
                      if (widget.busy)
                        const Positioned(
                          right: -3,
                          top: -3,
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(key: Key('rail-syncing'), strokeWidth: 2.2, color: Colors.white),
                          ),
                        ),
                      if (widget.failing)
                        Positioned(
                          right: -3,
                          top: -3,
                          child: Container(
                            key: const Key('rail-failing'),
                            width: 16,
                            height: 16,
                            decoration: BoxDecoration(
                              color: CC.warning,
                              shape: BoxShape.circle,
                              border: Border.all(color: CC.rail, width: 2),
                            ),
                            child: const Icon(Icons.priority_high, size: 10, color: Colors.black),
                          ),
                        ),
                      if (widget.unread > 0) Positioned(right: -4, bottom: -2, child: UnreadBadge(count: widget.unread)),
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
  const ChatSidebar({super.key, required this.state, required this.onSelect, required this.onNewChat, this.onOpenSaved});
  final AppState state;
  final void Function(Room room) onSelect;
  final VoidCallback onNewChat;

  /// The "Saved" entry (saved-for-later messages).
  final VoidCallback? onOpenSaved;

  @override
  Widget build(BuildContext context) {
    final rooms = state.visibleRooms;
    final groups = rooms.where((r) => !r.isDm).toList();
    final dms = rooms.where((r) => r.isDm).toList();
    final current = state.groupFor(state.networkFilter);
    final title = current?.label ?? 'All chats';
    final subtitle = current?.subtitle;
    // Status lines: the selected network's, or every network's in "All chats".
    final statusGroups = current != null ? [if (current.status != null) current] : state.networkGroups.where((g) => g.status != null).toList();
    return Container(
      color: CC.sidebar,
      child: Column(
        children: [
          Container(
            height: 52,
            padding: const EdgeInsets.only(left: 16, right: 4),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFF1F2023))),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: Colors.white),
                      ),
                      if (subtitle != null && subtitle.isNotEmpty)
                        Text(
                          subtitle,
                          key: const Key('network-subtitle'),
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11, color: CC.textMuted),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  key: const Key('new-chat'),
                  tooltip: 'New message',
                  onPressed: onNewChat,
                  icon: const Icon(Icons.edit_square, color: CC.textMuted, size: 20),
                ),
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
          for (final g in statusGroups) _NetworkStatusBanner(state: state, group: g, showName: current == null),
          if (onOpenSaved != null) _SavedEntry(count: state.saved.items.length, selected: state.showingSaved, onTap: onOpenSaved!),
          Expanded(
            child: rooms.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        current?.busy ?? false
                            ? 'Syncing your ${current!.label} chats. They appear here as they arrive.'
                            : 'No chats yet. Connect a network or start a new message.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: CC.textMuted),
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    children: [
                      if (groups.isNotEmpty) const _SectionLabel('Channels & groups'),
                      for (final r in groups)
                        _RoomTile(
                          room: r,
                          selected: !state.showingSaved && r.roomId == state.selectedRoomId,
                          showNetwork: state.networkFilter == null,
                          onTap: () => onSelect(r),
                          onMarkRead: () => state.markRead(r.roomId),
                          onMarkUnread: () => state.markUnread(r.roomId),
                        ),
                      if (dms.isNotEmpty) const _SectionLabel('Direct messages'),
                      for (final r in dms)
                        _RoomTile(
                          room: r,
                          selected: !state.showingSaved && r.roomId == state.selectedRoomId,
                          showNetwork: state.networkFilter == null,
                          onTap: () => onSelect(r),
                          onMarkRead: () => state.markRead(r.roomId),
                          onMarkUnread: () => state.markUnread(r.roomId),
                        ),
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
                      Text(
                        state.session?.userId ?? '',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white),
                      ),
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

/// "Syncing chats… 12 so far" / "Signed out. Sign in again." under the
/// sidebar header.
class _NetworkStatusBanner extends StatelessWidget {
  const _NetworkStatusBanner({required this.state, required this.group, required this.showName});
  final AppState state;
  final NetworkGroup group;
  final bool showName;

  @override
  Widget build(BuildContext context) {
    final g = group;
    final color = g.failing ? CC.warning : networkStyle(g.networkId).color;
    final bridge = state.bridges.where((b) => b.id == g.bridgeId).firstOrNull;
    final text = showName ? '${g.label}: ${g.status}' : g.status!;
    return Container(
      key: Key('network-status-${g.key}'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(6)),
      child: Row(
        children: [
          if (g.busy)
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
          else
            Icon(g.health == NetworkHealth.needsRelogin ? Icons.lock_outline : Icons.error_outline, size: 16, color: CC.warning),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 12.5))),
          if (g.health == NetworkHealth.needsRelogin && bridge != null && bridge.running)
            TextButton(key: Key('relogin-${g.key}'), onPressed: () => _relogin(context, bridge), child: const Text('Sign in')),
        ],
      ),
    );
  }

  void _relogin(BuildContext context, BridgeInfo bridge) => showDialog<void>(
    context: context,
    builder: (_) => BridgeLoginDialog(state: state, bridge: bridge),
  );
}

/// Sidebar entry for saved-for-later messages.
class _SavedEntry extends StatelessWidget {
  const _SavedEntry({required this.count, required this.selected, required this.onTap});
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
    child: Material(
      color: selected ? CC.selected : Colors.transparent,
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        key: const Key('saved-entry'),
        borderRadius: BorderRadius.circular(4),
        hoverColor: CC.hover,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              Icon(selected ? Icons.bookmark_rounded : Icons.bookmark_border_rounded, size: 18, color: selected ? Colors.white : CC.textMuted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Saved',
                  style: TextStyle(color: selected ? Colors.white : CC.textMuted, fontSize: 15, fontWeight: FontWeight.w500),
                ),
              ),
              if (count > 0)
                Text(
                  '$count',
                  key: const Key('saved-count'),
                  style: const TextStyle(color: CC.textFaint, fontSize: 12),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
    child: Text(
      label.toUpperCase(),
      style: const TextStyle(color: CC.textMuted, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.4),
    ),
  );
}

class _RoomTile extends StatelessWidget {
  const _RoomTile({
    required this.room,
    required this.selected,
    required this.showNetwork,
    required this.onTap,
    required this.onMarkRead,
    required this.onMarkUnread,
  });
  final Room room;
  final bool selected;
  final bool showNetwork;
  final VoidCallback onTap;
  final VoidCallback onMarkRead;
  final VoidCallback onMarkUnread;

  /// Right-click (desktop) / long-press (mobile) menu.
  Future<void> _showMenu(BuildContext context, Offset position) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(position & const Size(1, 1), Offset.zero & overlay.size),
      color: CC.panel,
      items: [
        if (room.isUnread)
          const PopupMenuItem(
            key: Key('menu-mark-read'),
            value: 'read',
            child: ListTile(dense: true, leading: Icon(Icons.mark_chat_read_outlined, size: 18), title: Text('Mark as read')),
          )
        else
          const PopupMenuItem(
            key: Key('menu-mark-unread'),
            value: 'unread',
            child: ListTile(dense: true, leading: Icon(Icons.mark_chat_unread_outlined, size: 18), title: Text('Mark as unread')),
          ),
      ],
    );
    if (choice == 'read') onMarkRead();
    if (choice == 'unread') onMarkUnread();
  }

  @override
  Widget build(BuildContext context) {
    final style = networkStyle(room.networkId);
    final bold = room.isUnread;
    final sub = room.subProtocol;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: selected ? CC.selected : Colors.transparent,
        borderRadius: BorderRadius.circular(4),
        child: GestureDetector(
          onSecondaryTapDown: (d) => _showMenu(context, d.globalPosition),
          onLongPressStart: (d) => _showMenu(context, d.globalPosition),
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
                            decoration: BoxDecoration(
                              color: style.color,
                              shape: BoxShape.circle,
                              border: Border.all(color: CC.sidebar, width: 2),
                            ),
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
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                room.name,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                                  color: bold || selected ? Colors.white : CC.textMuted,
                                ),
                              ),
                            ),
                            if (sub != null) ...[
                              const SizedBox(width: 6),
                              Container(
                                key: Key('subprotocol-${room.roomId}'),
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0.5),
                                decoration: BoxDecoration(
                                  border: Border.all(color: CC.textFaint),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                                child: Text(
                                  sub,
                                  style: const TextStyle(fontSize: 9.5, color: CC.textMuted, fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ],
                        ),
                        if (room.lastMessage != null)
                          Text(
                            room.lastMessage!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12, color: CC.textFaint),
                          ),
                      ],
                    ),
                  ),
                  if (room.unread > 0)
                    UnreadBadge(key: Key('unread-${room.roomId}'), count: room.unread)
                  else if (room.markedUnread)
                    Container(
                      key: Key('marked-unread-${room.roomId}'),
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(color: CC.danger, shape: BoxShape.circle),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
