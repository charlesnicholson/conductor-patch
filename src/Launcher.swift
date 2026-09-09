import AppKit
import Darwin
import Foundation

enum Launcher {
    private static let lsregister =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework"
        + "/Support/lsregister"

    // MARK: - Process inspection

    /// PIDs currently executing out of `bundle`.
    ///
    /// "The process we launched exited" is not the same as "the bundle is idle":
    /// Conductor's updater relaunches the app, and that replacement is not our child. This
    /// is the question that actually gates deletion.
    static func processes(under bundle: URL) -> [pid_t] {
        let prefix = bundle.standardizedFileURL.path + "/"
        var found: [pid_t] = []
        for pid in allProcesses() {
            if let path = executablePath(of: pid), path.hasPrefix(prefix) { found.append(pid) }
        }
        return found
    }

    private static func allProcesses() -> [pid_t] {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: Int(byteCount) / MemoryLayout<pid_t>.size + 16)
        let written = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listpids(
                UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress,
                Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard written > 0 else { return [] }
        return pids.prefix(Int(written) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    private static func executablePath(of pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is (4*MAXPATHLEN); the macro does not import.
        var path = [CChar](repeating: 0, count: 4 * 1024)
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        guard length > 0 else { return nil }
        return String(cString: path)
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Whether `pid` is still a Conductor -- for a process whose executable has been
    /// renamed or deleted underneath it, which is what the updater does to the instance
    /// it is replacing. Guards against a recycled PID before anything is signalled.
    ///
    /// The updater renames the old bundle to `current_app` inside a temporary directory
    /// before deleting it, so `proc_pidpath` reports `.../current_app/Contents/MacOS/
    /// conductor` for a while and then nothing at all; only the executable's own name is
    /// stable across both, and `proc_name` still knows it after the file is gone.
    static func isConductor(_ pid: pid_t) -> Bool {
        guard isAlive(pid) else { return false }
        if let path = executablePath(of: pid), path.hasSuffix("/Contents/MacOS/conductor") {
            return true
        }
        var name = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return false }
        return String(cString: name) == "conductor"
    }

    /// True when anything at all is executing out of the source install. Two Conductors
    /// against one 1.6 GB conductor.db is the failure this exists to prevent -- there is
    /// no single-instance guard in the app.
    static func conductorIsRunning() -> Bool {
        !processes(under: Paths.source).isEmpty || !processes(under: Paths.work).isEmpty
    }

    // MARK: - LaunchServices

    /// Registers the patched clone so `conductor://` resolves to it for the session.
    ///
    /// Both bundles declare `com.conductor.app` and the same URL scheme. The links that
    /// cross the OS boundary are the browser auth callbacks -- `conductor://gh-auth`,
    /// `github-connected`, the cloud onboarding ones -- and those should reach the app the
    /// user is actually looking at. Unregistered again on the way out.
    static func registerWithLaunchServices() {
        guard FileManager.default.isExecutableFile(atPath: lsregister) else { return }
        _ = try? run(lsregister, ["-f", Paths.work.path])
    }

    static func unregisterFromLaunchServices() {
        guard FileManager.default.isExecutableFile(atPath: lsregister) else { return }
        _ = try? run(lsregister, ["-u", Paths.work.path])
    }

    // MARK: - Launch and wait

    /// Launches through LaunchServices rather than spawning a child.
    ///
    /// posix_spawn would make this tool the "responsible process" for TCC, so Conductor's
    /// microphone and Documents prompts would be attributed to "Conductor QoL Patched".
    /// Going through LaunchServices leaves Conductor responsible for itself.
    static func launch() throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true

        let semaphore = DispatchSemaphore(value: 0)
        var failure: Error?

        NSWorkspace.shared.openApplication(at: Paths.work, configuration: configuration) {
            _, error in
            failure = error
            semaphore.signal()
        }
        semaphore.wait()

        if let failure { throw PatchError("failed to launch: \(failure.localizedDescription)") }
    }

    enum SessionEnd {
        /// Nothing runs out of the clone any more and the clone is intact.
        case quit
        /// The clone now holds a different release: Conductor's updater has installed it
        /// there and is about to relaunch from it.
        case updated(String)
    }

    /// Blocks until the session ends, one way or the other.
    ///
    /// The updater swaps the clone in two renames -- the old bundle out to a temporary
    /// directory, the new one in -- and only then restarts. From the moment of the first
    /// rename the running instance's executable path is no longer under the clone, so
    /// "nothing runs from the clone" is true for the rest of that instance's life.
    /// Treating that as "quit" tore the session down in the middle of an update, which
    /// is how a freshly installed release got deleted. Now an empty process list only
    /// counts once the clone is confirmed intact, and a version other than the one
    /// launched is reported as an update, since a release always carries a new version
    /// and our patching never changes it.
    ///
    /// `onProcesses` is told every PID seen running from the clone, so the caller can
    /// still find them after the updater has moved the bundle out from under them.
    static func waitForSessionEnd(
        launchedVersion: String,
        pollInterval: TimeInterval = 1.0,
        startupGrace: TimeInterval = 20.0,
        onProcesses: (Set<pid_t>) -> Void
    ) -> SessionEnd {
        let deadline = Date().addingTimeInterval(startupGrace)
        var everSeen = false
        var unreadableSince: Date?

        while true {
            let version = try? Pipeline.bundleVersion(of: Paths.work)
            if let version, version != launchedVersion { return .updated(version) }

            let running = processes(under: Paths.work)
            if !running.isEmpty {
                everSeen = true
                onProcesses(Set(running))
            } else if version != nil {
                if everSeen || Date() > deadline { return .quit }
            } else {
                // Nothing running and no readable bundle: mid-swap, or genuinely gone.
                // The swap takes milliseconds; a minute of this means gone.
                let since = unreadableSince ?? Date()
                unreadableSince = since
                if Date().timeIntervalSince(since) > 60 {
                    Log.warn("work bundle at \(Paths.work.path) is unreadable; ending session")
                    return .quit
                }
            }
            if version != nil { unreadableSince = nil }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    /// After the updater has installed a release into the clone: waits for the instance it
    /// is replacing to exit, then reports whether a new instance appeared in the clone.
    ///
    /// Tauri's restart is "spawn the executable at the path we started from, then exit",
    /// so a relaunch shows up within a moment of the old instance going. Nothing appearing
    /// means the user quit instead -- Conductor offers both -- and the session is over.
    /// The wait for the old instance is open-ended, because Conductor may sit on an
    /// installed update until the user chooses to restart.
    static func awaitUpdaterRelaunch(
        sessionProcesses: Set<pid_t>, relaunchWindow: TimeInterval = 10.0
    ) -> Bool {
        let inClone = Set(processes(under: Paths.work))
        let old = sessionProcesses.subtracting(inClone).filter(isConductor)
        if !old.isEmpty {
            Log.info("waiting for the previous Conductor (\(old.count) process(es)) to exit")
            while old.contains(where: isConductor) { Thread.sleep(forTimeInterval: 0.5) }
        }

        let deadline = Date().addingTimeInterval(relaunchWindow)
        while Date() < deadline {
            if !processes(under: Paths.work).isEmpty { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    /// SIGTERM everything running from the work bundle, plus any of `also` that is still a
    /// Conductor, escalating if it does not go quietly. `also` is for the instance an
    /// update has moved out from under the path check; it is filtered by name so a
    /// recycled PID is never signalled.
    static func terminateAll(also: Set<pid_t> = [], timeout: TimeInterval = 10.0) {
        func targets() -> Set<pid_t> {
            Set(processes(under: Paths.work)).union(also.filter(isConductor))
        }

        let running = targets()
        guard !running.isEmpty else { return }

        Log.info("asking Conductor to quit (\(running.count) process(es))")
        for pid in running { kill(pid, SIGTERM) }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if targets().isEmpty { return }
            Thread.sleep(forTimeInterval: 0.25)
        }

        let survivors = targets()
        if !survivors.isEmpty {
            Log.warn("force-killing \(survivors.count) process(es)")
            for pid in survivors { kill(pid, SIGKILL) }
        }
    }

    // MARK: - Adopt-back

    /// The work bundle's version alongside the source's, when the work bundle is strictly
    /// newer -- the precondition for it being an update rather than our own clone.
    private static func newerRelease() -> (work: String, source: String)? {
        guard FileManager.default.fileExists(atPath: Paths.work.path),
            let work = try? Pipeline.bundleVersion(of: Paths.work),
            let source = try? Pipeline.bundleVersion(of: Paths.source),
            work.compare(source, options: .numeric) == .orderedDescending
        else { return nil }
        return (work, source)
    }

    /// A newer bundle at the work path signed by the same Developer ID team as the
    /// install: a genuine release, not our ad-hoc clone. Nothing else may be adopted.
    private static func isGenuineRelease(_ versions: (work: String, source: String)) -> Bool {
        guard let workTeam = teamIdentifier(of: Paths.work),
            let sourceTeam = teamIdentifier(of: Paths.source),
            workTeam == sourceTeam
        else {
            Log.warn(
                "work bundle is \(versions.work) (newer than \(versions.source)) but is not signed "
                    + "by the original team; not adopting it")
            return false
        }
        return true
    }

    /// If Conductor updated itself inside the ephemeral clone, move that update into
    /// /Applications instead of throwing it away.
    ///
    /// The updater rewrites the bundle at the running app's own path, which here is the
    /// throwaway copy -- so without this, updates would be downloaded, installed and then
    /// deleted on every launch, and /Applications would never move.
    ///
    /// Must not be called while anything runs from the work bundle: the move takes the
    /// executable and sidecars away from under it.
    @discardableResult
    static func adoptUpdateIfPresent() -> Bool {
        guard let versions = newerRelease() else { return false }
        Log.step("Adopting Conductor \(versions.work)")
        guard isGenuineRelease(versions) else { return false }

        do {
            try run("/usr/bin/codesign", ["--verify", "--strict", Paths.work.path])
            _ = try FileManager.default.replaceItemAt(Paths.source, withItemAt: Paths.work)
            Log.info(
                "adopted Conductor \(versions.work) into \(Paths.source.path) "
                    + "(replacing \(versions.source))")
            return true
        } catch {
            Log.warn("could not adopt update \(versions.work): \(error)")
            return false
        }
    }

    /// True when the work bundle is a genuine newer release that has not been adopted.
    /// Such a bundle is kept across teardown so the next launch can try again, rather
    /// than deleted along with the clone it replaced.
    static func workBundleIsUnadoptedRelease() -> Bool {
        guard let versions = newerRelease() else { return false }
        return isGenuineRelease(versions)
    }

    /// Team identifier from the code signature, or nil for ad-hoc / unsigned.
    private static func teamIdentifier(of bundle: URL) -> String? {
        guard let output = try? run("/usr/bin/codesign", ["-dvv", bundle.path]) else { return nil }
        for line in output.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            let value = String(line.dropFirst("TeamIdentifier=".count))
            return value == "not set" ? nil : value
        }
        return nil
    }
}
