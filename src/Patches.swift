import Foundation

/// Result of one patch. Patches are independent: a miss is reported and the rest still
/// apply, because losing one quality-of-life tweak to a Conductor release is a nuisance
/// while refusing to launch at all is a broken tool.
struct PatchOutcome {
    enum Status: String {
        case applied
        case disabled
        case missing  // anchor no longer matches; needs re-anchoring
    }
    let name: String
    let status: Status
    let detail: String
}

enum Patches {
    /// Stamped into everything injected, so a patched image is recognisable.
    static let marker = "/*cqol*/"

    struct Options {
        var widenTranscript = true
        var widenBubbles = true
        var brightenRepoLabels = true
        var bandRepoGroups = true
        var qualifyRepoNames = true
    }

    /// Anchors used to identify assets by content rather than by filename.
    ///
    /// Deliberately unrelated to anything a patch edits. An earlier version located the
    /// script by the same string the sidebar patch anchors on, which meant that patch
    /// going stale took the whole tool down with it instead of degrading to "one feature
    /// missing". Locating and patching are now independent failures.
    static let stylesheetAnchors = ["@layer utilities", "--tw-", ":root{"]
    static let scriptAnchors = ["react.memo_cache_sentinel", "useSyncExternalStore"]

    /// Anchor for the sidebar patch specifically. Used to narrow the regex window, not to
    /// decide which asset is the script.
    static let headerAnchor = "pendingWorkspaceIds:"

    // MARK: - Width rules
    //
    // Appended to the stylesheet instead of rewriting className literals in the bundle.
    //
    // Two reasons. A combination selector `.a.b` matches `class="a b c"` and does not care
    // about class order, so it survives a developer adding a utility to one of these divs
    // -- which is exactly the churn that broke whole-string matching. And appending needs
    // no anchor at all: there is nothing to fail to find.
    //
    // Specificity is not what makes these win. Tailwind v4 emits everything inside
    // `@layer utilities`, and unlayered rules beat layered ones outright, so an appended
    // unlayered rule takes precedence however the layers are ordered.

    struct StyleRule {
        let name: String
        let selector: String
        /// The declaration body, without braces.
        let declarations: String
        /// Class tokens that must still co-occur in one className literal in the bundle.
        /// Not needed to apply the rule -- appending always succeeds -- but without this
        /// the patch could silently stop matching anything and just look wrong.
        let evidence: [String]
        /// Extra literals that must appear anywhere in the bundle.
        let literals: [String]
    }

    static let transcriptRules: [StyleRule] = [
        // Turn body, session header, empty states, loading skeleton.
        StyleRule(
            name: "session columns", selector: ".max-w-4xl.mx-auto.px-7",
            declarations: "max-width:none",
            evidence: ["max-w-4xl", "mx-auto", "px-7"], literals: []),
        // Composer, local and cloud workspaces.
        StyleRule(
            name: "composer", selector: ".max-w-4xl.mx-auto.relative.pointer-events-auto",
            declarations: "max-width:none",
            evidence: ["max-w-4xl", "mx-auto", "relative", "pointer-events-auto"], literals: []),
        // Per-turn wrapper. Anchored on the data attribute rather than `.pb-3.max-w-4xl
        // .mx-auto`, which also matches the workspace-list and routines page headers --
        // and a semantic attribute churns far less than a utility class.
        StyleRule(
            name: "turns", selector: "[data-turn-index].max-w-4xl",
            declarations: "max-width:none",
            evidence: ["max-w-4xl", "mx-auto"], literals: ["data-turn-index"]),
        // Scroll-to-bottom bar.
        StyleRule(
            name: "scroll-to-bottom", selector: ".pb-2.px-4.max-w-4xl.mx-auto",
            declarations: "max-width:none",
            evidence: ["pb-2", "px-4", "max-w-4xl", "mx-auto"], literals: []),
    ]

    static let bubbleRules: [StyleRule] = [
        // Your own message bubbles and the system-summary blocks. Without this the outer
        // column goes full width but the contents stop at 48rem, which moves the empty
        // space rather than removing it.
        StyleRule(
            name: "message bubbles", selector: #".max-w-xl.lg\:max-w-3xl"#,
            declarations: "max-width:none",
            evidence: ["max-w-xl", "lg:max-w-3xl"], literals: []),
    ]

