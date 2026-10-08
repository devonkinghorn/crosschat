import 'package:flutter/material.dart';

import '../daemon/daemon_client.dart';
import '../state/app_state.dart';
import 'add_network_dialog.dart';
import 'networks.dart';
import 'theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.state});
  final AppState state;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final _daemonUrl = TextEditingController(text: widget.state.settings.daemonUrl);
  late final _extractor = TextEditingController(text: widget.state.settings.extractorPath);

  AppState get s => widget.state;

  @override
  void dispose() {
    _daemonUrl.dispose();
    _extractor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final caps = s.capabilities;
        return Scaffold(
          appBar: AppBar(title: const Text('Settings'), backgroundColor: CC.sidebar),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  _section('Account'),
                  ListTile(
                    title: Text(s.session?.userId ?? '—'),
                    subtitle: Text(
                      'Device ${s.session?.deviceId ?? '—'} · ${s.session?.homeserver ?? ''} · ${s.backend.name}',
                      style: const TextStyle(color: CC.textMuted),
                    ),
                  ),
                  if (s.isLocalSession) ...[
                    _section('Server on this computer'),
                    ListTile(
                      key: const Key('local-server-info'),
                      leading: const Icon(Icons.computer_rounded, color: CC.accent),
                      title: const Text('localhost · this computer only'),
                      subtitle: FutureBuilder<String>(
                        future: s.localServer!.dataDir(),
                        builder: (context, snap) =>
                            Text('No federation; phones can\'t reach it. Data: ${snap.data ?? '…'}', style: const TextStyle(color: CC.textMuted)),
                      ),
                      trailing: OutlinedButton(
                        key: const Key('local-restart'),
                        onPressed: s.localStatus != null
                            ? null
                            : () async {
                                await s.retryLocalServer();
                                await s.connectDaemon();
                              },
                        child: Text(s.localStatus?.detail ?? 'Restart server'),
                      ),
                    ),
                    if (s.localError != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(s.localError!, style: const TextStyle(color: CC.danger, fontSize: 13)),
                      ),
                  ],
                  _section('Networks (crosschatd)'),
                  if (!s.isLocalSession)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              key: const Key('daemon-url'),
                              controller: _daemonUrl,
                              decoration: const InputDecoration(hintText: 'crosschatd URL (blank = same as homeserver)'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(onPressed: () => s.setDaemonUrl(_daemonUrl.text.trim()), child: const Text('Connect')),
                        ],
                      ),
                    ),
                  ListTile(
                    leading: Icon(s.daemonAvailable ? Icons.check_circle : Icons.cloud_off, color: s.daemonAvailable ? CC.success : CC.textFaint),
                    title: Text(s.daemonAvailable ? 'Connected to crosschatd' : 'crosschatd not reachable'),
                    subtitle: Text(
                      s.daemonAvailable
                          ? '${s.bridges.where((b) => b.running).length} of ${s.bridges.length} bridges running'
                          : 'Chats still work over plain Matrix; bridge login and contact search need crosschatd.',
                      style: const TextStyle(color: CC.textMuted),
                    ),
                  ),
                  for (final b in s.bridges.where((b) => b.enabled)) _bridgeTile(b),
                  if (s.daemonAvailable)
                    ListTile(
                      key: const Key('settings-add-network'),
                      leading: const Icon(Icons.add_circle_outline, color: CC.success),
                      title: const Text('Add network'),
                      subtitle: Text(
                        [
                          for (final b in s.bridges)
                            if (!b.enabled && b.hostSupported) b.displayName,
                        ].join(' · '),
                        style: const TextStyle(color: CC.textMuted),
                      ),
                      onTap: () => showAddNetwork(context, s),
                    ),
                  if (s.keepingAwake)
                    const ListTile(
                      key: Key('keeping-awake'),
                      dense: true,
                      leading: Icon(Icons.coffee_rounded, color: CC.textMuted, size: 18),
                      title: Text('Keeping this computer awake for iMessage (the screen can still turn off; closing the lid sleeps it).'),
                    ),
                  _section('Background sync'),
                  SwitchListTile(
                    key: const Key('persistent-sync'),
                    value: s.settings.persistentSync,
                    onChanged: caps.hasPersistentSyncService ? (v) => s.setPersistentSync(v) : null,
                    title: const Text('Keep connection open (Android)'),
                    subtitle: Text(
                      caps.hasPersistentSyncService
                          ? 'Runs a foreground service that keeps the Matrix sync connection open, so messages arrive without push. Shows a persistent notification and uses some battery.'
                          : 'Only available on Android. Push notifications are planned for the hosted tier.',
                      style: const TextStyle(color: CC.textMuted),
                    ),
                  ),
                  if (caps.canExtractAppleHardwareKey) ...[
                    _section('iMessage hardware key (macOS)'),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextField(
                        controller: _extractor,
                        decoration: const InputDecoration(helperText: 'Path to the upstream corten-matrix extract-key binary'),
                        onSubmitted: (v) {
                          s.settings.extractorPath = v.trim();
                          s.settings.save();
                        },
                      ),
                    ),
                  ],
                  _section('This device'),
                  _cap('Extract iMessage hardware key', caps.canExtractAppleHardwareKey),
                  _cap('Persistent sync service', caps.hasPersistentSyncService),
                  _cap('Embedded sign-in webview', caps.hasEmbeddedWebview),
                  const SizedBox(height: 24),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(foregroundColor: CC.danger),
                      icon: const Icon(Icons.logout),
                      label: const Text('Log out'),
                      onPressed: () async {
                        Navigator.of(context).pop();
                        await s.logout();
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _bridgeTile(BridgeInfo b) {
    final style = networkStyle(b.network);
    final status = b.processState ?? 'unknown';
    return ListTile(
      leading: Icon(style.icon, color: style.color),
      title: Row(
        children: [
          Text(b.displayName),
          if (b.maturity != 'stable') ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                border: Border.all(color: CC.warning),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(b.maturity, style: const TextStyle(color: CC.warning, fontSize: 10)),
            ),
          ],
        ],
      ),
      subtitle: Text(
        b.progress ?? b.setupError ?? '${b.enabled ? status : 'disabled'}${b.live == true ? ' · live' : ''}',
        style: TextStyle(color: b.setupError != null && b.progress == null ? CC.danger : CC.textMuted),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton.tonal(key: Key('connect-${b.id}'), onPressed: b.running ? () => showBridgeLogin(context, s, b) : null, child: const Text('Connect')),
          if (s.canManageNetworks)
            PopupMenuButton<String>(
              key: Key('network-menu-${b.id}'),
              tooltip: 'More',
              onSelected: (a) => _manage(b, a),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'disable', child: Text('Turn off (keeps sign-in and chats)')),
                PopupMenuItem(value: 'remove', child: Text('Remove… (signs out, deletes its data)')),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _manage(BridgeInfo b, String action) async {
    if (action == 'remove') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Remove ${b.displayName}?'),
          content: Text(
            'This signs out of ${b.displayName} and deletes the bridge\'s data on ${s.isLocalSession ? 'this computer' : 'the server'}. '
            'Chats already in Crosschat stay, but stop updating. You can add it again later.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              key: const Key('confirm-remove'),
              style: FilledButton.styleFrom(backgroundColor: CC.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      if (action == 'remove') {
        await s.removeNetwork(b.id);
      } else {
        await s.disableNetwork(b.id);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Widget _cap(String label, bool on) => ListTile(
    dense: true,
    leading: Icon(on ? Icons.check : Icons.remove, color: on ? CC.success : CC.textFaint, size: 18),
    title: Text(label),
  );

  Widget _section(String t) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
    child: Text(
      t.toUpperCase(),
      style: const TextStyle(color: CC.textMuted, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.5),
    ),
  );
}
