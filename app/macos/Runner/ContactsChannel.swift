import Contacts
import FlutterMacOS

/// `app.crosschat/contacts`: the Mac's address book for the new-chat
/// picker. `status` / `request` (shows the system prompt once) / `list`.
/// Everything stays on this Mac; the app only uses the numbers and emails
/// to find people on your networks.
enum ContactsChannel {
  static let store = CNContactStore()

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "app.crosschat/contacts", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "status":
        result(status())
      case "request":
        if CNContactStore.authorizationStatus(for: .contacts) != .notDetermined {
          result(status())
          return
        }
        store.requestAccess(for: .contacts) { _, _ in
          DispatchQueue.main.async { result(status()) }
        }
      case "list":
        if status() != "granted" {
          result([])
          return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          let out = list()
          DispatchQueue.main.async { result(out) }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  static func status() -> String {
    switch CNContactStore.authorizationStatus(for: .contacts) {
    case .notDetermined: return "not_determined"
    case .denied: return "denied"
    case .restricted: return "restricted"
    default: return "granted"  // authorized (or limited)
    }
  }

  static func list() -> [[String: Any]] {
    var keys: [CNKeyDescriptor] = [
      CNContactIdentifierKey as CNKeyDescriptor,
      CNContactOrganizationNameKey as CNKeyDescriptor,
      CNContactPhoneNumbersKey as CNKeyDescriptor,
      CNContactEmailAddressesKey as CNKeyDescriptor,
    ]
    keys.append(CNContactFormatter.descriptorForRequiredKeys(for: .fullName))
    let request = CNContactFetchRequest(keysToFetch: keys)
    var out: [[String: Any]] = []
    do {
      try store.enumerateContacts(with: request) { c, _ in
        let phones = c.phoneNumbers.map { $0.value.stringValue }
        let emails = c.emailAddresses.map { $0.value as String }
        if phones.isEmpty && emails.isEmpty { return }
        var name = CNContactFormatter.string(from: c, style: .fullName) ?? ""
        if name.isEmpty { name = c.organizationName }
        out.append(["id": c.identifier, "name": name, "phones": phones, "emails": emails])
      }
    } catch {
      NSLog("crosschat: reading contacts failed: \(error)")
    }
    return out
  }
}
