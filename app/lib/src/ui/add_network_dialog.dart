import 'package:flutter/material.dart';

import '../daemon/daemon_client.dart';
import '../state/app_state.dart';
import 'bridge_login_dialog.dart';
import 'networks.dart';
import 'theme.dart';

/// "Add network" from the rail's + or Settings: pick a network, crosschatd
/// sets it up on the server, then its sign-in opens.
Future<void> showAddNetwork(BuildContext context, AppState state) async {
  final ready = await showDialog<BridgeInfo>(
    context: context,
    builder: (_) => AddNetworkDialog(state: state),
  );
  if (ready != null && context.mounted) await showBridgeLogin(context, state, ready);
}

Future<void> showBridgeLogin(BuildContext context, AppState state, BridgeInfo bridge) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => BridgeLoginDialog(state: state, bridge: bridge),
);

const _osNames = {'macos': 'a Mac', 'linux': 'Linux'};

/// Every network crosschatd has a manifest for. Adding one installs the
/// prebuilt bridge (checksum pinned), configures it, registers it with the
/// homeserver and starts it; the dialog then closes with the ready bridge.
class AddNetworkDialog extends StatefulWidget {
  const AddNetworkDialog({super.key, required this.state});
  final AppState state;

  @override
  State<AddNetworkDialog> createState() => _AddNetworkDialogState();
}

class _AddNetworkDialogState extends State<AddNetworkDialog> {
  String? _adding;
  final Map<String, String> _errors = {};

  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    s.refreshBridges().catchError((_) {});
  }

  Future<void> _add(BridgeInfo b) async {
    setState(() {
      _adding = b.id;
      _errors.remove(b.id);
    });
    try {
      final ready = await s.enableNetwork(b.id);
      if (mounted) Navigator.pop(context, ready);
    } catch (e) {
      if (mounted) setState(() => _errors[b.id] = '$e');
    } finally {
      if (mounted) setState(() => _adding = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final list = [...s.bridges]..sort((a, b) => (a.hostSupported == b.hostSupported) ? 0 : (a.hostSupported ? -1 : 1));
        return Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Add a network', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(
                    s.isLocalSession
                        ? 'Each network runs as a bridge on this computer. Nothing to install by hand.'
                        : 'Each network runs as a bridge on your Crosschat server.',
                    style: const TextStyle(color: CC.textMuted, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  if (!s.daemonAvailable)
                    const Padding(
                      key: Key('add-network-offline'),
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('crosschatd isn\'t reachable, so networks can\'t be added right now.', style: TextStyle(color: CC.warning)),
                    )
                  else
                    Flexible(child: ListView(shrinkWrap: true, children: [for (final b in list) _tile(b)])),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _tile(BridgeInfo b) {
    final style = networkStyle(b.network);
    final busy = _adding == b.id || b.progress != null;
    final err = _errors[b.id] ?? (b.enabled && !busy ? b.setupError : null);
    final String status;
    if (busy) {
      status = b.progress ?? 'Starting…';
    } else if (!b.hostSupported) {
      status = 'Needs a server on ${b.hostPlatforms.map((p) => _osNames[p] ?? p).join(' or ')}.';
    } else if (b.enabled) {
      status = b.ready ? 'Added. Sign in to start syncing.' : (b.running ? 'Starting…' : (b.processState ?? 'Not running'));
    } else {
      status = b.description ?? '';
    }
    final Widget trailing;
    if (busy) {
      trailing = const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2));
    } else if (!b.hostSupported) {
      trailing = const Text('Unavailable', style: TextStyle(color: CC.textFaint));
    } else if (b.enabled) {
      trailing = FilledButton.tonal(
        key: Key('add-network-signin-${b.id}'),
        onPressed: b.ready ? () => Navigator.pop(context, b) : null,
        child: const Text('Sign in'),
      );
    } else if (!s.canManageNetworks) {
      trailing = const Text('Ask your server admin', style: TextStyle(color: CC.textFaint, fontSize: 12));
    } else {
      trailing = FilledButton(key: Key('add-network-${b.id}'), onPressed: _adding == null ? () => _add(b) : null, child: const Text('Add'));
    }
    return Opacity(
      opacity: b.hostSupported ? 1 : 0.5,
      child: Card(
        color: CC.input,
        child: ListTile(
          leading: Icon(style.icon, color: style.color),
          title: Row(
            children: [
              Flexible(child: Text(b.displayName)),
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
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                status,
                key: Key('add-network-status-${b.id}'),
                style: const TextStyle(color: CC.textMuted, fontSize: 12.5),
              ),
              if (b.keepAwake && b.hostSupported && s.isLocalSession)
                const Text('Keeps this computer awake while connected.', style: TextStyle(color: CC.textFaint, fontSize: 12)),
              if (err != null) Text(err, style: const TextStyle(color: CC.danger, fontSize: 12.5)),
            ],
          ),
          trailing: trailing,
        ),
      ),
    );
  }
}
