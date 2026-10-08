import 'dart:async';

import 'package:flutter/material.dart';

import '../contacts/device_contacts.dart';
import '../contacts/people.dart';
import '../daemon/daemon_client.dart';
import '../models.dart';
import '../state/app_state.dart';
import 'networks.dart';
import 'theme.dart';
import 'widgets.dart';

/// One search box across every connected network: the device's contacts
/// (when allowed) merged with people found on the networks (crosschatd:
/// bridgev2 search_users / resolve_identifier), plus plain Matrix users from
/// the user directory. Picking a person opens or creates the DM on their
/// network: the one chosen for them before, else iMessage when it reaches
/// them, else Google Messages. Degrades to Matrix-only without crosschatd.
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

  /// Default network per person key, once worked out (null = none).
  final Map<String, String?> _defaults = {};
  final Set<String> _resolving = {};
  String? _opening;

  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    s.loadDeviceContacts();
    s.loadNetworkPrefs().then((_) {
      if (mounted) setState(() {});
    });
  }

  List<Person> get _people {
    final q = _query.text.trim();
    final all = mergePeople(s.deviceContactList, _contacts, callingCode: s.callingCode);
    final out = [
      for (final p in all)
        if (p.matches(q) || p.bridgeContacts.isNotEmpty) p,
    ];
    // A number or email nobody has yet: offer to message it directly.
    final typed = q.isEmpty ? null : identifierKey(q, callingCode: s.callingCode);
    if (typed != null && !out.any((p) => p.identifiers.contains(typed))) {
      out.insert(0, Person(key: typed, name: typed.replaceFirst(RegExp('^(tel|mailto):'), ''), identifiers: {typed}));
    }
    return out;
  }

  /// Work out the default network for the first few results in the
  /// background (iMessage reachability needs a lookup per person).
  void _resolveDefaults(List<Person> people) {
    if (!s.daemonAvailable) return;
    for (final p in people.take(8)) {
      if (_defaults.containsKey(p.key) || _resolving.contains(p.key)) continue;
      _resolving.add(p.key);
      s
          .networkFor(p)
          .then(
            (b) {
              _resolving.remove(p.key);
              if (mounted) setState(() => _defaults[p.key] = b);
            },
            onError: (Object _) {
              _resolving.remove(p.key);
            },
          );
    }
  }

  String? _networkOf(Person p) => s.networkPrefs.byContact[p.key] ?? _defaults[p.key];

  Future<void> _openPerson(Person p) async {
    if (_opening != null) return;
    setState(() {
      _opening = p.key;
      _error = null;
    });
    try {
      await s.openPerson(p);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not start chat: $e');
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  Future<void> _pickNetwork(Person p, String bridge) async {
    await s.setNetworkFor(p, bridge);
    if (mounted) setState(() => _defaults[p.key] = bridge);
  }

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
        s.daemon!
            .search(q)
            .then((r) {
              _contacts = r.results;
              _bridgeErrors = r.errors;
            })
            .catchError((Object e) {
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
    return ListenableBuilder(listenable: s, builder: (context, _) => _build(context));
  }

  Widget _build(BuildContext context) {
    final people = _groupMode ? const <Person>[] : _people;
    if (_query.text.trim().isNotEmpty) _resolveDefaults(people);
    const maxShown = 200;
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
                    : 'Pick a contact, or search names, phone numbers, emails or Matrix IDs across every network.',
                style: const TextStyle(color: CC.textMuted, fontSize: 13),
              ),
              const SizedBox(height: 12),
              if (_groupMode) ...[
                TextField(
                  controller: _groupName,
                  decoration: const InputDecoration(hintText: 'Group name'),
                ),
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
                  suffixIcon: _searching
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                        )
                      : null,
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
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!, style: const TextStyle(color: CC.danger)),
                ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView(
                  children: [
                    if (!_groupMode) ...[
                      if (s.contactsAccess == ContactsAccess.notDetermined) _contactsPrompt(),
                      if (s.contactsAccess == ContactsAccess.denied && _query.text.isEmpty)
                        const Padding(
                          key: Key('contacts-denied'),
                          padding: EdgeInsets.fromLTRB(8, 8, 8, 0),
                          child: Text(
                            'Contacts access is off, so only people found on your networks show up. You can allow it in the system settings (Privacy → Contacts).',
                            style: TextStyle(color: CC.textFaint, fontSize: 12),
                          ),
                        ),
                      if (people.isNotEmpty) _header(_query.text.isEmpty ? 'Contacts' : 'People', CC.accent),
                      for (final p in people.take(maxShown)) _personTile(p),
                      if (people.length > maxShown)
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text('${people.length - maxShown} more. Type to search.', style: const TextStyle(color: CC.textFaint, fontSize: 12)),
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
                        trailing: _groupMode ? Checkbox(value: _selected.contains(u.userId), onChanged: (_) => _openMatrix(u)) : null,
                        onTap: () => _openMatrix(u),
                      ),
                    if (_query.text.isNotEmpty && !_searching && people.isEmpty && _matrixUsers.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'No matches yet. Try a phone number in international format (+1…) or a full Matrix ID.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: CC.textMuted),
                        ),
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

  Widget _contactsPrompt() => Container(
    key: const Key('contacts-prompt'),
    margin: const EdgeInsets.only(top: 6),
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(color: CC.input, borderRadius: BorderRadius.circular(6)),
    child: Row(
      children: [
        const Icon(Icons.contacts_rounded, color: CC.textMuted, size: 18),
        const SizedBox(width: 8),
        const Expanded(child: Text('Show your contacts here? They stay on this device.', style: TextStyle(fontSize: 12.5))),
        TextButton(key: const Key('contacts-allow'), onPressed: () => s.loadDeviceContacts(ask: true), child: const Text('Allow')),
      ],
    ),
  );

  Widget _personTile(Person p) {
    final candidates = candidateNetworks(p, s.usableBridges);
    final network = _networkOf(p);
    final resolving = _resolving.contains(p.key) || _opening == p.key;
    final style = network == null ? null : networkStyle(s.bridge(network)?.network ?? network);
    return ListTile(
      key: Key('person-${p.key}'),
      dense: true,
      leading: Avatar(name: p.name, seed: p.key, size: 32),
      title: Text(p.name),
      subtitle: Text(p.subtitle, style: const TextStyle(color: CC.textMuted)),
      trailing: candidates.isEmpty
          ? const Text('Not on a connected network', style: TextStyle(color: CC.textFaint, fontSize: 11))
          : PopupMenuButton<String>(
              key: Key('person-network-${p.key}'),
              tooltip: 'Send with…',
              onSelected: (b) => _pickNetwork(p, b),
              itemBuilder: (_) => [
                for (final b in candidates)
                  PopupMenuItem(
                    value: b,
                    child: Row(
                      children: [
                        Icon(networkStyle(s.bridge(b)?.network ?? b).icon, color: networkStyle(s.bridge(b)?.network ?? b).color, size: 18),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            '${s.bridge(b)?.displayName ?? networkStyle(b).label}'
                            '${b == 'imessage' && s.imessageReachableCached(p) == false ? ' · not on iMessage' : ''}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (resolving)
                      const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    else if (style != null) ...[
                      Icon(style.icon, color: style.color, size: 16),
                      const SizedBox(width: 4),
                      Text(style.label, style: const TextStyle(color: CC.textMuted, fontSize: 12)),
                    ] else
                      const Text('Auto', style: TextStyle(color: CC.textMuted, fontSize: 12)),
                    const Icon(Icons.arrow_drop_down, color: CC.textMuted, size: 18),
                  ],
                ),
              ),
            ),
      onTap: candidates.isEmpty ? null : () => _openPerson(p),
    );
  }

  Widget _header(String label, Color color) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
    child: Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label.toUpperCase(),
          style: const TextStyle(color: CC.textMuted, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5),
        ),
      ],
    ),
  );
}
