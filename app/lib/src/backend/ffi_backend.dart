import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../local/app_paths.dart';

import '../models.dart';
import '../rust/api/matrix.dart' as rs;
import 'backend.dart';

/// The real backend: crosschat-core (matrix-rust-sdk) embedded through
/// flutter_rust_bridge. Each install is its own Matrix device.
class FfiBackend implements ChatBackend {
  @override
  String get name => 'matrix-rust-sdk';

  Future<String> _dataDir() async {
    final dir = Directory(await AppPaths.matrixStore());
    await dir.create(recursive: true);
    return dir.path;
  }

  Session _session(rs.SessionInfo s) => Session(userId: s.userId, deviceId: s.deviceId, homeserver: s.homeserver, accessToken: s.accessToken);

  static Message message(rs.ChatMessage m) => Message(
    eventId: m.eventId,
    sender: m.sender,
    senderName: m.senderName,
    body: m.body,
    kind: m.kind,
    ts: m.ts.toInt(),
    threadRoot: m.threadRoot,
    inReplyTo: m.inReplyTo,
    edited: m.edited,
    isOwn: m.isOwn,
    senderAvatar: m.senderAvatar,
    media: m.media == null
        ? null
        : MediaAttachment(
            source: m.media!.source,
            filename: m.media!.filename,
            mimetype: m.media!.mimetype,
            size: m.media!.size?.toInt(),
            width: m.media!.width,
            height: m.media!.height,
            durationMs: m.media!.durationMs?.toInt(),
            caption: m.media!.caption,
            thumbnailSource: m.media!.thumbnailSource,
          ),
    reactions: [for (final r in m.reactions) ReactionGroup(key: r.key, senders: r.senders, own: r.own)],
    tapback: m.tapback == null
        ? null
        : TapbackInfo(
            key: m.tapback!.key,
            removed: m.tapback!.removed,
            targetText: m.tapback!.targetText,
            truncated: m.tapback!.truncated,
            targetKind: m.tapback!.targetKind,
          ),
    thread: m.thread == null
        ? null
        : ThreadSummary(
            replyCount: m.thread!.replyCount,
            latestReplyTs: m.thread!.latestReplyTs?.toInt(),
            latestReplyBody: m.thread!.latestReplyBody,
            participants: m.thread!.participants,
          ),
  );

  @override
  Future<Session?> restore() async {
    final s = await rs.restoreSession(dataDir: await _dataDir());
    return s == null ? null : _session(s);
  }

  @override
  Future<Session> login({required String homeserver, required String username, required String password}) async {
    final s = await rs.login(
      homeserver: homeserver,
      username: username,
      password: password,
      dataDir: await _dataDir(),
      deviceName: 'Crosschat (${Platform.operatingSystem})',
    );
    return _session(s);
  }

  @override
  Future<void> logout() => rs.logout();

  @override
  Stream<BackendUpdate> updates() => rs.subscribeUpdates().map((u) {
    switch (u.kind) {
      case 'new_message':
        return BackendUpdate.newMessage(u.roomId!, message(u.message!));
      case 'sync_state':
        return BackendUpdate.syncState(u.state ?? '');
      case 'timeline_changed':
        return BackendUpdate.timelineChanged(u.roomId!);
      default:
        return const BackendUpdate.roomsChanged();
    }
  });

  @override
  Future<List<Room>> rooms() async => (await rs.listRooms())
      .map(
        (r) => Room(
          roomId: r.roomId,
          name: r.name,
          topic: r.topic,
          isDm: r.isDm,
          unread: r.unread.toInt(),
          highlights: r.highlights.toInt(),
          lastTs: r.lastTs.toInt(),
          lastMessage: r.lastMessage,
          networkId: r.networkId,
          networkName: r.networkName,
          threadsSupported: r.threadsSupported,
          bridgeId: r.bridgeId,
          bridgeBot: r.bridgeBot,
          protocolId: r.protocolId,
          protocolName: r.protocolName,
          loginId: r.loginId,
          roomType: r.roomType,
          markedUnread: r.markedUnread,
        ),
      )
      .toList();

  @override
  Future<List<Message>> timeline(String roomId, {int limit = 60}) async => (await rs.roomTimeline(roomId: roomId, limit: limit)).map(message).toList();

  @override
  Future<List<Message>> thread(String roomId, String rootId, {int limit = 100}) async =>
      (await rs.threadTimeline(roomId: roomId, rootId: rootId, limit: limit)).map(message).toList();

  @override
  Future<String> sendText(String roomId, String body, {String? threadRoot}) => rs.sendText(roomId: roomId, body: body, threadRoot: threadRoot);

  @override
  Future<void> markRead(String roomId, {String? eventId}) => rs.markRead(roomId: roomId, eventId: eventId);

  @override
  Future<void> setMarkedUnread(String roomId, bool unread) => rs.setMarkedUnread(roomId: roomId, unread: unread);

  @override
  Future<Uint8List> mediaBytes(String source, {int? thumbWidth, int? thumbHeight}) =>
      rs.mediaBytes(source: source, thumbWidth: thumbWidth, thumbHeight: thumbHeight);

  @override
  Future<List<DirectoryUser>> searchDirectory(String term) async =>
      (await rs.searchDirectory(term: term, limit: 20)).map((u) => DirectoryUser(userId: u.userId, displayName: u.displayName)).toList();

  @override
  Future<String> createDm(String userId) => rs.createDm(userId: userId);

  @override
  Future<String> createGroup(String name, List<String> invites) => rs.createGroup(name: name, invites: invites);

  @override
  Future<String> joinRoom(String idOrAlias) => rs.joinRoom(roomIdOrAlias: idOrAlias);

  @override
  Future<Map<String, dynamic>?> accountData(String type) async {
    final json = await rs.getAccountData(eventType: type);
    if (json == null) return null;
    final v = jsonDecode(json);
    return v is Map ? v.cast<String, dynamic>() : null;
  }

  @override
  Future<void> setAccountData(String type, Map<String, dynamic> content) => rs.setAccountData(eventType: type, json: jsonEncode(content));
}
