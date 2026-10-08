import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../models.dart';
import 'backend.dart';

/// In-memory backend with sample conversations across the first-version
/// networks. Used by widget tests, screenshots and `--dart-define=CROSSCHAT_DEMO=true`.
class DemoBackend implements ChatBackend {
  DemoBackend({DateTime? now, this.autoLogin = false}) : _now = now ?? DateTime.now() {
    _seed();
  }

  final DateTime _now;

  /// Start already signed in (demo mode / screenshots).
  final bool autoLogin;
  final _updates = StreamController<BackendUpdate>.broadcast();
  final Map<String, Room> _rooms = {};
  final Map<String, List<Message>> _events = {};
  int _counter = 0;

  static const me = '@devon:crosschat.app';

  @override
  String get name => 'demo';

  int _ago(Duration d) => _now.subtract(d).millisecondsSinceEpoch;

  void _room(Room r, List<Message> msgs) {
    _rooms[r.roomId] = r;
    _events[r.roomId] = msgs;
  }

  Message _m(String id, String sender, String name, String body, Duration ago, {String? root}) =>
      Message(eventId: id, sender: sender, senderName: name, body: body, ts: _ago(ago), threadRoot: root, isOwn: sender == me);

  void _seed() {
    _room(
      const Room(
        roomId: '!eng:slack',
        name: 'eng-platform',
        topic: 'Platform team · deploys, incidents, RFCs',
        networkId: 'slack',
        networkName: 'Slack',
        threadsSupported: true,
        unread: 3,
      ),
      [
        _m(r'$s1', '@slack_u1:crosschat.app', 'Priya Natarajan', 'Deploy of api-gateway v2.14 is rolling out to canary now 🚀', const Duration(hours: 3)),
        _m(
          r'$s2',
          '@slack_u2:crosschat.app',
          'Marcus Lee',
          'Seeing a small bump in p99 latency on canary, probably cache warmup',
          const Duration(hours: 2, minutes: 50),
        ),
        _m(
          r'$s2r1',
          '@slack_u1:crosschat.app',
          'Priya Natarajan',
          'Yeah, warms up after ~5 min. Watching it.',
          const Duration(hours: 2, minutes: 45),
          root: r'$s2',
        ),
        _m(r'$s2r2', me, 'Devon', 'Dashboard looks fine now, p99 back under 180ms', const Duration(hours: 2, minutes: 30), root: r'$s2'),
        _m(r'$s2r3', '@slack_u2:crosschat.app', 'Marcus Lee', 'Confirmed, promoting to 50%', const Duration(hours: 2, minutes: 20), root: r'$s2'),
        _m(r'$s3', me, 'Devon', 'RFC for moving the bridge daemon to a single binary is up, reviews welcome', const Duration(hours: 1)),
        _m(r'$s4', '@slack_u3:crosschat.app', 'Hana Okafor', 'Reading it now. Love the provisioning proxy idea.', const Duration(minutes: 40)),
        _m(r'$s4r1', me, 'Devon', 'Thanks! The bridges stay on loopback, only crosschatd is exposed.', const Duration(minutes: 35), root: r'$s4'),
        _m(r'$s5', '@slack_u2:crosschat.app', 'Marcus Lee', 'Canary at 100%, closing the deploy thread 👍', const Duration(minutes: 12)),
      ],
    );
    _room(const Room(roomId: '!mom:imessage', name: 'Mom', isDm: true, networkId: 'imessage', networkName: 'iMessage', threadsSupported: false, unread: 1), [
      _m(r'$i1', '@imessage_mom:crosschat.app', 'Mom', 'Are you still coming Sunday?', const Duration(hours: 5)),
      _m(r'$i2', me, 'Devon', 'Yes! I\'ll bring the pie', const Duration(hours: 4, minutes: 55)),
      _m(r'$i3', '@imessage_mom:crosschat.app', 'Mom', 'Perfect ❤️ dinner at 5', const Duration(minutes: 25)),
    ]);
    _room(const Room(roomId: '!climb:gmessages', name: 'Climbing crew', networkId: 'gmessages', networkName: 'Google Messages', threadsSupported: false), [
      _m(r'$g1', '@gmessages_1:crosschat.app', 'Jess', 'Bouldering Thursday at 7?', const Duration(hours: 9)),
      _m(r'$g2', '@gmessages_2:crosschat.app', 'Tom', 'I\'m in', const Duration(hours: 8)),
      _m(r'$g3', me, 'Devon', 'Count me in, I\'ll book the wall', const Duration(hours: 7)),
    ]);
    _room(const Room(roomId: '!ward:groupme', name: 'Ward basketball', networkId: 'groupme', networkName: 'GroupMe', threadsSupported: false, unread: 6), [
      _m(r'$gm1', '@groupme_1:crosschat.app', 'Coach Rivera', 'Gym is open Saturday 8am, bring water', const Duration(days: 1)),
      _m(r'$gm2', '@groupme_2:crosschat.app', 'Sam', 'Can someone grab the extra balls from the closet?', const Duration(hours: 20)),
    ]);
    _room(const Room(roomId: '!crosschat:matrix', name: 'crosschat-dev', topic: 'Plain Matrix room', unread: 0), [
      _m(r'$x1', '@alice:matrix.org', 'Alice', 'Threads in Matrix rooms work everywhere, including Element.', const Duration(hours: 30)),
      _m(r'$x1r', me, 'Devon', 'And they show up in Crosschat\'s side panel.', const Duration(hours: 29), root: r'$x1'),
    ]);
    _room(const Room(roomId: '!sam:slack', name: 'Sam Patel', isDm: true, networkId: 'slack', networkName: 'Slack', threadsSupported: true), [
      _m(r'$sp1', '@slack_u9:crosschat.app', 'Sam Patel', 'Got a minute to look at the on-call doc?', const Duration(hours: 26)),
    ]);
  }

