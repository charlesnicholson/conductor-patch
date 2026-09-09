import AppKit
import Darwin
import Foundation

// MARK: - Options

struct Options {
    var patches = Patches.Options()
    var launch = true
    var keepBundle = false
    var forceCLI = false
    var forceGUI = false
    var doctor = false
    var dump: URL?

    static let usage = """
        conductor-qol - launch Conductor with quality-of-life patches applied.

        Clones /Applications/Conductor.app, rewrites the cloned copy's embedded frontend,
        re-signs it ad-hoc, launches it, and deletes the clone when it exits. The installed
        copy is never modified, so Conductor's own auto-update keeps working: when the
        running clone updates itself, the new release is moved into /Applications and a
        patched clone of it is relaunched in place of the unpatched one.

        usage: conductor-qol [options]

          --doctor               report which anchors still match, patch nothing, exit
          --dump DIR             with --doctor: write the decoded stylesheet and scripts to DIR
          --source PATH          the Conductor.app to clone or inspect (default: /Applications)
          --no-launch            patch only; leave the clone in place and print its path
          --keep                 do not delete the clone on exit
          --no-widen-transcript  leave the chat column capped at max-w-4xl
          --no-widen-bubbles     leave your own message bubbles capped at lg:max-w-3xl
          --no-band-repos        do not alternate background tints per repository group
          --no-repo-names        leave sidebar groups showing the bare repository name
          --cli / --gui          force terminal or menu-bar mode (default: by isatty;
                                 --doctor and --no-launch are always terminal)
          -v, --verbose          more detail
          -h, --help             this text

        Every run is also logged to ~/Library/Logs/conductor-qol.log.
        """

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        func value(for flag: String) throws -> String {
            index += 1
            guard index < arguments.count else {
                throw PatchError("\(flag) needs a value\n\n\(usage)")
            }
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--doctor": options.doctor = true
            case "--dump": options.dump = URL(fileURLWithPath: try value(for: argument))
            case "--source": Paths.source = URL(fileURLWithPath: try value(for: argument))
            case "--no-launch": options.launch = false
            case "--keep": options.keepBundle = true
            case "--no-widen-transcript": options.patches.widenTranscript = false
            case "--no-widen-bubbles": options.patches.widenBubbles = false
            case "--no-band-repos": options.patches.bandRepoGroups = false
            case "--no-repo-names": options.patches.qualifyRepoNames = false
            case "--cli": options.forceCLI = true
            case "--gui": options.forceGUI = true
            case "-v", "--verbose": Log.verbose = true
            case "-h", "--help":
                print(usage)
                exit(0)
            default:
                throw PatchError("unknown option \(argument)\n\n\(usage)")
            }
            index += 1
        }
        if !options.launch { options.keepBundle = true }
        if options.dump != nil, !options.doctor {
            throw PatchError("--dump only applies with --doctor")
        }
        return options
    }
}

// MARK: - Runner

final class Runner {
    private let options: Options
    private let lock = NSLock()
    private var toreDown = false
    /// Only ever terminate a Conductor this process started. Teardown used to kill
    /// anything running out of the work bundle unconditionally, which meant a --no-launch
    /// run -- which starts nothing -- would still shoot down a session already in flight.
    private var didLaunch = false
    /// Every PID seen running out of the clone this session. After Conductor's updater has
    /// renamed the clone away, the instance it is replacing no longer shows up under the
    /// path check, and this is how Quit still reaches it.
    private var sessionProcesses = Set<pid_t>()

    init(_ options: Options) { self.options = options }

    /// Patch, launch, wait. Returns once nothing is running out of the clone -- surviving
    /// any number of self-updates along the way, each of which ends with a patched clone
    /// of the new release running.
    func run() throws {
        guard FileManager.default.fileExists(atPath: Paths.source.path) else {
            throw PatchError("\(Paths.source.path) not found")
        }
        guard !Launcher.conductorIsRunning() else {
            throw PatchError(
                "Conductor is already running. Quit it first -- two instances share one "
                    + "conductor.db and the app has no single-instance guard.")
        }

        Log.step("Preparing clone")
        // A previous session can leave a newer Conductor at the work path -- the updater
        // installed it there and teardown never ran, or could not move it. Adopt it now,
        // while nothing runs, rather than delete it with the reclone below.
        Launcher.adoptUpdateIfPresent()
        try Pipeline.removeWorkBundle()
        try Pipeline.cloneBundle()
        var version = try Pipeline.bundleVersion(of: Paths.work)
        Log.info("Conductor \(version)")

        Log.step("Patching")
        report(try Pipeline.patch(options: options.patches))
        Profile.shared.report()

        guard options.launch else {
            Log.step("Done (not launching)")
            print(Paths.work.path)
            return
        }

        try launch(version)
        while true {
            Log.step("Running Conductor \(version)")
            let end = Launcher.waitForSessionEnd(launchedVersion: version) { [weak self] pids in
                self?.noteProcesses(pids)
            }
            switch end {
            case .quit:
                return
            case .updated(let newVersion):
                guard try continueAfterUpdate(from: version, to: newVersion) else { return }
                version = newVersion
            }
        }
    }

    private func launch(_ version: String) throws {
        Log.step("Launching Conductor \(version)")
        Launcher.registerWithLaunchServices()
        try Launcher.launch()
        lock.lock()
        didLaunch = true
        lock.unlock()
    }

    private func noteProcesses(_ pids: Set<pid_t>) {
        lock.lock()
        sessionProcesses.formUnion(pids)
        lock.unlock()
    }

    private func currentSessionProcesses() -> Set<pid_t> {
        lock.lock()
        defer { lock.unlock() }
        return sessionProcesses
    }

