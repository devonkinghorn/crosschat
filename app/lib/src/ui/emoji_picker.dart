import 'package:flutter/material.dart';

import 'emoji_data.dart';
import 'theme.dart';

/// Reactions offered first (Slack's defaults for Devon's workspace).
const quickReactions = ['✅', '👀', '🙌', '👍', '❤️', '😂'];

/// Slack-style shortcodes people type into the search box.
const _aliases = <String, String>{
  '+1': '👍',
  'thumbsup': '👍',
  '-1': '👎',
  'thumbsdown': '👎',
  'white_check_mark': '✅',
  'check': '✅',
  'heavy_check_mark': '✔️',
  'eyes': '👀',
  'raised_hands': '🙌',
  'heart': '❤️',
  'joy': '😂',
  'lol': '😂',
  'tada': '🎉',
  'fire': '🔥',
  'pray': '🙏',
  'thanks': '🙏',
  '100': '💯',
  'ok': '👌',
  'ok_hand': '👌',
  'smile': '😄',
  'rofl': '🤣',
  'clap': '👏',
  'rocket': '🚀',
  'sob': '😭',
  'thinking': '🤔',
  'wave': '👋',
  'muscle': '💪',
  'x': '❌',
  'warning': '⚠️',
  'sparkles': '✨',
  'party': '🥳',
};

class _Emoji {
  const _Emoji(this.char, this.name);
  final String char;
  final String name;
}

List<(String, String, List<_Emoji>)>? _groups;

List<(String, String, List<_Emoji>)> _parsed() => _groups ??= [
  for (final (label, icon, data) in emojiGroups)
    (
      label,
      icon,
      [
        for (final line in data.split('\n'))
          if (line.contains('\t')) _Emoji(line.substring(0, line.indexOf('\t')), line.substring(line.indexOf('\t') + 1)),
      ],
    ),
];

Map<String, String>? _nameMap;

Map<String, String> _names() => _nameMap ??= {
  for (final (_, _, list) in _parsed())
    for (final e in list) e.char: e.name,
};

/// The CLDR name of an emoji ("thumbs up"), if known.
String? emojiName(String e) => _names()[e] ?? _names()['${e.replaceAll('\uFE0F', '')}\uFE0F'] ?? _names()[e.replaceAll('\uFE0F', '')];

/// Emoji the user picked recently in this session, newest first.
final List<String> recentEmoji = [];

void _noteRecent(String e) {
  recentEmoji
    ..remove(e)
    ..insert(0, e);
  if (recentEmoji.length > 24) recentEmoji.removeLast();
}

/// Search the emoji list by name or Slack-style shortcode.
List<String> searchEmoji(String query) {
  final q = query.trim().toLowerCase().replaceAll(':', '');
  if (q.isEmpty) return const [];
  final out = <String>[];
  final alias = _aliases[q];
  if (alias != null) out.add(alias);
  final words = q.replaceAll('_', ' ');
  final starts = <String>[], contains = <String>[];
  for (final (_, _, list) in _parsed()) {
    for (final e in list) {
      if (out.contains(e.char)) continue;
      if (e.name.startsWith(words) || e.name.split(' ').any((w) => w.startsWith(words))) {
        starts.add(e.char);
      } else if (e.name.contains(words)) {
        contains.add(e.char);
      }
    }
  }
  for (final e in _aliases.entries) {
    if (e.key.startsWith(q) && !out.contains(e.value) && !starts.contains(e.value)) out.add(e.value);
  }
  return [...out, ...starts, ...contains];
}

/// Pick an emoji: a popover dialog on desktop, a bottom sheet on phones.
Future<String?> showEmojiPicker(BuildContext context) async {
  final narrow = MediaQuery.sizeOf(context).width < 720;
  final String? picked;
  if (narrow) {
    picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: CC.panel,
      showDragHandle: true,
      builder: (context) => SizedBox(height: MediaQuery.sizeOf(context).height * 0.6, child: const EmojiPicker()),
    );
  } else {
    picked = await showDialog<String>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: CC.panel,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        child: const SizedBox(width: 380, height: 440, child: EmojiPicker()),
      ),
    );
  }
  if (picked != null) _noteRecent(picked);
  return picked;
}

/// Searchable emoji grid by category. Pops the route with the chosen emoji.
class EmojiPicker extends StatefulWidget {
  const EmojiPicker({super.key, this.onPicked});

  /// Called instead of popping the route (embedding / tests).
  final ValueChanged<String>? onPicked;

  @override
  State<EmojiPicker> createState() => _EmojiPickerState();
}

class _EmojiPickerState extends State<EmojiPicker> {
  final _search = TextEditingController();
  int _group = -1; // -1: frequently used

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _pick(String e) {
    if (widget.onPicked != null) {
      widget.onPicked!(e);
    } else {
      Navigator.of(context).pop(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = _parsed();
    final q = _search.text;
    final List<String> shown;
    if (q.trim().isNotEmpty) {
      shown = searchEmoji(q);
    } else if (_group < 0) {
      shown = <String>{...recentEmoji, ...quickReactions, ...groups.first.$3.take(48).map((e) => e.char)}.toList();
    } else {
      shown = [for (final e in groups[_group].$3) e.char];
    }
    return Column(
      key: const Key('emoji-picker'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
          child: TextField(
            key: const Key('emoji-search'),
            controller: _search,
            autofocus: MediaQuery.sizeOf(context).width >= 720,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              final hits = searchEmoji(_search.text);
              if (hits.isNotEmpty) _pick(hits.first);
            },
            decoration: const InputDecoration(isDense: true, hintText: 'Search emoji', prefixIcon: Icon(Icons.search, size: 18)),
          ),
        ),
        if (q.trim().isEmpty)
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              children: [
                _GroupTab(
                  icon: const Icon(Icons.schedule, size: 18, color: CC.textMuted),
                  label: 'Frequently used',
                  selected: _group < 0,
                  onTap: () => setState(() => _group = -1),
                ),
                for (var i = 0; i < groups.length; i++)
                  _GroupTab(
                    key: Key('emoji-group-${groups[i].$1}'),
                    icon: Text(groups[i].$2, style: emojiStyle(17)),
                    label: groups[i].$1,
                    selected: _group == i,
                    onTap: () => setState(() => _group = i),
                  ),
              ],
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: shown.isEmpty
              ? const Center(
                  child: Text('No emoji found', style: TextStyle(color: CC.textMuted)),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(6),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 42, mainAxisSpacing: 2, crossAxisSpacing: 2),
                  itemCount: shown.length,
                  itemBuilder: (context, i) {
                    final e = shown[i];
                    return Tooltip(
                      message: emojiName(e) ?? e,
                      waitDuration: const Duration(milliseconds: 500),
                      child: InkWell(
                        key: Key('emoji-$e'),
                        borderRadius: BorderRadius.circular(6),
                        onTap: () => _pick(e),
                        child: Center(child: Text(e, style: emojiStyle(24))),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _GroupTab extends StatelessWidget {
  const _GroupTab({super.key, required this.icon, required this.label, required this.selected, required this.onTap});
  final Widget icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: selected ? CC.accent : Colors.transparent, width: 2)),
        ),
        child: icon,
      ),
    ),
  );
}
