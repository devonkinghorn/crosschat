import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A person from the device's address book.
class DeviceContact {
  const DeviceContact({required this.id, required this.name, this.phones = const [], this.emails = const []});

  factory DeviceContact.fromMap(Map<Object?, Object?> m) => DeviceContact(
    id: '${m['id']}',
    name: (m['name'] as String?) ?? '',
    phones: ((m['phones'] as List?) ?? const []).cast<String>(),
    emails: ((m['emails'] as List?) ?? const []).cast<String>(),
  );

  final String id;
  final String name;
  final List<String> phones;
  final List<String> emails;
}

enum ContactsAccess {
  /// Not asked yet: asking shows the system prompt.
  notDetermined,
  granted,

  /// Denied (or restricted): only the system settings can change it.
  denied,

  /// No address book on this platform (Linux, web).
  unsupported,
}

/// The device's address book (macOS Contacts, Android ContactsContract).
/// The app works without it; the new-chat picker then only shows people
/// found on the networks.
abstract class DeviceContactsSource {
  Future<ContactsAccess> status();

  /// Ask for access (system prompt the first time).
  Future<ContactsAccess> request();

  Future<List<DeviceContact>> list();
}

class MethodChannelContacts implements DeviceContactsSource {
  static const channel = MethodChannel('app.crosschat/contacts');

  bool get _platformHasContacts =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  static ContactsAccess _parse(Object? s) => switch (s) {
    'granted' => ContactsAccess.granted,
    'not_determined' => ContactsAccess.notDetermined,
    'denied' || 'restricted' => ContactsAccess.denied,
    _ => ContactsAccess.unsupported,
  };

  Future<ContactsAccess> _call(String method) async {
    if (!_platformHasContacts) return ContactsAccess.unsupported;
    try {
      return _parse(await channel.invokeMethod<String>(method));
    } on MissingPluginException {
      return ContactsAccess.unsupported;
    } on PlatformException {
      return ContactsAccess.unsupported;
    }
  }

  @override
  Future<ContactsAccess> status() => _call('status');

  @override
  Future<ContactsAccess> request() => _call('request');

  @override
  Future<List<DeviceContact>> list() async {
    if (!_platformHasContacts) return const [];
    try {
      final v = await channel.invokeMethod<List<Object?>>('list') ?? const [];
      return [for (final m in v) DeviceContact.fromMap(m! as Map<Object?, Object?>)];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }
}

/// Replaced in tests.
DeviceContactsSource deviceContacts = MethodChannelContacts();
