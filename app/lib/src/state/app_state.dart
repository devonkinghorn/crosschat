import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../backend/backend.dart';
import '../daemon/daemon_client.dart';
import '../local/local_server.dart';
import '../models.dart';
import '../platform.dart';
import '../ui/media_cache.dart';
import 'network_groups.dart';
import 'timeline_fold.dart';
import 'settings.dart';

/// Single source of UI state. Plain ChangeNotifier; the Rust core owns the
/// real Matrix state and pushes updates through [ChatBackend.updates].
class AppState extends ChangeNotifier {
  AppState({
    required this.backend,
    AppSettings? settings,
    PlatformCapabilities? capabilities,
    this.daemonHttp,
    this.localServer,
    this.accountsPollInterval = const Duration(seconds: 3),
    DateTime Function()? clock,
    SyncTracker? syncTracker,
  }) : settings = settings ?? AppSettings(),
       capabilities = capabilities ?? PlatformCapabilities.current(),
       clock = clock ?? DateTime.now,
       syncTracker = syncTracker ?? SyncTracker() {
    MediaCache.instance
      ..clear()
      ..backend = backend;
  }

  /// How often bridge accounts are checked while something is syncing (idle:
  /// every [_idleAccountsPoll]). `null` = no timer (tests drive it).
  final Duration? accountsPollInterval;
  static const _idleAccountsPoll = Duration(seconds: 30);
  final DateTime Function() clock;
  final SyncTracker syncTracker;

  /// The this-computer-only server (desktop). Null = not available (tests,
  /// demo mode, platforms without process support).
  final LocalServerController? localServer;

  /// Owner of the local server if one was set up on this computer.
  String? localOwner;

  /// Progress of starting/creating the local server (null when idle).
  LocalServerStatus? localStatus;

  /// Last local-server failure (shown on the setup/login screen).
  String? localError;

  bool get localServerSupported => localServer?.supported ?? false;

  /// Logged in to the local server.
  bool get isLocalSession => localServer != null && session != null && _sameUrl(session!.homeserver, localServer!.homeserverUrl);

  static bool _sameUrl(String a, String b) {
    String n(String u) => u.trim().replaceAll(RegExp(r'/+$'), '').toLowerCase();
    return n(a) == n(b);
  }

  final ChatBackend backend;
  final AppSettings settings;
  final PlatformCapabilities capabilities;

  /// HTTP client for crosschatd (injectable for tests).
  final http.Client? daemonHttp;

  bool initializing = true;
  Session? session;
  String? error;
  String syncState = 'idle';

  /// Chats (bridge spaces removed), each tagged with its rail entry.
  List<Room> rooms = [];
  List<Room> _rawRooms = [];

  /// Rail entries: one per bridge login, with sync/health state.
  List<NetworkGroup> networkGroups = [];

  /// The user's accounts per bridge id (bridgev2 whoami via crosschatd).
  Map<String, BridgeAccounts> accounts = {};

  /// Bridges that just completed a login whose account isn't listed yet.
  final Map<String, DateTime> _pendingLogins = {};
  DateTime? _lastAccountsPoll;
  Timer? _accountsTimer;
  bool _pollingAccounts = false;

  String? networkFilter; // null = all networks, else a NetworkGroup.key
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
  Timer? _timelineDebounce;

  // ---- Read state ----------------------------------------------------------
  // The server's unread counts only change on the next sync after a receipt,
  // so marking read/unread is applied locally right away and reconciled with
  // what the server reports (see [_applyReadState]).

  /// Window focused / app in the foreground. New messages in the open chat
  /// are only marked read while this is true.
  bool appFocused = true;

  /// The chat the user opened (clicked). Automatic selection at startup
  /// doesn't count, so launching the app never marks a chat read by itself.
  String? _readingRoomId;

  /// Set when the user marks the open chat unread: stop auto-marking it read
  /// until they open a chat again.
  String? _autoReadPaused;

  /// roomId -> lastTs of the room when we marked it read locally.
  final Map<String, int> _readLocally = {};

  /// roomId -> marked-unread value we set that sync hasn't confirmed yet.
  final Map<String, bool> _markedLocally = {};

  Timer? _markReadDebounce;
  String? _pendingReadEvent;

  Room? get selectedRoom => rooms.where((r) => r.roomId == selectedRoomId).firstOrNull;

  /// Rail entry keys, in display order.
  List<String> get networks => [for (final g in networkGroups) g.key];

  NetworkGroup? groupFor(String? key) => key == null ? null : networkGroups.where((g) => g.key == key).firstOrNull;

  List<Room> get visibleRooms => networkFilter == null ? rooms : rooms.where((r) => r.groupKey == networkFilter).toList();

