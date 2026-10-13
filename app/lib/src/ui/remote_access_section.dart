import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../local/local_server.dart';
import 'theme.dart';

/// Settings → Server on this computer → "Allow access from other devices":
/// lets a phone use this server through the user's own HTTPS reverse proxy.
class RemoteAccessSection extends StatefulWidget {
  const RemoteAccessSection({super.key, required this.local, required this.userId});
  final LocalServerController local;

  /// The account to sign in with on the phone (e.g. `@devon:localhost`).
  final String? userId;

  @override
  State<RemoteAccessSection> createState() => _RemoteAccessSectionState();
}

class _RemoteAccessSectionState extends State<RemoteAccessSection> {
  final _publicUrl = TextEditingController();
  RemoteAccessStatus? _status;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _publicUrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final s = await widget.local.remoteAccess();
      if (!mounted) return;
      setState(() {
        _status = s;
        _error = null;
        _publicUrl.text = s.publicUrl ?? '';
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _apply({required bool enabled}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final s = await widget.local.setRemoteAccess(enabled: enabled, publicUrl: _publicUrl.text.trim());
      if (!mounted) return;
      setState(() {
        _status = s;
        _publicUrl.text = s.publicUrl ?? '';
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    final on = s?.enabled ?? false;
    const muted = TextStyle(color: CC.textMuted, fontSize: 13);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: const Key('remote-access-switch'),
          value: on,
          onChanged: s == null || _busy ? null : (v) => _apply(enabled: v),
          title: const Text('Allow access from other devices'),
          subtitle: const Text(
            'Lets your phone use this server through your own HTTPS reverse proxy. Only the Matrix client API is shared; '
            'the bridges stay on this computer.',
            style: muted,
          ),
        ),
        if (_error != null || s?.error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              s?.error ?? _error!,
              key: const Key('remote-access-error'),
              style: const TextStyle(color: CC.danger, fontSize: 13),
            ),
          ),
        if (s != null && on) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
              s.listening != null ? 'Listening on port ${s.port} (plain HTTP). Point your reverse proxy at:' : 'Not listening (port ${s.port}).',
              style: muted,
            ),
          ),
          for (final t in s.proxyTargets)
            ListTile(
              key: Key('remote-target-$t'),
              dense: true,
              leading: const Icon(Icons.lan_rounded, size: 18, color: CC.accent),
              title: SelectableText(t, style: const TextStyle(fontFamily: 'monospace')),
              trailing: IconButton(
                tooltip: 'Copy',
                icon: const Icon(Icons.copy_rounded, size: 18),
                onPressed: () => Clipboard.setData(ClipboardData(text: t)),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('remote-public-url'),
                    controller: _publicUrl,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'Public URL (optional)',
                      hintText: 'https://matrix.example.com',
                      helperText: 'The HTTPS address of your proxy. Served at /.well-known/matrix/client.',
                    ),
                    onSubmitted: (_) => _apply(enabled: true),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(key: const Key('remote-public-url-save'), onPressed: _busy ? null : () => _apply(enabled: true), child: const Text('Save')),
              ],
            ),
          ),
          ListTile(
            key: const Key('remote-phone-login'),
            dense: true,
            leading: const Icon(Icons.phone_android_rounded, size: 18, color: CC.textMuted),
            title: Text(
              'On your phone: "Use an existing Matrix server", homeserver ${s.publicUrl ?? 'https://<your proxy>'}, '
              'username ${widget.userId ?? '@you:${s.serverName}'} and this account\'s password.',
              style: muted,
            ),
          ),
          const ListTile(
            key: Key('remote-awake-warning'),
            dense: true,
            leading: Icon(Icons.coffee_rounded, size: 18, color: CC.warning),
            title: Text(
              'This computer must stay on and awake for your phone to connect. Crosschat keeps it from idle-sleeping while this is on; '
              'closing the lid still sleeps it.',
              style: muted,
            ),
          ),
          const ListTile(
            dense: true,
            leading: Icon(Icons.shield_outlined, size: 18, color: CC.textMuted),
            title: Text(
              'If macOS asks whether crosschatd may accept incoming network connections, choose Allow. '
              'Only expose it through HTTPS on your proxy; don\'t forward this port on your router.',
              style: muted,
            ),
          ),
        ],
      ],
    );
  }
}
