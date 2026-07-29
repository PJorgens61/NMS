import Foundation

/// Reads this Mac's CPU load, so a check round can record how busy the
/// machine was when it ran.
///
/// Exists because ping failures turned out not to always mean network
/// failures: twice in one day every ICMP probe timed out during a clean
/// Xcode build while DNS and HTTP kept working — the forked `ping`
/// processes were starved past their 1-2s timeouts, and the app wrote a
/// complete fictional outage. See
/// `ConnectivityViewModel.isLikelyLocalPingFailure`.
///
/// **`getloadavg(3)`, not a subprocess.** That's the whole point: it's a
/// libc call needing no fork, no permission, and no measurable time.
/// Shelling out to `top` or `ps` to diagnose *subprocess starvation*
/// would be self-defeating — the diagnostic would be the first thing to
/// stall under the condition it exists to detect.
struct SystemLoadService {
    /// One-minute load average divided by core count, so the number
    /// means the same thing on every machine: 1.0 is "as many runnable
    /// processes as cores", i.e. saturated. Raw load average can't be
    /// compared across Macs — 8 is idle-ish on a 16-core and severe on a
    /// dual-core.
    ///
    /// `nil` if the call fails, which shouldn't happen but shouldn't be
    /// silently reported as 0 (idle) if it does — that's the one value
    /// that would wrongly imply the machine was quiet.
    static func normalizedLoad() -> Double? {
        var samples = [Double](repeating: 0, count: 3)
        guard getloadavg(&samples, 3) > 0 else { return nil }
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        return samples[0] / Double(cores)
    }

    /// Above this, the machine has more runnable work than cores and
    /// short-timeout subprocesses are genuinely at risk of being starved.
    ///
    /// Deliberately used only as *corroboration*, never as a trigger on
    /// its own — a busy Mac is not evidence the network is fine, and
    /// suppressing real outages because someone happened to be compiling
    /// would be a far worse failure than the one this is fixing.
    static let saturatedThreshold: Double = 1.0

    /// A one-minute rolling average, so a genuinely isolated one-second
    /// spike may barely register. That's an accepted limit: the observed
    /// incidents happened during multi-minute builds, where load stays
    /// high throughout. True instantaneous CPU would need
    /// `host_processor_info` deltas — more machinery for a sharper signal
    /// than this needs.
    static let isLaggingIndicator = true
}
