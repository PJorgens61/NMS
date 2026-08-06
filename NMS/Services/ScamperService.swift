import Foundation

#if DEBUG
/// Second-opinion alias resolution for Path Discovery, via CAIDA's
/// `scamper` (`dealias -m ally`) — raised directly ("can we make use of
/// the scamper software?"), as a rigorous, protocol-level check on what
/// `GlobalpingReverseTraceService.deviceStem` can only guess from hostname
/// strings: Ally sends alternating probes to two addresses and checks
/// whether their IP-ID sequence numbers interleave, which is real
/// evidence two addresses are the same box, not a naming-convention
/// inference. See `TracerouteViewModel.reverseTraceCorroborates`'s own
/// doc comment for the real case (`bng3.snfcca05.sonic.net` answering
/// under three different addresses, 2026-08-06) this exists to double-check.
///
/// **Never bundled, never linked** — scamper is GPL-2.0-only (confirmed
/// via `brew info scamper`), and the explicit constraint from direct
/// discussion was no NMS license change. Invoked as a separate subprocess
/// only, the same "mere aggregation" shape this app already uses for
/// `/usr/sbin/traceroute` — see this file's own `confirmAlias` for the
/// `Process` invocation, copied from `TracerouteService.trace`'s exact
/// shape. The project reasoned through this same cost before, for
/// `rrdtool` (`DESIGN-NOTES.md`, "RRDtool for historical storage"):
/// adopting a third-party CLI dependency means asking users to install
/// something new, and shelling out via `Process` — never linking — was
/// the only integration shape considered there too.
///
/// Debug-only, same tier as `HoihoService`/`GlobalpingReverseTraceService`
/// — this exists purely to double-check Path Discovery's own comparison
/// table, not for anything the always-on monitoring path depends on.
enum ScamperService {
    enum ScamperError: Error {
        case processFailed(String)
    }

    /// Not installed by Homebrew at a single fixed path the way
    /// `/usr/bin/snmpget` is — Apple Silicon and Intel Homebrew installs
    /// differ (`/opt/homebrew` vs. `/usr/local`), so both are checked
    /// rather than picking one.
    private static let candidatePaths = ["/opt/homebrew/bin/scamper", "/usr/local/bin/scamper"]

    /// Which of three real states scamper is in on this Mac — richer than
    /// `SNMPService.isAvailable`'s plain `Bool` because there's a genuine
    /// middle state here with no equivalent for a system-provided tool:
    /// installed, but unusable until a one-time privileged step.
    enum ScamperAvailability: Equatable {
        case notInstalled
        case notPrivileged(path: String)
        case ready(path: String)
    }

    /// Confirmed live (2026-08-06): `/usr/sbin/traceroute` ships
    /// setuid-root (`-r-sr-xr-x root wheel`), so this app already gets
    /// raw-socket access for free everywhere else. Homebrew's scamper is
    /// a plain, user-owned, non-setuid binary — running it unprivileged
    /// fails immediately with `dl_bpf_open_dev: could not open
    /// /dev/bpf4: Permission denied`.
    ///
    /// **Two conditions, not one** — confirmed the hard way: setting only
    /// the setuid bit (`chmod u+s`) on a binary still owned by the
    /// installing user does *not* grant root, since setuid runs the
    /// process as the *file's owner*, whichever user that is. Scamper's
    /// own man page says exactly this ("set the setuid bit on the
    /// scamper binary, and set the ownership of the scamper binary to
    /// root") but it's easy to read past the second half — an earlier
    /// version of this code and of `DebugToolsView`'s copyable command
    /// only checked/fixed the bit, and still reported `.ready` (wrongly)
    /// once the bit alone was set. Both are checked here now: the setuid
    /// bit itself, and that the owning UID is actually `0` (root).
    ///
    /// Checked via the file's own permission bits and owner
    /// (`FileManager.attributesOfItem`), not by a trial invocation —
    /// cheap, and doesn't risk misfiring a real probe just to check
    /// availability.
    ///
    /// Deliberately does *not* attempt to fix this itself (e.g. running
    /// `chown`/`chmod` via an elevated helper) — both are system-security
    /// changes, squarely something the user should do themselves. See
    /// `DebugToolsView`'s "Copy Setup Command" for the one-time fix this
    /// surfaces instead: `sudo chown root:wheel <path> && sudo chmod u+s <path>`.
    static func checkAvailability() -> ScamperAvailability {
        availability(forCandidatePaths: candidatePaths)
    }

