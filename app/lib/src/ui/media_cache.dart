import 'package:flutter/services.dart';

import '../backend/backend.dart';

/// Downloaded media (attachments, avatars), shared by all widgets. Keeps the
/// most recent entries in memory; matrix-sdk also caches on disk.
class MediaCache {
  MediaCache._();
  static final instance = MediaCache._();

  ChatBackend? backend;

  static const _maxEntries = 120;
  static const _maxBytes = 160 * 1024 * 1024;
  final _entries = <String, Future<Uint8List>>{}; // insertion-ordered = LRU
  final _sizes = <String, int>{};
  int _total = 0;

  /// Bytes of [source] (`mxc://` URL or attachment source JSON); with a
  /// thumbnail size, the server scales it down where it can.
  Future<Uint8List> load(String source, {int? thumbWidth, int? thumbHeight}) {
    final b = backend;
    if (b == null) return Future.error(StateError('no backend'));
    final key = '$source#${thumbWidth ?? ''}x${thumbHeight ?? ''}';
    final hit = _entries.remove(key);
    if (hit != null) {
      _entries[key] = hit; // most recently used
      return hit;
    }
    final f = b.mediaBytes(source, thumbWidth: thumbWidth, thumbHeight: thumbHeight);
    _entries[key] = f;
    f.then(
      (bytes) {
        _sizes[key] = bytes.length;
        _total += bytes.length;
        _evict();
      },
      onError: (_) {
        _entries.remove(key); // retry next time
      },
    );
    return f;
  }

  void _evict() {
    while ((_entries.length > _maxEntries || _total > _maxBytes) && _entries.length > 1) {
      final k = _entries.keys.first;
      _entries.remove(k);
      _total -= _sizes.remove(k) ?? 0;
    }
  }

  void clear() {
    _entries.clear();
    _sizes.clear();
    _total = 0;
  }
}

/// HEIC/HEIF ("ftypheic", "ftypmif1", …) by content, whatever the mimetype says.
bool looksLikeHeic(Uint8List b) {
  if (b.length < 12) return false;
  final tag = String.fromCharCodes(b.sublist(4, 12));
  return tag.startsWith('ftyp') && const ['heic', 'heix', 'hevc', 'hevx', 'heim', 'heis', 'mif1', 'msf1'].contains(tag.substring(4));
}

/// The platform's image decoder (ImageIO on macOS/iOS, ImageDecoder on
/// Android) for formats Flutter can't decode itself, i.e. HEIC. Returns JPEG.
class PlatformImage {
  static const _channel = MethodChannel('app.crosschat/image');

  static Future<Uint8List?> toJpeg(Uint8List bytes, {int maxDimension = 2048}) async {
    try {
      return await _channel.invokeMethod<Uint8List>('toJpeg', {'bytes': bytes, 'maxDimension': maxDimension});
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
