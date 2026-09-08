import AppKit
import Foundation

/// Menu-bar presence for the agent (LSUIElement) mode.
///
/// The patch takes ~15 s before Conductor's window appears, and this process then stays
/// alive for the whole session to own teardown. Both facts need to be visible somewhere,
/// and a status item is the least intrusive place: progress while patching, then a quiet
/// indicator with a Quit that shuts Conductor down cleanly and removes the clone.
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let onQuit: () -> Void

    init(onQuit: @escaping () -> Void) {
        self.onQuit = onQuit
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "slider.horizontal.below.rectangle",
                accessibilityDescription: "Conductor QoL Patched")
            button.toolTip = "Conductor QoL Patched"
        }

        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit Conductor", action: #selector(quit), keyEquivalent: "q"))
        menu.items.last?.target = self
        statusItem.menu = menu
    }

    func update(_ message: String) {
        DispatchQueue.main.async { [statusLine] in
            statusLine.title = message
        }
    }

    @objc private func quit() {
        update("Quitting…")
        onQuit()
    }
}
