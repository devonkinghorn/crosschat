import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

const _homeDefine = String.fromEnvironment('CROSSCHAT_HOME');

/// Where Crosschat keeps its data on this device.
///
/// * macOS: `~/Library/Application Support/Crosschat`
/// * Linux: `$XDG_DATA_HOME/crosschat` (`~/.local/share/crosschat`)
/// * Android/iOS: the app's support directory
///
/// `CROSSCHAT_HOME` (environment variable on desktop, or
/// `--dart-define=CROSSCHAT_HOME=...`) overrides it, e.g. for a throwaway
/// test profile. Inside: `matrix/` (the Rust core's store and session) and
/// `server/` (the local crosschatd + Tuwunel, see `crosschatd local`).
class AppPaths {
  AppPaths._();

  static String? _override() {
    if (_homeDefine.isNotEmpty) return _homeDefine;
    if (kIsWeb) return null;
    final env = Platform.environment['CROSSCHAT_HOME'];
    return (env != null && env.isNotEmpty) ? env : null;
  }

  /// Desktop default without touching plugins (pure, testable).
  static String? desktopHome({required String os, required Map<String, String> env}) {
    final home = env['HOME'];
    if (home == null || home.isEmpty) return null;
    switch (os) {
      case 'macos':
        return '$home/Library/Application Support/Crosschat';
      case 'linux':
        final xdg = env['XDG_DATA_HOME'];
        return '${(xdg != null && xdg.isNotEmpty) ? xdg : '$home/.local/share'}/crosschat';
      default:
        return null;
    }
  }

  static Future<String> home() async {
    final o = _override();
    if (o != null) return o;
    if (!kIsWeb) {
      final d = desktopHome(os: Platform.operatingSystem, env: Platform.environment);
      if (d != null) return d;
    }
    return (await getApplicationSupportDirectory()).path;
  }

  static Future<String> matrixStore() async => '${await home()}/matrix';
  static Future<String> localServer() async => '${await home()}/server';
}
