import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../backend/backend.dart';
import '../daemon/daemon_client.dart';
import '../models.dart';
import '../platform.dart';
import 'settings.dart';

/// Single source of UI state. Plain ChangeNotifier; the Rust core owns the
/// real Matrix state and pushes updates through [ChatBackend.updates].
class AppState extends ChangeNotifier {
  AppState({required this.backend, AppSettings? settings, PlatformCapabilities? capabilities, this.daemonHttp})
    : settings = settings ?? AppSettings(),
      capabilities = capabilities ?? PlatformCapabilities.current();

  final ChatBackend backend;
  final AppSettings settings;
  final PlatformCapabilities capabilities;

  /// HTTP client for crosschatd (injectable for tests).
  final http.Client? daemonHttp;

  bool initializing = true;
  Session? session;
  String? error;
  String syncState = 'idle';

  List<Room> rooms = [];
  String? networkFilter; // null = all networks
  String? selectedRoomId;
  List<Message> messages = [];
  bool loadingMessages = false;

  String? openThreadRoot;
  List<Message> threadMessages = [];

  DaemonClient? daemon;
  bool daemonAvailable = false;
  List<BridgeInfo> bridges = [];

  StreamSubscription<BackendUpdate>? _sub;
  Timer? _refreshDebounce;

  Room? get selectedRoom => rooms.where((r) => r.roomId == selectedRoomId).firstOrNull;

  /// Networks present in the room list (for the left rail).
  List<String> get networks {
    final ids = <String>{};
    for (final r in rooms) {
      ids.add(r.networkId ?? 'matrix');
    }
    const order = ['imessage', 'gmessages', 'slack', 'groupme', 'matrix'];
    final list = ids.toList()
      ..sort((a, b) {
        final ia = order.indexOf(a), ib = order.indexOf(b);
        return (ia < 0 ? 99 : ia).compareTo(ib < 0 ? 99 : ib);
      });
    return list;
  }

  List<Room> get visibleRooms =>
      networkFilter == null ? rooms : rooms.where((r) => (r.networkId ?? 'matrix') == networkFilter).toList();

  int unreadFor(String network) =>
      rooms.where((r) => (r.networkId ?? 'matrix') == network).fold(0, (a, r) => a + r.unread);

  Future<void> init() async {
    try {
      session = await backend.restore();
      if (session != null) await _afterLogin();
    } catch (e) {
      error = 'Could not restore session: $e';
    }
    initializing = false;
    notifyListeners();
  }

  Future<void> login(String homeserver, String username, String password) async {
    error = null;
    notifyListeners();
    try {
      session = await backend.login(homeserver: homeserver, username: username, password: password);
      await _afterLogin();
    } catch (e) {
      error = '$e';
    }
    notifyListeners();
  }

  Future<void> _afterLogin() async {
    _sub?.cancel();
    _sub = backend.updates().listen(_onUpdate);
    await refreshRooms();
    if (selectedRoomId == null && rooms.isNotEmpty) {
      await selectRoom(rooms.first.roomId);
    }
    if (settings.persistentSync && capabilities.hasPersistentSyncService) {
      await PersistentSyncService.setEnabled(true);
    }
    unawaited(connectDaemon());
  }

  /// Connect to crosschatd (bridge management, contact search). Optional:
  /// the app degrades to plain Matrix when it's unavailable.
  Future<void> connectDaemon() async {
    final s = session;
    if (s == null) return;
    final url = settings.daemonUrl.isNotEmpty ? settings.daemonUrl : s.homeserver;
    final client = DaemonClient(baseUrl: url, accessToken: s.accessToken, httpClient: daemonHttp);
    daemon = client;
    daemonAvailable = await client.isAvailable();
    if (daemonAvailable) {
      try {
        bridges = await client.networks();
      } catch (e) {
        daemonAvailable = false;
        debugPrint('crosschatd networks failed: $e');
      }
    }
    notifyListeners();
  }

  void _onUpdate(BackendUpdate u) {
    switch (u.kind) {
      case 'new_message':
        final m = u.message!;
        if (u.roomId == selectedRoomId) {
          if (m.threadRoot == null) {
            if (!messages.any((x) => x.eventId == m.eventId)) messages = [...messages, m];
          } else {
            _bumpThreadSummary(m);
            if (m.threadRoot == openThreadRoot && !threadMessages.any((x) => x.eventId == m.eventId)) {
              threadMessages = [...threadMessages, m];
            }
          }
        }
        _scheduleRoomRefresh();
      case 'sync_state':
        syncState = u.state ?? '';
      default:
        _scheduleRoomRefresh();
    }
    notifyListeners();
  }

