import 'package:crosschat/src/backend/demo_backend.dart';
import 'package:crosschat/src/models.dart';
import 'package:crosschat/src/state/app_state.dart';
import 'package:crosschat/src/state/timeline_fold.dart';
import 'package:crosschat/src/ui/media_cache.dart';
import 'package:crosschat/src/ui/message_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/gmessages_events.dart';

Future<DemoBackend> _pumpList(WidgetTester tester, List<Message> msgs) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final backend = DemoBackend();
  MediaCache.instance
    ..clear()
    ..backend = backend;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: MessageList(messages: msgs)),
    ),
  );
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return backend;
}

void main() {
  final heicCalls = <Map<Object?, Object?>>[];
  setUp(() {
    heicCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('app.crosschat/image'), (call) async {
      heicCalls.add(call.arguments as Map<Object?, Object?>);
      return DemoBackend.samplePng;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('app.crosschat/image'), null);
  });

  testWidgets('images render inline instead of as their file name', (tester) async {
    final backend = await _pumpList(tester, foldTapbacks(familyChat()));
    // Bug: "IMG_3406.heic" used to be the whole message.
    expect(find.text('IMG_3406.heic'), findsNothing);
    expect(find.byKey(const Key(r'media-image-$img1')), findsOneWidget);
    expect(find.byKey(const Key(r'media-image-$gif1')), findsOneWidget, reason: 'GIFs are images (and animate)');
    // Encrypted attachments are fetched (and decrypted) by source, not by URL.
    expect(backend.mediaRequests.where((s) => s.contains('"file"')).length, greaterThanOrEqualTo(3));
    // The sender's avatar is loaded.
    expect(backend.mediaRequests, contains('mxc://localhost/alexavatar'));
  });

  testWidgets('HEIC goes through the platform decoder', (tester) async {
    await _pumpList(tester, foldTapbacks(familyChat()));
    expect(find.byKey(const Key(r'media-image-$heic1')), findsOneWidget);
    expect(heicCalls, hasLength(1));
    expect(heicCalls.single['maxDimension'], 1200);
  });

  testWidgets('HEIC without a platform decoder falls back to a file card', (tester) async {
    // No native decoder registered (e.g. iOS for now).
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('app.crosschat/image'),
      (call) async => throw MissingPluginException(),
    );
    final heic = familyChat().firstWhere((m) => m.eventId == r'$heic1');
    await _pumpList(tester, [heic]);
    expect(find.byKey(const Key(r'media-image-$heic1')), findsNothing);
    expect(find.text('IMG_0001.heic'), findsOneWidget);
    expect(find.byKey(const Key('media-download')), findsOneWidget);
  });

  testWidgets('clicking an image opens it full size', (tester) async {
    await _pumpList(tester, foldTapbacks(familyChat()));
    await tester.tap(find.byKey(const Key(r'media-image-$img1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('media-full')), findsOneWidget);
  });

  testWidgets('videos and files are cards with download', (tester) async {
    await _pumpList(tester, foldTapbacks(familyChat()));
    expect(find.text('clip.mp4'), findsOneWidget);
    expect(find.byKey(const Key('media-file')), findsOneWidget);
    expect(find.byKey(const Key('media-download')), findsOneWidget);
    expect(find.textContaining('15.5 MB'), findsOneWidget);
  });

  testWidgets('tapbacks render as reactions or a compact line, not messages', (tester) async {
    await _pumpList(tester, foldTapbacks(familyChat()));
    // Bug: "Laughed at an image" used to be a full message.
    expect(find.text('Laughed at an image'), findsNothing);
    expect(find.byKey(const Key(r'reaction-$gif1-😂')), findsOneWidget);
    expect(find.byKey(const Key(r'reaction-$t1-❤️')), findsOneWidget);
    expect(find.byKey(const Key(r'reaction-$t1-👍')), findsOneWidget);
    expect(find.text('👍 2'), findsOneWidget);
    // Unmatched: a compact muted line.
    expect(find.byKey(const Key(r'tapback-line-$tb4')), findsOneWidget);
    expect(find.textContaining('reacted ‼️ to'), findsOneWidget);
    // Real text is untouched.
    expect(find.text('Loved the movie last night'), findsOneWidget);
  });

  testWidgets('names update live when member info changes; no raw MXIDs', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final backend = DemoBackend(autoLogin: true);
    final state = AppState(backend: backend, daemonHttp: MockClient((_) async => http.Response('', 503)), accountsPollInterval: null);
    await state.init();
    await state.selectRoom('!climb:gmessages');
    // A message from a contact whose name the bridge hasn't set yet.
    final now = DateTime.now().millisecondsSinceEpoch;
    final early = Message(eventId: r'$n1', sender: '@gmessages_1.14:crosschat.app', senderName: 'Unknown contact', body: 'hey all', ts: now);
    backend.addEvent('!climb:gmessages', early);
    backend.emit(BackendUpdate.newMessage('!climb:gmessages', early));
    await tester.pump();
    expect(state.messages.last.senderName, 'Unknown contact');
    // The bridge sets the display name; the core reports the change.
    final events = await backend.timeline('!climb:gmessages');
    final renamed = early.copyWith(senderName: 'Nicole', senderAvatar: 'mxc://localhost/n');
    final list = [
      for (final m in events)
        if (m.eventId != r'$n1') m,
      renamed,
    ];
    backend.replaceEvents('!climb:gmessages', list);
    backend.emit(const BackendUpdate.timelineChanged('!climb:gmessages'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    final shown = state.messages.firstWhere((m) => m.eventId == r'$n1');
    expect(shown.senderName, 'Nicole');
    expect(shown.senderAvatar, 'mxc://localhost/n');
    state.dispose();
  });

  testWidgets('a live tapback folds into the message it quotes', (tester) async {
    final backend = DemoBackend(autoLogin: true);
    final state = AppState(backend: backend, daemonHttp: MockClient((_) async => http.Response('', 503)), accountsPollInterval: null);
    await state.init();
    await state.selectRoom('!climb:gmessages');
    final now = DateTime.now().millisecondsSinceEpoch;
    final tap = Message(
      eventId: r'$live',
      sender: '@gmessages_2:crosschat.app',
      senderName: 'Tom',
      body: 'Loved “Bouldering Thursday at 7?”',
      ts: now,
      tapback: const TapbackInfo(key: '❤️', targetText: 'Bouldering Thursday at 7?'),
    );
    backend.emit(BackendUpdate.newMessage('!climb:gmessages', tap));
    await tester.pump();
    expect(state.messages.any((m) => m.eventId == r'$live'), isFalse);
    expect(state.messages.firstWhere((m) => m.eventId == r'$g1').reactions.single.key, '❤️');
    state.dispose();
  });
}
