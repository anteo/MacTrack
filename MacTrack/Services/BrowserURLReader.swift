import AppKit

/// Reads the active tab's URL + title from a supported browser via Apple Events.
/// This is what makes per-website tracking possible. `NSAppleScript` needs a
/// running main-loop to receive its Apple Event reply, so execution is scheduled
/// asynchronously on the main queue rather than blocking the sampler directly.
///
/// The first read of each browser triggers macOS's Automation permission prompt.
/// We surface that state so the UI can ask the user to grant access.
final class BrowserURLReader {

    struct Browser {
        let bundleID: String
        let tabAccessor: String  // "current tab" (Safari) or "active tab" (Chromium)
        /// Chromium browsers run page JavaScript via `execute … javascript`; Safari
        /// via `do JavaScript … in <tab>`.
        let chromium: Bool
    }

    /// Supported browsers, keyed by bundle identifier.
    static let browsers: [String: Browser] = [
        "com.apple.Safari":            Browser(bundleID: "com.apple.Safari", tabAccessor: "current tab", chromium: false),
        "com.apple.SafariTechnologyPreview": Browser(bundleID: "com.apple.SafariTechnologyPreview", tabAccessor: "current tab", chromium: false),
        "com.google.Chrome":           Browser(bundleID: "com.google.Chrome", tabAccessor: "active tab", chromium: true),
        "com.google.Chrome.canary":    Browser(bundleID: "com.google.Chrome.canary", tabAccessor: "active tab", chromium: true),
        "com.microsoft.edgemac":       Browser(bundleID: "com.microsoft.edgemac", tabAccessor: "active tab", chromium: true),
        "com.brave.Browser":           Browser(bundleID: "com.brave.Browser", tabAccessor: "active tab", chromium: true),
        // Arc exposes the same active-tab/URL AppleScript surface as Chromium.
        "company.thebrowser.Browser":  Browser(bundleID: "company.thebrowser.Browser", tabAccessor: "active tab", chromium: true),
        "com.vivaldi.Vivaldi":         Browser(bundleID: "com.vivaldi.Vivaldi", tabAccessor: "active tab", chromium: true),
    ]

    static func isBrowser(_ bundleID: String) -> Bool { browsers[bundleID] != nil }

    private var compiled: [String: NSAppleScript] = [:]

    /// True once a read has failed with a permissions error and hasn't since
    /// succeeded. Lets the UI nudge the user toward System Settings.
    private(set) var automationDenied = false

    struct TabInfo { let url: URL; let title: String? }

    enum FetchResult {
        case tab(TabInfo)   // a real http(s) page
        case noURL          // front tab has no trackable URL (new/empty tab, Start Page, no window)
        case failed         // couldn't reach the browser (permission denied / transient)
    }

    func fetch(bundleID: String, completion: @escaping (FetchResult) -> Void) {
        guard let browser = Self.browsers[bundleID] else { completion(.failed); return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let script = self.script(for: browser)
            var errorInfo: NSDictionary?
            let descriptor = script.executeAndReturnError(&errorInfo)

            if let errorInfo {
                let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
                // -1743 = not authorized to send Apple events; -600 = app not running.
                if code == -1743 { self.automationDenied = true }
                completion(.failed)
                return
            }
            self.automationDenied = false

            let raw = descriptor.stringValue ?? ""
            let parts = raw.components(separatedBy: "\u{1F}") // unit separator
            let urlString = parts.first ?? ""
            let title = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil

            // No http(s) URL means an empty/new tab or Start Page — credit no site.
            guard let url = URL(string: urlString),
                  let scheme = url.scheme, scheme.hasPrefix("http") else {
                completion(.noURL)
                return
            }
            completion(.tab(TabInfo(url: url, title: (title?.isEmpty == false) ? title : nil)))
        }
    }

    /// JavaScript that returns the logged-in X account's handle — the one signal that
    /// reflects the *active* account, since the URL is shared across accounts. Reads
    /// the left-nav Profile link first, then falls back to the account-switcher
    /// button's "@handle". Single-quoted, no double quotes, so it embeds cleanly in
    /// the AppleScript string.
    private static let xAccountJS =
        "(function(){var a=document.querySelector('a[data-testid=AppTabBar_Profile_Link]');if(a){var x=a.getAttribute('href');if(x)return x;}var b=document.querySelector('[data-testid=SideNav_AccountSwitcher_Button]');if(b){var m=(b.textContent||'').match(/@([A-Za-z0-9_]+)/);if(m)return m[1];}return '';})()"

