import 'package:flutter/material.dart';

import 'theme.dart';

/// Deterministic colored initials avatar (no media loading in the alpha).
class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.name, this.size = 36, this.seed});
  final String name;
  final String? seed;
  final double size;

  static const _palette = [
    Color(0xFF5865F2), Color(0xFFEB459E), Color(0xFF3BA55C), Color(0xFFFAA61A),
    Color(0xFFED4245), Color(0xFF9B59B6), Color(0xFF1ABC9C), Color(0xFFE67E22),
  ];

  @override
  Widget build(BuildContext context) {
    final s = seed ?? name;
    final color = _palette[s.codeUnits.fold(0, (a, c) => a + c) % _palette.length];
    final clean = name.replaceAll(RegExp(r'^[@#!]'), '').trim();
    final parts = clean.split(RegExp(r'[\s_.-]+')).where((p) => p.isNotEmpty).toList();
    final initials = parts.isEmpty
        ? '?'
        : (parts.length == 1 ? parts.first.substring(0, 1) : '${parts[0][0]}${parts[1][0]}').toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(size * 0.3)),
      child: Text(
        initials,
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: size * 0.38),
      ),
    );
  }
}

String formatTime(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final m = t.minute.toString().padLeft(2, '0');
  return '$h:$m ${t.hour < 12 ? 'AM' : 'PM'}';
}

String formatRelative(DateTime t, {DateTime? now}) {
  final d = (now ?? DateTime.now()).difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 7) return '${d.inDays}d ago';
  return '${t.month}/${t.day}/${t.year}';
}

String formatDay(DateTime t, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(t.year, t.month, t.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  return '${months[t.month - 1]} ${t.day}, ${t.year}';
}

class UnreadBadge extends StatelessWidget {
  const UnreadBadge({super.key, required this.count});
  final int count;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    constraints: const BoxConstraints(minWidth: 18),
    decoration: BoxDecoration(color: CC.danger, borderRadius: BorderRadius.circular(9)),
    child: Text(
      count > 99 ? '99+' : '$count',
      textAlign: TextAlign.center,
      style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700),
    ),
  );
}
