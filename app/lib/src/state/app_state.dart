import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../backend/backend.dart';
import '../contacts/device_contacts.dart';
import '../contacts/people.dart';
import '../daemon/daemon_client.dart';
import '../local/local_server.dart';
import '../models.dart';
import '../platform.dart';
import '../ui/media_cache.dart';
import 'network_groups.dart';
import 'saved.dart';
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

  /// This user may add and remove networks (server admin, crosschatd that
  /// supports it).
  bool canManageNetworks = false;

  /// The server keeps its computer awake (a network like iMessage needs it).
  bool keepingAwake = false;

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
    unawaited(loadSaved());
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
        _applyNetworks(await client.networksInfo());
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

  void _applyNetworks(NetworksInfo info) {
    bridges = info.bridges;
    canManageNetworks = info.canManage && info.admin;
    keepingAwake = info.keepingAwake;
  }

  BridgeInfo? bridge(String id) {
    for (final b in bridges) {
      if (b.id == id) return b;
    }
    return null;
  }

  /// Re-read the bridge list from crosschatd.
  Future<void> refreshBridges() async {
    final d = daemon;
    if (d == null || !daemonAvailable) return;
    _applyNetworks(await d.networksInfo());
    _recompute();
    notifyListeners();
  }

  /// Polling interval while a network is being added.
  @visibleForTesting
  Duration networkPollInterval = const Duration(seconds: 1);

  /// "Add network": crosschatd installs the bridge (prebuilt, checksum
  /// pinned), configures it, registers it with the homeserver (restarting
  /// it if needed; chats reconnect by themselves) and starts it. Completes
  /// when the bridge is ready to sign in; [bridges] shows progress meanwhile.
  Future<BridgeInfo> enableNetwork(String id, {Duration timeout = const Duration(minutes: 8)}) async {
    final d = daemon;
    if (d == null || !daemonAvailable) throw StateError('crosschatd is not connected');
    await d.bridgeAction(id, 'enable');
    final deadline = clock().add(timeout);
    while (true) {
      await Future<void>.delayed(networkPollInterval);
      BridgeInfo? b;
      try {
        await refreshBridges();
        b = bridge(id);
        if (b == null) throw NetworkSetupException('crosschatd doesn\'t know $id');
      } on NetworkSetupException {
        rethrow;
      } catch (_) {
        // The homeserver restarts while the network is added; crosschatd
        // can't check tokens for a moment.
      }
      if (b != null && b.progress == null) {
        if (b.setupError != null) throw NetworkSetupException(b.setupError!);
        if (b.ready) {
          await refreshAccounts();
          _ensureAccountsTimer();
          return b;
        }
      }
      if (clock().isAfter(deadline)) {
        throw NetworkSetupException(b?.setupError ?? 'Timed out (${b?.progress ?? b?.processState ?? 'not started'})');
      }
    }
  }

  /// Turn a network off. Its logins and data stay; adding it again resumes.
  Future<void> disableNetwork(String id) async {
    await daemon!.bridgeAction(id, 'disable');
    accounts.remove(id);
    await refreshBridges();
  }

  /// Sign out of a network and delete its data on the server.
  Future<void> removeNetwork(String id) async {
    await daemon!.bridgeAction(id, 'remove');
    accounts.remove(id);
    await refreshBridges();
  }

  // ---- Contacts (new chat) -------------------------------------------------

  ContactsAccess contactsAccess = ContactsAccess.unsupported;
  List<DeviceContact> deviceContactList = [];

  /// Per-person network choices (Matrix account data, synced).
  ContactNetworkPrefs networkPrefs = ContactNetworkPrefs();
  bool _prefsLoaded = false;

  /// iMessage reachability per `tel:` / `mailto:` key (null = not reachable).
  final Map<String, Contact?> _imessageReach = {};

  /// Country calling code for numbers saved without one.
  String callingCode = callingCodeFor(PlatformDispatcher.instance.locale.countryCode);

  /// Read the address book; with [ask], show the system prompt if the user
  /// hasn't decided yet. Denied or unsupported just means no device contacts.
  Future<void> loadDeviceContacts({bool ask = false}) async {
    try {
      var a = await deviceContacts.status();
      if (ask && a == ContactsAccess.notDetermined) a = await deviceContacts.request();
      contactsAccess = a;
      deviceContactList = a == ContactsAccess.granted ? await deviceContacts.list() : const [];
    } catch (e) {
      debugPrint('contacts: $e');
      deviceContactList = const [];
    }
    notifyListeners();
  }

  Future<void> loadNetworkPrefs() async {
    if (_prefsLoaded || session == null) return;
    try {
      networkPrefs = ContactNetworkPrefs.fromJson(await backend.accountData(ContactNetworkPrefs.eventType));
      _prefsLoaded = true;
    } catch (e) {
      debugPrint('contact network prefs: $e');
    }
  }

  Future<void> _saveNetworkPrefs() async {
    try {
      await backend.setAccountData(ContactNetworkPrefs.eventType, networkPrefs.toJson());
    } catch (e) {
      debugPrint('saving contact network prefs: $e');
    }
  }

  /// Bridges that are running with at least one login.
  Set<String> get usableBridges => {
    for (final b in bridges)
      if (b.running && (accounts[b.id]?.logins.isNotEmpty ?? false)) b.id,
  };

  /// The `tel:` / `mailto:` key iMessage can reach [p] at, if any
  /// (bridgev2 `resolve_identifier`, cached).
  Future<String?> imessageIdentifier(Person p) async {
    final d = daemon;
    if (d == null || !usableBridges.contains('imessage')) return null;
    for (final id in p.identifiers) {
      if (!_imessageReach.containsKey(id)) {
        try {
          _imessageReach[id] = (await d.resolve(id, bridges: const ['imessage']))['imessage'];
        } catch (e) {
          debugPrint('iMessage lookup failed: $e');
          continue;
        }
      }
      if (_imessageReach[id] != null) return id;
    }
    return null;
  }

  /// Known iMessage reachability for [p] without asking: true / false, or
  /// null when not checked yet.
  bool? imessageReachableCached(Person p) {
    var unknown = false;
    for (final id in p.identifiers) {
      if (!_imessageReach.containsKey(id)) {
        unknown = true;
      } else if (_imessageReach[id] != null) {
        return true;
      }
    }
    return unknown ? null : false;
  }

  /// Where a chat with [p] goes: the network the user picked for them, else
  /// iMessage when it can reach them, else Google Messages (RCS/SMS), else
  /// the network they were found on.
  Future<String?> networkFor(Person p) async {
    await loadNetworkPrefs();
    final candidates = candidateNetworks(p, usableBridges);
    final saved = networkPrefs.byContact[p.key];
    if (saved != null && candidates.contains(saved)) return saved;
    if (candidates.contains('imessage') && await imessageIdentifier(p) != null) return 'imessage';
    for (final b in candidates) {
      if (b != 'imessage') return b;
    }
    return null;
  }

  /// Remember [bridge] for [p] (synced through account data).
  Future<void> setNetworkFor(Person p, String bridge) async {
    await loadNetworkPrefs();
    networkPrefs.byContact[p.key] = bridge;
    notifyListeners();
    await _saveNetworkPrefs();
  }

  /// Open (or create) the DM with [p] on [bridge] (default [networkFor]).
  /// Picking a network explicitly remembers it for this person.
  Future<void> openPerson(Person p, {String? bridge}) async {
    final d = daemon;
    if (d == null) throw StateError('crosschatd is not connected');
    await loadNetworkPrefs();
    final b = bridge ?? await networkFor(p);
    if (b == null) throw StateError('${p.name} isn\'t reachable on a connected network');
    final c = p.contactOn(b);
    var roomId = c?.dmRoomMxid;
    if (roomId == null) {
      final ident =
          c?.id ??
          (b == 'imessage' ? (await imessageIdentifier(p) ?? p.identifiers.first) : (p.phones.isNotEmpty ? 'tel:${p.phones.first}' : p.identifiers.first));
      roomId = await d.startDm(b, ident);
    }
    if (roomId == null) throw StateError('The bridge didn\'t return a chat');
    networkPrefs.rooms[roomId] = p.key;
    if (bridge != null) networkPrefs.byContact[p.key] = bridge;
    unawaited(_saveNetworkPrefs());
    await openPortal(roomId);
  }

  /// The person behind a DM opened from the contact picker (for the network
  /// switcher by the composer), or null.
  Person? personForRoom(Room room) {
    final key = networkPrefs.rooms[room.roomId];
    if (key == null || !(key.startsWith('tel:') || key.startsWith('mailto:'))) return null;
    return Person(key: key, name: room.name, identifiers: {key});
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
        if (showingSaved && saved.items.any((i) => i.roomId == u.roomId)) _scheduleSavedReload();
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
    final root = openThreadRoot;
    if (root != null) unawaited(_reloadThread(roomId, root));
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

  Future<void> _reloadThread(String roomId, String root) async {
    try {
      final fresh = await backend.thread(roomId, root);
      if (selectedRoomId != roomId || openThreadRoot != root) return;
      threadMessages = fresh;
      notifyListeners();
    } catch (_) {}
  }

  // ---- Reactions -------------------------------------------------------------

  /// Toggle the user's reaction [key] on [m] (in the open chat, or
  /// [roomId]): click on a chip, quick reaction or picker choice. Returns a
  /// message for the user when it didn't (fully) work.
  Future<String?> toggleReaction(Message m, String key, {String? roomId}) {
    final g = m.reactions.where((r) => r.matches(key)).firstOrNull;
    return react(m, key, add: !(g?.own ?? false), roomId: roomId);
  }

  /// Add or remove the user's reaction: a real `m.reaction` / redaction,
  /// applied locally right away and reconciled by the next timeline reload.
  Future<String?> react(Message m, String key, {required bool add, String? roomId}) async {
    final room = roomId ?? selectedRoomId;
    final me = session?.userId;
    if (room == null || me == null) return null;
    final group = m.reactions.where((r) => r.matches(key)).firstOrNull;
    _applyLocalReaction(m.eventId, key, me, add: add);
    notifyListeners();
    String? problem;
    try {
      final changed = await backend.setReaction(room, m.eventId, key, add: add);
      if (!add && !changed && group != null && group.ownFromText) {
        problem = 'That reaction was sent from your phone as a text message, so it can only be removed there.';
      }
    } catch (e) {
      problem = 'Reaction failed: $e';
    }
    if (room == selectedRoomId) _scheduleTimelineReload();
    if (showingSaved) _scheduleSavedReload();
    return problem;
  }

  void _applyLocalReaction(String eventId, String key, String me, {required bool add}) {
    List<Message> apply(List<Message> list) => [
      for (final x in list)
        if (x.eventId == eventId) x.copyWith(reactions: applyOwnReaction(x.reactions, key, me, add: add)) else x,
    ];
    messages = apply(messages);
    threadMessages = apply(threadMessages);
    savedMessages = {
      for (final e in savedMessages.entries)
        e.key: e.value == null || e.value!.eventId != eventId ? e.value : e.value!.copyWith(reactions: applyOwnReaction(e.value!.reactions, key, me, add: add)),
    };
  }

  // ---- Saved for later -------------------------------------------------------

  SavedMessages saved = SavedMessages();
  bool _savedLoaded = false;

  /// The Saved view is open instead of a chat.
  bool showingSaved = false;

  /// `roomId|eventId` -> the saved message (null: gone / not loadable).
  Map<String, Message?> savedMessages = {};
  bool loadingSaved = false;
  Timer? _savedDebounce;

  static String _savedKey(String roomId, String eventId) => '$roomId|$eventId';

  bool isSaved(String roomId, String eventId) => saved.contains(roomId, eventId);

  Future<void> loadSaved({bool force = false}) async {
    if ((_savedLoaded && !force) || session == null) return;
    try {
      saved = SavedMessages.fromJson(await backend.accountData(SavedMessages.eventType));
      _savedLoaded = true;
      notifyListeners();
    } catch (e) {
      debugPrint('saved messages: $e');
    }
  }

  /// Save [m] (in [roomId], default the open chat) for later, or unsave it.
  /// Returns a message for the user when saving failed.
  Future<String?> toggleSaved(Message m, {String? roomId}) async {
    final room = roomId ?? selectedRoomId;
    if (room == null) return null;
    await loadSaved();
    final items = [...saved.items];
    final i = items.indexWhere((x) => x.roomId == room && x.eventId == m.eventId);
    if (i >= 0) {
      items.removeAt(i);
    } else {
      items.insert(0, SavedItem(roomId: room, eventId: m.eventId, savedAt: clock().millisecondsSinceEpoch));
      savedMessages = {...savedMessages, _savedKey(room, m.eventId): m};
    }
    final before = saved;
    saved = SavedMessages(items);
    notifyListeners();
    try {
      await backend.setAccountData(SavedMessages.eventType, saved.toJson());
      return null;
    } catch (e) {
      saved = before;
      notifyListeners();
      return 'Saving failed: $e';
    }
  }

  /// Show the Saved list (sidebar entry).
  Future<void> openSaved() async {
    showingSaved = true;
    openThreadRoot = null;
    threadMessages = [];
    notifyListeners();
    await loadSaved(force: true);
    await _loadSavedMessages();
  }

  void closeSaved() {
    showingSaved = false;
    notifyListeners();
  }

  Message? savedMessage(SavedItem i) => savedMessages[_savedKey(i.roomId, i.eventId)];
  bool savedMessageLoaded(SavedItem i) => savedMessages.containsKey(_savedKey(i.roomId, i.eventId));

  void _scheduleSavedReload() {
    _savedDebounce?.cancel();
    _savedDebounce = Timer(const Duration(milliseconds: 400), _loadSavedMessages);
  }

  Future<void> _loadSavedMessages() async {
    loadingSaved = true;
    notifyListeners();
    final out = <String, Message?>{};
    await Future.wait([
      for (final i in saved.items)
        () async {
          try {
            out[_savedKey(i.roomId, i.eventId)] = await backend.message(i.roomId, i.eventId);
          } catch (_) {
            out[_savedKey(i.roomId, i.eventId)] = null;
          }
        }(),
    ]);
    savedMessages = out;
    loadingSaved = false;
    notifyListeners();
  }

  /// Jump from the Saved list to a message: open its chat (and thread).
  Future<void> openSavedItem(SavedItem i) async {
    final m = savedMessage(i);
    await selectRoom(i.roomId);
    final root = m?.threadRoot;
    if (root != null) await openThread(root);
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
    if (userInitiated) showingSaved = false;
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
    canManageNetworks = false;
    keepingAwake = false;
    networkPrefs = ContactNetworkPrefs();
    _prefsLoaded = false;
    _imessageReach.clear();
    saved = SavedMessages();
    _savedLoaded = false;
    savedMessages = {};
    showingSaved = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _refreshDebounce?.cancel();
    _timelineDebounce?.cancel();
    _savedDebounce?.cancel();
    _markReadDebounce?.cancel();
    _accountsTimer?.cancel();
    super.dispose();
  }
}

class NetworkSetupException implements Exception {
  NetworkSetupException(this.message);
  final String message;
  @override
  String toString() => message;
}
