import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../backend/backend.dart';
import '../daemon/daemon_client.dart';
import '../local/local_server.dart';
import '../models.dart';
import '../platform.dart';
import 'network_groups.dart';
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
       syncTracker = syncTracker ?? SyncTracker();

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

  Room? get selectedRoom => rooms.where((r) => r.roomId == selectedRoomId).firstOrNull;

  /// Rail entry keys, in display order.
  List<String> get networks => [for (final g in networkGroups) g.key];

  NetworkGroup? groupFor(String? key) => key == null ? null : networkGroups.where((g) => g.key == key).firstOrNull;

  List<Room> get visibleRooms => networkFilter == null ? rooms : rooms.where((r) => r.groupKey == networkFilter).toList();

  int unreadFor(String key) => rooms.where((r) => r.groupKey == key).fold(0, (a, r) => a + r.unread);

  /// Rebuild rooms + rail entries from the raw room list and bridge accounts.
  void _recompute() {
    final view = resolveNetworks(
      _rawRooms,
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
      _rawRooms = await backend.rooms();
      _recompute();
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
    _accountsTimer?.cancel();
    super.dispose();
  }
}
