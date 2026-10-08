import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models.dart';
import 'media_cache.dart';
import 'theme.dart';

const _maxW = 360.0;
const _maxH = 320.0;

/// Inline rendering of an attachment: images (incl. animated GIF and HEIC)
/// as previews that open full size on click; video / audio / files as a card
/// with download.
class MediaView extends StatelessWidget {
  const MediaView({super.key, required this.message});
  final Message message;

  @override
  Widget build(BuildContext context) {
    final media = message.media!;
    final image = message.kind == 'image' || message.kind == 'sticker';
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: image ? _ImagePreview(media: media, eventId: message.eventId) : FileCard(media: media, kind: message.kind),
    );
  }
}

/// Decoded-for-display bytes: HEIC goes through the platform decoder.
Future<Uint8List> displayableBytes(MediaAttachment media, {bool full = false}) async {
  final plainThumb = !full && media.thumbnailSource != null;
  var bytes = await MediaCache.instance.load(
    plainThumb ? media.thumbnailSource! : media.source,
    thumbWidth: !full && !media.isGif && media.source.startsWith('{"url"') ? 800 : null,
    thumbHeight: !full && !media.isGif && media.source.startsWith('{"url"') ? 800 : null,
  );
  if (media.isHeic || looksLikeHeic(bytes)) {
    final jpeg = await PlatformImage.toJpeg(bytes, maxDimension: full ? 4096 : 1200);
    if (jpeg == null) throw UnsupportedError('HEIC');
    bytes = jpeg;
  }
  return bytes;
}

Size _previewSize(MediaAttachment m) {
  final w = m.width?.toDouble(), h = m.height?.toDouble();
  if (w == null || h == null || w <= 0 || h <= 0) return const Size(_maxW, 240);
  final scale = [1.0, _maxW / w, _maxH / h].reduce((a, b) => a < b ? a : b);
  return Size((w * scale).clamp(48, _maxW), (h * scale).clamp(48, _maxH));
}

class _ImagePreview extends StatefulWidget {
  const _ImagePreview({required this.media, required this.eventId});
  final MediaAttachment media;
  final String eventId;

  @override
  State<_ImagePreview> createState() => _ImagePreviewState();
}

