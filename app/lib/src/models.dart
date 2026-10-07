/// UI-side models, decoupled from the generated flutter_rust_bridge types so
/// the UI can run against the demo backend (tests, screenshots) as well.
library;

class ThreadSummary {
  const ThreadSummary({
    required this.replyCount,
    this.latestReplyTs,
    this.latestReplyBody,
    this.participants = const [],
  });

  final int replyCount;
  final int? latestReplyTs;
  final String? latestReplyBody;
  final List<String> participants;
}

class Message {
  const Message({
    required this.eventId,
    required this.sender,
    required this.senderName,
    required this.body,
    required this.ts,
    this.kind = 'text',
    this.threadRoot,
    this.inReplyTo,
    this.thread,
    this.edited = false,
    this.isOwn = false,
  });

  final String eventId;
  final String sender;
  final String senderName;
  final String body;
  final String kind;
  final int ts;
  final String? threadRoot;
  final String? inReplyTo;
  final ThreadSummary? thread;
  final bool edited;
  final bool isOwn;

  DateTime get time => DateTime.fromMillisecondsSinceEpoch(ts);
}

class Room {
  const Room({
    required this.roomId,
    required this.name,
    this.topic,
    this.isDm = false,
    this.unread = 0,
    this.highlights = 0,
    this.lastTs = 0,
    this.lastMessage,
    this.networkId,
    this.networkName,
    this.threadsSupported,
  });

  final String roomId;
  final String name;
  final String? topic;
  final bool isDm;
  final int unread;
  final int highlights;
  final int lastTs;
  final String? lastMessage;

  /// Bridged network id (`imessage`, `gmessages`, `slack`, `groupme`, ...);
  /// `null` for plain Matrix rooms.
  final String? networkId;
  final String? networkName;

  /// From `com.beeper.room_features`; `null` = unknown.
  final bool? threadsSupported;

  /// Threads are offered unless the bridge says the network can't carry them
  /// (we never fake threads that wouldn't reach the remote network).
  bool get canThread => threadsSupported ?? (networkId == null || networkId == 'slack');
}

class Session {
  const Session({
    required this.userId,
    required this.deviceId,
    required this.homeserver,
    required this.accessToken,
  });

  final String userId;
  final String deviceId;
  final String homeserver;
  final String accessToken;
}

class DirectoryUser {
  const DirectoryUser({required this.userId, this.displayName});
  final String userId;
  final String? displayName;
}

/// Update from the sync loop.
class BackendUpdate {
  const BackendUpdate.roomsChanged() : kind = 'rooms_changed', roomId = null, message = null, state = null;
  const BackendUpdate.newMessage(String this.roomId, Message this.message) : kind = 'new_message', state = null;
  const BackendUpdate.syncState(String this.state) : kind = 'sync_state', roomId = null, message = null;

  final String kind;
  final String? roomId;
  final Message? message;
  final String? state;
}
