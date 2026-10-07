import 'package:flutter/material.dart';

import '../local/local_server.dart';
import '../state/app_state.dart';
import 'login_screen.dart';
import 'theme.dart';

enum _Mode { choose, local, existing, localLogin }

/// First run: start a private server on this computer (default) or sign in
/// to an existing Matrix homeserver. After logout from a local server this
/// shows the local sign-in instead.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.state});
  final AppState state;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late _Mode _mode = widget.state.localOwner != null && widget.state.localServerSupported ? _Mode.localLogin : _Mode.choose;

  void _go(_Mode m) {
    widget.state.clearError();
    setState(() => _mode = m);
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    switch (_mode) {
      case _Mode.existing:
        return LoginScreen(
          key: const Key('existing-login'),
          state: state,
          onBack: () => _go(_Mode.choose),
        );
      case _Mode.localLogin:
        final owner = state.localOwner ?? '';
        final localpart = owner.startsWith('@') ? owner.substring(1).split(':').first : owner;
        return LoginScreen(
          key: const Key('local-login'),
          state: state,
          initialHomeserver: state.localServer!.homeserverUrl,
          initialUsername: localpart,
          subtitle: 'Sign in to the server on this computer.',
          onBack: () => _go(_Mode.choose),
          backLabel: 'Use a different server',
          notice: state.localError == null ? null : _LocalErrorNotice(state: state),
        );
      case _Mode.local:
        return _Shell(child: _NewServerForm(state: state, onBack: () => _go(_Mode.choose)));
      case _Mode.choose:
        return _Shell(child: _Chooser(state: state, onLocal: () => _go(_Mode.local), onExisting: () => _go(_Mode.existing)));
    }
  }
}

class _Shell extends StatelessWidget {
  const _Shell({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: CC.rail,
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Card(
            color: CC.sidebar,
            elevation: 8,
            child: Padding(padding: const EdgeInsets.all(28), child: child),
          ),
        ),
      ),
    ),
  );
}

class _Chooser extends StatelessWidget {
  const _Chooser({required this.state, required this.onLocal, required this.onExisting});
  final AppState state;
  final VoidCallback onLocal;
  final VoidCallback onExisting;

  @override
  Widget build(BuildContext context) {
    final supported = state.localServerSupported;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.hub_rounded, size: 44, color: CC.accent),
        const SizedBox(height: 12),
        const Text('Welcome to Crosschat', textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        const Text('Where should your chats live?', textAlign: TextAlign.center, style: TextStyle(color: CC.textMuted)),
        const SizedBox(height: 24),
        _OptionCard(
          key: const Key('setup-local'),
          icon: Icons.computer_rounded,
          title: 'Start a new server on this computer',
          subtitle: supported
              ? 'Crosschat runs its own Matrix server and bridges here. No other account needed.'
              : (state.localServer?.unsupportedReason ?? 'Runs in the desktop app (macOS or Linux).'),
          badge: supported ? 'Recommended' : null,
          primary: supported,
          onTap: supported ? onLocal : null,
        ),
        const SizedBox(height: 12),
        _OptionCard(
          key: const Key('setup-existing'),
          icon: Icons.public_rounded,
          title: 'Use an existing Matrix server',
          subtitle: 'Sign in to your own Synapse/Tuwunel, matrix.org or any homeserver.',
          primary: !supported,
          onTap: onExisting,
        ),
        const SizedBox(height: 16),
        const Text(
          'Bridges (iMessage, Google Messages, Slack, GroupMe) are managed by crosschatd next to your server.',
          textAlign: TextAlign.center,
          style: TextStyle(color: CC.textFaint, fontSize: 12),
        ),
      ],
    );
  }
}

