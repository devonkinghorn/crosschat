// "Add network" (enable → sign-in), the iMessage login steps in the generic
// renderer, removing a network, and the contact picker with per-person
// network choice.
import 'dart:convert';

import 'package:crosschat/main.dart';
import 'package:crosschat/src/backend/demo_backend.dart';
import 'package:crosschat/src/contacts/device_contacts.dart';
import 'package:crosschat/src/contacts/people.dart';
import 'package:crosschat/src/daemon/daemon_client.dart';
import 'package:crosschat/src/local/local_server.dart';
import 'package:crosschat/src/platform.dart';
import 'package:crosschat/src/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const mac = PlatformCapabilities(os: 'macos', canExtractAppleHardwareKey: true, hasPersistentSyncService: false, hasEmbeddedWebview: false, isMobile: false);

Map<String, dynamic> bridgeJson(
  String id,
  String name, {
  bool enabled = false,
  String? state,
  bool live = false,
  String? progress,
  String? setupError,
  bool hostSupported = true,
  List<Map<String, dynamic>> preflight = const [],
}) => {
  'id': id,
  'display_name': name,
  'network': id,
  'description': '$name description',
  'enabled': enabled,
  'maturity': id == 'imessage' ? 'beta' : 'stable',
  'host_supported': hostSupported,
  'host_platforms': hostSupported ? ['linux', 'macos'] : ['windows'],
  'process': state == null ? null : {'state': state},
  'health': enabled ? {'live': live} : null,
  'progress': progress,
  'setup_error': setupError,
  'keep_awake': id == 'imessage',
  'preflight': preflight,
  'requirements': [],
  'capabilities': {},
};

const imessagePreflight = [
  {'id': 'contact_key_verification', 'severity': 'blocking', 'confirm': true, 'message': 'Contact Key Verification is OFF for your Apple ID.'},
  {'id': 'stay_awake', 'severity': 'warning', 'message': 'This Mac has to stay on, awake and online.'},
];

Map<String, dynamic> whoami(String network, {bool loggedIn = true}) => {
  'network': {'displayname': network, 'network_id': network},
  'bridge_bot': '@${network}bot:localhost',
  'logins': [
    if (loggedIn)
      {
        'id': '$network-login',
        'name': 'me',
        'state_event': 'CONNECTED',
        'state': {'state_event': 'CONNECTED'},
        'profile': <String, dynamic>{},
      },
  ],
};

/// crosschatd with Google Messages running; iMessage can be added.
class FakeCrosschatd {
  final seen = <http.Request>[];
  bool imessageEnabled = false;
  int pollsUntilReady = 2;
  bool imessageLoggedIn = false;
  bool gmessagesEnabled = true;

  /// Identifiers iMessage reaches.
  Set<String> onImessage = {};

