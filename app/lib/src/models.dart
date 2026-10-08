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

/// An attachment (image / video / audio / file / sticker). [source] is
/// opaque: hand it to `ChatBackend.mediaBytes`.
class MediaAttachment {
  const MediaAttachment({
    required this.source,
    required this.filename,
    this.mimetype,
    this.size,
    this.width,
    this.height,
    this.durationMs,
    this.caption,
    this.thumbnailSource,
  });

  final String source;
  final String filename;
  final String? mimetype;
  final int? size;
  final int? width;
  final int? height;
  final int? durationMs;
  final String? caption;
  final String? thumbnailSource;

  String get _ext {
    final i = filename.lastIndexOf('.');
    return i < 0 ? '' : filename.substring(i + 1).toLowerCase();
  }

  /// HEIC/HEIF: Flutter's decoders can't read it everywhere, so it goes
  /// through the platform's decoder (see `media_view.dart`).
  bool get isHeic {
    final m = (mimetype ?? '').toLowerCase();
    return m == 'image/heic' || m == 'image/heif' || ((m.isEmpty || m == 'application/octet-stream') && (_ext == 'heic' || _ext == 'heif'));
  }

  bool get isGif => (mimetype ?? '').toLowerCase() == 'image/gif' || _ext == 'gif';
}

/// Reactions with one key on a message.
class ReactionGroup {
  const ReactionGroup({required this.key, required this.senders, this.own = false, this.ownFromText = false});
  final String key;
  final List<String> senders;
  final bool own;

  /// The user's reaction came in as an SMS/RCS tapback text (sent from
  /// their phone), which can't be removed from here.
  final bool ownFromText;
  int get count => senders.length;

  /// Same emoji, ignoring variation selectors ("❤" == "❤️").
  bool matches(String other) => normalizeReactionKey(key) == normalizeReactionKey(other);
}

String normalizeReactionKey(String key) => key.replaceAll('\uFE0F', '').trim();

/// [groups] with the user's reaction [key] added or removed (local echo).
List<ReactionGroup> applyOwnReaction(List<ReactionGroup> groups, String key, String me, {required bool add}) {
  final out = [...groups];
  final i = out.indexWhere((g) => g.matches(key));
  if (add) {
    if (i < 0) {
      out.add(ReactionGroup(key: key, senders: [me], own: true));
    } else if (!out[i].own) {
      out[i] = ReactionGroup(key: out[i].key, senders: [...out[i].senders.where((s) => s != me), me], own: true, ownFromText: out[i].ownFromText);
    }
  } else if (i >= 0 && out[i].own && !out[i].ownFromText) {
    final rest = out[i].senders.where((s) => s != me).toList();
    if (rest.isEmpty) {
      out.removeAt(i);
    } else {
      out[i] = ReactionGroup(key: out[i].key, senders: rest);
    }
  }
  return out;
}

/// SMS/RCS tapback fallback ("Loved “hi”", "Laughed at an image").
class TapbackInfo {
  const TapbackInfo({required this.key, this.removed = false, this.targetText, this.truncated = false, this.targetKind});
  final String key;
  final bool removed;
  final String? targetText;
  final bool truncated;

  /// `image`, `video`, `audio`, `file` or `any`, for "… an image".
  final String? targetKind;
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
    this.senderAvatar,
    this.media,
    this.reactions = const [],
    this.tapback,
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

  /// `mxc://` avatar of the sender.
  final String? senderAvatar;
  final MediaAttachment? media;
  final List<ReactionGroup> reactions;

  /// Set on SMS/RCS tapback fallback texts; see `foldTapbacks`.
  final TapbackInfo? tapback;

  DateTime get time => DateTime.fromMillisecondsSinceEpoch(ts);

  Message copyWith({List<ReactionGroup>? reactions, ThreadSummary? thread, String? senderName, String? senderAvatar}) => Message(
    eventId: eventId,
    sender: sender,
    senderName: senderName ?? this.senderName,
    body: body,
    ts: ts,
    kind: kind,
    threadRoot: threadRoot,
    inReplyTo: inReplyTo,
    thread: thread ?? this.thread,
    edited: edited,
    isOwn: isOwn,
    senderAvatar: senderAvatar ?? this.senderAvatar,
    media: media,
    reactions: reactions ?? this.reactions,
    tapback: tapback,
  );
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
    this.markedUnread = false,
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

  /// Explicitly marked unread (MSC2867).
  final bool markedUnread;

  /// Bold + badge in the sidebar: unread messages or marked unread.
  bool get isUnread => unread > 0 || markedUnread;

  /// What a chat adds to badge totals: its unread count, or 1 when it's only
  /// marked unread.
  int get badgeCount => unread > 0 ? unread : (markedUnread ? 1 : 0);

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

  Room copyWith({String? networkId, String? networkName, String? bridgeId, String? groupKey, int? unread, bool? markedUnread}) => Room(
    roomId: roomId,
    name: name,
    topic: topic,
    isDm: isDm,
    unread: unread ?? this.unread,
    markedUnread: markedUnread ?? this.markedUnread,
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

  /// Reactions / edits / redactions / member names changed in a room.
  const BackendUpdate.timelineChanged(String this.roomId) : kind = 'timeline_changed', message = null, state = null;

  final String kind;
  final String? roomId;
  final Message? message;
  final String? state;
}
