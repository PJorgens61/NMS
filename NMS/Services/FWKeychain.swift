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
/// Synced via iCloud Keychain (`kSecAttrSynchronizable`) since
/// 2026-08-05 — raised and spiked directly ("i need to manually copy the
/// token onto every mac that runs nms?"), originally blocked on this:
/// `SecItemAdd` failed with `errSecMissingEntitlement`/-34018 under this
/// project's then-ad-hoc, no-team signing, since a synchronizable item's
/// access group needs a real Team Identifier to scope. Unblocked the
/// same day once a real code-signing Team + Keychain Sharing entitlement
/// (`NMS.entitlements`, `keychain-access-groups`) landed — see
/// `PUNCHLIST.md`.
///
/// Migration note: an item stored **before** this change was a plain
/// (non-synchronizable) Keychain entry, which a `kSecAttrSynchronizable:
/// true` query does not match — `token()` will read as empty on a Mac
/// with a pre-existing local-only entry until `setToken` writes a fresh
/// synchronizable one (re-pasting the token in Preferences once is
/// enough; the old local-only entry is simply orphaned, not deleted).
///
/// A DEBUG-only file-based bypass unrelated to sync lived here briefly
/// the same day, to dodge ad-hoc signing's separate Keychain re-prompt-
/// on-every-rebuild problem — removed once the code-signing Team fix
/// made it unnecessary. Keychain unconditionally again, DEBUG and
/// Release behaving the same.
///
/// Registration isn't built (see FW's own memory/README — single-user
/// scope for now): the token is generated server-side from `FW_TOKENS`
/// and pasted into Preferences by hand, `FWKeychain.setToken` is what
/// that field writes to.
enum FWKeychain {
    private static let service = "Thistle.NMS.fw-device-token"
    private static let account = "device-token"

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: true
        ]
    }

    static func token() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Add-or-update: `SecItemAdd` fails with `errSecDuplicateItem` if a
    /// token from a previous run is already there, so this always tries
    /// update first and only falls back to add for the genuinely-first-
    /// time case.
    @discardableResult
    static func setToken(_ token: String) -> Bool {
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
    }

    /// `errSecItemNotFound` counts as success here — "no token stored" is
    /// the end state either way, not a failure the caller needs to
    /// distinguish from "deleted one that was there."
    @discardableResult
    static func deleteToken() -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