    static let sidebarRules: [StyleRule] = [
        // Alternating bands, one per repository group.
        //
        // No JavaScript required, because the DOM already has exactly the right shape: the
        // repo list is a @hello-pangea/dnd droppable whose id is "repo-list", each group is
        // one draggable child of it, and each of those wraps the header *and* its sessions.
        // So tinting every other child gives banded groups for free, and a group's sessions
        // inherit their header's band rather than needing to be matched separately. When
        // every repo is collapsed each group is one row, so it degrades to alternating rows.
        //
        // Keyed on the library's data attributes rather than utility classes: `repo-list`
        // is a semantic identifier the Conductor authors chose, and churns far less than
        // Tailwind soup.
        //
        // color-mix against --sidebar-foreground rather than a literal rgba keeps the tint
        // the right polarity in both themes: that token is white at 90% in the dark theme
        // and near-black at 70% in the light one, so the band lifts in one and darkens in
        // the other. 5% of it lands just under the 5% flat white of --sidebar-accent, which
        // is the row hover colour, so hover still reads on a banded group.
        StyleRule(
            name: "repo group banding",
            selector: "[data-rfd-droppable-id='repo-list']>[data-rfd-draggable-id]:nth-child(even)",
            declarations:
                "background:color-mix(in srgb,var(--sidebar-foreground) 5%,transparent)"
                + ";border-radius:6px",
            evidence: [],
            literals: ["repo-list", "data-rfd-draggable-id"]),

        // The repository group header, lifted out of the muted palette.
        //
        // It ships as `--sidebar-muted-foreground`, which is white at 60% in the dark
        // theme -- dimmer than the session rows beneath it, which inherit the full
        // `--sidebar-foreground`. Promoting the header to that same token is a 30-point
        // jump in alpha and reads as a heading without adding weight, which at 700 just
        // made the panel busy.
        //
        // Using the token rather than a literal colour keeps it correct in the light
        // theme too, where the same pair is #14100f at 60% and 70%.
        //
        // `font-sans` is the discriminator: the header is the only sidebar element pairing
        // it with `font-medium`, so three classes identify it uniquely without pinning the
        // layout utilities that are likelier to churn.
        StyleRule(
            name: "repo label colour",
            selector: ".font-sans.font-medium.text-sidebar-muted-foreground",
            declarations: "color:var(--sidebar-foreground)",
            evidence: ["font-sans", "font-medium", "text-sidebar-muted-foreground"],
            literals: []),
    ]

    /// Every style rule, for reporting.
    static var allStyleRules: [StyleRule] { transcriptRules + bubbleRules + sidebarRules }

    // MARK: - Stylesheet patch

    static func injectStyles(stylesheet: inout Data, script: Data, options: Options)
        -> [PatchOutcome]
    {
        var rules: [StyleRule] = []
        var outcomes: [PatchOutcome] = []

        if options.widenTranscript {
            rules += transcriptRules
        } else {
            outcomes.append(
                PatchOutcome(name: "chat column", status: .disabled, detail: "--no-widen-transcript"))
        }
        if options.widenBubbles {
            rules += bubbleRules
        } else {
            outcomes.append(
                PatchOutcome(name: "message bubbles", status: .disabled, detail: "--no-widen-bubbles"))
        }
        if options.brightenRepoLabels {
            rules += sidebarRules.filter { $0.name != "repo group banding" }
        } else {
            outcomes.append(
                PatchOutcome(
                    name: "repo label colour", status: .disabled,
                    detail: "--no-brighten-repos"))
        }
        if options.bandRepoGroups {
            rules += sidebarRules.filter { $0.name == "repo group banding" }
        } else {
            outcomes.append(
                PatchOutcome(
                    name: "repo group banding", status: .disabled, detail: "--no-band-repos"))
        }
        guard !rules.isEmpty else { return outcomes }

        for rule in rules {
            let supported = evidenceFound(for: rule, in: script)
            outcomes.append(
                PatchOutcome(
                    name: rule.name,
                    status: supported ? .applied : .missing,
                    detail: supported
                        ? rule.selector
                        : "\(rule.selector) — no element in the bundle carries these classes any "
                            + "more; the rule was still appended but will match nothing"))
        }

        // Every rule is appended regardless: a rule matching nothing is inert, and leaving
        // it in place means a Conductor release that merely renames a sibling class can
        // start working again on its own.
        var css = "\n\(marker)"
        for rule in rules { css += "\n\(rule.selector){\(rule.declarations)}" }
        css += "\n"
        stylesheet.append(Data(css.utf8))

        return outcomes
    }