    /// Conductor's updater has replaced the clone with a newer release and will relaunch
    /// from it: unpatched, and from a path that used to be deleted on exit. Steer that
    /// into the release living in /Applications and a patched clone of it running.
    ///
    /// The relaunched instance is terminated within a couple of seconds of appearing.
    /// It has nothing of the user's yet -- the update flow just quit the old one -- and
    /// letting it run would mean an unpatched session with the update lost on exit, which
    /// is exactly the failure this replaces.
    ///
    /// Returns false when the session is over: the user quit rather than restarting.
    private func continueAfterUpdate(from old: String, to new: String) throws -> Bool {
        Log.step("Conductor updated itself: \(old) -> \(new)")
        let relaunched = Launcher.awaitUpdaterRelaunch(sessionProcesses: currentSessionProcesses())
        if relaunched {
            Log.info("replacing the unpatched \(new) the updater started")
            Launcher.terminateAll()
        }

        let adopted = Launcher.adoptUpdateIfPresent()
        guard relaunched else {
            Log.info("Conductor was quit rather than relaunched; ending the session")
            return false
        }

        if adopted {
            try Pipeline.removeWorkBundle()
            try Pipeline.cloneBundle()
        } else {
            // The clone is the only copy of the new release; patch it where it is. The
            // next teardown or launch retries the adopt.
            Log.warn("patching \(new) in place; \(Paths.source.path) still holds \(old)")
        }

        Log.step("Patching")
        do {
            report(try Pipeline.patch(options: options.patches))
        } catch {
            Log.warn("could not patch Conductor \(new): \(error)")
            Log.warn("launching it unpatched instead")
            if adopted {
                try Pipeline.removeWorkBundle()
                try Pipeline.cloneBundle()
            }
        }
        try launch(new)
        return true
    }

    /// Patches are independent, so say plainly which landed. A `missing` line is the
    /// signal to re-anchor; `--doctor` narrows it down.
    private func report(_ outcomes: [PatchOutcome]) {
        for outcome in outcomes {
            switch outcome.status {
            case .applied: Log.info("applied   \(outcome.name)")
            case .disabled: Log.info("disabled  \(outcome.name) (\(outcome.detail))")
            case .missing: Log.warn("MISSING   \(outcome.name): \(outcome.detail)")
            }
        }
        let missing = outcomes.filter { $0.status == .missing }
        if !missing.isEmpty {
            Log.warn(
                "\(missing.count) patch(es) no longer match this build of Conductor. "
                    + "Launching anyway; run --doctor for detail.")
        }
    }

    /// Idempotent teardown: safe to call from a signal source, the Quit item, or the
    /// normal end of `run()`.
    func tearDown() {
        lock.lock()
        if toreDown {
            lock.unlock()
            return
        }
        toreDown = true
        let launched = didLaunch
        let session = sessionProcesses
        lock.unlock()

        if launched {
            Launcher.terminateAll(also: session)
            Launcher.unregisterFromLaunchServices()
        }

        // Order matters: adopt first, because adopting consumes the bundle and there is
        // then nothing left to delete.
        if Launcher.adoptUpdateIfPresent() { return }
        if Launcher.workBundleIsUnadoptedRelease() {
            Log.warn("keeping \(Paths.work.path): it holds a release that could not be adopted")
            return
        }

        guard !options.keepBundle else {
            Log.info("keeping \(Paths.work.path)")
            return
        }
        do {
            try Pipeline.removeWorkBundle()
        } catch {
            Log.warn("could not remove work bundle: \(error)")
        }
    }
}

// MARK: - Signals

/// Signal *sources* rather than handlers: the default disposition is ignored first, then
/// the source fires on a background queue, so teardown can take its time even while the
/// main thread is blocked mid-patch.
func installSignalHandlers(_ onSignal: @escaping () -> Void) -> [DispatchSourceSignal] {
    let queue = DispatchQueue(label: "conductor-qol.signals")
    return [SIGINT, SIGTERM, SIGHUP].map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
        source.setEventHandler { onSignal() }
        source.resume()
        return source
    }
}

// MARK: - Entry point

let options: Options
do {
    options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(2)
}

if options.doctor {
    do {
        try Pipeline.doctor(dump: options.dump)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
}

let runner = Runner(options)

// Menu-bar mode exists to give a long-lived launch a Quit affordance and somewhere to put
// log lines. A --no-launch run needs neither: it starts nothing and returns as soon as it
// has printed the clone's path. Leaving it on the isatty default meant invoking the tool
// from any non-terminal parent -- a script, an agent's shell -- put a modal dialog on
// screen instead of text on the pipe the caller was reading. An explicit --gui still wins.
// (--doctor never reaches here; it runs and exits above.)
let wantsMenuBar = options.launch && isatty(FileHandle.standardError.fileDescriptor) != 1
let interactive = options.forceCLI || !(options.forceGUI || wantsMenuBar)

if interactive {
    let sources = installSignalHandlers {
        runner.tearDown()
        exit(130)
    }
    defer { sources.forEach { $0.cancel() } }

    do {
        try runner.run()
        runner.tearDown()
    } catch {
        runner.tearDown()
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
} else {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)

    let status = StatusItemController {
        DispatchQueue.global(qos: .userInitiated).async {
            runner.tearDown()
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
    }
    Log.observer = { [weak status] message in status?.update(message) }

    let sources = installSignalHandlers {
        runner.tearDown()
        exit(130)
    }
    _ = sources

    DispatchQueue.global(qos: .userInitiated).async {
        do {
            try runner.run()
            runner.tearDown()
        } catch {
            let text = "\(error)"
            Log.warn(text)
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "Conductor QoL Patch failed"
                alert.informativeText = text + "\n\nDetails: " + Log.logFile.path
                alert.runModal()
            }
            runner.tearDown()
        }
        DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
    }

    application.run()
}