    /// Reads the active X account handle from the front tab via a one-line JS, in a
    /// separate script so a JS failure can never break URL reading. Returns nil if
    /// the page has no account, the browser blocks JS-from-Apple-Events, or anything
    /// errors — the caller then just tracks the bare domain.
    func fetchAccount(bundleID: String, completion: @escaping (String?) -> Void) {
        guard let browser = Self.browsers[bundleID] else { completion(nil); return }
        DispatchQueue.main.async {
            let js = Self.xAccountJS
            let invoke = browser.chromium
                ? "execute (active tab of front window) javascript \"\(js)\""
                : "do JavaScript \"\(js)\" in current tab of front window"
            let source = """
            tell application id "\(browser.bundleID)"
                if (count of windows) is 0 then return ""
                try
                    return (\(invoke)) as text
                on error
                    return ""
                end try
            end tell
            """
            var err: NSDictionary?
            let desc = NSAppleScript(source: source)?.executeAndReturnError(&err)
            let raw = (err == nil ? desc?.stringValue : nil) ?? ""
            let handle = Self.parseHandle(raw)
            completion(handle)
        }
    }

    /// "/elonmusk" → "elonmusk", validated as a plausible handle.
    static func parseHandle(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("/") { s.removeFirst() }
        guard !s.isEmpty, s.count <= 20,
              s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return s
    }

    /// Drives X's account switcher via JavaScript to switch the active account to
    /// `handle` — so landing on a blocked account routes you to your allowed one
    /// instead of just bouncing. Best-effort: it opens the switcher and clicks the
    /// matching account (found by its avatar's handle-stamped testid); if the click
    /// misses, the switcher is left open for a manual pick. Needs "Allow JavaScript
    /// from Apple Events" (already required for account detection).
    func switchXAccount(bundleID: String, toHandle handle: String) {
        guard let browser = Self.browsers[bundleID],
              handle.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return }
        DispatchQueue.main.async {
            // No double quotes anywhere in the JS, so it embeds cleanly. Opens the
            // switcher, then after a beat clicks the row whose avatar testid carries
            // the target handle, climbing to the nearest clickable ancestor.
            let js = "(function(){var t='\(handle)';var b=document.querySelector('[data-testid=SideNav_AccountSwitcher_Button]');if(!b)return;b.click();setTimeout(function(){var a=document.querySelector('[data-testid=UserAvatar-Container-'+t+']');var e=a;for(var i=0;i<7&&e;i++){var r=e.getAttribute&&e.getAttribute('role');if(r==='menuitem'||r==='button'||e.tagName==='BUTTON'){break;}e=e.parentElement;}if(e){e.click();}else if(a){a.click();}},500);})()"
            let invoke = browser.chromium
                ? "execute (active tab of front window) javascript \"\(js)\""
                : "do JavaScript \"\(js)\" in current tab of front window"
            let source = """
            tell application id "\(browser.bundleID)"
                if (count of windows) is 0 then return
                try
                    \(invoke)
                end try
            end tell
            """
            NSAppleScript(source: source)?.executeAndReturnError(nil)
        }
    }

    /// Forces the active tab off a blocked site by loading about:blank.
    func blockActiveTab(bundleID: String) {
        guard let browser = Self.browsers[bundleID] else { return }
        DispatchQueue.main.async {
            let source = """
            tell application id "\(browser.bundleID)"
                if (count of windows) is 0 then return
                try
                    set URL of \(browser.tabAccessor) of front window to "about:blank"
                end try
            end tell
            """
            NSAppleScript(source: source)?.executeAndReturnError(nil)
        }
    }

    private func script(for browser: Browser) -> NSAppleScript {
        if let existing = compiled[browser.bundleID] { return existing }
        // Returns "url<US>title" or empty string if there's no front window.
        let source = """
        tell application id "\(browser.bundleID)"
            if (count of windows) is 0 then return ""
            -- Arc resolves its active tab lazily and returns an empty value if
            -- the tab is first assigned to an AppleScript variable. Read the
            -- properties directly from the window so Arc and Chromium browsers
            -- both return the visible page. Do not swallow an error here: an
            -- Automation denial must reach Swift so macOS can prompt the user.
            set theURL to (URL of \(browser.tabAccessor) of front window) as text
            try
                set theTitle to (title of \(browser.tabAccessor) of front window) as text
            on error
                set theTitle to ""
            end try
            -- `NSAppleScript` rejects a literal control character in source code.
            -- Build the unit-separator delimiter in AppleScript instead so the
            -- returned descriptor remains safely splittable in Swift.
            return theURL & (character id 31) & theTitle
        end tell
        """
        let script = NSAppleScript(source: source)!
        compiled[browser.bundleID] = script
        return script
    }
}