  late final client = MockClient((req) async {
    seen.add(req);
    final path = req.url.path;
    Map<String, dynamic>? body() => req.body.isEmpty ? null : jsonDecode(req.body) as Map<String, dynamic>;
    http.Response ok(Object v) => http.Response(jsonEncode(v), 200);
    if (path == '/_crosschat/v1/health') return ok({'status': 'ok'});
    if (path == '/_crosschat/v1/networks') {
      Map<String, dynamic> imessage;
      if (!imessageEnabled) {
        imessage = bridgeJson('imessage', 'iMessage', preflight: imessagePreflight);
      } else if (pollsUntilReady > 0) {
        pollsUntilReady--;
        imessage = bridgeJson('imessage', 'iMessage', enabled: pollsUntilReady == 0, progress: 'Installing iMessage', preflight: imessagePreflight);
      } else {
        imessage = bridgeJson('imessage', 'iMessage', enabled: true, state: 'running', live: true, preflight: imessagePreflight);
      }
      return ok({
        'admin': true,
        'can_manage': true,
        'keeping_awake': imessageEnabled && pollsUntilReady == 0,
        'host_os': 'macos',
        'bridges': [
          bridgeJson('gmessages', 'Google Messages', enabled: gmessagesEnabled, state: gmessagesEnabled ? 'running' : null, live: gmessagesEnabled),
          imessage,
          bridgeJson('groupme', 'GroupMe', hostSupported: false),
        ],
      });
    }
    if (path == '/_crosschat/v1/bridges/imessage/enable') {
      imessageEnabled = true;
      return ok({'ok': true, 'started': true});
    }
    if (path == '/_crosschat/v1/bridges/gmessages/remove') {
      gmessagesEnabled = false;
      return ok({'ok': true});
    }
    if (path.endsWith('/provision/v3/whoami')) {
      final b = path.split('/')[4];
      if (b == 'imessage') return ok(whoami('imessage', loggedIn: imessageLoggedIn));
      return ok(whoami(b));
    }
    if (path == '/_crosschat/v1/resolve') {
      final id = body()!['identifier'] as String;
      return ok({
        'results': {
          'imessage': onImessage.contains(id)
              ? {
                  'bridge': 'imessage',
                  'network': 'imessage',
                  'id': id,
                  'identifiers': [id],
                }
              : null,
        },
        'errors': onImessage.contains(id) ? {} : {'imessage': 'user not found on iMessage'},
      });
    }
    if (path == '/_crosschat/v1/dm') {
      final b = body()!;
      return ok({'dm_room_mxid': '!dm-${b['bridge']}-${(b['identifier'] as String).hashCode}:localhost'});
    }
    if (path == '/_crosschat/v1/search') return ok({'results': [], 'errors': {}});
    // iMessage login (step shapes from corten-matrix 1.3.2 on macOS).
    if (path.endsWith('/imessage/provision/v3/login/flows')) {
      return ok({
        'flows': [
          {'id': 'apple-id', 'name': 'Apple ID', 'description': 'Log in with your Apple ID to send and receive iMessages'},
          {'id': 'external-key', 'name': 'Apple ID (External Key)', 'description': 'Log in using a hardware key extracted from a Mac.'},
        ],
      });
    }
    if (path.endsWith('/imessage/provision/v3/login/start/apple-id')) {
      return ok({
        'login_id': 'L1',
        'type': 'user_input',
        'step_id': 'fi.mau.imessage.login.appleid',
        'instructions': 'Enter your Apple ID credentials.',
        'user_input': {
          'fields': [
            {'type': 'email', 'id': 'username', 'name': 'Apple ID'},
            {'type': 'password', 'id': 'password', 'name': 'Password'},
          ],
        },
      });
    }
    if (path.endsWith('/login/step/L1/fi.mau.imessage.login.appleid/user_input')) {
      return ok({
        'login_id': 'L1',
        'type': 'user_input',
        'step_id': 'fi.mau.imessage.login.2fa',
        'instructions': 'Enter your Apple ID verification code.',
        'user_input': {
          'fields': [
            {'id': 'code', 'name': '2FA Code'},
          ],
        },
      });
    }
    if (path.endsWith('/login/step/L1/fi.mau.imessage.login.2fa/user_input')) {
      return ok({
        'login_id': 'L1',
        'type': 'user_input',
        'step_id': 'fi.mau.imessage.login.select_device',
        'instructions': 'Multiple Apple devices were found on your account.',
        'user_input': {
          'fields': [
            {
              'type': 'select',
              'id': 'device',
              'name': 'Device',
              'options': ['1. iPhone', '2. MacBook'],
            },
          ],
        },
      });
    }
    if (path.endsWith('/login/step/L1/fi.mau.imessage.login.select_device/user_input')) {
      return ok({
        'login_id': 'L1',
        'type': 'user_input',
        'step_id': 'fi.mau.imessage.login.device_passcode',
        'instructions': 'Enter the passcode for iPhone.',
        'user_input': {
          'fields': [
            {'type': 'password', 'id': 'passcode', 'name': 'Device Passcode'},
          ],
        },
      });
    }
    if (path.endsWith('/login/step/L1/fi.mau.imessage.login.device_passcode/user_input')) {
      return ok({
        'login_id': 'L1',
        'type': 'user_input',
        'step_id': 'fi.mau.imessage.login.select_handle',
        'instructions': 'Choose which identity to use for outgoing iMessages.',
        'user_input': {
          'fields': [
            {
              'type': 'select',
              'id': 'handle',
              'name': 'Handle',
              'options': ['tel:+15550000001'],
            },
          ],
        },
      });
    }
    if (path.endsWith('/login/step/L1/fi.mau.imessage.login.select_handle/user_input')) {
      imessageLoggedIn = true;
      return ok({'login_id': 'L1', 'type': 'complete', 'step_id': 'fi.mau.imessage.login.complete', 'instructions': 'Successfully logged in.', 'complete': {}});
    }
    return http.Response('{"errcode":"M_NOT_FOUND","error":"not found"}', 404);
  });

