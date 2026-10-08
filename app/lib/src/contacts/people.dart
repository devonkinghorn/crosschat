import '../daemon/daemon_client.dart';
import 'device_contacts.dart';

/// Country calling code for a locale's country (default `1`): used to read
/// local numbers from the address book like `(801) 555-1234`.
String callingCodeFor(String? countryCode) => _callingCodes[countryCode?.toUpperCase()] ?? '1';

const _callingCodes = {
  'US': '1',
  'CA': '1',
  'PR': '1',
  'GB': '44',
  'IE': '353',
  'DE': '49',
  'AT': '43',
  'CH': '41',
  'FR': '33',
  'BE': '32',
  'NL': '31',
  'LU': '352',
  'ES': '34',
  'PT': '351',
  'IT': '39',
  'DK': '45',
  'SE': '46',
  'NO': '47',
  'FI': '358',
  'IS': '354',
  'PL': '48',
  'CZ': '420',
  'SK': '421',
  'HU': '36',
  'RO': '40',
  'GR': '30',
  'TR': '90',
  'UA': '380',
  'IL': '972',
  'AE': '971',
  'SA': '966',
  'IN': '91',
  'PK': '92',
  'BD': '880',
  'CN': '86',
  'HK': '852',
  'TW': '886',
  'JP': '81',
  'KR': '82',
  'SG': '65',
  'MY': '60',
  'TH': '66',
  'VN': '84',
  'PH': '63',
  'ID': '62',
  'AU': '61',
  'NZ': '64',
  'ZA': '27',
  'NG': '234',
  'KE': '254',
  'EG': '20',
  'MX': '52',
  'BR': '55',
  'AR': '54',
  'CL': '56',
  'CO': '57',
  'PE': '51',
};

/// A phone number in E.164 (`+18015551234`), or null when it can't be one
/// (too short, letters). Numbers without a country code get
/// [callingCode]; for `1` (North America) they must have 10 digits.
String? normalizePhone(String raw, {String callingCode = '1'}) {
  var t = raw.trim();
  if (t.startsWith('tel:')) t = t.substring(4);
  if (t.isEmpty || RegExp(r'[A-Za-z]').hasMatch(t)) return null;
  var digits = t.replaceAll(RegExp(r'[^0-9]'), '');
  var international = t.startsWith('+');
  if (!international && t.startsWith('00')) {
    international = true;
    digits = digits.substring(2);
  }
  if (international) return digits.length >= 7 && digits.length <= 15 ? '+$digits' : null;
  if (callingCode == '1') {
    if (digits.length == 10) return '+1$digits';
    if (digits.length == 11 && digits.startsWith('1')) return '+$digits';
    return null;
  }
  if (digits.startsWith('0')) digits = digits.substring(1);
  return digits.length >= 6 ? '+$callingCode$digits' : null;
}

String? normalizeEmail(String raw) {
  var t = raw.trim();
  if (t.startsWith('mailto:')) t = t.substring(7);
  return t.contains('@') && !t.startsWith('@') && !t.contains(' ') ? t.toLowerCase() : null;
}

/// `tel:+1…` / `mailto:…` key for a phone number or email, or null.
String? identifierKey(String raw, {String callingCode = '1'}) {
  final e = raw.contains('@') ? normalizeEmail(raw) : null;
  if (e != null) return 'mailto:$e';
  final p = normalizePhone(raw, callingCode: callingCode);
  return p == null ? null : 'tel:$p';
}

/// One person in the new-chat picker: an address-book entry and/or people
/// found on the networks, merged by phone number / email.
class Person {
  Person({required this.key, required this.name, Set<String>? identifiers, this.deviceId, List<Contact>? bridgeContacts})
    : identifiers = identifiers ?? <String>{},
      bridgeContacts = bridgeContacts ?? <Contact>[];

  /// Stable id: the first `tel:` / `mailto:` identifier, else
  /// `bridge:<bridge>:<id>`. Network choices are remembered under it.
  final String key;
  String name;

  /// `tel:+…` and `mailto:…` keys.
  final Set<String> identifiers;
  final String? deviceId;
  final List<Contact> bridgeContacts;

  Iterable<String> get phones => identifiers.where((i) => i.startsWith('tel:')).map((i) => i.substring(4));
  Iterable<String> get emails => identifiers.where((i) => i.startsWith('mailto:')).map((i) => i.substring(7));
  bool get fromDevice => deviceId != null;

  /// What to show under the name.
  String get subtitle => [...phones, ...emails].take(2).join(' · ');

