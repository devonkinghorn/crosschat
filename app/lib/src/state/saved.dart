/// "Save for later": message bookmarks kept in the user's global account
/// data (`app.crosschat.saved_messages`), so they follow the account to
/// every device.
class SavedItem {
  const SavedItem({required this.roomId, required this.eventId, required this.savedAt});
  final String roomId;
  final String eventId;

  /// Milliseconds since epoch.
  final int savedAt;

  Map<String, dynamic> toJson() => {'room_id': roomId, 'event_id': eventId, 'saved_at': savedAt};

  static SavedItem? fromJson(Object? v) {
    if (v is! Map) return null;
    final room = v['room_id'], event = v['event_id'], at = v['saved_at'];
    if (room is! String || event is! String) return null;
    return SavedItem(roomId: room, eventId: event, savedAt: at is int ? at : 0);
  }
}

class SavedMessages {
  SavedMessages([List<SavedItem>? items]) : items = items ?? [];

  static const eventType = 'app.crosschat.saved_messages';

  /// Newest first.
  final List<SavedItem> items;

  bool contains(String roomId, String eventId) => items.any((i) => i.roomId == roomId && i.eventId == eventId);

  static SavedMessages fromJson(Map<String, dynamic>? json) {
    final raw = json?['items'];
    if (raw is! List) return SavedMessages();
    final items = raw.map(SavedItem.fromJson).whereType<SavedItem>().toList()..sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return SavedMessages(items);
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'items': [for (final i in items) i.toJson()],
  };
}