  List<Message> _withSummaries(List<Message> all) {
    final main = all.where((m) => m.threadRoot == null).toList();
    return [
      for (final m in main)
        () {
          final replies = all.where((r) => r.threadRoot == m.eventId).toList();
          if (replies.isEmpty) return m;
          final last = replies.last;
          final people = <String>[];
          for (final r in replies.reversed) {
            if (!people.contains(r.sender)) people.add(r.sender);
          }
          return m.copyWith(
            thread: ThreadSummary(replyCount: replies.length, latestReplyTs: last.ts, latestReplyBody: last.body, participants: people),
          );
        }(),
    ];
  }

  @override
  Future<Session?> restore() async => autoLogin ? _session : null;

  @override
  Future<Session> login({required String homeserver, required String username, required String password}) async => _session;

  static const _session = Session(userId: me, deviceId: 'DEMO', homeserver: 'https://matrix.crosschat.app', accessToken: 'demo');

  @override
  Future<void> logout() async {}

  @override
  Stream<BackendUpdate> updates() => _updates.stream;

  @override
  Future<List<Room>> rooms() async {
    Room withLast(Room r) {
      final main = _events[r.roomId]!.where((m) => m.threadRoot == null).toList();
      final last = main.isEmpty ? null : main.last;
      return Room(
        roomId: r.roomId,
        name: r.name,
        topic: r.topic,
        isDm: r.isDm,
        unread: r.unread,
        highlights: r.highlights,
        lastTs: last?.ts ?? 0,
        lastMessage: last == null ? null : (last.isOwn ? 'You: ${last.body}' : last.body),
        networkId: r.networkId,
        networkName: r.networkName,
        threadsSupported: r.threadsSupported,
        bridgeId: r.bridgeId,
        bridgeBot: r.bridgeBot,
        protocolId: r.protocolId,
        protocolName: r.protocolName,
        loginId: r.loginId,
        roomType: r.roomType,
        markedUnread: r.markedUnread,
      );
    }

    final list = _rooms.values.map(withLast).toList()..sort((a, b) => b.lastTs.compareTo(a.lastTs));
    return list;
  }

  @override
  Future<List<Message>> timeline(String roomId, {int limit = 60}) async => _withSummaries(_events[roomId] ?? []);

  @override
  Future<List<Message>> thread(String roomId, String rootId, {int limit = 100}) async {
    final all = _events[roomId] ?? [];
    return all.where((m) => m.eventId == rootId || m.threadRoot == rootId).toList();
  }

  @override
  Future<String> sendText(String roomId, String body, {String? threadRoot}) async {
    final id = '\$local${_counter++}';
    final m = Message(eventId: id, sender: me, senderName: 'Devon', body: body, ts: DateTime.now().millisecondsSinceEpoch, threadRoot: threadRoot, isOwn: true);
    _events[roomId]!.add(m);
    _updates.add(BackendUpdate.newMessage(roomId, m));
    _updates.add(const BackendUpdate.roomsChanged());
    return id;
  }

  /// Calls made, for tests: `(roomId, eventId)`.
  final List<(String, String?)> readCalls = [];
  final List<(String, bool)> markedUnreadCalls = [];
  final List<String> mediaRequests = [];

  @override
  Future<void> markRead(String roomId, {String? eventId}) async {
    readCalls.add((roomId, eventId));
    final r = _rooms[roomId];
    if (r != null) _rooms[roomId] = r.copyWith(unread: 0, markedUnread: false);
  }

  @override
  Future<void> setMarkedUnread(String roomId, bool unread) async {
    markedUnreadCalls.add((roomId, unread));
    final r = _rooms[roomId];
    if (r != null) _rooms[roomId] = r.copyWith(markedUnread: unread);
  }

  /// A 1×1 PNG.
  static final Uint8List samplePng = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==');

  @override
  Future<Uint8List> mediaBytes(String source, {int? thumbWidth, int? thumbHeight}) async {
    mediaRequests.add(source);
    return samplePng;
  }

  /// Push a sync update (tests).
  void emit(BackendUpdate u) => _updates.add(u);

  /// Replace a room's server-side state (tests).
  void setRoom(Room r) => _rooms[r.roomId] = r;

  /// Append an event to a room's timeline (tests).
  void addEvent(String roomId, Message m) => _events[roomId]!.add(m);

  /// Replace a room's timeline (tests).
  void replaceEvents(String roomId, List<Message> msgs) => _events[roomId] = [...msgs];

  @override
  Future<List<DirectoryUser>> searchDirectory(String term) async => [
    if ('alice'.contains(term.toLowerCase())) const DirectoryUser(userId: '@alice:matrix.org', displayName: 'Alice'),
  ];

  @override
  Future<String> createDm(String userId) async {
    final id = '!dm-$userId';
    _room(Room(roomId: id, name: userId, isDm: true), []);
    _updates.add(const BackendUpdate.roomsChanged());
    return id;
  }

  @override
  Future<String> createGroup(String name, List<String> invites) async {
    final id = '!group-${_counter++}';
    _room(Room(roomId: id, name: name), []);
    _updates.add(const BackendUpdate.roomsChanged());
    return id;
  }

  @override
  Future<String> joinRoom(String idOrAlias) async => idOrAlias;
}
