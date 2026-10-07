import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../daemon/daemon_client.dart';
import '../platform.dart';
import '../state/app_state.dart';
import 'networks.dart';
import 'theme.dart';

/// Generic bridgev2 login renderer. Every bridgev2 bridge describes its login
/// as steps over the same provisioning API, so one renderer covers iMessage,
/// Google Messages, Slack and GroupMe:
///   * user_input       → form fields (phone, password, 2FA, select, ...)
///   * display_and_wait → QR / pairing code / emoji, then long-poll
///   * cookies          → sign-in page whose cookies are handed to the bridge
///   * complete         → done
class BridgeLoginDialog extends StatefulWidget {
  const BridgeLoginDialog({super.key, required this.state, required this.bridge});
  final AppState state;
  final BridgeInfo bridge;

  @override
  State<BridgeLoginDialog> createState() => _BridgeLoginDialogState();
}

class _BridgeLoginDialogState extends State<BridgeLoginDialog> {
  List<Map<String, dynamic>>? _flows;
  Map<String, dynamic>? _step;
  String? _error;
  bool _busy = false;
  final Map<String, TextEditingController> _fields = {};

  DaemonClient get _d => widget.state.daemon!;
  PlatformCapabilities get _caps => widget.state.capabilities;
  String get _bridgeId => widget.bridge.id;

  @override
  void initState() {
    super.initState();
    _loadFlows();
  }

