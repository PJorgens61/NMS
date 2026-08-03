import Darwin

/// Samples this Mac's own system-wide CPU load — used by
/// `WiFiStressTestService` to help distinguish "the network is the
/// bottleneck" from "this Mac's own fork/exec rate is the bottleneck"
/// while firing many concurrent `ping` subprocesses.
///
/// Uses the same Mach `host_statistics`/`HOST_CPU_LOAD_INFO` query
/// Activity Monitor/`top` are built on — a standard host-level read, no
/// special entitlement needed.
nonisolated final class CPULoadSampler {
    private var previousTicks: host_cpu_load_info?

    /// System-wide CPU busy % (user + system + nice, out of user + system
    /// + nice + idle) since the *previous* call to this method — `nil` on
    /// the first call, since there's no prior snapshot yet to diff
    /// against. Call this repeatedly at a fixed interval; each call's
    /// result covers the time since the last one, the same delta-of-ticks
    /// technique `top` uses between its own refreshes.
    func sampleBusyPercent() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        defer { previousTicks = info }
        guard let previous = previousTicks else { return nil }

        let userDelta = Double(info.cpu_ticks.0 - previous.cpu_ticks.0)
        let systemDelta = Double(info.cpu_ticks.1 - previous.cpu_ticks.1)
        let idleDelta = Double(info.cpu_ticks.2 - previous.cpu_ticks.2)
        let niceDelta = Double(info.cpu_ticks.3 - previous.cpu_ticks.3)
        let totalDelta = userDelta + systemDelta + idleDelta + niceDelta
        guard totalDelta > 0 else { return nil }
        return (userDelta + systemDelta + niceDelta) / totalDelta * 100
    }
}
