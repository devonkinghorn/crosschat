import 'dart:io';

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

  Session _session(rs.SessionInfo s) =>
      Session(userId: s.userId, deviceId: s.deviceId, homeserver: s.homeserver, accessToken: s.accessToken);

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
        ),
      )
      .toList();

  @override
  Future<List<Message>> timeline(String roomId, {int limit = 60}) async =>
      (await rs.roomTimeline(roomId: roomId, limit: limit)).map(message).toList();

  @override
  Future<List<Message>> thread(String roomId, String rootId, {int limit = 100}) async =>
      (await rs.threadTimeline(roomId: roomId, rootId: rootId, limit: limit)).map(message).toList();

  @override
  Future<String> sendText(String roomId, String body, {String? threadRoot}) =>
      rs.sendText(roomId: roomId, body: body, threadRoot: threadRoot);

  @override
  Future<List<DirectoryUser>> searchDirectory(String term) async => (await rs.searchDirectory(term: term, limit: 20))
      .map((u) => DirectoryUser(userId: u.userId, displayName: u.displayName))
      .toList();

  @override
  Future<String> createDm(String userId) => rs.createDm(userId: userId);

  @override
  Future<String> createGroup(String name, List<String> invites) => rs.createGroup(name: name, invites: invites);

  @override
  Future<String> joinRoom(String idOrAlias) => rs.joinRoom(roomIdOrAlias: idOrAlias);
}
