import 'package:crosschat/src/models.dart';
import 'package:crosschat/src/state/network_groups.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/bridge_rooms.dart';

void main() {
  final gm = bridge('gmessages', 'Google Messages');
  final gmAccounts = {'gmessages': BridgeAccounts.fromWhoami(gm, gmWhoami())};

  group('grouping (bug: Google Messages split into 3 rail entries)', () {
    test('old core shapes: raw gmessages-rcs / gmessages-sms ids and the space fold into one entry', () {
      final v = resolveNetworks(devonsRooms(raw: true), bridges: [gm], accounts: gmAccounts);
      expect(v.groups.map((g) => g.key), ['gmessages', 'matrix']);
      final g = v.groups.first;
      expect(g.label, 'Google Messages');
      expect(g.subtitle, 'me@example.com');
      expect(g.roomCount, 25, reason: 'the space is not a chat');
      expect(v.rooms.where((r) => r.roomId == gmSpace), isEmpty);
      expect(v.rooms.where((r) => r.groupKey == 'gmessages').every((r) => r.networkId == 'gmessages'), isTrue);
    });

    test('current core shapes group into one entry even without crosschatd', () {
      final v = resolveNetworks(devonsRooms());
      expect(v.groups.map((g) => g.key), ['gmessages', 'matrix']);
      expect(v.groups.first.roomCount, 25);
      expect(v.groups.first.subtitle, 'me@example.com');
    });

    test('per-chat RCS / SMS badge', () {
      expect(gmRoom(1).subProtocol, 'RCS');
      expect(gmRoom(1, sms: true).subProtocol, 'SMS');
      expect(const Room(roomId: '!x', name: 'x', networkId: 'slack', protocolId: 'slackgo', protocolName: 'Slack').subProtocol, isNull);
    });

    test('two accounts on one bridge get one entry each', () {
      final rooms = [gmRoom(1), gmRoom(2, login: 'other@example.com/15550002222'), gmRoom(3, sms: true, login: 'other@example.com/15550002222')];
      final v = resolveNetworks(rooms);
      expect(v.groups.map((g) => g.key), ['gmessages/$gmLogin', 'gmessages/other@example.com/15550002222']);
      expect(v.groups.map((g) => g.subtitle), ['me@example.com', 'other@example.com']);
      expect(v.groups.last.roomCount, 2);
    });

    test('slack (protocol id slackgo), imessage and groupme group by bridge too', () {
      final sl = bridge('slack', 'Slack');
      const bot = '@slackbot:localhost';
      final rooms = [
        // Shared Slack channels have no receiver; DMs do.
        const Room(roomId: '!c1', name: 'general', networkId: 'slack', bridgeId: 'slack', bridgeBot: bot, protocolId: 'slackgo', protocolName: 'Slack'),
        const Room(roomId: '!d1', name: 'Sam', isDm: true, networkId: 'slack', bridgeId: 'slack', bridgeBot: bot, protocolId: 'slackgo', loginId: 'T1-U1'),
        const Room(roomId: '!im', name: 'Mom', isDm: true, networkId: 'imessage', bridgeId: 'imessage', protocolId: 'imessagego'),
        const Room(roomId: '!gm', name: 'Climbing', networkId: 'groupme', protocolId: 'groupme'),
      ];
      final accounts = {
        'slack': BridgeAccounts(
          bridgeId: 'slack',
          network: 'slack',
          displayName: 'Slack',
          bridgeBot: bot,
          logins: const [BridgeLogin(id: 'T1-U1', name: 'Acme', stateEvent: 'CONNECTED')],
        ),
      };
      final v = resolveNetworks(rooms, bridges: [sl], accounts: accounts);
      expect(v.groups.map((g) => g.key), ['imessage', 'slack', 'groupme']);
      expect(v.groups[1].roomCount, 2);
      expect(v.groups[1].subtitle, 'Acme');
    });

    test('an entry with no chats is never shown when nothing is going on', () {
      final v = resolveNetworks([gmSpaceRoom, adminRoom], bridges: [gm], accounts: gmAccounts);
      expect(v.groups.map((g) => g.key), ['matrix']);
    });
  });

  group('sync state (bug: nothing in the sidebar right after connecting)', () {
    test('a just-completed login shows the network as syncing before any chat exists', () {
      final v = resolveNetworks([adminRoom], bridges: [gm], pendingBridges: {'gmessages'});
      final g = v.groups.first;
      expect(g.key, 'gmessages');
      expect(g.health, NetworkHealth.syncing);
      expect(g.status, 'Syncing chats…');
      expect(g.roomCount, 0);
    });

    test('syncing counts chats as they appear and settles when the count stops changing', () {
      final t0 = DateTime(2026, 10, 8, 12);
      final tracker = SyncTracker();
      tracker.start('gmessages/$gmLogin', t0);
      NetworkGroup at(List<Room> rooms, DateTime now) =>
          resolveNetworks(rooms, bridges: [gm], accounts: gmAccounts, tracker: tracker, now: now).groups.firstWhere((g) => g.networkId == 'gmessages');

      final empty = resolveNetworks([adminRoom], bridges: [gm], accounts: gmAccounts, tracker: tracker, now: t0).groups;
      expect(empty.first.status, 'Syncing chats…');
      expect(at([gmRoom(1), gmRoom(2)], t0.add(const Duration(seconds: 5))).status, 'Syncing chats… 2 so far');
      expect(at(devonsRooms(), t0.add(const Duration(seconds: 15))).status, 'Syncing chats… 25 so far');
      // 20 s without new chats: done.
      final done = at(devonsRooms(), t0.add(const Duration(seconds: 40)));
      expect(done.health, NetworkHealth.ok);
      expect(done.status, isNull);
      expect(tracker.active, isFalse);
    });

    test('bridge states: backfilling, connecting, errors and sign-in needed', () {
      NetworkGroup with_(String state, {String? message}) => resolveNetworks(
        devonsRooms(),
        bridges: [gm],
        accounts: {'gmessages': BridgeAccounts.fromWhoami(gm, gmWhoami(state: state, message: message))},
      ).groups.first;
      expect(with_('BACKFILLING').health, NetworkHealth.syncing);
      expect(with_('CONNECTING').status, 'Connecting…');
      expect(with_('TRANSIENT_DISCONNECT').health, NetworkHealth.error);
      final out = with_('BAD_CREDENTIALS', message: 'Logged out from Google');
      expect(out.health, NetworkHealth.needsRelogin);
      expect(out.status, 'Logged out from Google');
      expect(with_('LOGGED_OUT').status, contains('Sign in again'));
      // Even with no chats, a broken account stays visible.
      final broken = resolveNetworks(
        [adminRoom],
        bridges: [gm],
        accounts: {'gmessages': BridgeAccounts.fromWhoami(gm, gmWhoami(state: 'BAD_CREDENTIALS'))},
      ).groups.first;
      expect(broken.key, 'gmessages');
      expect(broken.failing, isTrue);
    });

    test('an unreachable bridge is an error', () {
      final acc = BridgeAccounts.fromWhoami(gm, gmWhoami()).withUnreachable('not running');
      final g = resolveNetworks(devonsRooms(), bridges: [gm], accounts: {'gmessages': acc}).groups.first;
      expect(g.health, NetworkHealth.error);
      expect(g.status, contains('not running'));
    });
  });
}