class _ImagePreviewState extends State<_ImagePreview> {
  late Future<Uint8List> _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = displayableBytes(widget.media);
  }

  @override
  void didUpdateWidget(covariant _ImagePreview old) {
    super.didUpdateWidget(old);
    if (old.media.source != widget.media.source) _bytes = displayableBytes(widget.media);
  }

  @override
  Widget build(BuildContext context) {
    final size = _previewSize(widget.media);
    final known = widget.media.width != null && widget.media.height != null;
    return FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (context, snap) {
        if (snap.hasError) return FileCard(media: widget.media, kind: 'image');
        if (!snap.hasData) {
          return Container(
            key: Key('media-loading-${widget.eventId}'),
            width: size.width,
            height: size.height,
            decoration: BoxDecoration(color: CC.input, borderRadius: BorderRadius.circular(8)),
            alignment: Alignment.center,
            child: const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        final img = Image.memory(
          snap.data!,
          key: Key('media-image-${widget.eventId}'),
          fit: BoxFit.contain,
          gaplessPlayback: true,
          // Decode at display size (GIFs keep animating).
          cacheWidth: (_maxW * MediaQuery.devicePixelRatioOf(context)).round(),
          errorBuilder: (_, _, _) => FileCard(media: widget.media, kind: 'image'),
        );
        return MouseRegion(
          cursor: SystemMouseCursors.zoomIn,
          child: GestureDetector(
            onTap: () => showDialog<void>(
              context: context,
              builder: (_) => FullImageDialog(media: widget.media),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _maxW, maxHeight: _maxH),
                child: known ? SizedBox(width: size.width, height: size.height, child: img) : img,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Full-size image, zoomable, with download.
class FullImageDialog extends StatelessWidget {
  const FullImageDialog({super.key, required this.media});
  final MediaAttachment media;

  @override
  Widget build(BuildContext context) => Dialog(
    key: const Key('media-full'),
    backgroundColor: Colors.black,
    insetPadding: const EdgeInsets.all(24),
    child: Stack(
      children: [
        Positioned.fill(
          child: FutureBuilder<Uint8List>(
            future: displayableBytes(media, full: true),
            builder: (context, snap) => snap.hasData
                ? InteractiveViewer(
                    maxScale: 8,
                    child: Center(child: Image.memory(snap.data!, fit: BoxFit.contain)),
                  )
                : Center(child: snap.hasError ? const Text("Couldn't load the image") : const CircularProgressIndicator()),
          ),
        ),
        Positioned(
          top: 4,
          right: 4,
          child: Row(
            children: [
              IconButton(
                tooltip: 'Download',
                icon: const Icon(Icons.download, color: Colors.white),
                onPressed: () => saveMedia(context, media),
              ),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

String formatBytes(int? n) {
  if (n == null) return '';
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(0)} KB';
  if (n < 1024 * 1024 * 1024) return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(n / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
}

/// Video / audio / file attachment: name, size, open + download.
class FileCard extends StatelessWidget {
  const FileCard({super.key, required this.media, required this.kind});
  final MediaAttachment media;
  final String kind;

  IconData get _icon => switch (kind) {
    'video' => Icons.movie_outlined,
    'audio' => Icons.audiotrack,
    'image' || 'sticker' => Icons.image_outlined,
    _ => Icons.insert_drive_file_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final details = [
      if (media.durationMs != null) _duration(media.durationMs!),
      formatBytes(media.size),
      if (media.mimetype != null) media.mimetype!.split('/').last.toUpperCase(),
    ].where((s) => s.isNotEmpty).join(' · ');
    return Container(
      key: const Key('media-file'),
      constraints: const BoxConstraints(maxWidth: _maxW),
      padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
      decoration: BoxDecoration(
        color: CC.input,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: CC.divider),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_icon, color: CC.textMuted, size: 28),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  media.filename.isEmpty ? 'Attachment' : media.filename,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (details.isNotEmpty) Text(details, style: const TextStyle(color: CC.textFaint, fontSize: 12)),
              ],
            ),
          ),
          if (!Platform.isAndroid && !Platform.isIOS)
            IconButton(
              key: const Key('media-open'),
              tooltip: 'Open',
              icon: const Icon(Icons.open_in_new, color: CC.textMuted, size: 20),
              onPressed: () => openMedia(context, media),
            ),
          IconButton(
            key: const Key('media-download'),
            tooltip: 'Download',
            icon: const Icon(Icons.download, color: CC.textMuted, size: 20),
            onPressed: () => saveMedia(context, media),
          ),
        ],
      ),
    );
  }

  static String _duration(int ms) {
    final s = ms ~/ 1000;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }
}

String _safeName(String name) {
  final n = name.replaceAll(RegExp(r'[/\\:\x00-\x1f]'), '_').trim();
  return n.isEmpty ? 'attachment' : n;
}

Future<File> _writeUnique(Directory dir, String name, Uint8List bytes) async {
  final base = _safeName(name);
  final dot = base.lastIndexOf('.');
  final stem = dot > 0 ? base.substring(0, dot) : base;
  final ext = dot > 0 ? base.substring(dot) : '';
  var f = File('${dir.path}/$base');
  for (var i = 1; await f.exists(); i++) {
    f = File('${dir.path}/$stem ($i)$ext');
  }
  return f.writeAsBytes(bytes, flush: true);
}

/// Save the (decrypted) original to Downloads (desktop) or the app's
/// documents folder (mobile).
Future<void> saveMedia(BuildContext context, MediaAttachment media) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final bytes = await MediaCache.instance.load(media.source);
    final dir = (Platform.isAndroid || Platform.isIOS)
        ? await getApplicationDocumentsDirectory()
        : (await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory());
    final f = await _writeUnique(dir, media.filename, bytes);
    messenger?.showSnackBar(SnackBar(content: Text('Saved to ${f.path}')));
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text('Download failed: $e')));
  }
}

/// Open with the system's default app (desktop), via a temp copy.
Future<void> openMedia(BuildContext context, MediaAttachment media) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final bytes = await MediaCache.instance.load(media.source);
    final dir = await Directory('${(await getTemporaryDirectory()).path}/crosschat-media').create(recursive: true);
    final f = await _writeUnique(dir, media.filename, bytes);
    await launchUrl(Uri.file(f.path));
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text("Couldn't open: $e")));
  }
}
