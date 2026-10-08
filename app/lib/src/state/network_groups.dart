/// Network rail model: one entry per bridge login ("Google Messages",
/// subtitle = the account), with a sync/health state.
///
/// Rooms are grouped by *bridge* (bot / appservice id / canonical network
/// id), never by the raw `m.bridge` `protocol.id`: Google Messages labels
/// each chat `gmessages-rcs` or `gmessages-sms` and its per-account space
/// `gmessages`, which used to produce three rail entries (one of them the
/// empty space). Bridge spaces are not chats and are dropped.
library;

import '../daemon/daemon_client.dart';
import '../models.dart';

/// One account on a bridge (bridgev2 `GET /v3/whoami` `logins[]`).
class BridgeLogin {
  const BridgeLogin({required this.id, this.name, this.stateEvent, this.error, this.message, this.spaceRoom});

  factory BridgeLogin.fromJson(Map<String, dynamic> j) {
    final st = (j['state'] as Map?)?.cast<String, dynamic>() ?? const {};
    String? s(Object? v) => v is String && v.isNotEmpty ? v : null;
    return BridgeLogin(
      id: j['id'] as String,
      name: s(j['name']),
      stateEvent: s(st['state_event']) ?? s(j['state_event']),
      error: s(st['error']),
      message: s(st['message']) ?? s(st['reason']),
      spaceRoom: s(j['space_room']),
    );
  }

  final String id;
  final String? name;

  /// bridgev2 bridge state: CONNECTED, CONNECTING, BACKFILLING,
  /// TRANSIENT_DISCONNECT, BAD_CREDENTIALS, LOGGED_OUT, UNKNOWN_ERROR, ...
  final String? stateEvent;
  final String? error;
  final String? message;
  final String? spaceRoom;
}

/// A running bridge and the user's logins on it.
class BridgeAccounts {
  const BridgeAccounts({required this.bridgeId, required this.network, required this.displayName, this.bridgeBot, this.logins = const [], this.unreachable});

  factory BridgeAccounts.fromWhoami(BridgeInfo b, Map<String, dynamic> j) => BridgeAccounts(
    bridgeId: b.id,
    network: b.network,
    displayName: b.displayName,
    bridgeBot: j['bridge_bot'] as String?,
    logins: ((j['logins'] as List?) ?? const []).cast<Map<String, dynamic>>().map(BridgeLogin.fromJson).toList(),
  );

  final String bridgeId;
  final String network;
  final String displayName;
  final String? bridgeBot;
  final List<BridgeLogin> logins;

  /// Set when the bridge didn't answer (not running, crashed, ...).
  final String? unreachable;

  BridgeAccounts withUnreachable(String why) =>
      BridgeAccounts(bridgeId: bridgeId, network: network, displayName: displayName, bridgeBot: bridgeBot, logins: logins, unreachable: why);
}

enum NetworkHealth { ok, connecting, syncing, error, needsRelogin }

class NetworkGroup {
  const NetworkGroup({
    required this.key,
    required this.networkId,
    required this.label,
    this.bridgeId,
    this.loginId,
    this.subtitle,
    this.roomCount = 0,
    this.unread = 0,
    this.health = NetworkHealth.ok,
    this.status,
  });

  /// Rail/filter key: the network id, or `<network>/<login id>` when the
  /// user has several accounts on one bridge.
  final String key;

  /// Style id (`gmessages`, `slack`, ..., `matrix`).
  final String networkId;
  final String label;
  final String? bridgeId;
  final String? loginId;

  /// The account (e.g. the Google account / phone number).
  final String? subtitle;
  final int roomCount;
  final int unread;
  final NetworkHealth health;

  /// "Syncing chats… 12 so far", "Signed out. Sign in again.", ...
  final String? status;

  bool get busy => health == NetworkHealth.syncing || health == NetworkHealth.connecting;
  bool get failing => health == NetworkHealth.error || health == NetworkHealth.needsRelogin;
}

/// Decides how long a fresh login counts as "syncing": from the moment the
/// login completes until its chat count stops changing for [settle] (or
/// [maxSync] passes).
class SyncTracker {
  SyncTracker({this.settle = const Duration(seconds: 20), this.maxSync = const Duration(minutes: 10)});

  final Duration settle;
  final Duration maxSync;
  final Map<String, DateTime> _started = {};
  final Map<String, int> _count = {};
  final Map<String, DateTime> _changed = {};

