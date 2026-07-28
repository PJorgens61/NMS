import Foundation

/// One speed-test run's result. Unlike almost everything else this app
/// persists, a run is never deduplicated against the previous one (see
/// DESIGN-NOTES.md's "Why this doesn't fit the existing change-log
/// pattern") — every run is an intentional, standalone data point the
/// user wants to compare against past ones, not a change to detect.
struct NetworkQualityResult: Equatable, Codable {
    let downloadMbps: Double
    let uploadMbps: Double
    let testedAt: Date
}
