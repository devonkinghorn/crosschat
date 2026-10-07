import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Per-platform capability flags. Some features only exist on some devices
/// (by design): e.g. only the macOS app can extract the Apple hardware key
/// that the iMessage bridge needs when it runs on Linux.
class PlatformCapabilities {
  const PlatformCapabilities({
    required this.os,
    required this.canExtractAppleHardwareKey,
    required this.hasPersistentSyncService,
    required this.hasEmbeddedWebview,
    required this.isMobile,
  });

  factory PlatformCapabilities.current() {
    if (kIsWeb) {
      return const PlatformCapabilities(
        os: 'web',
        canExtractAppleHardwareKey: false,
        hasPersistentSyncService: false,
        hasEmbeddedWebview: false,
        isMobile: false,
      );
    }
    return PlatformCapabilities(
      os: Platform.operatingSystem,
      canExtractAppleHardwareKey: Platform.isMacOS,
      hasPersistentSyncService: Platform.isAndroid,
      // Embedded sign-in window (lib/src/webauth): WKWebView on macOS,
      // WebKitGTK on Linux when the system has it (checked at runtime by
      // WebAuthLauncher.isAvailable). Android: not yet (paste fallback).
      hasEmbeddedWebview: Platform.isMacOS || Platform.isLinux,
      isMobile: Platform.isAndroid || Platform.isIOS,
    );
  }

  final String os;
  final bool canExtractAppleHardwareKey;
  final bool hasPersistentSyncService;
  final bool hasEmbeddedWebview;
  final bool isMobile;

  /// Platform ids used in bridge manifest `provided_by` lists.
  String get manifestPlatform => os == 'macos' ? 'macos' : os;
}

/// Android-only: keeps the process (and the Rust sync loop) alive with a
/// foreground service instead of push notifications.
class PersistentSyncService {
  static const _channel = MethodChannel('app.crosschat/sync_service');

  static Future<bool> setEnabled(bool enabled) async {
    if (kIsWeb || !Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>(enabled ? 'start' : 'stop') ?? false;
    } on MissingPluginException {
      return false;
    }
  }
}

/// macOS-only: run the upstream corten-matrix hardware-key extractor CLI
/// and return the base64 key it prints.
class AppleKeyExtractor {
  static Future<String> run(String extractorPath) async {
    final result = await Process.run(extractorPath, const []);
    if (result.exitCode != 0) {
      throw Exception('extract-key failed: ${result.stderr}');
    }
    final lines = (result.stdout as String).trim().split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) throw Exception('extract-key printed nothing');
    return lines.last.trim();
  }
}
