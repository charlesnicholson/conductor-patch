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

        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: Int(byteCount) / MemoryLayout<pid_t>.size + 16)
        let written = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listpids(
                UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress,
                Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard written > 0 else { return [] }

        var found: [pid_t] = []
        // PROC_PIDPATHINFO_MAXSIZE is (4*MAXPATHLEN); the macro does not import.
        var path = [CChar](repeating: 0, count: 4 * 1024)
        for pid in pids.prefix(Int(written) / MemoryLayout<pid_t>.size) where pid > 0 {
            let length = proc_pidpath(pid, &path, UInt32(path.count))
            guard length > 0 else { continue }
            if String(cString: path).hasPrefix(prefix) { found.append(pid) }
        }
        return found
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

    /// Blocks until nothing is running out of the work bundle.
    ///
    /// The grace period covers the gap between LaunchServices returning and the process
    /// actually appearing, and it is re-armed across an updater relaunch by simply
    /// continuing to poll rather than latching on first exit.
    static func waitForExit(pollInterval: TimeInterval = 1.0, startupGrace: TimeInterval = 20.0) {
        let deadline = Date().addingTimeInterval(startupGrace)
        var everSeen = false

        while true {
            let running = processes(under: Paths.work)
            if !running.isEmpty {
                everSeen = true
            } else if everSeen || Date() > deadline {
                return
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    /// SIGTERM everything under the work bundle, escalating if it does not go quietly.
    static func terminateAll(timeout: TimeInterval = 10.0) {
        let running = processes(under: Paths.work)
        guard !running.isEmpty else { return }

        Log.info("asking Conductor to quit (\(running.count) process(es))")
        for pid in running { kill(pid, SIGTERM) }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if processes(under: Paths.work).isEmpty { return }
            Thread.sleep(forTimeInterval: 0.25)
        }

        let survivors = processes(under: Paths.work)
        if !survivors.isEmpty {
            Log.warn("force-killing \(survivors.count) process(es)")
            for pid in survivors { kill(pid, SIGKILL) }
        }
    }

    // MARK: - Adopt-back

    /// If Conductor updated itself inside the ephemeral clone, move that update into
    /// /Applications instead of throwing it away.
    ///
    /// The updater rewrites the bundle at the running app's own path, which here is the
    /// throwaway copy -- so without this, updates would be downloaded, installed and then
    /// deleted on every launch, and /Applications would never move.
    ///
    /// Only adopts a bundle that is genuinely a fresh download: strictly newer version,
    /// and a real Developer ID team identifier. Our own patched clone is ad-hoc and has
    /// no team, so it can never be mistaken for an update.
    @discardableResult
    static func adoptUpdateIfPresent() -> Bool {
        guard FileManager.default.fileExists(atPath: Paths.work.path) else { return false }

        guard let workVersion = try? Pipeline.bundleVersion(of: Paths.work),
            let sourceVersion = try? Pipeline.bundleVersion(of: Paths.source)
        else { return false }

        guard workVersion.compare(sourceVersion, options: .numeric) == .orderedDescending else {
            return false
        }

        guard let workTeam = teamIdentifier(of: Paths.work),
            let sourceTeam = teamIdentifier(of: Paths.source),
            workTeam == sourceTeam
        else {
            Log.warn(
                "work bundle is \(workVersion) (newer than \(sourceVersion)) but is not signed "
                    + "by the original team; not adopting it")
            return false
        }

        do {
            try run("/usr/bin/codesign", ["--verify", "--strict", Paths.work.path])
            _ = try FileManager.default.replaceItemAt(Paths.source, withItemAt: Paths.work)
            Log.step("adopted Conductor \(workVersion) into \(Paths.source.path)")
            return true
        } catch {
            Log.warn("could not adopt update \(workVersion): \(error)")
            return false
        }
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
