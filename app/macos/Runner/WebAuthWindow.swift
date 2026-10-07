import Cocoa
import FlutterMacOS
import WebKit

/// The embedded sign-in window for bridge `cookies` login steps
/// (lib/src/webauth/web_auth.dart drives it over `app.crosschat/webauth`).
///
/// Each sign-in gets a fresh, non-persistent WKWebsiteDataStore, like a
/// private Safari window: nothing is shared with Safari or earlier sign-ins
/// and everything is discarded when the window closes. The user agent is
/// Safari's, so Google treats the window like Safari rather than an
/// "insecure" embedded browser.
final class WebAuthWindow: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, NSWindowDelegate {
  private static var shared: WebAuthWindow?

  private let channel: FlutterMethodChannel
  private var window: NSWindow?
  private var webView: WKWebView?
  private var store: WKWebsiteDataStore?
  private var allowedDomains: [String] = []
  private var urlObservation: NSKeyValueObservation?
  private var closingProgrammatically = false

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "app.crosschat/webauth", binaryMessenger: messenger)
    let instance = WebAuthWindow(channel: channel)
    channel.setMethodCallHandler { call, result in instance.handle(call, result: result) }
    shared = instance
  }

  private init(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  /// Oldest Safari version reported. Sign-in pages turn away browsers they
  /// consider outdated (slack.com/signin rejects anything below Safari 26 as
  /// "not supported"), even though the system WebKit handles them fine.
  static let minimumSafariMajor = 26

  /// "Version/26.0 Safari/605.1.15": the installed Safari's version (raised
  /// to [minimumSafariMajor]). Appended to WebKit's default UA this reads
  /// exactly like Safari's own UA string.
  static var safariApplicationName: String {
    var version = "\(minimumSafariMajor).0"
    for path in ["/Applications/Safari.app", "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"] {
      if let v = Bundle(path: path)?.infoDictionary?["CFBundleShortVersionString"] as? String,
         let major = Int(v.split(separator: ".").first ?? ""), major >= minimumSafariMajor {
        version = v
        break
      }
    }
    return "Version/\(version) Safari/605.1.15"
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "isAvailable":
      result(true)
    case "open":
      open(args)
      result(nil)
    case "getCookies":
      guard let store = store else { return result([]) }
      let wanted = (args["domains"] as? [String] ?? []).map { Self.stripDot($0.lowercased()) }
      store.httpCookieStore.getAllCookies { cookies in
        // Includes HttpOnly cookies, which page JavaScript can't see.
        let out: [[String: Any]] = cookies.compactMap { c in
          let d = Self.stripDot(c.domain.lowercased())
          let related = wanted.isEmpty || wanted.contains { w in d == w || d.hasSuffix("." + w) || w.hasSuffix("." + d) }
          guard related else { return nil }
          return ["name": c.name, "value": c.value, "domain": c.domain, "path": c.path, "secure": c.isSecure, "http_only": c.isHTTPOnly]
        }
        result(out)
      }
    case "evaluate":
      guard let webView = webView, let script = args["script"] as? String else { return result(nil) }
      webView.evaluateJavaScript(script) { value, _ in
        switch value {
        case let s as String: result(s)
        case let n as NSNumber: result(n)
        default: result(nil)
        }
      }
    case "snapshot":
      guard let webView = webView, let path = args["path"] as? String else { return result(false) }
      webView.takeSnapshot(with: nil) { image, _ in
        guard let image = image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return result(false) }
        result((try? png.write(to: URL(fileURLWithPath: path))) != nil)
      }
    case "windowFrame":
      guard let f = window?.frame else { return result(nil) }
      result([f.origin.x, f.origin.y, f.size.width, f.size.height, window?.isZoomed == true ? 1 : 0, window?.styleMask.contains(.fullScreen) == true ? 1 : 0])
    case "close":
      closeWindow()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func open(_ args: [String: Any]) {
    closeWindow()
    guard let urlString = args["url"] as? String, let url = URL(string: urlString) else {
      send(["type": "error", "message": "invalid sign-in URL"])
      return
    }
    allowedDomains = (args["allowedDomains"] as? [String] ?? []).map { Self.stripDot($0.lowercased()) }

    let store = WKWebsiteDataStore.nonPersistent()
    let config = WKWebViewConfiguration()
    config.websiteDataStore = store
    config.applicationNameForUserAgent = Self.safariApplicationName
    config.preferences.javaScriptCanOpenWindowsAutomatically = false
    let content = WKUserContentController()
    content.add(WeakScriptHandler(self), name: "crosschat")
    if let script = args["documentStartScript"] as? String, !script.isEmpty {
      content.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }
    config.userContentController = content

    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 720), configuration: config)
    if let ua = args["userAgent"] as? String, !ua.isEmpty {
      webView.customUserAgent = ua
    }
    webView.navigationDelegate = self
    webView.uiDelegate = self
    urlObservation = webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
      if let u = wv.url?.absoluteString { self?.send(["type": "url", "url": u]) }
    }

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 720),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered, defer: false)
    window.title = args["title"] as? String ?? "Sign in"
    window.isReleasedWhenClosed = false
    // A separate window, never a tab of the main window (the "prefer tabs"
    // system setting would otherwise merge it).
    window.tabbingMode = .disallowed
    window.contentView = webView
    window.delegate = self
    window.minSize = NSSize(width: 360, height: 480)
    if let main = NSApp.mainWindow ?? NSApp.windows.first(where: { $0 is MainFlutterWindow }) {
      let f = main.frame
      window.setFrameOrigin(NSPoint(x: f.midX - 240, y: max(f.midY - 360, 0)))
    } else {
      window.center()
    }

    self.store = store
    self.webView = webView
    self.window = window
    closingProgrammatically = false

    let group = DispatchGroup()
    for c in args["initialCookies"] as? [[String: Any]] ?? [] {
      var props: [HTTPCookiePropertyKey: Any] = [
        .name: c["name"] as? String ?? "",
        .value: c["value"] as? String ?? "",
        .domain: c["domain"] as? String ?? (url.host ?? ""),
        .path: c["path"] as? String ?? "/",
      ]
      if c["secure"] as? Bool == true { props[.secure] = "TRUE" }
      if c["http_only"] as? Bool == true { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
      if let cookie = HTTPCookie(properties: props) {
        group.enter()
        store.httpCookieStore.setCookie(cookie) { group.leave() }
      }
    }
    group.notify(queue: .main) { [weak self, weak webView] in
      guard let self = self, let webView = webView, webView === self.webView else { return }
      webView.load(URLRequest(url: url))
    }
    if args["hidden"] as? Bool != true {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  private func closeWindow() {
    guard let window = window else { return }
    closingProgrammatically = true
    window.close()
    teardown()
  }

  private func teardown() {
    urlObservation?.invalidate()
    urlObservation = nil
    if let webView = webView {
      webView.stopLoading()
      webView.navigationDelegate = nil
      webView.uiDelegate = nil
      webView.configuration.userContentController.removeScriptMessageHandler(forName: "crosschat")
    }
    // Discard everything the sign-in left behind.
    store?.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    store = nil
    webView = nil
    window?.delegate = nil
    window = nil
  }

  private func send(_ event: [String: Any]) {
    DispatchQueue.main.async { self.channel.invokeMethod("event", arguments: event) }
  }

  private static func stripDot(_ s: String) -> String {
    var s = s
    while s.hasPrefix(".") { s.removeFirst() }
    return s
  }

  private func isAllowed(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    if allowedDomains.isEmpty { return true }
    return allowedDomains.contains { host == $0 || host.hasSuffix("." + $0) }
  }

  // MARK: NSWindowDelegate

  func windowWillClose(_ notification: Notification) {
    if !closingProgrammatically {
      send(["type": "closed"])
      teardown()
    }
  }

  // MARK: WKNavigationDelegate

  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { return decisionHandler(.cancel) }
    // No app hand-offs (slack://, intent://, ...).
    if !["http", "https", "about", "blob", "data"].contains(scheme) { return decisionHandler(.cancel) }
    // Keep the user on the sign-in site: link clicks elsewhere are ignored.
    // Redirects and form posts (SSO providers) are allowed.
    let mainFrame = action.targetFrame?.isMainFrame ?? true
    if mainFrame && action.navigationType == .linkActivated && (scheme == "http" || scheme == "https") && !isAllowed(url) {
      return decisionHandler(.cancel)
    }
    decisionHandler(.allow)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    send(["type": "loaded", "url": webView.url?.absoluteString ?? ""])
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    webView.reload()
  }

  // MARK: WKUIDelegate

  /// Pop-ups (target=_blank, window.open) load in the same window instead.
  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
               for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), isAllowed(url) {
      webView.load(action.request)
    }
    return nil
  }

  // MARK: WKScriptMessageHandler

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    if let body = message.body as? String {
      send(["type": "message", "data": body])
    }
  }
}

/// WKUserContentController retains its handlers; this breaks the cycle.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
  weak var target: WKScriptMessageHandler?
  init(_ target: WKScriptMessageHandler) { self.target = target }
  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    target?.userContentController(controller, didReceive: message)
  }
}
