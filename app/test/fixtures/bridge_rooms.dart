// Room shapes as the Rust core reports them, modeled on a real
// mautrix-gmessages v0.2609 account (27 joined rooms: 19 RCS chats, 6 SMS
// chats, the bridge's per-account space and the homeserver admin room).
// Names and identifiers are made up.

import 'package:crosschat/src/daemon/daemon_client.dart';
import 'package:crosschat/src/models.dart';

const gmBot = '@gmessagesbot:localhost';
const gmLogin = 'me@example.com/15550001111';
const gmSpace = '!space:localhost';

/// One Google Messages chat. [raw] = what an older core (grouping by the raw
/// `protocol.id`) reported: networkId `gmessages-rcs` / `gmessages-sms`.
Room gmRoom(int i, {bool sms = false, bool raw = false, String login = gmLogin, String bot = gmBot, int unread = 0}) {
  final pid = sms ? 'gmessages-sms' : 'gmessages-rcs';
  final pname = sms ? 'Google Messages (SMS)' : 'Google Messages (RCS)';
  return Room(
    roomId: '!gm$i${sms ? 's' : 'r'}:localhost',
    name: 'Chat $i',
    isDm: sms || i.isEven,
    unread: unread,
    lastTs: 1000 + i,
    networkId: raw ? pid : 'gmessages',
    networkName: raw ? pname : 'Google Messages',
    bridgeId: raw ? null : 'gmessages',
    bridgeBot: bot,
    protocolId: pid,
    protocolName: pname,
    loginId: login,
    roomType: sms || i.isEven ? 'dm' : null,
  );
}

/// The bridge's per-account space (`com.beeper.room_type.v2:
/// personal_filtering_space`, protocol id `gmessages`). The core now skips
/// spaces; older cores listed it as a chat.
const gmSpaceRoom = Room(
  roomId: gmSpace,
  name: 'Google Messages',
  networkId: 'gmessages',
  networkName: 'Google Messages',
  bridgeBot: gmBot,
  protocolId: 'gmessages',
  protocolName: 'Google Messages',
  loginId: gmLogin,
  roomType: 'personal_filtering_space',
);

/// Tuwunel's admin room: a plain Matrix room.
const adminRoom = Room(roomId: '!admins:localhost', name: 'Admin Room');

List<Room> devonsRooms({bool raw = false, bool withSpace = true}) => [
  for (var i = 0; i < 19; i++) gmRoom(i, raw: raw),
  for (var i = 0; i < 6; i++) gmRoom(100 + i, sms: true, raw: raw),
  if (withSpace) gmSpaceRoom,
  adminRoom,
];

BridgeInfo bridge(String id, String name, {String? network}) => BridgeInfo(
  id: id,
  displayName: name,
  network: network ?? id,
  enabled: true,
  maturity: 'stable',
  processState: 'running',
  live: true,
  preflight: const [],
  requirements: const [],
  capabilities: const {},
);

/// bridgev2 `GET /v3/whoami`, as mautrix-gmessages answers it.
Map<String, dynamic> gmWhoami({String state = 'CONNECTED', List<String> logins = const [gmLogin], String? message}) => {
  'network': {'displayname': 'Google Messages', 'network_id': 'gmessages', 'beeper_bridge_type': 'gmessages'},
  'login_flows': [
    {'name': 'Google Account', 'id': 'google'},
  ],
  'homeserver': 'localhost',
  'bridge_bot': gmBot,
  'command_prefix': '!gm',
  'logins': [
    for (final l in logins)
      {
        'state_event': state,
        'state': {'state_event': state, 'timestamp': 1, 'ttl': 21600, 'source': 'bridge', 'message': ?message},
        'id': l,
        'name': l.split('/').first,
        'profile': <String, dynamic>{},
        'space_room': gmSpace,
      },
  ],
};
