import 'dart:convert';

import 'package:http/http.dart' as http;

/// Client for crosschatd's HTTP API (`/_crosschat/v1`). Authenticated with
/// the user's Matrix access token; crosschatd validates it against the
/// homeserver and forwards provisioning calls to the right bridge.
class DaemonClient {
  DaemonClient({required this.baseUrl, required this.accessToken, http.Client? httpClient})
    : _http = httpClient ?? http.Client();

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

  Future<List<BridgeInfo>> networks() async {
    final v = await _send('GET', '/_crosschat/v1/networks') as Map<String, dynamic>;
    return (v['bridges'] as List).map((b) => BridgeInfo.fromJson(b as Map<String, dynamic>)).toList();
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
      timeout: type == 'display_and_wait' ? const Duration(minutes: 10) : null,
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

  bool get running => processState == 'running';
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
