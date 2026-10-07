import 'dart:async';

import 'package:flutter/material.dart';

import '../daemon/daemon_client.dart';
import '../models.dart';
import '../state/app_state.dart';
import 'networks.dart';
import 'theme.dart';
import 'widgets.dart';

/// One search box across every connected network. Bridge contacts come from
/// crosschatd's provisioning proxy (bridgev2 search_users /
/// resolve_identifier / create_dm); plain Matrix users come from the user
/// directory. Degrades to Matrix-only when crosschatd is unreachable.
class NewChatDialog extends StatefulWidget {
  const NewChatDialog({super.key, required this.state});
  final AppState state;

  @override
  State<NewChatDialog> createState() => _NewChatDialogState();
}

class _NewChatDialogState extends State<NewChatDialog> {
  final _query = TextEditingController();
  final _groupName = TextEditingController();
  Timer? _debounce;
  bool _searching = false;
  String? _error;
  List<Contact> _contacts = [];
  Map<String, String> _bridgeErrors = {};
  List<DirectoryUser> _matrixUsers = [];
  final Set<String> _selected = {};
  bool _groupMode = false;

  AppState get s => widget.state;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    _groupName.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(q));
  }

  Future<void> _search(String q) async {
    q = q.trim();
    if (q.isEmpty) {
      setState(() {
        _contacts = [];
        _matrixUsers = [];
      });
      return;
    }
    setState(() {
      _searching = true;
      _error = null;
    });
    final futures = <Future<void>>[];
    if (s.daemonAvailable && s.daemon != null) {
      futures.add(
        s.daemon!.search(q).then((r) {
          _contacts = r.results;
          _bridgeErrors = r.errors;
        }).catchError((Object e) {
          _contacts = [];
          _bridgeErrors = {'crosschatd': '$e'};
        }),
      );
    }
    futures.add(
      s.backend.searchDirectory(q).then((u) => _matrixUsers = u).catchError((Object e) {
        _matrixUsers = [];
        return <DirectoryUser>[];
      }),
    );
    // Allow typing a full MXID directly.
    await Future.wait(futures);
    if (q.startsWith('@') && q.contains(':') && !_matrixUsers.any((u) => u.userId == q)) {
      _matrixUsers = [DirectoryUser(userId: q), ..._matrixUsers];
    }
    if (mounted) setState(() => _searching = false);
  }

  Future<void> _openContact(Contact c) async {
    try {
      final roomId = c.dmRoomMxid ?? await s.daemon!.createDm(c.bridge, c.id);
      if (roomId == null) throw Exception('bridge did not return a room');
      await s.openPortal(roomId);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = 'Could not start chat: $e');
    }
  }

  Future<void> _openMatrix(DirectoryUser u) async {
    if (_groupMode) {
      setState(() => _selected.contains(u.userId) ? _selected.remove(u.userId) : _selected.add(u.userId));
      return;
    }
    try {
      await s.openOrCreateDm(u.userId);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = 'Could not start chat: $e');
    }
  }

  Future<void> _createGroup() async {
    final name = _groupName.text.trim();
    if (name.isEmpty) return;
    try {
      final id = await s.backend.createGroup(name, _selected.toList());
      await s.refreshRooms();
      await s.selectRoom(id);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = 'Could not create group: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final byNetwork = <String, List<Contact>>{};
    for (final c in _contacts) {
      byNetwork.putIfAbsent(c.network, () => []).add(c);
    }
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(_groupMode ? 'New group' : 'New message', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  TextButton.icon(
                    icon: Icon(_groupMode ? Icons.person : Icons.group_add),
                    label: Text(_groupMode ? 'Direct message' : 'Group'),
                    onPressed: () => setState(() => _groupMode = !_groupMode),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                _groupMode
                    ? 'Pick Matrix users for a new group room. Bridged group creation comes later.'
                    : 'Search names, phone numbers, emails or Matrix IDs across every network.',
                style: const TextStyle(color: CC.textMuted, fontSize: 13),
              ),
              const SizedBox(height: 12),
              if (_groupMode) ...[
                TextField(controller: _groupName, decoration: const InputDecoration(hintText: 'Group name')),
                const SizedBox(height: 8),
              ],
              TextField(
                key: const Key('new-chat-search'),
                controller: _query,
                autofocus: true,
                onChanged: _onChanged,
                onSubmitted: _search,
                decoration: InputDecoration(
                  hintText: 'Who do you want to talk to?',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searching ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))) : null,
                ),
              ),
              if (!s.daemonAvailable)
                Container(
                  key: const Key('daemon-unavailable'),
                  margin: const EdgeInsets.only(top: 10),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: CC.warning.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6)),
                  child: const Row(
                    children: [
                      Icon(Icons.info_outline, color: CC.warning, size: 18),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Bridge contact search is unavailable (crosschatd not reachable). Showing Matrix users only.',
                          style: TextStyle(fontSize: 12.5),
                        ),
                      ),
                    ],
                  ),
                ),
              if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: CC.danger))),
              const SizedBox(height: 8),
              Expanded(
                child: ListView(
                  children: [
                    if (!_groupMode)
                      for (final entry in byNetwork.entries) ...[
                        _header(networkStyle(entry.key).label, networkStyle(entry.key).color),
                        for (final c in entry.value)
                          ListTile(
                            dense: true,
                            leading: Avatar(name: c.name ?? c.id, seed: c.id, size: 32),
                            title: Text(c.name ?? c.id),
                            subtitle: Text(c.identifiers.isNotEmpty ? c.identifiers.join(', ') : c.id, style: const TextStyle(color: CC.textMuted)),
                            trailing: Icon(networkStyle(c.network).icon, color: networkStyle(c.network).color, size: 18),
                            onTap: () => _openContact(c),
                          ),
                      ],
                    if (_bridgeErrors.isNotEmpty && !_groupMode)
                      for (final e in _bridgeErrors.entries)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                          child: Text('${networkStyle(e.key).label}: ${e.value}', style: const TextStyle(color: CC.textFaint, fontSize: 12)),
                        ),
                    if (_matrixUsers.isNotEmpty) _header('Matrix', networkStyle('matrix').color),
                    for (final u in _matrixUsers)
                      ListTile(
                        dense: true,
                        leading: Avatar(name: u.displayName ?? u.userId, seed: u.userId, size: 32),
                        title: Text(u.displayName ?? u.userId),
                        subtitle: Text(u.userId, style: const TextStyle(color: CC.textMuted)),
                        trailing: _groupMode
                            ? Checkbox(value: _selected.contains(u.userId), onChanged: (_) => _openMatrix(u))
                            : null,
                        onTap: () => _openMatrix(u),
                      ),
                    if (_query.text.isNotEmpty && !_searching && _contacts.isEmpty && _matrixUsers.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('No matches yet. Try a phone number in international format (+1…) or a full Matrix ID.', textAlign: TextAlign.center, style: TextStyle(color: CC.textMuted)),
                      ),
                  ],
                ),
              ),
              if (_groupMode)
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(onPressed: _createGroup, child: Text('Create group (${_selected.length})')),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(String label, Color color) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
    child: Row(
      children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label.toUpperCase(), style: const TextStyle(color: CC.textMuted, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
      ],
    ),
  );
}