  /// `loginKey` is `<bridge id>/<login id>`.
  void start(String loginKey, DateTime now) => _started[loginKey] = now;

  bool get active => _started.isNotEmpty;

  void observe(String groupKey, int count, DateTime now) {
    if (_count[groupKey] != count) {
      _count[groupKey] = count;
      _changed[groupKey] = now;
    }
  }

  bool isSyncing(String loginKey, String groupKey, DateTime now) {
    final s = _started[loginKey];
    if (s == null) return false;
    if (now.difference(s) > maxSync) {
      _started.remove(loginKey);
      return false;
    }
    final count = _count[groupKey] ?? 0;
    final changed = _changed[groupKey];
    final last = changed == null || changed.isBefore(s) ? s : changed;
    if (count > 0 && now.difference(last) > settle) {
      _started.remove(loginKey);
      return false;
    }
    return true;
  }
}

class NetworkView {
  const NetworkView(this.rooms, this.groups);

  /// Chats (bridge spaces removed), each with its [Room.groupKey] set.
  final List<Room> rooms;

  /// Rail entries in display order; never empty unless something's going on
  /// (syncing, error, sign-in needed).
  final List<NetworkGroup> groups;
}

const _railOrder = ['imessage', 'gmessages', 'slack', 'groupme'];
const _spaceTypes = {'space', 'personal_filtering_space'};

String _loginSubtitle(String? name, String? id) {
  if (name != null) return name;
  if (id == null) return '';
  // gmessages login ids look like `<account>/<phone>`; show the account.
  final slash = id.indexOf('/');
  return slash > 0 ? id.substring(0, slash) : id;
}

