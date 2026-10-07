import '../models.dart';

/// Everything the UI needs from the Matrix core. Implemented by
/// [FfiBackend] (Rust core via flutter_rust_bridge) and [DemoBackend]
/// (in-memory sample data for tests, screenshots and UI work).
abstract class ChatBackend {
  String get name;

  Future<Session?> restore();
  Future<Session> login({required String homeserver, required String username, required String password});
  Future<void> logout();

  /// Starts syncing and streams updates.
  Stream<BackendUpdate> updates();

  Future<List<Room>> rooms();
  Future<List<Message>> timeline(String roomId, {int limit = 60});
  Future<List<Message>> thread(String roomId, String rootId, {int limit = 100});
  Future<String> sendText(String roomId, String body, {String? threadRoot});

  /// Plain-Matrix user directory (new-chat fallback).
  Future<List<DirectoryUser>> searchDirectory(String term);
  Future<String> createDm(String userId);
  Future<String> createGroup(String name, List<String> invites);
  Future<String> joinRoom(String idOrAlias);
}
