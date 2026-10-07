import 'package:flutter/material.dart';

/// Visual identity per bridged network.
class NetworkStyle {
  const NetworkStyle(this.label, this.color, this.icon, this.short);
  final String label;
  final Color color;
  final IconData icon;
  final String short;
}

const _styles = <String, NetworkStyle>{
  'imessage': NetworkStyle('iMessage', Color(0xFF1F8FFF), Icons.chat_bubble_rounded, 'iM'),
  'gmessages': NetworkStyle('Google Messages', Color(0xFF1A73E8), Icons.sms_rounded, 'RCS'),
  'slack': NetworkStyle('Slack', Color(0xFF611F69), Icons.tag_rounded, 'S'),
  'groupme': NetworkStyle('GroupMe', Color(0xFF00AFF0), Icons.groups_rounded, 'GM'),
  'whatsapp': NetworkStyle('WhatsApp', Color(0xFF25D366), Icons.phone_in_talk_rounded, 'WA'),
  'signal': NetworkStyle('Signal', Color(0xFF3A76F0), Icons.lock_rounded, 'Sig'),
  'telegram': NetworkStyle('Telegram', Color(0xFF26A5E4), Icons.send_rounded, 'TG'),
  'matrix': NetworkStyle('Matrix', Color(0xFF0DBD8B), Icons.grid_view_rounded, '[m]'),
};

NetworkStyle networkStyle(String? id) =>
    _styles[id ?? 'matrix'] ?? NetworkStyle(id ?? 'Matrix', const Color(0xFF80848E), Icons.hub_rounded, '?');