class _OptionCard extends StatelessWidget {
  const _OptionCard({super.key, required this.icon, required this.title, required this.subtitle, this.badge, this.primary = false, this.onTap});
  final IconData icon;
  final String title;
  final String subtitle;
  final String? badge;
  final bool primary;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Material(
        color: primary ? CC.accent.withValues(alpha: 0.14) : CC.input,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: primary ? CC.accent : CC.divider, width: primary ? 1.5 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(color: primary ? CC.accent : CC.selected, borderRadius: BorderRadius.circular(10)),
                  child: Icon(icon, color: Colors.white, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                          if (badge != null)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(color: CC.success, borderRadius: BorderRadius.circular(4)),
                              child: Text(badge!, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white)),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(subtitle, style: const TextStyle(color: CC.textMuted, fontSize: 13)),
                    ],
                  ),
                ),
                if (enabled) const Padding(padding: EdgeInsets.only(left: 8, top: 10), child: Icon(Icons.chevron_right, color: CC.textMuted)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NewServerForm extends StatefulWidget {
  const _NewServerForm({required this.state, required this.onBack});
  final AppState state;
  final VoidCallback onBack;

  @override
  State<_NewServerForm> createState() => _NewServerFormState();
}

class _NewServerFormState extends State<_NewServerForm> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _confirm = TextEditingController();
  String? _validation;
  bool _busy = false;
  String? _dataDir;

  @override
  void initState() {
    super.initState();
    widget.state.localServer?.dataDir().then((d) {
      if (mounted) setState(() => _dataDir = d);
    });
  }

  Future<void> _submit() async {
    final user = _user.text.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();
    final v = validateLocalpart(user) ??
        validatePassword(_pass.text) ??
        (_pass.text != _confirm.text ? 'Passwords don\'t match.' : null);
    setState(() => _validation = v);
    if (v != null) return;
    setState(() => _busy = true);
    await widget.state.createLocalServer(user, _pass.text);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final error = _validation ?? state.localError ?? state.error;
    final progress = state.localStatus;
    return AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('local-back'),
              onPressed: _busy ? null : widget.onBack,
              icon: const Icon(Icons.arrow_back, size: 16),
              label: const Text('Back'),
              style: TextButton.styleFrom(foregroundColor: CC.textMuted),
            ),
          ),
          const Icon(Icons.computer_rounded, size: 40, color: CC.accent),
          const SizedBox(height: 10),
          const Text('New server on this computer', textAlign: TextAlign.center, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          const Text('Create the owner account for your server.', textAlign: TextAlign.center, style: TextStyle(color: CC.textMuted)),
          const SizedBox(height: 16),
          Container(
            key: const Key('local-notice'),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: CC.warning.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: CC.warning.withValues(alpha: 0.5)),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, color: CC.warning, size: 18),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'For this computer only. The server is named "localhost", federation is off and it only listens '
                    'on this computer, so your phone can\'t connect to it. A Matrix server name can\'t be changed '
                    'later; moving to your own domain will be a migration.',
                    style: TextStyle(fontSize: 12.5, color: CC.text),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _label('USERNAME'),
          TextField(
            key: const Key('local-username'),
            controller: _user,
            enabled: !_busy,
            autofillHints: const [AutofillHints.newUsername],
            decoration: const InputDecoration(hintText: 'devon', suffixText: ':localhost'),
          ),
          const SizedBox(height: 14),
          _label('PASSWORD'),
          TextField(
            key: const Key('local-password'),
            controller: _pass,
            enabled: !_busy,
            obscureText: true,
            autofillHints: const [AutofillHints.newPassword],
          ),
          const SizedBox(height: 14),
          _label('CONFIRM PASSWORD'),
          TextField(
            key: const Key('local-confirm'),
            controller: _confirm,
            enabled: !_busy,
            obscureText: true,
            onSubmitted: (_) => _busy ? null : _submit(),
          ),
          if (error != null && !_busy) ...[
            const SizedBox(height: 12),
            Text(error, key: const Key('local-error'), style: const TextStyle(color: CC.danger, fontSize: 13)),
          ],
          const SizedBox(height: 20),
          FilledButton(
            key: const Key('local-create'),
            style: FilledButton.styleFrom(backgroundColor: CC.accent, padding: const EdgeInsets.symmetric(vertical: 14)),
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Create server'),
          ),
          if (_busy && progress != null) ...[
            const SizedBox(height: 12),
            Text(
              progress.detail,
              key: const Key('local-progress'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: CC.textMuted, fontSize: 13),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            _dataDir == null ? 'Stored on this computer.' : 'Stored in $_dataDir',
            textAlign: TextAlign.center,
            style: const TextStyle(color: CC.textFaint, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _label(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(t, style: const TextStyle(color: CC.textMuted, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
  );
}

class _LocalErrorNotice extends StatelessWidget {
  const _LocalErrorNotice({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('local-start-error'),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: CC.danger.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('The local server didn\'t start:\n${state.localError}', style: const TextStyle(color: CC.text, fontSize: 12.5)),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            key: const Key('local-retry'),
            onPressed: state.localStatus != null ? null : state.retryLocalServer,
            child: Text(state.localStatus != null ? state.localStatus!.detail : 'Retry'),
          ),
        ),
      ],
    ),
  );
}
