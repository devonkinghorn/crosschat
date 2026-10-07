import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  AppSettings({this.daemonUrl = '', this.persistentSync = false, this.extractorPath = ''});

  /// crosschatd base URL. Empty = same as the homeserver URL.
  String daemonUrl;

  /// Android: keep a live sync connection with a foreground service.
  bool persistentSync;

  /// macOS: path to the corten-matrix `extract-key` CLI.
  String extractorPath;

  static Future<AppSettings> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      return AppSettings(
        daemonUrl: p.getString('daemon_url') ?? '',
        persistentSync: p.getBool('android_persistent_sync') ?? false,
        extractorPath: p.getString('extractor_path') ?? '',
      );
    } catch (_) {
      return AppSettings();
    }
  }

  Future<void> save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('daemon_url', daemonUrl);
      await p.setBool('android_persistent_sync', persistentSync);
      await p.setString('extractor_path', extractorPath);
    } catch (_) {}
  }
}