  Contact? contactOn(String bridge) {
    for (final c in bridgeContacts) {
      if (c.bridge == bridge) return c;
    }
    return null;
  }

  bool matches(String q) {
    final t = q.trim().toLowerCase();
    if (t.isEmpty) return true;
    if (name.toLowerCase().contains(t)) return true;
    final digits = t.replaceAll(RegExp(r'[^0-9]'), '');
    for (final i in identifiers) {
      if (i.contains(t)) return true;
      if (digits.length >= 3 && i.startsWith('tel:') && i.replaceAll(RegExp(r'[^0-9]'), '').contains(digits)) return true;
    }
    return false;
  }
}

/// Address-book entries plus contacts from the networks, one [Person] per
/// human: a network contact joins the address-book entry that shares a
/// phone number or email. Sorted by name; address-book entries without a
/// number or email are dropped.
List<Person> mergePeople(List<DeviceContact> device, List<Contact> network, {String callingCode = '1'}) {
  final people = <Person>[];
  final byIdentifier = <String, Person>{};
  for (final d in device) {
    final ids = <String>{
      for (final p in d.phones) ?identifierKey(p, callingCode: callingCode),
      for (final e in d.emails) ?identifierKey(e, callingCode: callingCode),
    };
    if (ids.isEmpty) continue;
    // The same number in two address-book cards: keep them together.
    final existing = ids.map((i) => byIdentifier[i]).whereType<Person>().firstOrNull;
    if (existing != null) {
      existing.identifiers.addAll(ids);
      for (final i in ids) {
        byIdentifier[i] = existing;
      }
      continue;
    }
    final name = d.name.trim().isEmpty ? ids.first.replaceFirst(RegExp('^(tel|mailto):'), '') : d.name.trim();
    final p = Person(key: ids.first, name: name, identifiers: ids, deviceId: d.id);
    people.add(p);
    for (final i in ids) {
      byIdentifier[i] = p;
    }
  }
  for (final c in network) {
    final ids = <String>{
      for (final i in [...c.identifiers, c.id]) ?identifierKey(i, callingCode: callingCode),
    };
    final existing = ids.map((i) => byIdentifier[i]).whereType<Person>().firstOrNull;
    if (existing != null) {
      existing.bridgeContacts.add(c);
      existing.identifiers.addAll(ids);
      if (existing.name.isEmpty && (c.name ?? '').isNotEmpty) existing.name = c.name!;
      continue;
    }
    final p = Person(
      key: ids.isNotEmpty ? ids.first : 'bridge:${c.bridge}:${c.id}',
      name: (c.name ?? '').isNotEmpty ? c.name! : (ids.isNotEmpty ? ids.first.replaceFirst(RegExp('^(tel|mailto):'), '') : c.id),
      identifiers: ids,
      bridgeContacts: [c],
    );
    people.add(p);
    for (final i in ids) {
      byIdentifier[i] = p;
    }
  }
  people.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return people;
}

/// The networks [p] could be reached on, best first: iMessage and Google
/// Messages for numbers (iMessage also for emails) when [usable] (running
/// with a login), plus every network the person was found on.
List<String> candidateNetworks(Person p, Set<String> usable) {
  final out = <String>[];
  void add(String b) {
    if (usable.contains(b) && !out.contains(b)) out.add(b);
  }

  if (p.identifiers.isNotEmpty) add('imessage');
  if (p.phones.isNotEmpty) add('gmessages');
  for (final c in p.bridgeContacts) {
    if (!out.contains(c.bridge)) out.add(c.bridge);
  }
  return out;
}

/// The user's per-person network choices, kept in Matrix account data
/// ([eventType]) so they follow the account to every device.
class ContactNetworkPrefs {
  ContactNetworkPrefs({Map<String, String>? byContact, Map<String, String>? rooms}) : byContact = byContact ?? {}, rooms = rooms ?? {};

  factory ContactNetworkPrefs.fromJson(Map<String, dynamic>? j) => ContactNetworkPrefs(
    byContact: ((j?['by_contact'] as Map?) ?? const {}).map((k, v) => MapEntry('$k', '$v')),
    rooms: ((j?['rooms'] as Map?) ?? const {}).map((k, v) => MapEntry('$k', '$v')),
  );

  static const eventType = 'app.crosschat.contact_networks';

  /// Person key → bridge id the user picked.
  final Map<String, String> byContact;

  /// DM room id → person key, for the network switcher by the composer.
  final Map<String, String> rooms;

  Map<String, dynamic> toJson() => {'version': 1, 'by_contact': byContact, 'rooms': rooms};
}
