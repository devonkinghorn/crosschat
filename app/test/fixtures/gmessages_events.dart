import 'package:crosschat/src/models.dart';

/// The Google Messages group chat shapes seen on a real install, as the Rust
/// core hands them to the UI (see crates/crosschat-core/fixtures/
/// gmessages_events.json): encrypted attachments without thumbnails, an
/// iPhone `.heic` delivered as JPEG, a GIF, real RCS reactions, and SMS
/// tapback fallback texts with no relation to the message they quote.
/// Content is synthetic.
const me = '@devon:localhost';
const alex = '@gmessages_1.14:localhost';
const sam = '@gmessages_1.9:localhost';
const gmRoomId = '!family:localhost';

String _enc(String id) =>
    '{"file":{"v":"v2","url":"mxc://localhost/$id","key":{"alg":"A256CTR","ext":true,"k":"qcHVMSgYg","key_ops":["encrypt","decrypt"],"kty":"oct"},"iv":"X85+XgHN+HEAAAAAAAAAAA","hashes":{"sha256":"5qG4fFnbbV"}}}';

Message _m(
  String id,
  String sender,
  String name,
  String body,
  int ts, {
  String kind = 'text',
  MediaAttachment? media,
  List<ReactionGroup> reactions = const [],
  TapbackInfo? tapback,
}) => Message(
  eventId: id,
  sender: sender,
  senderName: name,
  body: body,
  ts: ts,
  kind: kind,
  isOwn: sender == me,
  media: media,
  reactions: reactions,
  tapback: tapback,
  senderAvatar: sender == alex ? 'mxc://localhost/alexavatar' : null,
);

const t0 = 1791400000000;

List<Message> familyChat() => [
  _m(
    r'$t1',
    me,
    'Devon',
    'Dinner at 7 on Sunday?',
    t0 + 2000,
    reactions: const [
      ReactionGroup(key: '👍', senders: [sam, me], own: true),
    ],
  ),
  _m(
    r'$img1',
    alex,
    'Alex Rivera',
    '',
    t0 + 3000,
    kind: 'image',
    media: MediaAttachment(source: _enc('heicasjpeg'), filename: 'IMG_3406.heic', mimetype: 'image/jpeg', size: 127496),
  ),
  _m(
    r'$gif1',
    sam,
    'Sam',
    '',
    t0 + 4000,
    kind: 'image',
    media: MediaAttachment(source: _enc('gif1'), filename: 'funny.gif', mimetype: 'image/gif', size: 326315),
  ),
  _m(
    r'$heic1',
    alex,
    'Alex Rivera',
    '',
    t0 + 4500,
    kind: 'image',
    media: MediaAttachment(source: _enc('realheic'), filename: 'IMG_0001.heic', mimetype: 'image/heic', size: 2787600, width: 4284, height: 5712),
  ),
  _m(
    r'$vid1',
    me,
    'Devon',
    '',
    t0 + 5000,
    kind: 'video',
    media: MediaAttachment(source: _enc('vid1'), filename: 'clip.mp4', mimetype: 'video/mp4', size: 16205603),
  ),
  _m(
    r'$tb1',
    alex,
    'Alex Rivera',
    'Laughed at an image',
    t0 + 7000,
    tapback: const TapbackInfo(key: '😂', targetKind: 'image'),
  ),
  _m(
    r'$tb2',
    alex,
    'Alex Rivera',
    'Loved “Dinner at 7 on Sunday?”',
    t0 + 7100,
    tapback: const TapbackInfo(key: '❤️', targetText: 'Dinner at 7 on Sunday?'),
  ),
  _m(
    r'$tb3',
    sam,
    'Sam',
    '\u200b👍\u200b to “Dinner at 7 on Sunday?”',
    t0 + 7200,
    tapback: const TapbackInfo(key: '👍', targetText: 'Dinner at 7 on Sunday?'),
  ),
  _m(
    r'$tb4',
    sam,
    'Sam',
    'Emphasized “a message we don\'t have anymore”',
    t0 + 7300,
    tapback: const TapbackInfo(key: '‼️', targetText: "a message we don't have anymore"),
  ),
  _m(r'$t2', alex, 'Alex Rivera', 'Loved the movie last night', t0 + 8000),
];
