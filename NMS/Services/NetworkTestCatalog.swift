import Foundation

/// Metadata for every test the popover's Run Test ▾ menu (Expert Mode)
/// and Quick Check bundle (Simple Mode) can trigger — labels, Quick
/// Check membership, confirmation gating, and each test's runtime
/// parameters, externalized here per explicit request ("parameterize all
/// the tests for experimentation") so tuning a value (a byte size, a
/// timeout, a duration) is a JSON edit, not a rebuild.
///
/// This is metadata only — it cannot drive the actual trigger logic.
/// Each `id` still dispatches to real Swift code (`wifiStressTest.run(...)`,
/// `networkQualityService.measureDownload()`, etc.); the catalog only
/// supplies what to call it with. Read fresh from disk on every access,
/// same "edit and reload, no rebuild" pattern
/// `LocalDiagnosticServer.readAsset` already established for its own
/// assets — a `var`, not a cached `let`.
enum NetworkTestCatalog {
    struct Test: Decodable, Identifiable {
        let id: String
        let label: String
        let includeInQuickCheck: Bool
        let requiresConfirmation: Bool
        let confirmationText: String?
        let parameters: [String: JSONValue]
        let quickCheckParameters: [String: JSONValue]?

        /// Merges `quickCheckParameters` over `parameters` rather than
        /// replacing them outright — a Quick Check variant only overrides
        /// the keys it actually needs to soften (e.g. `speedTest`'s
        /// `bytes`), any key it doesn't mention still resolves to the
        /// full-test value.
        var resolvedQuickCheckParameters: [String: JSONValue] {
            guard let overrides = quickCheckParameters else { return parameters }
            return parameters.merging(overrides) { _, override in override }
        }
    }

    private struct Root: Decodable {
        let tests: [Test]
    }

    /// A minimal `Decodable` box for arbitrary JSON scalars/containers —
    /// `parameters`/`quickCheckParameters` are deliberately untyped at
    /// this layer (each test defines its own parameter shape; there's no
    /// single schema across all 9), so callers pull out what they expect
    /// by key (`parameters["fullBytes"]?.intValue`) rather than this type
    /// trying to model every test's parameter shape generically.
    enum JSONValue: Decodable {
        case string(String)
        case number(Double)
        case bool(Bool)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else {
                self = .string(try container.decode(String.self))
            }
        }

        var intValue: Int? {
            if case let .number(value) = self { return Int(value) }
            return nil
        }
        var doubleValue: Double? {
            if case let .number(value) = self { return value }
            return nil
        }
        var stringValue: String? {
            if case let .string(value) = self { return value }
            return nil
        }
    }

    private static let assetPath = "NMS/Services/NetworkTestCatalogAssets/test-catalog.json"

    /// Same `#filePath`-relative project-root resolution as
    /// `LocalDiagnosticServer.projectRoot()` — this file lives one
    /// directory shallower (`NMS/Services/`, not `NMS/Services/
    /// DiagnosticServer/` or similar), so the walk-up count matches this
    /// file's own location, not copied blindly from that one.
    private static func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // NMS/Services
            .deletingLastPathComponent() // NMS
            .deletingLastPathComponent() // project root
    }

    static var tests: [Test] {
        let url = projectRoot().appendingPathComponent(assetPath)
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONDecoder().decode(Root.self, from: data) else {
            print("NetworkTestCatalog: couldn't read test-catalog.json, no tests available")
            return []
        }
        return root.tests
    }

    static func test(id: String) -> Test? {
        tests.first { $0.id == id }
    }

    /// Every test flagged `includeInQuickCheck`, in catalog order —
    /// Simple Mode's "Run Quick Check" bundle iterates this directly, so
    /// reordering/adding/removing a test from the bundle is a JSON edit.
    static var quickCheckTests: [Test] {
        tests.filter(\.includeInQuickCheck)
    }
}
