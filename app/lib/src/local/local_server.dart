import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'app_paths.dart';

/// Status reported by `crosschatd local` (`GET /_crosschat/v1/local/status`).
class LocalServerStatus {
  const LocalServerStatus({
    required this.phase,
    this.detail = '',
    this.error,
    this.owner,
    this.dataDir,
    this.serverName = 'localhost',
    this.homeserverUrl = LocalServerController.defaultHomeserverUrl,
    this.daemonUrl = LocalServerController.defaultDaemonUrl,
  });

  factory LocalServerStatus.fromJson(Map<String, dynamic> j) => LocalServerStatus(
    phase: j['phase'] as String? ?? 'starting',
    detail: j['detail'] as String? ?? '',
    error: j['error'] as String?,
    owner: j['owner'] as String?,
    dataDir: j['data_dir'] as String?,
    serverName: j['server_name'] as String? ?? 'localhost',
    homeserverUrl: j['homeserver_url'] as String? ?? LocalServerController.defaultHomeserverUrl,
    daemonUrl: j['daemon_url'] as String? ?? LocalServerController.defaultDaemonUrl,
  );

  /// `starting`, `ready` or `failed`.
  final String phase;
  final String detail;
  final String? error;
  final String? owner;
  final String? dataDir;
  final String serverName;
  final String homeserverUrl;
  final String daemonUrl;

  bool get ready => phase == 'ready';
  bool get failed => phase == 'failed';
}

class LocalServerException implements Exception {
  LocalServerException(this.message, {this.errcode});
  final String message;
  final String? errcode;
  @override
  String toString() => message;
}

/// Runs the private, this-computer-only server: crosschatd in local mode
/// with a bundled Tuwunel (server_name `localhost`, loopback only, no
/// federation). Abstract so widget tests can fake it.
abstract class LocalServerController {
  static const defaultDaemonUrl = 'http://127.0.0.1:29300';
  static const defaultHomeserverUrl = 'http://127.0.0.1:6167';

  /// Only desktop apps can host the server.
  bool get supported;

  /// Why [supported] is false (shown on the setup screen).
  String get unsupportedReason;

  String get homeserverUrl;
  String get daemonUrl;

  /// The owner account if this computer already has a local server.
  Future<String?> configuredOwner();

  /// Start crosschatd (or reuse the one already running for our data dir)
  /// and wait until the homeserver is up. Throws [LocalServerException].
  Future<LocalServerStatus> start({void Function(LocalServerStatus status)? onProgress});

  /// Create the owner account (once). Returns the Matrix user ID.
  Future<String> createOwner(String username, String password);

  /// Stop crosschatd, its homeserver and bridges.
  Future<void> stop();

  /// Where the server keeps its data (for display).
  Future<String> dataDir();
}

/// Same rules crosschatd enforces (Matrix localpart).
String? validateLocalpart(String s) {
  if (s.isEmpty) return 'Pick a username.';
  if (s.length > 64) return 'Username is too long (64 characters max).';
  if (!RegExp(r'^[a-z0-9._=/\-]+$').hasMatch(s)) return 'Use lowercase letters, digits and . _ = / - only.';
  return null;
}

String? validatePassword(String p) => p.runes.length < 8 ? 'Use at least 8 characters for the password.' : null;

