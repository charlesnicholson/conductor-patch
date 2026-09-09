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

    static let usage = """
        conductor-qol - launch Conductor with quality-of-life patches applied.

        Clones /Applications/Conductor.app, rewrites two things in the cloned copy's
        embedded frontend, re-signs it ad-hoc, launches it, and deletes the clone when it
        exits. The installed copy is never modified, so Conductor's own auto-update keeps
        working; if the clone updates itself mid-session the update is moved into
        /Applications instead of being thrown away.

        usage: conductor-qol [options]

          --doctor               report which anchors still match, patch nothing, exit
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
        """

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        for argument in arguments {
            switch argument {
            case "--doctor": options.doctor = true
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
        }
        if !options.launch { options.keepBundle = true }
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

    init(_ options: Options) { self.options = options }

    /// Patch, launch, wait. Returns once nothing is running out of the clone.
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
        try Pipeline.removeWorkBundle()
        try Pipeline.cloneBundle()
        let version = try Pipeline.bundleVersion(of: Paths.work)
        Log.info("Conductor \(version)")

        Log.step("Patching")
        let outcomes = try Pipeline.patch(options: options.patches)
        report(outcomes)
        Profile.shared.report()

        guard options.launch else {
            Log.step("Done (not launching)")
            print(Paths.work.path)
            return
        }

        Log.step("Launching Conductor")
        Launcher.registerWithLaunchServices()
        try Launcher.launch()
        lock.lock()
        didLaunch = true
        lock.unlock()

        Log.step("Running")
        Launcher.waitForExit()
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
        lock.unlock()

        if launched {
            Launcher.terminateAll()
            Launcher.unregisterFromLaunchServices()
        }

        // Order matters: adopt first, because adopting consumes the bundle and there is
        // then nothing left to delete.
        if Launcher.adoptUpdateIfPresent() { return }

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
        try Pipeline.doctor()
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
                alert.informativeText = text
                alert.runModal()
            }
            runner.tearDown()
        }
        DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
    }

    application.run()
}