  int unreadFor(String key) => rooms.where((r) => r.groupKey == key).fold(0, (a, r) => a + r.badgeCount);

  /// The raw rooms with local read/unread actions applied until the server
  /// reflects them: a chat marked read shows no badge until something newer
  /// than what we read arrives; a marked-unread flag shows until sync echoes it.
  List<Room> _applyReadState(List<Room> raw) => [for (final r in raw) _withReadState(r)];

  Room _withReadState(Room r) {
    var room = r;
    final marked = _markedLocally[r.roomId];
    if (marked != null) {
      if (r.markedUnread == marked) {
        _markedLocally.remove(r.roomId);
      } else {
        room = room.copyWith(markedUnread: marked);
      }
    }
    final readAt = _readLocally[r.roomId];
    if (readAt != null) {
      if (r.lastTs > readAt || (r.unread == 0 && !r.markedUnread && marked == null)) {
        // Newer activity (trust the server's count again), or the server caught up.
        _readLocally.remove(r.roomId);
      } else {
        room = room.copyWith(unread: 0, markedUnread: _markedLocally[r.roomId] ?? false);
      }
    }
    return room;
  }

  /// Rebuild rooms + rail entries from the raw room list and bridge accounts.
  void _recompute() {
    final view = resolveNetworks(
      _applyReadState(_rawRooms),
      bridges: bridges,
      accounts: accounts,
      pendingBridges: _pendingLogins.keys.toSet(),
      tracker: syncTracker,
      now: clock(),
    );
    rooms = view.rooms;
    networkGroups = view.groups;
    if (networkFilter != null && !networkGroups.any((g) => g.key == networkFilter)) networkFilter = null;
  }

  /// Called when a bridge login finishes: the network shows up right away as
  /// "Syncing chats…" and fills in as the bridge creates the chats.
  Future<void> noteLoginCompleted(String bridgeId) async {
    _pendingLogins[bridgeId] = clock();
    _recompute();
    notifyListeners();
    _ensureAccountsTimer();
    await refreshAccounts();
    await refreshRooms();
  }

  /// Fetch the user's logins on every enabled bridge.
  Future<void> refreshAccounts() async {
    final d = daemon;
    if (d == null || !daemonAvailable || _pollingAccounts) return;
    _pollingAccounts = true;
    final now = clock();
    try {
      final next = <String, BridgeAccounts>{};
      for (final b in bridges.where((b) => b.enabled)) {
        final prev = accounts[b.id];
        try {
          final j = await d.provision(b.id, 'GET', 'v3/whoami', timeout: const Duration(seconds: 8));
          final acc = BridgeAccounts.fromWhoami(b, (j as Map).cast<String, dynamic>());
          next[b.id] = acc;
          _noteNewLogins(b.id, prev, acc, now);
        } catch (e) {
          if (prev != null && prev.logins.isNotEmpty) next[b.id] = prev.withUnreachable(b.running ? 'no answer' : 'not running');
        }
      }
      accounts = next;
      _lastAccountsPoll = now;
      // A pending login nobody picked up (failed, or the bridge restarted).
      _pendingLogins.removeWhere((_, since) => now.difference(since) > syncTracker.maxSync);
    } finally {
      _pollingAccounts = false;
    }
    _recompute();
    notifyListeners();
  }

  void _noteNewLogins(String bridgeId, BridgeAccounts? prev, BridgeAccounts acc, DateTime now) {
    final before = prev?.logins.map((l) => l.id).toSet();
    final fresh = [
      for (final l in acc.logins)
        if (before != null && !before.contains(l.id)) l.id,
    ];
    final pending = _pendingLogins.containsKey(bridgeId);
    if (pending && acc.logins.isNotEmpty) {
      // Signed in from this app: the new account (or, for a re-login of the
      // same account, every account on the bridge) is syncing.
      for (final id in fresh.isNotEmpty ? fresh : acc.logins.map((l) => l.id)) {
        syncTracker.start('$bridgeId/$id', _pendingLogins[bridgeId]!);
      }
      _pendingLogins.remove(bridgeId);
    } else {
      // Signed in elsewhere (another device, the bridge's bot commands).
      for (final id in fresh) {
        syncTracker.start('$bridgeId/$id', now);
      }
    }
  }

  void _ensureAccountsTimer() {
    final interval = accountsPollInterval;
    if (interval == null || _accountsTimer != null || !daemonAvailable) return;
    _accountsTimer = Timer.periodic(interval, (_) => tickAccounts());
  }