/// Groups [raw] rooms into rail entries using what crosschatd knows about the
/// bridges ([bridges], [accounts] keyed by bridge id). [pendingBridges] just
/// finished a login whose account isn't listed yet; [tracker] marks fresh
/// logins as syncing.
NetworkView resolveNetworks(
  List<Room> raw, {
  List<BridgeInfo> bridges = const [],
  Map<String, BridgeAccounts> accounts = const {},
  Set<String> pendingBridges = const {},
  SyncTracker? tracker,
  DateTime? now,
}) {
  final clock = now ?? DateTime.now();
  final spaceRooms = {
    for (final a in accounts.values)
      for (final l in a.logins)
        if (l.spaceRoom != null) l.spaceRoom!,
  };
  BridgeAccounts? byBot(String? bot) => bot == null ? null : accounts.values.where((a) => a.bridgeBot == bot).firstOrNull;
  BridgeInfo? bridgeById(String? id) => id == null ? null : bridges.where((b) => b.id == id).firstOrNull;
  BridgeInfo? bridgeByNetwork(String n) => bridges.where((b) => b.network == n).firstOrNull;

  // 1. Which bridge/network is each chat on?
  final placed = <({Room room, String network, String? bridgeId})>[];
  for (final r in raw) {
    if (_spaceTypes.contains(r.roomType) || spaceRooms.contains(r.roomId)) continue;
    if (r.networkId == null && r.protocolId == null) {
      placed.add((room: r, network: 'matrix', bridgeId: null));
      continue;
    }
    final acc = byBot(r.bridgeBot);
    final b = acc != null ? bridgeById(acc.bridgeId) : bridgeById(r.bridgeId);
    final network = acc?.network ?? b?.network ?? r.networkId ?? r.protocolId!;
    placed.add((room: r, network: network, bridgeId: acc?.bridgeId ?? b?.id ?? r.bridgeId ?? bridgeByNetwork(network)?.id));
  }

  // 2. Several accounts on one network get one entry each.
  final loginsPerNetwork = <String, Set<String>>{};
  for (final a in accounts.values) {
    loginsPerNetwork.putIfAbsent(a.network, () => {}).addAll(a.logins.map((l) => l.id));
  }
  for (final p in placed) {
    final l = p.room.loginId;
    if (l != null && p.network != 'matrix') loginsPerNetwork.putIfAbsent(p.network, () => {}).add(l);
  }
  String keyFor(String network, String? loginId) => (loginsPerNetwork[network]?.length ?? 0) > 1 && loginId != null ? '$network/$loginId' : network;

  final rooms = <Room>[];
  final counts = <String, int>{}, unread = <String, int>{};
  final meta = <String, ({String network, String? bridgeId, String? loginId, String? name})>{};
  for (final p in placed) {
    final key = p.network == 'matrix' ? 'matrix' : keyFor(p.network, p.room.loginId);
    rooms.add(p.room.copyWith(networkId: p.network == 'matrix' ? null : p.network, bridgeId: p.bridgeId, groupKey: key));
    counts[key] = (counts[key] ?? 0) + 1;
    unread[key] = (unread[key] ?? 0) + p.room.unread;
    meta.putIfAbsent(key, () => (network: p.network, bridgeId: p.bridgeId, loginId: p.room.loginId, name: p.room.networkName));
  }

  // 3. Accounts without chats yet (just signed in, or broken).
  final loginOf = <String, ({BridgeAccounts acc, BridgeLogin? login})>{};
  for (final a in accounts.values) {
    if (a.logins.isEmpty) {
      if (pendingBridges.contains(a.bridgeId) || a.unreachable != null && counts.containsKey(a.network)) {
        loginOf[a.network] = (acc: a, login: null);
        meta.putIfAbsent(a.network, () => (network: a.network, bridgeId: a.bridgeId, loginId: null, name: a.displayName));
      }
      continue;
    }
    for (final l in a.logins) {
      final key = keyFor(a.network, l.id);
      loginOf[key] = (acc: a, login: l);
      meta.putIfAbsent(key, () => (network: a.network, bridgeId: a.bridgeId, loginId: l.id, name: a.displayName));
    }
  }
  for (final id in pendingBridges) {
    final b = bridgeById(id);
    if (b == null || accounts[id]?.logins.isNotEmpty == true) continue;
    meta.putIfAbsent(b.network, () => (network: b.network, bridgeId: b.id, loginId: null, name: b.displayName));
  }

  // 4. Status per entry.
  final groups = <NetworkGroup>[];
  for (final e in meta.entries) {
    final key = e.key, m = e.value;
    final count = counts[key] ?? 0;
    tracker?.observe(key, count, clock);
    final link = loginOf[key];
    final login = link?.login;
    final bridgeId = m.bridgeId ?? link?.acc.bridgeId;
    var health = NetworkHealth.ok;
    String? status;
    final st = login?.stateEvent;
    final syncing =
        bridgeId != null &&
        (pendingBridges.contains(bridgeId) && (login == null || count == 0) ||
            login != null && tracker != null && tracker.isSyncing('$bridgeId/${login.id}', key, clock));
    if (st == 'BAD_CREDENTIALS' || st == 'LOGGED_OUT') {
      health = NetworkHealth.needsRelogin;
      status = login?.message ?? 'Signed out. Sign in again to keep your chats syncing.';
    } else if (link?.acc.unreachable != null) {
      health = NetworkHealth.error;
      status = 'Bridge not responding: ${link!.acc.unreachable}';
    } else if (st == 'TRANSIENT_DISCONNECT' || st == 'UNKNOWN_ERROR' || st == 'BRIDGE_UNREACHABLE') {
      health = NetworkHealth.error;
      status = login?.message ?? (st == 'TRANSIENT_DISCONNECT' ? 'Reconnecting…' : 'Connection problem');
    } else if (syncing || st == 'BACKFILLING') {
      health = NetworkHealth.syncing;
      status = count == 0 ? 'Syncing chats…' : 'Syncing chats… $count so far';
    } else if (st == 'CONNECTING' || st == 'STARTING') {
      health = NetworkHealth.connecting;
      status = 'Connecting…';
    }
    if (count == 0 && health == NetworkHealth.ok) continue; // never an empty entry
    final network = m.network;
    groups.add(
      NetworkGroup(
        key: key,
        networkId: network,
        bridgeId: bridgeId,
        loginId: login?.id ?? m.loginId,
        label: network == 'matrix' ? 'Matrix' : (link?.acc.displayName ?? bridgeByNetwork(network)?.displayName ?? m.name ?? network),
        subtitle: network == 'matrix' ? null : _loginSubtitle(login?.name, login?.id ?? m.loginId),
        roomCount: count,
        unread: unread[key] ?? 0,
        health: health,
        status: status,
      ),
    );
  }
  int rank(NetworkGroup g) {
    if (g.networkId == 'matrix') return 1000;
    final i = _railOrder.indexOf(g.networkId);
    return i < 0 ? 99 : i;
  }

  groups.sort((a, b) {
    final r = rank(a).compareTo(rank(b));
    return r != 0 ? r : a.key.compareTo(b.key);
  });
  return NetworkView(rooms, groups);
}