  void _bumpThreadSummary(Message reply) {
    messages = [
      for (final m in messages)
        if (m.eventId == reply.threadRoot)
          Message(
            eventId: m.eventId,
            sender: m.sender,
            senderName: m.senderName,
            body: m.body,
            kind: m.kind,
            ts: m.ts,
            isOwn: m.isOwn,
            edited: m.edited,
            thread: ThreadSummary(
              replyCount: (m.thread?.replyCount ?? 0) + 1,
              latestReplyTs: reply.ts,
              latestReplyBody: reply.body,
              participants: [reply.sender, ...?m.thread?.participants.where((p) => p != reply.sender)],
            ),
          )
        else
          m,
    ];
  }

  void _scheduleRoomRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 400), refreshRooms);
  }

  Future<void> refreshRooms() async {
    try {
      rooms = await backend.rooms();
    } catch (e) {
      error = 'Room list failed: $e';
    }
    notifyListeners();
    // Fresh logins start with an empty store; pick a room once sync fills it.
    if (selectedRoomId == null && rooms.isNotEmpty) {
      await selectRoom(rooms.first.roomId);
    }
  }

  void setNetworkFilter(String? network) {
    networkFilter = network;
    notifyListeners();
  }

  Future<void> selectRoom(String roomId) async {
    selectedRoomId = roomId;
    openThreadRoot = null;
    threadMessages = [];
    loadingMessages = true;
    notifyListeners();
    try {
      messages = await backend.timeline(roomId);
    } catch (e) {
      messages = [];
      error = 'Timeline failed: $e';
    }
    loadingMessages = false;
    notifyListeners();
  }

  Future<void> openThread(String rootId) async {
    final roomId = selectedRoomId;
    if (roomId == null) return;
    openThreadRoot = rootId;
    threadMessages = messages.where((m) => m.eventId == rootId).toList();
    notifyListeners();
    try {
      threadMessages = await backend.thread(roomId, rootId);
    } catch (e) {
      error = 'Thread failed: $e';
    }
    notifyListeners();
  }

  void closeThread() {
    openThreadRoot = null;
    threadMessages = [];
    notifyListeners();
  }

  Future<void> send(String text, {String? threadRoot}) async {
    final roomId = selectedRoomId;
    final body = text.trim();
    if (roomId == null || body.isEmpty) return;
    try {
      await backend.sendText(roomId, body, threadRoot: threadRoot);
    } catch (e) {
      error = 'Send failed: $e';
      notifyListeners();
    }
  }

  Future<void> openOrCreateDm(String userId) async {
    final roomId = await backend.createDm(userId);
    await refreshRooms();
    await selectRoom(roomId);
  }

  /// Open a bridged portal room created via the provisioning API.
  Future<void> openPortal(String roomId) async {
    await refreshRooms();
    if (!rooms.any((r) => r.roomId == roomId)) {
      try {
        await backend.joinRoom(roomId);
      } catch (_) {}
      await refreshRooms();
    }
    await selectRoom(roomId);
  }

  Future<void> setPersistentSync(bool enabled) async {
    settings.persistentSync = enabled;
    await settings.save();
    if (capabilities.hasPersistentSyncService && session != null) {
      await PersistentSyncService.setEnabled(enabled);
    }
    notifyListeners();
  }

  Future<void> setDaemonUrl(String url) async {
    settings.daemonUrl = url.trim();
    await settings.save();
    await connectDaemon();
  }

  void clearError() {
    error = null;
    notifyListeners();
  }

  Future<void> logout() async {
    await _sub?.cancel();
    _sub = null;
    await PersistentSyncService.setEnabled(false);
    try {
      await backend.logout();
    } catch (_) {}
    session = null;
    rooms = [];
    messages = [];
    selectedRoomId = null;
    openThreadRoot = null;
    daemon = null;
    daemonAvailable = false;
    bridges = [];
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _refreshDebounce?.cancel();
    super.dispose();
  }
}