  /// Periodic check: poll fast while something is syncing, slowly otherwise;
  /// re-evaluate "syncing" (it settles once the chat count stops changing).
  Future<void> tickAccounts() async {
    final now = clock();
    final busy = syncTracker.active || _pendingLogins.isNotEmpty || networkGroups.any((g) => g.busy);
    final last = _lastAccountsPoll;
    if (busy || last == null || now.difference(last) >= _idleAccountsPoll) {
      await refreshAccounts();
    } else if (syncTracker.active) {
      _recompute();
      notifyListeners();
    }
  }

  Future<void> init() async {
    final local = localServer;
    if (local != null && local.supported) {
      localOwner = await local.configuredOwner();
      if (localOwner != null) {
        // A server was set up here before: start it (or reuse the running one).
        await _startLocal();
      }
    }
    try {
      session = await backend.restore();
      if (session != null) await _afterLogin();
    } catch (e) {
      error = 'Could not restore session: $e';
    }
    if (session != null && localError != null && isLocalSession) {
      error = 'Local server: $localError';
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

  Future<bool> _startLocal() async {
    final local = localServer!;
    localError = null;
    localStatus = const LocalServerStatus(phase: 'starting', detail: 'Starting the local server');
    notifyListeners();
    try {
      await local.start(
        onProgress: (s) {
          localStatus = s;
          notifyListeners();
        },
      );
      localStatus = null;
      return true;
    } catch (e) {
      localError = '$e';
      localStatus = null;
      return false;
    } finally {
      notifyListeners();
    }
  }

  /// First-run "Start a new server on this computer": start crosschatd +
  /// Tuwunel, create the owner account, then log in to it.
  Future<void> createLocalServer(String username, String password) async {
    final local = localServer;
    if (local == null || !local.supported) return;
    error = null;
    if (!await _startLocal()) return;
    try {
      localStatus = const LocalServerStatus(phase: 'starting', detail: 'Creating your account');
      notifyListeners();
      final userId = await local.createOwner(username, password);
      localOwner = userId;
      localStatus = const LocalServerStatus(phase: 'starting', detail: 'Signing in');
      notifyListeners();
      session = await backend.login(homeserver: local.homeserverUrl, username: username, password: password);
      localStatus = null;
      await _afterLogin();
    } catch (e) {
      localError = '$e';
      localStatus = null;
    }
    notifyListeners();
  }

  /// Retry starting the configured local server (after a failure).
  Future<void> retryLocalServer() async {
    final local = localServer;
    if (local == null) return;
    await local.stop();
    await _startLocal();
  }

  Future<void> _afterLogin() async {
    _sub?.cancel();
    _sub = backend.updates().listen(_onUpdate);
    await refreshRooms();
    if (selectedRoomId == null && rooms.isNotEmpty) {
      await selectRoom(rooms.first.roomId, userInitiated: false);
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
    final url = isLocalSession ? localServer!.daemonUrl : (settings.daemonUrl.isNotEmpty ? settings.daemonUrl : s.homeserver);
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
    if (daemonAvailable) {
      await refreshAccounts();
      _ensureAccountsTimer();
    }
    _recompute();
    notifyListeners();
  }

  void _onUpdate(BackendUpdate u) {
    switch (u.kind) {
      case 'new_message':
        final m = u.message!;
        if (u.roomId == selectedRoomId) {
          if (m.threadRoot == null) {
            if (!messages.any((x) => x.eventId == m.eventId)) messages = foldTapbacks([...messages, m]);
          } else {
            _bumpThreadSummary(m);
            if (m.threadRoot == openThreadRoot && !threadMessages.any((x) => x.eventId == m.eventId)) {
              threadMessages = [...threadMessages, m];
            }
          }
        }
        if (u.roomId == selectedRoomId && !m.isOwn) _noteSeen(u.roomId!, m);
        _scheduleRoomRefresh();
      case 'timeline_changed':
        if (u.roomId == selectedRoomId) _scheduleTimelineReload();
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
          m.copyWith(
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

  /// A message arrived in the open chat: mark it read if the user is looking.
  void _noteSeen(String roomId, Message m) {
    if (!_canAutoRead(roomId)) return;
    _readLocally[roomId] = m.ts > (_readLocally[roomId] ?? 0) ? m.ts : _readLocally[roomId]!;
    _pendingReadEvent = m.eventId;
    _markReadDebounce?.cancel();
    _markReadDebounce = Timer(const Duration(milliseconds: 500), () {
      final ev = _pendingReadEvent;
      _pendingReadEvent = null;
      if (selectedRoomId == roomId) unawaited(_sendRead(roomId, eventId: ev));
    });
  }

  bool _canAutoRead(String roomId) => appFocused && _readingRoomId == roomId && _autoReadPaused != roomId;

  /// Window focus / app lifecycle changed.
  void setAppFocused(bool focused) {
    if (appFocused == focused) return;
    appFocused = focused;
    final id = selectedRoomId;
    if (focused && id != null && _canAutoRead(id) && (selectedRoom?.isUnread ?? false)) {
      unawaited(markRead(id));
    }
  }

  /// Mark a chat read now (clears its badge immediately) and tell the server
  /// (read receipt + fully-read marker on the latest message).
  Future<void> markRead(String roomId, {String? eventId}) async {
    final room = rooms.where((r) => r.roomId == roomId).firstOrNull ?? _rawRooms.where((r) => r.roomId == roomId).firstOrNull;
    _readLocally[roomId] = room?.lastTs ?? 0;
    if (room?.markedUnread ?? false) _markedLocally[roomId] = false;
    _recompute();
    notifyListeners();
    await _sendRead(roomId, eventId: eventId);
  }

  Future<void> _sendRead(String roomId, {String? eventId}) async {
    try {
      await backend.markRead(roomId, eventId: eventId);
    } catch (e) {
      _readLocally.remove(roomId);
      _markedLocally.remove(roomId);
      error = 'Could not mark as read: $e';
      _recompute();
      notifyListeners();
    }
  }

  /// Mark a chat unread (MSC2867). Marking the open chat unread keeps it
  /// unread until the user opens a chat again.
  Future<void> markUnread(String roomId) async {
    _readLocally.remove(roomId);
    _markedLocally[roomId] = true;
    if (roomId == selectedRoomId) _autoReadPaused = roomId;
    _recompute();
    notifyListeners();
    try {
      await backend.setMarkedUnread(roomId, true);
    } catch (e) {
      _markedLocally.remove(roomId);
      error = 'Could not mark as unread: $e';
      _recompute();
      notifyListeners();
    }
  }

  void _scheduleTimelineReload() {
    _timelineDebounce?.cancel();
    _timelineDebounce = Timer(const Duration(milliseconds: 300), reloadTimeline);
  }

  /// Re-fetch the open chat's timeline (reactions, edits, names changed).
  Future<void> reloadTimeline() async {
    final roomId = selectedRoomId;
    if (roomId == null) return;
    try {
      final fresh = foldTapbacks(await backend.timeline(roomId));
      if (selectedRoomId != roomId) return;
      // Keep live messages newer than the fetched page.
      final lastTs = fresh.isEmpty ? 0 : fresh.last.ts;
      final ids = fresh.map((m) => m.eventId).toSet();
      messages = foldTapbacks([...fresh, ...messages.where((m) => m.ts > lastTs && !ids.contains(m.eventId))]);
      notifyListeners();
    } catch (_) {}
  }

  void _scheduleRoomRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 400), refreshRooms);
  }

  Future<void> refreshRooms() async {
    try {
      _rawRooms = await backend.rooms();
      _recompute();
    } catch (e) {
      error = 'Room list failed: $e';
    }
    notifyListeners();
    // Fresh logins start with an empty store; pick a room once sync fills it.
    if (selectedRoomId == null && rooms.isNotEmpty) {
      await selectRoom(rooms.first.roomId, userInitiated: false);
    }
  }

  void setNetworkFilter(String? network) {
    networkFilter = network;
    notifyListeners();
  }

  /// Open a chat. [userInitiated] (a click/tap) also marks it read; the
  /// automatic selection at startup doesn't.
  Future<void> selectRoom(String roomId, {bool userInitiated = true}) async {
    selectedRoomId = roomId;
    openThreadRoot = null;
    threadMessages = [];
    loadingMessages = true;
    _markReadDebounce?.cancel();
    _pendingReadEvent = null;
    if (userInitiated) {
      _readingRoomId = roomId;
      _autoReadPaused = null;
      final room = rooms.where((r) => r.roomId == roomId).firstOrNull;
      if (appFocused && room != null && room.isUnread) {
        unawaited(markRead(roomId));
      }
    } else if (_readingRoomId != roomId) {
      _readingRoomId = null;
    }
    notifyListeners();
    try {
      messages = foldTapbacks(await backend.timeline(roomId));
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
    _accountsTimer?.cancel();
    _accountsTimer = null;
    accounts = {};
    _pendingLogins.clear();
    networkGroups = [];
    networkFilter = null;
    _rawRooms = [];
    rooms = [];
    messages = [];
    selectedRoomId = null;
    _readingRoomId = null;
    _autoReadPaused = null;
    _readLocally.clear();
    _markedLocally.clear();
    MediaCache.instance.clear();
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
    _timelineDebounce?.cancel();
    _markReadDebounce?.cancel();
    _accountsTimer?.cancel();
    super.dispose();
  }
}
