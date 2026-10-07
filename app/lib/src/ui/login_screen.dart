import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'theme.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.state});
  final AppState state;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _hs = TextEditingController(text: 'https://');
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;

  Future<void> _submit() async {
    setState(() => _busy = true);
    await widget.state.login(_hs.text.trim(), _user.text.trim(), _pass.text);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final error = widget.state.error;
    return Scaffold(
      backgroundColor: CC.rail,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              color: CC.sidebar,
              elevation: 8,
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Icon(Icons.hub_rounded, size: 44, color: CC.accent),
                      const SizedBox(height: 12),
                      const Text('Welcome to Crosschat', textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      const Text(
                        'Sign in to your Matrix homeserver. Your bridged networks come along.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: CC.textMuted),
                      ),
                      const SizedBox(height: 24),
                      _label('HOMESERVER'),
                      TextField(key: const Key('homeserver'), controller: _hs, keyboardType: TextInputType.url),
                      const SizedBox(height: 14),
                      _label('USERNAME'),
                      TextField(
                        key: const Key('username'),
                        controller: _user,
                        autofillHints: const [AutofillHints.username],
                        decoration: const InputDecoration(hintText: 'devon or @devon:example.com'),
                      ),
                      const SizedBox(height: 14),
                      _label('PASSWORD'),
                      TextField(
                        key: const Key('password'),
                        controller: _pass,
                        obscureText: true,
                        autofillHints: const [AutofillHints.password],
                        onSubmitted: (_) => _submit(),
                      ),
                      if (error != null) ...[
                        const SizedBox(height: 12),
                        Text(error, style: const TextStyle(color: CC.danger, fontSize: 13)),
                      ],
                      const SizedBox(height: 20),
                      FilledButton(
                        key: const Key('login'),
                        style: FilledButton.styleFrom(backgroundColor: CC.accent, padding: const EdgeInsets.symmetric(vertical: 14)),
                        onPressed: _busy ? null : _submit,
                        child: _busy
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Text('Log in'),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Works with any Matrix server. Bridges are managed by crosschatd on your host.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: CC.textFaint, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(t, style: const TextStyle(color: CC.textMuted, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
  );
}
