/// UI-side models, decoupled from the generated flutter_rust_bridge types so
/// the UI can run against the demo backend (tests, screenshots) as well.
library;

class ThreadSummary {
  const ThreadSummary({required this.replyCount, this.latestReplyTs, this.latestReplyBody, this.participants = const []});

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
    this.bridgeId,
    this.bridgeBot,
    this.protocolId,
    this.protocolName,
    this.loginId,
    this.roomType,
    this.assignedGroup,
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

  /// Bridge identity from the room's `m.bridge` state: appservice id, bot,
  /// the raw per-chat protocol (Google Messages: `gmessages-rcs` /
  /// `gmessages-sms`), the bridge login (`fi.mau.receiver`) and room type.
  final String? bridgeId;
  final String? bridgeBot;
  final String? protocolId;
  final String? protocolName;
  final String? loginId;
  final String? roomType;

  /// Rail entry assigned by `resolveNetworks` (see [groupKey]).
  final String? assignedGroup;

  /// Network rail entry this room is listed under (one per bridge login);
  /// defaults to the network id.
  String get groupKey => assignedGroup ?? networkId ?? 'matrix';

  /// Per-chat transport when the bridge distinguishes it, e.g. `SMS` / `RCS`
  /// for Google Messages (from `Google Messages (SMS)` / `gmessages-sms`).
  String? get subProtocol {
    final name = protocolName;
    if (name != null) {
      final m = RegExp(r'\(([^()]{1,12})\)\s*$').firstMatch(name);
      if (m != null) return m.group(1);
    }
    final pid = protocolId, net = networkId;
    if (pid != null && net != null && pid.startsWith('$net-')) return pid.substring(net.length + 1).toUpperCase();
    return null;
  }

  Room copyWith({String? networkId, String? networkName, String? bridgeId, String? groupKey}) => Room(
    roomId: roomId,
    name: name,
    topic: topic,
    isDm: isDm,
    unread: unread,
    highlights: highlights,
    lastTs: lastTs,
    lastMessage: lastMessage,
    networkId: networkId ?? this.networkId,
    networkName: networkName ?? this.networkName,
    threadsSupported: threadsSupported,
    bridgeId: bridgeId ?? this.bridgeId,
    bridgeBot: bridgeBot,
    protocolId: protocolId,
    protocolName: protocolName,
    loginId: loginId,
    roomType: roomType,
    assignedGroup: groupKey ?? assignedGroup,
  );

  /// Threads are offered unless the bridge says the network can't carry them
  /// (we never fake threads that wouldn't reach the remote network).
  bool get canThread => threadsSupported ?? (networkId == null || networkId == 'slack');
}

class Session {
  const Session({required this.userId, required this.deviceId, required this.homeserver, required this.accessToken});

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
