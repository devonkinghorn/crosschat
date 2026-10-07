import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// Message composer. Enter sends, Shift+Enter inserts a newline.
class Composer extends StatefulWidget {
  const Composer({super.key, required this.hint, required this.onSend, this.footer});
  final String hint;
  final Future<void> Function(String text) onSend;
  final Widget? footer;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _ctrl = TextEditingController();
  late final _focus = FocusNode(onKeyEvent: _onKey);

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.enter && !HardwareKeyboard.instance.isShiftPressed) {
      _send();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _send() async {
    final text = _ctrl.text;
    if (text.trim().isEmpty) return;
    _ctrl.clear();
    await widget.onSend(text);
    _focus.requestFocus();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          decoration: BoxDecoration(color: CC.input, borderRadius: BorderRadius.circular(8)),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                tooltip: 'Attachments are not in the alpha yet',
                icon: const Icon(Icons.add_circle, color: CC.textMuted),
                onPressed: null,
              ),
              Expanded(
                child: TextField(
                  key: const Key('composer'),
                  controller: _ctrl,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: 8,
                  style: const TextStyle(fontSize: 15),
                  decoration: InputDecoration(
                    hintText: widget.hint,
                    fillColor: Colors.transparent,
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              IconButton(
                key: const Key('send'),
                tooltip: 'Send',
                icon: const Icon(Icons.send_rounded, color: CC.textMuted),
                onPressed: _send,
              ),
            ],
          ),
        ),
        if (widget.footer != null) Padding(padding: const EdgeInsets.only(top: 4), child: widget.footer),
      ],
    ),
  );
}