// MARK: - Domain reduction

enum DomainReducer {
    // A pragmatic slice of multi-label public suffixes. Not the full PSL, but it
    // keeps the common cases ("bbc.co.uk", not "co.uk") honest.
    private static let multiPartSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "co.jp", "ne.jp", "or.jp",
        "com.au", "net.au", "org.au", "co.nz", "com.br", "com.cn", "com.mx",
        "co.in", "co.kr", "com.tr", "com.sg", "com.hk", "co.za", "com.tw",
    ]

    /// "https://www.youtube.com/watch?v=x" -> "youtube.com"
    static func registrableDomain(from url: URL) -> String? {
        guard var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if host.isEmpty { return nil }

        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return host }

        let lastTwo = labels.suffix(2).joined(separator: ".")
        if multiPartSuffixes.contains(lastTwo) {
            return labels.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }

    /// Search-engine brands whose results pages are "pass-through", not a destination.
    private static let searchBrands: Set<String> = [
        "google", "bing", "duckduckgo", "yahoo", "ecosia", "startpage",
        "yandex", "baidu", "qwant", "kagi", "brave", "aol", "ask",
        "perplexity", "phind", "mojeek", "searx", "swisscows", "lite",
    ]

    /// True for a search-*results* page — a search engine with a query (Google's
    /// `/search?q=`, DuckDuckGo's `/?q=`, …). You pass through these on the way to a
    /// real site, so their time isn't credited to any site (it lands in the browser's
    /// uncredited total, out of the productivity split — like a new/empty tab). It
    /// deliberately does NOT match a search engine's other pages: Gmail
    /// (mail.google.com), Google Docs/Maps, etc. still count as normal sites.
    static func isSearchResults(_ url: URL) -> Bool {
        guard let domain = registrableDomain(from: url),
              let brand = domain.split(separator: ".").first.map(String.init),
              searchBrands.contains(brand) else { return false }
        let path = url.path.lowercased()
        if path.contains("search") || path.hasPrefix("/html") { return true }
        // Engines that carry the query on the root path (DuckDuckGo, Google "/").
        if path == "/" || path.isEmpty {
            let q = url.query?.lowercased() ?? ""
            return q.range(of: "(^|&)(q|p|query|text|wd)=", options: .regularExpression) != nil
        }
        return false
    }
}

// MARK: - Per-account site keys

/// Sites that can be split by account (today: X / Twitter) are stored under a
/// composite key, "x.com/@handle", so each account is its own trackable, taggable
/// entry. Everything else stays the bare domain. These helpers build and read that
/// key, and recover the base domain for favicons and the handle for display.
enum SiteKey {
    private static let mark = "/@"
    /// Domains for which we track per account, when a handle is detectable.
    static let perAccount: Set<String> = ["x.com", "twitter.com"]

    static func splits(_ domain: String) -> Bool { perAccount.contains(domain) }

    /// "x.com" + "elonmusk" → "x.com/@elonmusk".
    static func account(base: String, handle: String) -> String { base + mark + handle }

    static func isAccount(_ key: String) -> Bool { key.contains(mark) }

    /// The bare domain behind a key — for favicons and exclusion checks.
    static func base(_ key: String) -> String {
        guard let r = key.range(of: mark) else { return key }
        return String(key[..<r.lowerBound])
    }

    /// What the row/header shows: "@handle" for an account, else the domain.
    static func display(_ key: String) -> String {
        guard let r = key.range(of: mark) else { return key }
        return "@" + key[r.upperBound...]
    }

    /// The bare handle of an account key ("x.com/@elonmusk" → "elonmusk"), else nil.
    static func handle(_ key: String) -> String? {
        guard let r = key.range(of: mark) else { return nil }
        return String(key[r.upperBound...])
    }
}
