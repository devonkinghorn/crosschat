import 'dart:convert';

import 'package:http/http.dart' as http;

/// Client for crosschatd's HTTP API (`/_crosschat/v1`). Authenticated with
/// the user's Matrix access token; crosschatd validates it against the
/// homeserver and forwards provisioning calls to the right bridge.
class DaemonClient {
  DaemonClient({required this.baseUrl, required this.accessToken, http.Client? httpClient}) : _http = httpClient ?? http.Client();

  /// Usually the homeserver URL (crosschatd is mounted at `/_crosschat/` on
  /// the same domain), or e.g. `http://127.0.0.1:29300` locally.
  final String baseUrl;
  final String accessToken;
  final http.Client _http;

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    return Uri.parse('$base$path').replace(queryParameters: query);
  }

  Map<String, String> get _headers => {'Authorization': 'Bearer $accessToken', 'Content-Type': 'application/json'};

  Future<dynamic> _send(String method, String path, {Object? body, Map<String, String>? query, Duration? timeout}) async {
    final req = http.Request(method, _uri(path, query))..headers.addAll(_headers);
    if (body != null) req.body = jsonEncode(body);
    final streamed = await _http.send(req).timeout(timeout ?? const Duration(seconds: 15));
    final resp = await http.Response.fromStream(streamed);
    final decoded = resp.body.isEmpty ? null : jsonDecode(resp.body);
    if (resp.statusCode >= 400) {
      final msg = decoded is Map ? (decoded['error'] ?? decoded['errcode'] ?? resp.statusCode).toString() : '${resp.statusCode}';
      throw DaemonException(resp.statusCode, msg, decoded is Map ? decoded['errcode'] as String? : null);
    }
    return decoded;
  }

  Future<bool> isAvailable() async {
    try {
      final r = await _http.get(_uri('/_crosschat/v1/health')).timeout(const Duration(seconds: 4));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<List<BridgeInfo>> networks() async => (await networksInfo()).bridges;

  /// Every bridge crosschatd knows (enabled or not) plus what this user may do.
  Future<NetworksInfo> networksInfo() async {
    final v = await _send('GET', '/_crosschat/v1/networks') as Map<String, dynamic>;
    return NetworksInfo.fromJson(v);
  }

  /// Turn a network on (`enable`: install, configure, register with the
  /// homeserver, start; runs in the background, watch [networksInfo]), off
  /// (`disable`: keeps its data and logins) or `remove` it (signs out and
  /// deletes its data). Server admins only.
  Future<void> bridgeAction(String bridge, String action) async {
    await _send('POST', '/_crosschat/v1/bridges/$bridge/$action', body: <String, dynamic>{}, timeout: const Duration(seconds: 60));
  }

  /// Is this phone number / email reachable on each running network
  /// (bridgev2 `resolve_identifier`, in the form each bridge expects)?
  /// Maps bridge id → the contact, or null when it isn't reachable there.
  Future<Map<String, Contact?>> resolve(String identifier, {List<String>? bridges}) async {
    final v = await _send(
      'POST',
      '/_crosschat/v1/resolve',
      body: {'identifier': identifier, 'bridges': ?bridges},
      timeout: const Duration(seconds: 25),
    ) as Map<String, dynamic>;
    return {
      for (final e in (v['results'] as Map).entries) e.key as String: e.value == null ? null : Contact.fromJson((e.value as Map).cast<String, dynamic>()),
    };
  }

  /// Start (or reuse) a DM with a phone number / email (or a bridge user id)
  /// on one network; returns the portal room id.
  Future<String?> startDm(String bridge, String identifier, {String? loginId}) async {
    final v = await _send(
      'POST',
      '/_crosschat/v1/dm',
      body: {'bridge': bridge, 'identifier': identifier, 'login_id': ?loginId},
      timeout: const Duration(seconds: 30),
    ) as Map<String, dynamic>;
    return v['dm_room_mxid'] as String?;
  }

  /// Contact search across every bridge (bridgev2 `search_users` +
  /// `resolve_identifier`).
  Future<SearchResponse> search(String query) async {
    final v = await _send('POST', '/_crosschat/v1/search', body: {'query': query}) as Map<String, dynamic>;
    return SearchResponse(
      results: (v['results'] as List).map((r) => Contact.fromJson(r as Map<String, dynamic>)).toList(),
      errors: (v['errors'] as Map?)?.map((k, v) => MapEntry(k as String, v.toString())) ?? {},
    );
  }

  Future<List<Contact>> contacts(String bridge) async {
    final v = await _send('GET', '/_crosschat/v1/contacts', query: {'bridge': bridge}) as Map<String, dynamic>;
    return (v['contacts'] as List).map((r) => Contact.fromJson(r as Map<String, dynamic>)).toList();
  }

  /// Raw bridgev2 provisioning call through the proxy.
  Future<dynamic> provision(String bridge, String method, String path, {Object? body, Map<String, String>? query, Duration? timeout}) =>
      _send(method, '/_crosschat/v1/bridges/$bridge/provision/$path', body: body, query: query, timeout: timeout);

  /// Start (or reuse) a DM on the remote network; returns the portal room id.
  Future<String?> createDm(String bridge, String identifier, {String? loginId}) async {
    final v = await provision(
      bridge,
      'POST',
      'v3/create_dm/${Uri.encodeComponent(identifier)}',
      query: loginId == null ? null : {'login_id': loginId},
    ) as Map<String, dynamic>;
    return v['dm_room_mxid'] as String?;
  }

  Future<List<Map<String, dynamic>>> loginFlows(String bridge) async {
    final v = await provision(bridge, 'GET', 'v3/login/flows') as Map<String, dynamic>;
    return (v['flows'] as List).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> startLogin(String bridge, String flowId) async =>
      await provision(bridge, 'POST', 'v3/login/start/$flowId', body: <String, dynamic>{}) as Map<String, dynamic>;

  /// Submit a login step. `type` is the step type (`user_input`, `cookies`,
  /// `display_and_wait`). display_and_wait long-polls until the user acts.
  Future<Map<String, dynamic>> submitStep(String bridge, Map<String, dynamic> step, Map<String, String> data) async {
    final type = step['type'] as String;
    return await provision(
      bridge,
      'POST',
      'v3/login/step/${step['login_id']}/${step['step_id']}/$type',
      body: type == 'display_and_wait' ? <String, dynamic>{} : data,
      // Waiting on the phone can take minutes; so can a step's work (e.g.
      // iMessage registering with Apple and joining the iCloud Keychain).
      timeout: type == 'display_and_wait' ? const Duration(minutes: 10) : const Duration(minutes: 3),
    ) as Map<String, dynamic>;
  }

  Future<void> cancelLogin(String bridge, String loginProcessId) async {
    await provision(bridge, 'POST', 'v3/login/cancel/$loginProcessId', body: <String, dynamic>{});
  }
}

class DaemonException implements Exception {
  DaemonException(this.status, this.message, this.errcode);
  final int status;
  final String message;
  final String? errcode;
  @override
  String toString() => 'crosschatd: $message ($status)';
}

class NetworksInfo {
  NetworksInfo({required this.bridges, this.admin = false, this.canManage = false, this.keepingAwake = false, this.hostOs});

  factory NetworksInfo.fromJson(Map<String, dynamic> v) => NetworksInfo(
    bridges: (v['bridges'] as List).map((b) => BridgeInfo.fromJson(b as Map<String, dynamic>)).toList(),
    admin: v['admin'] as bool? ?? false,
    canManage: v['can_manage'] as bool? ?? false,
    keepingAwake: v['keeping_awake'] as bool? ?? false,
    hostOs: v['host_os'] as String?,
  );

  final List<BridgeInfo> bridges;

  /// This user administers the server (may add and remove networks).
  final bool admin;

  /// The server supports adding/removing networks at runtime.
  final bool canManage;

  /// The server is keeping its computer awake (e.g. for iMessage).
  final bool keepingAwake;
  final String? hostOs;
}

class BridgeInfo {
  BridgeInfo({
    required this.id,
    required this.displayName,
    required this.network,
    required this.enabled,
    required this.maturity,
    required this.processState,
    required this.live,
    required this.preflight,
    required this.requirements,
    required this.capabilities,
    this.description,
    this.hostSupported = true,
    this.progress,
    this.setupError,
    this.keepAwake = false,
    this.hostPlatforms = const [],
  });

  factory BridgeInfo.fromJson(Map<String, dynamic> j) => BridgeInfo(
    id: j['id'] as String,
    displayName: j['display_name'] as String,
    network: j['network'] as String,
    enabled: j['enabled'] as bool? ?? false,
    maturity: j['maturity'] as String? ?? 'stable',
    processState: (j['process'] as Map?)?['state'] as String?,
    live: (j['health'] as Map?)?['live'] as bool?,
    preflight: ((j['preflight'] as List?) ?? []).cast<Map<String, dynamic>>(),
    requirements: ((j['requirements'] as List?) ?? []).cast<Map<String, dynamic>>(),
    capabilities: (j['capabilities'] as Map?)?.cast<String, dynamic>() ?? {},
    description: j['description'] as String?,
    hostSupported: j['host_supported'] as bool? ?? true,
    progress: j['progress'] as String?,
    setupError: j['setup_error'] as String?,
    keepAwake: j['keep_awake'] as bool? ?? false,
    hostPlatforms: ((j['host_platforms'] as List?) ?? []).cast<String>(),
  );

  final String id;
  final String displayName;
  final String network;
  final bool enabled;
  final String maturity;
  final String? processState;
  final bool? live;
  final List<Map<String, dynamic>> preflight;
  final List<Map<String, dynamic>> requirements;
  final Map<String, dynamic> capabilities;
  final String? description;

  /// The server's OS can run it (e.g. iMessage needs a Mac or a hardware key).
  final bool hostSupported;

  /// What enabling is doing right now ("Installing iMessage").
  final String? progress;
  final String? setupError;

  /// Needs its computer awake (the server keeps it from sleeping).
  final bool keepAwake;

  /// Server OSes it runs on (`linux`, `macos`).
  final List<String> hostPlatforms;

  bool get running => processState == 'running';

  /// Running and answering health checks: ready to sign in.
  bool get ready => running && live == true;

  /// Preflight items the user must tick off before signing in.
  List<Map<String, dynamic>> get checklist => [
    for (final p in preflight)
      if (p['confirm'] == true) p,
  ];
}

class Contact {
  Contact({required this.bridge, required this.network, required this.id, this.name, this.mxid, this.dmRoomMxid, this.identifiers = const []});

  factory Contact.fromJson(Map<String, dynamic> j) => Contact(
    bridge: j['bridge'] as String,
    network: j['network'] as String,
    id: j['id'] as String,
    name: j['name'] as String?,
    mxid: j['mxid'] as String?,
    dmRoomMxid: j['dm_room_mxid'] as String?,
    identifiers: ((j['identifiers'] as List?) ?? []).cast<String>(),
  );

  final String bridge;
  final String network;
  final String id;
  final String? name;
  final String? mxid;
  final String? dmRoomMxid;
  final List<String> identifiers;
}

class SearchResponse {
  SearchResponse({required this.results, required this.errors});
  final List<Contact> results;
  final Map<String, String> errors;
}
