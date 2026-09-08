import Foundation

/// The edits themselves, applied to the decompressed `renderApp-<hash>.js`.
///
/// Everything lives in that one chunk, and the two Tailwind utilities the width patches
/// substitute in (`.w-full{width:100%}`, `.max-w-full{max-width:100%}`) are already
/// emitted in Conductor's stylesheet, so the CSS asset is left untouched.
enum Patches {
    /// Stamped into the injected code so an already-patched bundle is recognisable.
    static let marker = "/*cqol*/"

    struct Options {
        var widenTranscript = true
        var widenBubbles = true
        var qualifyRepoNames = true
    }

    static func apply(to script: inout Data, options: Options) throws {
        guard script.occurrences(of: Data(marker.utf8)).isEmpty else {
            throw PatchError(
                "the bundle already contains \(marker) -- refusing to patch a patched image")
        }
        if options.widenTranscript { try widenTranscript(&script) }
        if options.widenBubbles { try widenBubbles(&script) }
        if options.qualifyRepoNames { try qualifyRepoNames(&script) }
    }

    // MARK: - Chat column width

    /// Un-caps the chat session's centred column so it fills the middle panel.
    ///
    /// `max-w-4xl` is 56rem, which is what leaves the wide black margins on a large
    /// display. It appears 26 times across the bundle; only these nine are the session
    /// view and its composer. The rest -- onboarding, the workspace list, the routines
    /// page, the PR/checks tabs, the attachment dialog -- are deliberately left alone, so
    /// each edit names its full class string rather than the bare token.
    private static let transcriptEdits: [(from: String, to: String, count: Int)] = [
        // Turn body and session header.
        ("\"max-w-4xl mx-auto px-7\"", "\"w-full mx-auto px-7\"", 2),
        // Per-turn wrapper (the div carrying data-turn-index).
        ("\"pb-3 max-w-4xl mx-auto\"", "\"pb-3 w-full mx-auto\"", 1),
        // Empty-session states.
        ("\"min-w-0 max-w-4xl mx-auto px-7\"", "\"min-w-0 w-full mx-auto px-7\"", 1),
        (
            "\"text-muted-foreground text-sm max-w-4xl mx-auto px-7\"",
            "\"text-muted-foreground text-sm w-full mx-auto px-7\"", 1
        ),
        // Loading skeleton. Already has w-full, so the cap just goes away.
        (
            "\"mx-auto flex w-full max-w-4xl flex-1 flex-col gap-4 px-7 pb-7\"",
            "\"mx-auto flex w-full flex-1 flex-col gap-4 px-7 pb-7\"", 1
        ),
        // Scroll-to-bottom bar.
        ("\"pb-2 px-4 max-w-4xl mx-auto\"", "\"pb-2 px-4 w-full mx-auto\"", 1),
        // The composer, local and cloud workspaces.
        (
            "\"max-w-4xl mx-auto relative pointer-events-auto\"",
            "\"w-full mx-auto relative pointer-events-auto\"", 2
        ),
    ]

    private static func widenTranscript(_ script: inout Data) throws {
        for edit in transcriptEdits {
            try script.replaceAll(
                edit.from, with: edit.to, expected: edit.count, context: "transcript width")
        }
        Log.info("chat column: un-capped \(transcriptEdits.reduce(0) { $0 + $1.count }) containers")
    }

    /// Removes the 48rem cap on your own message bubbles and the system-summary blocks.
    ///
    /// Without this the outer column goes full width but the bubbles inside it stop at
    /// `lg:max-w-3xl`, which just moves the empty space rather than removing it.
    /// `max-w-full` un-caps without forcing width, so short messages still size to content.
    private static func widenBubbles(_ script: inout Data) throws {
        try script.replaceAll(
            "max-w-xl lg:max-w-3xl", with: "max-w-full", expected: 3, context: "bubble width")
        Log.info("message bubbles: un-capped 3 containers")
    }

    // MARK: - Fully-qualified repository names