    /// Split out from `checkAvailability()` so `NMSTests` can exercise
    /// every branch (not installed / installed-not-ready / ready)
    /// against real temp files with controlled permissions/ownership,
    /// rather than depending on whatever happens to be installed on the
    /// machine running the tests — same "testable without depending on
    /// live environment state" reasoning as every other pure helper in
    /// this app. Not `private` for that reason.
    static func availability(forCandidatePaths paths: [String]) -> ScamperAvailability {
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return .notInstalled
        }
        // Homebrew installs `scamper` as a symlink (`/usr/local/bin/scamper
        // -> ../Cellar/scamper/<version>/bin/scamper`) -- `chown`/`chmod`
        // follow it by default and modify the real Cellar binary, but
        // `FileManager.attributesOfItem` does *not* follow it, and
        // reports the symlink's own attributes (still owned by whichever
        // user installed it, never setuid) instead. Confirmed the hard
        // way: the real binary was genuinely root-owned and setuid, and
        // this still reported `.notPrivileged` until resolving the
        // symlink first. `path` itself (the Homebrew-visible location)
        // is still what's shown/copied in `DebugToolsView` and passed to
        // `confirmAlias` -- only the attributes lookup needs the real path.
        let resolvedPath = (path as NSString).resolvingSymlinksInPath
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedPath),
              let permissions = attributes[.posixPermissions] as? Int,
              permissions & 0o4000 != 0, // S_ISUID
              let ownerID = attributes[.ownerAccountID] as? Int,
              ownerID == 0 // root -- setuid alone runs the process as
              // whichever user *owns* the file, so the bit by itself
              // (still owned by the installing user) grants nothing.
        else {
            return .notPrivileged(path: path)
        }
        return .ready(path: path)
    }

    /// Whether `addressA`/`addressB` are the same physical device,
    /// per scamper's Ally alias-resolution technique. `nil` means
    /// genuinely inconclusive — a timeout, an unparsable/unexpected
    /// response, or (right now) an unverified field in the JSON schema
    /// below — never asserted as a confident yes/no from a guess. Same
    /// "can't tell, don't guess" posture as `TracerouteHop.isLocal`/
    /// `TracerouteViewModel.leadingNonInternetHopCount` elsewhere in this
    /// app.
    ///
    /// Schema confirmed live (2026-08-06) against real output, once the
    /// one-time root setup was actually complete — `scamper -O json`
    /// emits newline-delimited JSON, one object per line
    /// (`cycle-start`/`dealias`/`cycle-stop`), not one parseable
    /// document; `parseVerdict` finds the `dealias` line itself.
    static func confirmAlias(_ addressA: String, _ addressB: String, scamperPath: String) throws -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: scamperPath)
        // Matches scamper's own documented EXAMPLES form (`man scamper`,
        // DEALIAS section) — `-I "dealias ..."` with the two addresses
        // positional after the probe definition, rather than the
        // `-c`/top-level `-i` form, which is for iterating one command
        // over a whole address list rather than one self-contained
        // two-address comparison.
        process.arguments = [
            "-O", "json",
            "-I", "dealias -O inseq -m ally -p '-P icmp-echo' \(addressA) \(addressB)"
        ]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        let trace = SubprocessTracer.begin(process.executableURL!.path, process.arguments ?? [])
        do {
            try process.run()
        } catch {
            SubprocessTracer.end(trace, exitCode: nil, byteCount: 0)
            throw ScamperError.processFailed(error.localizedDescription)
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        SubprocessTracer.end(trace, exitCode: process.terminationStatus, byteCount: data.count)

        guard process.terminationStatus == 0 else { return nil }
        return Self.parseVerdict(data)
    }

    /// Real shape, captured live (2026-08-06):
    /// ```
    /// {"type":"dealias","version":"0.2","method":"ally","userid":0,
    ///  "result":"not-aliases", ...,
    ///  "probedefs":[{"id":0,"dst":"75.101.33.52",...},{"id":1,"dst":"157.131.209.36",...}],
    ///  "probes":[{"probedef_id":0,"seq":0,...,
    ///             "replies":[{"src":"75.101.33.52","ipid":0,...}]}, ...]}
    /// ```
    private struct DealiasResponse: Decodable {
        struct Reply: Decodable { var ipid: Int? }
        struct Probe: Decodable {
            var probedef_id: Int
            var replies: [Reply]
        }
        var type: String?
        var result: String?
        var probes: [Probe]?
    }

    /// Not `private` — `NMSTests` reaches this directly via `@testable
    /// import`, same reasoning as `GlobalpingReverseTraceService
    /// .parseMeasurementID`: a pure parser, tested against captured
    /// response shapes rather than a live subprocess.
    ///
    /// `scamper -O json` writes newline-delimited JSON — `cycle-start`,
    /// then the `dealias` result, then `cycle-stop`, three separate
    /// top-level objects, not one document — so this scans line by line
    /// for the one with `"type":"dealias"` rather than decoding the
    /// whole blob directly.
    static func parseVerdict(_ data: Data) -> Bool? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let response = text.split(separator: "\n").lazy
            .compactMap({ line -> DealiasResponse? in
                try? JSONDecoder().decode(DealiasResponse.self, from: Data(line.utf8))
            })
            .first(where: { $0.type == "dealias" })
        else { return nil }

        // Ally only works when *both* addresses expose a real, varying
        // IP-ID counter -- confirmed directly, live: Sonic's own bng3
        // edge router (the confirmed ISP edge this whole feature exists
        // to double-check) replies with a fixed `ipid: 0` on every
        // single probe, every run, vs. real variation from an ordinary
        // host (1.1.1.1: 54396 → 36198; 1.0.0.1: 41108 → 47773) tested
        // the same way. `ipid: 0` specifically is common, deliberate
        // hardening on modern carrier-grade routers (RFC 6864 permits a
        // zero IP-ID on atomic/non-fragmentable datagrams) -- and
        // against a degenerate counter like that, Ally structurally
        // cannot ever report "aliases", for *any* pair, including a
        // genuinely-aliased one. Confirmed live: the real alias pair
        // (75.101.33.52/157.131.209.36) and a real *non*-alias pair
        // (75.101.33.52 vs. an unrelated downstream device) both came
        // back "not-aliases" identically -- trusting `result` blindly
        // here would silently mislabel a real alias as "scamper
        // disagrees" for every Sonic customer this ever runs against,
        // not just this one case. So: fewer than two distinct reply
        // IP-IDs observed for *either* address means no real signal was
        // ever available, regardless of what `result` says.
        if let probes = response.probes {
            let repliesByProbedef = Dictionary(grouping: probes, by: \.probedef_id)
            for (_, group) in repliesByProbedef {
                let observedIPIDs = Set(group.flatMap(\.replies).compactMap(\.ipid))
                guard observedIPIDs.count > 1 else { return nil }
            }
        }

        switch response.result {
        case "aliases", "aliases-nobs": return true
        case "not-aliases": return false
        default: return nil
        }
    }
}
#endif