    /// True when some className literal in the bundle still carries all of a rule's tokens.
    static func evidenceFound(for rule: StyleRule, in script: Data) -> Bool {
        for literal in rule.literals where script.occurrences(of: Data(literal.utf8)).isEmpty {
            return false
        }
        guard let rarest = rule.evidence.min(by: { left, right in
            script.occurrences(of: Data(left.utf8)).count
                < script.occurrences(of: Data(right.utf8)).count
        }) else { return true }

        let wanted = Set(rule.evidence)
        for hit in script.occurrences(of: Data(rarest.utf8)) {
            guard let literal = enclosingStringLiteral(at: hit, in: script) else { continue }
            if wanted.isSubset(of: Set(literal.split(separator: " ").map(String.init))) {
                return true
            }
        }
        return false
    }

    /// The double-quoted literal containing `offset`, if it is a short single-line one.
    private static func enclosingStringLiteral(at offset: Int, in script: Data) -> String? {
        let quote = UInt8(ascii: "\"")
        let lower = max(script.startIndex, offset - 400)
        let upper = min(script.endIndex, offset + 400)

        var start = offset
        while start > lower, script[start] != quote { start -= 1 }
        guard script[start] == quote else { return nil }

        var end = offset
        while end < upper, script[end] != quote { end += 1 }
        guard end < upper, script[end] == quote, end > start else { return nil }

        let body = script[(start + 1) ..< end]
        guard body.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { return nil }
        return String(decoding: body, as: UTF8.self)
    }

    // MARK: - Fully-qualified repository names

    /// Rewrites the sidebar's repository group header from `docs` to
    /// `envy-package-manager/docs`.
    ///
    /// The header component destructures its props and takes the bare name:
    ///
    ///     {repository:n,workspaceIds:i,pendingWorkspaceIds:r, ... }=t, ... ,b=n.name;
    ///
    /// Only `n.name` is replaced, not the whole assignment, so nothing depends on what the
    /// destination variable is called or whether the statement ends in `,` or `;`. The
    /// props parameter is matched as any identifier rather than the literal `t`: that name
    /// is minifier output and will eventually change.
    private static let headerPattern = """
        \\{repository:([A-Za-z_$][A-Za-z0-9_$]*),[^}]{0,200}pendingWorkspaceIds:[^}]{0,200}\\}\
        =[A-Za-z_$][A-Za-z0-9_$]*,[\\s\\S]{0,400}?=(\\1\\.name)\\b
        """

    /// Derives `owner/repo` from a git remote, falling back to the plain name for anything
    /// that is not `host.tld[:/]owner/repo` -- notably the `file://` remotes Conductor
    /// writes for a locally-added project, which would otherwise render as a meaningless
    /// trailing path pair.
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

    static func qualifyRepoNames(in script: inout Data, options: Options) -> PatchOutcome {
        let name = "repository names"
        guard options.qualifyRepoNames else {
            return PatchOutcome(name: name, status: .disabled, detail: "--no-repo-names")
        }

        guard let match = Profile.shared.measure("find sidebar anchor", { findHeader(in: script) }) else {
            return PatchOutcome(
                name: name, status: .missing,
                detail: "sidebar header assignment not found near \(headerAnchor.debugDescription)")
        }

        script.replaceSubrange(
            match.range, with: Data(nameExpression(repoVariable: match.repoVariable).utf8))
        return PatchOutcome(
            name: name, status: .applied, detail: "rewrote \(match.repoVariable).name")
    }

    /// Located without mutating, so `--doctor` can report on it.
    static func findHeader(in script: Data) -> (range: Range<Int>, repoVariable: String)? {
        guard let regex = try? NSRegularExpression(pattern: headerPattern) else { return nil }

        for anchorOffset in script.occurrences(of: Data(headerAnchor.utf8)) {
            // The destructuring starts before the anchor and the assignment lands after it.
            let start = max(script.startIndex, anchorOffset - 400)
            let end = min(script.endIndex, anchorOffset + 1200)
            let window = script[start ..< end]

            // NSRegularExpression indexes UTF-16, so byte offsets only map back cleanly
            // while the window is ASCII. Minified JS around a destructuring always is, but
            // check rather than silently corrupt the bundle if it ever is not.
            guard window.allSatisfy({ $0 < 0x80 }) else { continue }

            let text = String(decoding: window, as: UTF8.self)
            let full = NSRange(text.startIndex ..< text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: full),
                let repoVariable = Range(match.range(at: 1), in: text).map({ String(text[$0]) })
            else { continue }

            let target = match.range(at: 2)
            return (
                (start + target.location) ..< (start + target.location + target.length),
                repoVariable
            )
        }
        return nil
    }

    // MARK: - Idempotence

    static func alreadyPatched(_ blob: Data) -> Bool {
        !blob.occurrences(of: Data(marker.utf8)).isEmpty
    }
}