/// Where to look for the `crosschatd` binary, in order:
/// 1. `$CROSSCHATD_BIN`
/// 2. next to the app executable (`Crosschat.app/Contents/MacOS/crosschatd`,
///    or the Linux bundle directory), or `Contents/Resources/crosschatd`
/// 3. a Crosschat source checkout above the executable or the working
///    directory: `target/release/crosschatd`, then `target/debug/crosschatd`
///    (so `flutter run` from `app/` finds `cargo build` output)
/// 4. `$PATH`
List<String> crosschatdCandidates({
  required Map<String, String> env,
  required String executable,
  required String cwd,
  required bool Function(String path) exists,
}) {
  final out = <String>[];
  final override = env['CROSSCHATD_BIN'];
  if (override != null && override.isNotEmpty) out.add(override);
  final exeDir = File(executable).parent.path;
  out.add('$exeDir/crosschatd');
  out.add('${File(exeDir).parent.path}/Resources/crosschatd');
  for (final start in [exeDir, cwd]) {
    var dir = Directory(start).absolute;
    for (var i = 0; i < 12; i++) {
      if (exists('${dir.path}/Cargo.toml') && exists('${dir.path}/crates/crosschatd/Cargo.toml')) {
        out.add('${dir.path}/target/release/crosschatd');
        out.add('${dir.path}/target/debug/crosschatd');
        break;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
  }
  for (final p in (env['PATH'] ?? '').split(':').where((p) => p.isNotEmpty)) {
    out.add('$p/crosschatd');
  }
  return out;
}

String? findCrosschatd() {
  if (kIsWeb) return null;
  bool exists(String p) => File(p).existsSync();
  final candidates = crosschatdCandidates(
    env: Platform.environment,
    executable: Platform.resolvedExecutable,
    cwd: Directory.current.path,
    exists: exists,
  );
  for (final c in candidates) {
    if (exists(c)) return c;
  }
  return null;
}

/// The real thing: spawns `crosschatd local --dir <AppPaths.localServer>`
/// detached, so bridges keep running after the window closes, and talks to
/// it over HTTP on 127.0.0.1.
class ProcessLocalServer implements LocalServerController {
  ProcessLocalServer({http.Client? client, String? dir, String? binary})
    : _http = client ?? http.Client(),
      _dirOverride = dir,
      _binaryOverride = binary;

  final http.Client _http;
  final String? _dirOverride;
  final String? _binaryOverride;

  @override
  String homeserverUrl = LocalServerController.defaultHomeserverUrl;
  @override
  String daemonUrl = LocalServerController.defaultDaemonUrl;

  /// How long to wait for a freshly spawned crosschatd to answer at all.
  Duration spawnTimeout = const Duration(seconds: 25);

  @override
  bool get supported => !kIsWeb && (Platform.isMacOS || Platform.isLinux);

  @override
  String get unsupportedReason => kIsWeb || Platform.isAndroid || Platform.isIOS
      ? 'Runs in the desktop app (macOS or Linux). A phone can\'t host your server.'
      : 'Not available on ${Platform.operatingSystem} yet (macOS and Linux only).';

  @override
  Future<String> dataDir() async => _dirOverride ?? await AppPaths.localServer();

  @override
  Future<String?> configuredOwner() async {
    try {
      final f = File('${await dataDir()}/local.json');
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return j['owner'] as String?;
    } catch (_) {
      return null;
    }
  }

  Future<LocalServerStatus?> _status() async {
    try {
      final r = await _http.get(Uri.parse('$daemonUrl/_crosschat/v1/local/status')).timeout(const Duration(seconds: 3));
      if (r.statusCode != 200) return null;
      final s = LocalServerStatus.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
      homeserverUrl = s.homeserverUrl;
      return s;
    } catch (_) {
      return null;
    }
  }

  Future<String> _logTail(String dir) async {
    try {
      final lines = await File('$dir/crosschatd.log').readAsLines();
      return lines.skip(lines.length > 12 ? lines.length - 12 : 0).join('\n');
    } catch (_) {
      return '';
    }
  }

  @override
  Future<LocalServerStatus> start({void Function(LocalServerStatus status)? onProgress}) async {
    final dir = await dataDir();
    var s = await _status();
    if (s != null && s.dataDir != null && s.dataDir != dir) {
      throw LocalServerException(
        'Another Crosschat server is already running on ${Uri.parse(daemonUrl).authority} (data in ${s.dataDir}). Quit it first.',
      );
    }
    if (s != null) {
      // Already running for our data dir (e.g. left running by the last session).
      onProgress?.call(s);
      if (s.ready) return s;
    } else {
      final bin = _binaryOverride ?? findCrosschatd();
      if (bin == null) {
        throw LocalServerException(
          'Couldn\'t find crosschatd. Build it with `cargo build --release -p crosschatd` in the Crosschat checkout, '
          'or set CROSSCHATD_BIN.',
        );
      }
      await Directory(dir).create(recursive: true);
      debugPrint('starting $bin local --dir $dir');
      onProgress?.call(const LocalServerStatus(phase: 'starting', detail: 'Starting crosschatd'));
      await Process.start(bin, ['local', '--dir', dir], mode: ProcessStartMode.detached);
    }
    final spawned = DateTime.now();
    var seen = s != null;
    while (true) {
      s = await _status();
      if (s == null) {
        if (!seen && DateTime.now().difference(spawned) > spawnTimeout) {
          final tail = await _logTail(dir);
          throw LocalServerException('crosschatd didn\'t start.${tail.isEmpty ? '' : '\n$tail'}');
        }
      } else {
        seen = true;
        onProgress?.call(s);
        if (s.ready) return s;
        if (s.failed) throw LocalServerException(s.error ?? 'The local server failed to start (see $dir/crosschatd.log)');
      }
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
  }

  @override
  Future<String> createOwner(String username, String password) async {
    final dir = await dataDir();
    final token = (await File('$dir/data/admin.token').readAsString()).trim();
    final r = await _http
        .post(
          Uri.parse('$daemonUrl/_crosschat/v1/local/owner'),
          headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
          body: jsonEncode({'username': username, 'password': password}),
        )
        .timeout(const Duration(seconds: 60));
    final body = r.body.isEmpty ? null : jsonDecode(r.body);
    if (r.statusCode != 200) {
      final m = body is Map ? body : const {};
      final code = m['errcode'] as String?;
      final msg = code == 'M_USER_IN_USE' ? 'That username is taken on this server.' : (m['error'] ?? 'HTTP ${r.statusCode}').toString();
      throw LocalServerException(msg, errcode: code);
    }
    return (body as Map)['user_id'] as String;
  }

  @override
  Future<void> stop() async {
    final dir = await dataDir();
    try {
      final pid = int.parse((await File('$dir/crosschatd.pid').readAsString()).trim());
      Process.killPid(pid, ProcessSignal.sigterm);
    } catch (_) {
      return;
    }
    for (var i = 0; i < 40; i++) {
      if (await _status() == null) return;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }
}