  List<Map<String, dynamic>> bodiesFor(String pathEnd) => [
    for (final r in seen)
      if (r.url.path.endsWith(pathEnd)) jsonDecode(r.body) as Map<String, dynamic>,
  ];
}

class FakeContacts implements DeviceContactsSource {
  FakeContacts(this.access, [this.contacts = const []]);
  ContactsAccess access;
  final List<DeviceContact> contacts;
  int requests = 0;

  @override
  Future<ContactsAccess> status() async => access;

  @override
  Future<ContactsAccess> request() async {
    requests++;
    if (access == ContactsAccess.notDetermined) access = ContactsAccess.granted;
    return access;
  }

  @override
  Future<List<DeviceContact>> list() async => access == ContactsAccess.granted ? contacts : const [];
}

const people = [
  DeviceContact(id: 'a', name: 'Avery Example', phones: ['(801) 555-0101']),
  DeviceContact(id: 'b', name: 'Blake Example', phones: ['+1 801 555 0102'], emails: ['Blake@Example.com']),
  DeviceContact(id: 'c', name: 'No Number', phones: []),
];

Future<AppState> pumpApp(WidgetTester tester, FakeCrosschatd daemon, {DemoBackend? backend}) async {
  tester.view.physicalSize = const Size(1600, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final state = AppState(backend: backend ?? DemoBackend(), capabilities: mac, daemonHttp: daemon.client, accountsPollInterval: null)
    ..networkPollInterval = const Duration(milliseconds: 10)
    ..callingCode = '1';
  await tester.pumpWidget(CrosschatApp(state: state));
  await state.init();
  await tester.pumpAndSettle();
  if (find.byKey(const Key('setup-existing')).evaluate().isNotEmpty) {
    await tester.tap(find.byKey(const Key('setup-existing')));
    await tester.pumpAndSettle();
  }
  await tester.enterText(find.byKey(const Key('homeserver')), 'https://matrix.example.org');
  await tester.enterText(find.byKey(const Key('username')), 'devon');
  await tester.enterText(find.byKey(const Key('password')), 'hunter2');
  await tester.tap(find.byKey(const Key('login')));
  await tester.pumpAndSettle();
  return state;
}

void main() {
  group('people', () {
    test('phone numbers become E.164', () {
      expect(normalizePhone('(801) 555-0101'), '+18015550101');
      expect(normalizePhone('1-801-555-0101'), '+18015550101');
      expect(normalizePhone('+44 20 7946 0958'), '+442079460958');
      expect(normalizePhone('0044 20 7946 0958'), '+442079460958');
      expect(normalizePhone('020 7946 0958', callingCode: '44'), '+442079460958');
      expect(normalizePhone('555-0101'), isNull, reason: 'no area code');
      expect(normalizePhone('call me'), isNull);
      expect(normalizePhone('tel:+18015550101'), '+18015550101');
      expect(callingCodeFor('GB'), '44');
      expect(callingCodeFor(null), '1');
    });

    test('identifier keys', () {
      expect(identifierKey('Blake@Example.com'), 'mailto:blake@example.com');
      expect(identifierKey('mailto:x@y.z'), 'mailto:x@y.z');
      expect(identifierKey('801.555.0101'), 'tel:+18015550101');
      expect(identifierKey('U123ABC'), isNull);
    });

    test('device and network contacts merge by number or email', () {
      final merged = mergePeople(people, [
        Contact(bridge: 'gmessages', network: 'gmessages', id: '17', name: 'Avery E', identifiers: ['tel:+18015550101']),
        Contact(bridge: 'slack', network: 'slack', id: 'U1', name: 'Slack Only'),
      ]);
      expect(merged.map((p) => p.name), ['Avery Example', 'Blake Example', 'Slack Only']);
      final avery = merged.first;
      expect(avery.key, 'tel:+18015550101');
      expect(avery.contactOn('gmessages')?.id, '17');
      expect(merged[1].identifiers, {'tel:+18015550102', 'mailto:blake@example.com'});
      expect(merged[2].key, 'bridge:slack:U1');
      expect(avery.matches('avery'), isTrue);
      expect(avery.matches('555-0101'), isTrue);
      expect(avery.matches('blake'), isFalse);
    });

    test('candidate networks: iMessage first, then Google Messages, then where they were found', () {
      final p = Person(key: 'tel:+18015550101', name: 'A', identifiers: {'tel:+18015550101'});
      expect(candidateNetworks(p, {'gmessages', 'imessage', 'slack'}), ['imessage', 'gmessages']);
      expect(candidateNetworks(p, {'gmessages'}), ['gmessages']);
      final e = Person(key: 'mailto:a@b.c', name: 'A', identifiers: {'mailto:a@b.c'});
      expect(candidateNetworks(e, {'gmessages', 'imessage'}), ['imessage']);
    });

    test('network prefs round-trip through account data JSON', () {
      final prefs = ContactNetworkPrefs.fromJson({
        'version': 1,
        'by_contact': {'tel:+1': 'imessage'},
        'rooms': {'!r:x': 'tel:+1'},
      });
      expect(prefs.byContact['tel:+1'], 'imessage');
      expect(ContactNetworkPrefs.fromJson(jsonDecode(jsonEncode(prefs.toJson())) as Map<String, dynamic>).rooms, {'!r:x': 'tel:+1'});
      expect(ContactNetworkPrefs.fromJson(null).byContact, isEmpty);
    });
  });

  test('an outdated local server is restarted with the bundled crosschatd', () {
    final t = DateTime.fromMillisecondsSinceEpoch(1000000000);
    const old = LocalServerStatus(phase: 'ready');
    expect(shouldUpgradeLocalServer(old, t), isTrue, reason: 'too old to report its binary');
    expect(shouldUpgradeLocalServer(const LocalServerStatus(phase: 'ready', exeMtimeMs: 1000000000), t), isFalse);
    expect(shouldUpgradeLocalServer(const LocalServerStatus(phase: 'ready', exeMtimeMs: 900000000), t), isTrue);
    expect(shouldUpgradeLocalServer(old, null), isFalse, reason: 'no binary to start');
  });

  testWidgets('add iMessage from the rail: installs, checklist, then every login step', (tester) async {
    final d = FakeCrosschatd();
    final state = await pumpApp(tester, d);
    expect(state.canManageNetworks, isTrue);

    await tester.tap(find.byKey(const Key('rail-add')));
    await tester.pumpAndSettle();
    expect(find.text('Add a network'), findsOneWidget);
    expect(find.text('Unavailable'), findsOneWidget, reason: 'GroupMe needs another OS');
    expect(find.text('Keeps this computer awake while connected.'), findsNothing, reason: 'remote server in this test');

    await tester.tap(find.byKey(const Key('add-network-imessage')));
    await tester.pumpAndSettle();
    expect(d.seen.where((r) => r.url.path == '/_crosschat/v1/bridges/imessage/enable'), hasLength(1));

    // Straight to the sign-in, with the checklist first.
    expect(find.text('Connect iMessage'), findsOneWidget);
    expect(find.text('This Mac has to stay on, awake and online.'), findsOneWidget);
    expect(find.textContaining('Tick the checklist'), findsOneWidget);
    await tester.tap(find.byKey(const Key('flow-apple-id')));
    await tester.pumpAndSettle();
    expect(d.seen.where((r) => r.url.path.endsWith('/login/start/apple-id')), isEmpty, reason: 'checklist not ticked');
    await tester.tap(find.byKey(const Key('check-contact_key_verification')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Recommended.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('flow-apple-id')));
    await tester.pumpAndSettle();

    // Apple ID + password.
    final user = tester.widget<TextField>(find.byKey(const Key('field-username')));
    expect(user.keyboardType, TextInputType.emailAddress);
    expect(tester.widget<TextField>(find.byKey(const Key('field-password'))).obscureText, isTrue);
    await tester.enterText(find.byKey(const Key('field-username')), 'someone@example.com');
    await tester.enterText(find.byKey(const Key('field-password')), 'pw');
    await tester.tap(find.byKey(const Key('step-continue')));
    await tester.pumpAndSettle();
    expect(d.bodiesFor('fi.mau.imessage.login.appleid/user_input').single, {'username': 'someone@example.com', 'password': 'pw'});

    // 2FA code: number keyboard.
    expect(tester.widget<TextField>(find.byKey(const Key('field-code'))).keyboardType, TextInputType.number);
    await tester.enterText(find.byKey(const Key('field-code')), '123456');
    await tester.tap(find.byKey(const Key('step-continue')));
    await tester.pumpAndSettle();

    // Which device's passcode, then the passcode.
    await tester.tap(find.byKey(const Key('field-device')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1. iPhone').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('step-continue')));
    await tester.pumpAndSettle();
    expect(d.bodiesFor('select_device/user_input').single, {'device': '1. iPhone'});
    await tester.enterText(find.byKey(const Key('field-passcode')), '0000');
    await tester.tap(find.byKey(const Key('step-continue')));
    await tester.pumpAndSettle();

    // A single handle is preselected.
    await tester.tap(find.byKey(const Key('step-continue')));
    // (The rail now shows iMessage syncing, which animates.)
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(d.bodiesFor('select_handle/user_input').single, {'handle': 'tel:+15550000001'});
    expect(find.textContaining('Connected!'), findsOneWidget);
    expect(state.bridge('imessage')!.ready, isTrue);
  });

  testWidgets('remove a network from Settings after confirming', (tester) async {
    final d = FakeCrosschatd();
    final state = await pumpApp(tester, d);
    await tester.tap(find.byKey(const Key('open-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-add-network')), findsOneWidget);
    await tester.tap(find.byKey(const Key('network-menu-gmessages')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Remove…'));
    await tester.pumpAndSettle();
    expect(find.text('Remove Google Messages?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-remove')));
    await tester.pumpAndSettle();
    expect(d.seen.where((r) => r.url.path == '/_crosschat/v1/bridges/gmessages/remove'), hasLength(1));
    expect(state.bridge('gmessages')!.enabled, isFalse);
    expect(find.byKey(const Key('network-menu-gmessages')), findsNothing);
  });

  group('contact picker', () {
    late DeviceContactsSource previous;
    setUp(() => previous = deviceContacts);
    tearDown(() => deviceContacts = previous);

    testWidgets('iMessage when reachable, else Google Messages; picking a network is remembered', (tester) async {
      deviceContacts = FakeContacts(ContactsAccess.granted, people);
      final d = FakeCrosschatd()
        ..imessageEnabled = true
        ..pollsUntilReady = 0
        ..imessageLoggedIn = true
        ..onImessage = {'tel:+18015550101'};
      final backend = DemoBackend();
      final state = await pumpApp(tester, d, backend: backend);
      expect(state.usableBridges, {'gmessages', 'imessage'});

      await tester.tap(find.byKey(const Key('new-chat')));
      await tester.pumpAndSettle();
      expect(find.text('Avery Example'), findsOneWidget);
      expect(find.text('Blake Example'), findsOneWidget);
      expect(find.text('No Number'), findsNothing);

      // Avery is on iMessage.
      await tester.tap(find.text('Avery Example'));
      await tester.pumpAndSettle();
      expect(d.bodiesFor('/_crosschat/v1/dm').last, {'bridge': 'imessage', 'identifier': 'tel:+18015550101'});
      expect(state.selectedRoomId, startsWith('!dm-imessage-'));
      final averyRoom = state.selectedRoomId!;
      expect(backend.accountDataStore[ContactNetworkPrefs.eventType]!['rooms'], {averyRoom: 'tel:+18015550101'});

      // Blake isn't: Google Messages with the number.
      await tester.tap(find.byKey(const Key('new-chat')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('new-chat-search')), 'blake');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Blake Example'));
      await tester.pumpAndSettle();
      expect(d.bodiesFor('/_crosschat/v1/dm').last, {'bridge': 'gmessages', 'identifier': 'tel:+18015550102'});

      // Choose iMessage for Blake: remembered in account data.
      await tester.tap(find.byKey(const Key('new-chat')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('person-network-tel:+18015550102')));
      await tester.pumpAndSettle();
      // (Blake isn't reachable on iMessage; the menu says so but allows it.)
      await tester.tap(find.text('iMessage · not on iMessage'));
      await tester.pumpAndSettle();
      expect(backend.accountDataStore[ContactNetworkPrefs.eventType]!['by_contact'], {'tel:+18015550102': 'imessage'});
      expect(await state.networkFor(mergePeople(people, const [])[1]), 'imessage');
    });

    testWidgets('typing a number offers it directly; the composer can switch networks', (tester) async {
      deviceContacts = FakeContacts(ContactsAccess.granted);
      final d = FakeCrosschatd()
        ..imessageEnabled = true
        ..pollsUntilReady = 0
        ..imessageLoggedIn = true;
      final backend = DemoBackend();
      final state = await pumpApp(tester, d, backend: backend);
      await tester.tap(find.byKey(const Key('new-chat')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('new-chat-search')), '+1 801 555 0199');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('person-tel:+18015550199')));
      await tester.pumpAndSettle();
      expect(d.bodiesFor('/_crosschat/v1/dm').last, {'bridge': 'gmessages', 'identifier': 'tel:+18015550199'});
      final dm = state.selectedRoomId!;
      expect(state.networkPrefs.rooms[dm], 'tel:+18015550199');

      // An existing chat remembered for this number: the switcher appears.
      final room = state.rooms.first;
      state.networkPrefs.rooms[room.roomId] = 'tel:+18015550199';
      await state.selectRoom(room.roomId);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('composer-network')), findsOneWidget);
      await tester.tap(find.byKey(const Key('composer-network')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('iMessage').last);
      await tester.pumpAndSettle();
      expect(d.bodiesFor('/_crosschat/v1/dm').last, {'bridge': 'imessage', 'identifier': 'tel:+18015550199'});
      expect(backend.accountDataStore[ContactNetworkPrefs.eventType]!['by_contact'], {'tel:+18015550199': 'imessage'});
    });

    testWidgets('works without contacts access', (tester) async {
      final fake = FakeContacts(ContactsAccess.denied, people);
      deviceContacts = fake;
      await pumpApp(tester, FakeCrosschatd());
      await tester.tap(find.byKey(const Key('new-chat')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('contacts-denied')), findsOneWidget);
      expect(find.text('Avery Example'), findsNothing);
      expect(fake.requests, 0);
      await tester.enterText(find.byKey(const Key('new-chat-search')), 'ali');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('@alice:matrix.org'), findsOneWidget, reason: 'Matrix search still works');
    });

    testWidgets('asks for access only when the user taps Allow', (tester) async {
      final fake = FakeContacts(ContactsAccess.notDetermined, people);
      deviceContacts = fake;
      await pumpApp(tester, FakeCrosschatd());
      await tester.tap(find.byKey(const Key('new-chat')));
      await tester.pumpAndSettle();
      expect(fake.requests, 0);
      expect(find.byKey(const Key('contacts-prompt')), findsOneWidget);
      await tester.tap(find.byKey(const Key('contacts-allow')));
      await tester.pumpAndSettle();
      expect(fake.requests, 1);
      expect(find.text('Avery Example'), findsOneWidget);
      expect(find.byKey(const Key('contacts-prompt')), findsNothing);
    });
  });
}