  @override
  void dispose() {
    final step = _step;
    if (step != null && step['type'] != 'complete' && step['login_id'] != null) {
      _d.cancelLogin(_bridgeId, step['login_id'] as String).ignore();
    }
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _guard(Future<void> Function() f) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await f();
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _loadFlows() => _guard(() async {
    _flows = await _d.loginFlows(_bridgeId);
  });

  Future<void> _start(String flowId) => _guard(() async {
    _setStep(await _d.startLogin(_bridgeId, flowId));
  });

  void _setStep(Map<String, dynamic> step) {
    _step = step;
    for (final c in _fields.values) {
      c.dispose();
    }
    _fields.clear();
    if (step['type'] == 'display_and_wait') {
      // Nothing to collect: immediately wait for the user to act on their phone.
      Future.microtask(() => _submit({}));
    }
  }

  Future<void> _submit(Map<String, String> data) => _guard(() async {
    final next = await _d.submitStep(_bridgeId, _step!, data);
    if (mounted) setState(() => _setStep(next));
  });

  TextEditingController _ctrl(String id, [String? initial]) =>
      _fields.putIfAbsent(id, () => TextEditingController(text: initial ?? ''));

  Future<void> _extractHardwareKey(TextEditingController target) => _guard(() async {
    final path = widget.state.settings.extractorPath;
    if (path.isEmpty) throw Exception('Set the extract-key path in Settings first.');
    target.text = await AppleKeyExtractor.run(path);
  });

  @override
  Widget build(BuildContext context) {
    final style = networkStyle(widget.bridge.network);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(style.icon, color: style.color),
                    const SizedBox(width: 8),
                    Flexible(child: Text('Connect ${widget.bridge.displayName}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700))),
                  ],
                ),
                const SizedBox(height: 12),
                for (final p in widget.bridge.preflight) _preflight(p),
                for (final r in widget.bridge.requirements) _requirement(r),
                const SizedBox(height: 8),
                _body(),
                if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: CC.danger))),
                const SizedBox(height: 12),
                Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _preflight(Map<String, dynamic> p) {
    final sev = p['severity'] as String? ?? 'info';
    final color = sev == 'blocking' ? CC.danger : (sev == 'warning' ? CC.warning : CC.link);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(sev == 'info' ? Icons.info_outline : Icons.warning_amber_rounded, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(p['message'] as String? ?? '', style: const TextStyle(fontSize: 12.5))),
        ],
      ),
    );
  }

  Widget _requirement(Map<String, dynamic> r) {
    final providers = ((r['provided_by'] as List?) ?? []).cast<String>();
    final canProvide = providers.contains(_caps.manifestPlatform);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        canProvide
            ? '✓ ${r['description']} This device can provide it.'
            : '${r['description']} Available from: ${providers.join(', ')}.',
        style: const TextStyle(fontSize: 12.5, color: CC.textMuted),
      ),
    );
  }

  Widget _body() {
    if (_busy && _step == null) return const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()));
    final step = _step;
    if (step == null) {
      final flows = _flows ?? [];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Choose how to sign in:', style: TextStyle(color: CC.textMuted)),
          const SizedBox(height: 8),
          for (final f in flows)
            Card(
              color: CC.input,
              child: ListTile(
                title: Text(f['name'] as String? ?? f['id'] as String),
                subtitle: Text(f['description'] as String? ?? '', style: const TextStyle(color: CC.textMuted)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _start(f['id'] as String),
              ),
            ),
        ],
      );
    }
    final instructions = step['instructions'] as String?;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (instructions != null && instructions.isNotEmpty)
          Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(instructions)),
        switch (step['type']) {
          'user_input' => _userInput(step['user_input'] as Map<String, dynamic>),
          'display_and_wait' => _displayAndWait(step['display_and_wait'] as Map<String, dynamic>),
          'cookies' => _cookies(step['cookies'] as Map<String, dynamic>),
          'complete' => const ListTile(
            leading: Icon(Icons.check_circle, color: CC.success),
            title: Text('Connected! Your chats will appear in the sidebar shortly.'),
          ),
          _ => Text('This login step (${step['type']}) is not supported in the alpha yet.'),
        },
      ],
    );
  }

  Widget _userInput(Map<String, dynamic> params) {
    final fields = ((params['fields'] as List?) ?? []).cast<Map<String, dynamic>>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final f in fields) ...[
          Text(f['name'] as String? ?? f['id'] as String, style: const TextStyle(color: CC.textMuted, fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          if (f['type'] == 'select')
            DropdownButtonFormField<String>(
              initialValue: _ctrl(f['id'] as String, f['default_value'] as String?).text.isEmpty ? null : _ctrl(f['id'] as String).text,
              items: [for (final o in ((f['options'] as List?) ?? []).cast<String>()) DropdownMenuItem(value: o, child: Text(o))],
              onChanged: (v) => _ctrl(f['id'] as String).text = v ?? '',
            )
          else
            TextField(
              controller: _ctrl(f['id'] as String, f['default_value'] as String?),
              obscureText: const {'password', 'token'}.contains(f['type']),
              keyboardType: f['type'] == 'phone_number' ? TextInputType.phone : TextInputType.text,
              decoration: InputDecoration(helperText: f['description'] as String?),
            ),
          if (f['id'] == 'hardware_key')
            Align(
              alignment: Alignment.centerLeft,
              child: _caps.canExtractAppleHardwareKey
                  ? TextButton.icon(
                      icon: const Icon(Icons.memory),
                      label: const Text('Extract from this Mac'),
                      onPressed: () => _extractHardwareKey(_ctrl('hardware_key')),
                    )
                  : const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text('Extract this key once with the Crosschat macOS app, then paste it here.', style: TextStyle(color: CC.textFaint, fontSize: 12)),
                    ),
            ),
          const SizedBox(height: 12),
        ],
        FilledButton(
          onPressed: _busy ? null : () => _submit({for (final f in fields) f['id'] as String: _ctrl(f['id'] as String).text}),
          child: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Continue'),
        ),
      ],
    );
  }

  Widget _displayAndWait(Map<String, dynamic> p) {
    final data = p['data'] as String? ?? '';
    final Widget content = switch (p['type']) {
      'qr' => Container(
        color: Colors.white,
        padding: const EdgeInsets.all(12),
        child: QrImageView(data: data, size: 240),
      ),
      'code' => SelectableText(data, textAlign: TextAlign.center, style: const TextStyle(fontSize: 32, letterSpacing: 4, fontWeight: FontWeight.w700)),
      'emoji' => Text(data, textAlign: TextAlign.center, style: const TextStyle(fontSize: 72)),
      _ => const SizedBox.shrink(),
    };
    return Column(
      children: [
        Center(child: content),
        const SizedBox(height: 12),
        const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 8),
            Text('Waiting for you to confirm on your phone…', style: TextStyle(color: CC.textMuted)),
          ],
        ),
        if (p['type'] == 'qr' && _caps.isMobile)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Tip: a phone can\'t scan its own screen. Open this on your desktop instead.', style: TextStyle(color: CC.textFaint, fontSize: 12)),
          ),
      ],
    );
  }

  /// Field id: current bridgev2 uses `id` + `sources`; older bridges used
  /// `type` + `name`.
  static String _cookieFieldId(Map<String, dynamic> f) => (f['id'] ?? f['name']) as String;

  static String _cookieFieldLabel(Map<String, dynamic> f) {
    final sources = ((f['sources'] as List?) ?? []).cast<Map<String, dynamic>>();
    if (sources.isEmpty) return '${f['type'] ?? 'cookie'}: ${_cookieFieldId(f)}';
    final src = sources.first;
    final where = src['cookie_domain'] ?? '';
    return '${src['type'] ?? 'cookie'} ${src['name'] ?? _cookieFieldId(f)}${where == '' ? '' : ' ($where)'}';
  }

  /// Names a field can be matched by when parsing pasted cookies.
  static Set<String> _cookieNames(Map<String, dynamic> f) => {
    _cookieFieldId(f),
    for (final s in ((f['sources'] as List?) ?? []).cast<Map<String, dynamic>>())
      if (s['name'] is String) s['name'] as String,
  };

  void _applyPastedCookies(List<Map<String, dynamic>> fields, String pasted) {
    final values = parseCookiePaste(pasted);
    var filled = 0;
    for (final f in fields) {
      for (final n in _cookieNames(f)) {
        if (values[n] != null) {
          _ctrl(_cookieFieldId(f)).text = values[n]!;
          filled++;
          break;
        }
      }
    }
    setState(() => _error = filled == 0 ? 'No matching cookies found in the pasted text.' : null);
  }

  Widget _cookies(Map<String, dynamic> p) {
    final url = p['url'] as String? ?? '';
    final fields = ((p['fields'] as List?) ?? []).cast<Map<String, dynamic>>();
    final paste = _ctrl('__paste__');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _caps.hasEmbeddedWebview
              ? 'Embedded sign-in (fresh private webview with cookie capture) is the next milestone. For now, sign in in your browser and paste the values below.'
              : 'Sign in in your browser, then paste the requested values below (embedded sign-in on Linux/Windows needs a webview plugin; tracked in the roadmap).',
          style: const TextStyle(color: CC.textMuted, fontSize: 12.5),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: SelectableText(url, style: const TextStyle(color: CC.link, fontSize: 12))),
            IconButton(tooltip: 'Copy URL', icon: const Icon(Icons.copy, size: 18), onPressed: () => Clipboard.setData(ClipboardData(text: url))),
            IconButton(tooltip: 'Open in browser', icon: const Icon(Icons.open_in_new, size: 18), onPressed: () => launchUrl(Uri.parse(url))),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          key: const Key('cookie-paste'),
          controller: paste,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(hintText: 'Optional: paste a cURL command, Cookie header or JSON object to fill the fields'),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(onPressed: () => _applyPastedCookies(fields, paste.text), child: const Text('Fill from paste')),
        ),
        for (final f in fields) ...[
          Text(
            '${_cookieFieldLabel(f)}${f['required'] == false ? ' (optional)' : ''}',
            style: const TextStyle(color: CC.textMuted, fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          TextField(key: Key('cookie-${_cookieFieldId(f)}'), controller: _ctrl(_cookieFieldId(f)), obscureText: true),
          const SizedBox(height: 10),
        ],
        FilledButton(
          onPressed: _busy
              ? null
              : () => _submit({
                  for (final f in fields)
                    if (_ctrl(_cookieFieldId(f)).text.isNotEmpty) _cookieFieldId(f): _ctrl(_cookieFieldId(f)).text,
                }),
          child: const Text('Submit'),
        ),
      ],
    );
  }
}

/// Parses cookies from a JSON object, a `Cookie:` header, a raw
/// `a=b; c=d` string, or a cURL command (`-H 'cookie: …'` / `-b '…'`).
Map<String, String> parseCookiePaste(String text) {
  final t = text.trim();
  if (t.isEmpty) return {};
  if (t.startsWith('{')) {
    try {
      final v = jsonDecode(t);
      if (v is Map) return {for (final e in v.entries) '${e.key}': '${e.value}'};
    } catch (_) {}
  }
  String header = t;
  final m = RegExp(r"""(?:-H|--header)\s+(['"])cookie:\s*(.*?)\1""", caseSensitive: false).firstMatch(t) ??
      RegExp(r"""(?:-b|--cookie)\s+(['"])(.*?)\1""").firstMatch(t);
  if (m != null) {
    header = m.group(2)!;
  } else if (t.toLowerCase().startsWith('cookie:')) {
    header = t.substring(7);
  }
  final out = <String, String>{};
  for (final part in header.split(';')) {
    final i = part.indexOf('=');
    if (i <= 0) continue;
    out[part.substring(0, i).trim()] = part.substring(i + 1).trim();
  }
  return out;
}
