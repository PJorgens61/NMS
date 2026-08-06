import Foundation
import Security

/// Stores FW's device bearer token (see `FWClient`) in this Mac's login
/// keychain — the first real Keychain usage in this codebase. Existing
/// on-Mac secrets (SNMP community strings, `SNMPViewModel.communities`)
/// are deliberately kept in plain `UserDefaults` instead, documented
/// there as "not Keychain-grade" — those are LAN read-community strings
/// with essentially no blast radius. FW's token is a different kind of
/// thing: a bearer credential presented to an internet-hosted server, so
/// it gets the real thing rather than following that same precedent.
///
/// Local-only, deliberately, not synced via iCloud Keychain — raised and
/// spiked directly ("i need to manually copy the token onto every mac
/// that runs nms?"), but `kSecAttrSynchronizable` needs a real code-
/// signing Team Identifier (confirmed live: `SecItemAdd` fails with
/// `errSecMissingEntitlement`/-34018 under this project's current
/// ad-hoc, no-team signing, per DEV-SETUP.md's "no paid account needed to
/// run locally" goal) — a real posture change to every machine's build,
/// not just this file. Staying local-only for now; see the cross-machine
/// sync issue if that trade-off ever gets revisited.
///
/// Registration isn't built (see FW's own memory/README — single-user
/// scope for now): the token is generated server-side from `FW_TOKENS`
/// and pasted into Preferences by hand, `FWKeychain.setToken` is what
/// that field writes to.
enum FWKeychain {
    private static let service = "Thistle.NMS.fw-device-token"
    private static let account = "device-token"

    #if DEBUG
    /// Temporary DEBUG-only bypass around the real Keychain path below —
    /// raised directly during a live test session, right after a full
    /// build+test run required entering the login password around 20
    /// times. Root cause: ad-hoc code signing (no Team Identifier — see
    /// `PUNCHLIST.md`'s deferred "give NMS a real code-signing identity"
    /// entry) has no stable identity across rebuilds, so macOS's
    /// "Always Allow" Keychain grant never sticks — every rebuild looks
    /// like a brand-new untrusted app asking for the same secret again,
    /// and `NMSUITests` multiplies this badly since it relaunches the
    /// real signed app several times in one run.
    ///
    /// Until the real fix (a free Personal Team, already scoped and
    /// approved in `PUNCHLIST.md`) lands, DEBUG builds skip Keychain for
    /// this token entirely and read/write a plain local file instead —
    /// same trust boundary either way (this Mac's own login session; the
    /// file isn't in the repo, isn't synced, isn't Release-reachable),
    /// just without the repeated prompt. Release builds are untouched —
    /// this whole block compiles out.
    private static let debugFileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NMS", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("fw-device-token.debug-only.txt")
    }()
    #endif

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func token() -> String? {
        #if DEBUG
        return try? String(contentsOf: debugFileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        #else
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #endif
    }

    /// Add-or-update: `SecItemAdd` fails with `errSecDuplicateItem` if a
    /// token from a previous run is already there, so this always tries
    /// update first and only falls back to add for the genuinely-first-
    /// time case.
    @discardableResult
    static func setToken(_ token: String) -> Bool {
        #if DEBUG
        return (try? token.write(to: debugFileURL, atomically: true, encoding: .utf8)) != nil
        #else
        let data = Data(token.utf8)
        let query = baseQuery()
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        guard updateStatus == errSecItemNotFound else { return false }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        #endif
    }

    /// `errSecItemNotFound` counts as success here — "no token stored" is
    /// the end state either way, not a failure the caller needs to
    /// distinguish from "deleted one that was there."
    @discardableResult
    static func deleteToken() -> Bool {
        #if DEBUG
        try? FileManager.default.removeItem(at: debugFileURL)
        return true
        #else
        let status = SecItemDelete(baseQuery() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
        #endif
    }
}

#if DEBUG
private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
#endif