    /// Rewrites the sidebar's repository group header from `docs` to
    /// `envy-package-manager/docs`.
    ///
    /// The header component destructures its props and immediately takes the bare name:
    ///
    ///     {repository:n,workspaceIds:i,pendingWorkspaceIds:r,onHideRepo:o,
    ///      dragHandleProps:l,isDragging:c}=t, ... ,b=n.name;
    ///
    /// `b` is what the header span renders (and what the "Remove <b>?" confirmation says,
    /// which reads better qualified too). Repository objects carry `remoteUrl` alongside
    /// `name`, so owner/repo is derivable client-side with no new data.
    ///
    /// Anchored on `pendingWorkspaceIds:`, which occurs exactly twice in an 11 MB bundle,
    /// so the regex only ever runs over a few hundred bytes.
    private static let anchor = ",pendingWorkspaceIds:"

    private static let headerPattern = """
        \\{repository:([A-Za-z_$][A-Za-z0-9_$]*),workspaceIds:[A-Za-z_$][A-Za-z0-9_$]*\
        ,pendingWorkspaceIds:[^}]{0,160}\\}=t,[^;]{0,240}?\
        (,([A-Za-z_$][A-Za-z0-9_$]*)=\\1\\.name;)
        """

    /// Derives `owner/repo` from a git remote, falling back to the plain name for
    /// anything that is not `host.tld[:/]owner/repo` -- notably the `file://` remotes
    /// Conductor writes for a locally-added project, which would otherwise render as a
    /// meaningless trailing path pair.
    private static func nameExpression(repoVariable: String) -> String {
        let body = #"""
            (function(_r){\#
            var _u=_r.remoteUrl;\#
            if(typeof _u!=="string")return _r.name;\#
            var _m=/^(?:[a-z][a-z0-9+.-]*:\/\/)?(?:[^@\/]+@)?([^\/:]+\.[^\/:]+)[:\/](.+?)(?:\.git)?\/?$/i.exec(_u);\#
            if(!_m)return _r.name;\#
            var _s=_m[2].split("/").filter(Boolean);\#
            return _s.length>=2?_s.slice(-2).join("/"):_r.name;\#
            })
            """#
        return marker + body + "(" + repoVariable + ")"
    }

    private static func qualifyRepoNames(_ script: inout Data) throws {
        let anchors = script.occurrences(of: Data(anchor.utf8))
        guard !anchors.isEmpty else {
            throw PatchError(
                "repo names: anchor \(anchor.debugDescription) not found; Conductor's sidebar "
                    + "has changed and the patch needs re-anchoring.")
        }

        let regex = try NSRegularExpression(pattern: headerPattern)
        var edits: [(range: Range<Int>, replacement: String)] = []

        for anchorOffset in anchors {
            // The destructuring starts a little before the anchor and the assignment lands
            // a little after it; this window comfortably covers both.
            let start = max(script.startIndex, anchorOffset - 300)
            let end = min(script.endIndex, anchorOffset + 900)
            let window = script[start ..< end]

            // NSRegularExpression indexes UTF-16, so byte offsets only map back cleanly
            // while the window is ASCII. Minified JS around a destructuring always is,
            // but check rather than silently corrupt the bundle if it ever is not.
            guard window.allSatisfy({ $0 < 0x80 }) else {
                Log.debug("repo names: skipping non-ASCII window at \(anchorOffset)")
                continue
            }

            let text = String(decoding: window, as: UTF8.self)
            let full = NSRange(text.startIndex ..< text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: full),
                let repoVariable = Range(match.range(at: 1), in: text).map({ String(text[$0]) }),
                let nameVariable = Range(match.range(at: 3), in: text).map({ String(text[$0]) })
            else { continue }

            let tail = match.range(at: 2)
            let absolute = (start + tail.location) ..< (start + tail.location + tail.length)
            let replacement =
                "," + nameVariable + "=" + nameExpression(repoVariable: repoVariable) + ";"
            edits.append((absolute, replacement))
        }

        guard edits.count == 1 else {
            throw PatchError(
                "repo names: expected exactly 1 sidebar header match, found \(edits.count). "
                    + "Conductor's bundle has changed; the patch needs re-anchoring.")
        }

        let edit = edits[0]
        script.replaceSubrange(edit.range, with: Data(edit.replacement.utf8))
        Log.info("sidebar: repository headers now show owner/repo")
    }
}
