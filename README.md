# conductor-patch

Launches Conductor with quality-of-life patches applied. macOS, arm64.

## What it does

- Chat column, composer, turns and message bubbles fill the middle panel.
- Collapsed tool rows (Thinking, Bash, Error) stop ellipsising at 400px.
- Sidebar repository groups show `owner/repo`, with alternating background tints per group.

`/Applications/Conductor.app` is never modified. Each launch clones it, patches the clone,
ad-hoc re-signs it, launches that, and deletes it on exit.

Auto-update keeps working. Conductor's updater installs the new release over the running
clone and relaunches from it; the tool notices the version change, moves the release into
`/Applications`, and relaunches a patched clone of it in place of the unpatched one, so
"Restart to update" ends with the update applied *and* the patches on. If Conductor is
quit instead of restarted, the release is still moved into `/Applications` on the way out.

Conductor's frontend lives in its Mach-O as brotli blobs. The tool rewrites them in place,
recompressed to fit their original slots. Seven of the eight patches are CSS rules appended
to the stylesheet; only the `owner/repo` rewrite touches minified JS. A patch whose anchor
has moved is reported and skipped, not fatal. `--doctor` checks the anchors, and with
`--source path/to/Conductor.app` does so against a release that is not installed yet;
`--dump DIR` writes the decoded stylesheet and scripts out for re-anchoring. `--help` lists
the flags. A run takes about 1.8s. Everything is logged to `~/Library/Logs/conductor-qol.log`,
which is where to look when the menu-bar mode has nothing to say.

## Build

Needs Xcode; envy fetches brotli and cmake into a project-local `.envy` on first build.

```sh
./build.sh              # build into out/
./build.sh --install    # build, then install to /Applications
```

Launch **Conductor QoL Patched** from Spotlight. Quit Conductor first — two instances share
one `conductor.db`. The first launch re-prompts for microphone and folder access, because
the ad-hoc signature is a different code identity from Conductor's Developer ID.

## Password prompts

macOS will ask for your login password several times per launch, and will ask again the
next launch. Two separate reasons.

Within a launch: every keychain item carries its own access list naming which code may
read it. Conductor reads several — agent credentials, git tokens — so you get one prompt
per item, not one per app.

Across launches: an access list identifies code by its signature. The patched clone is
signed ad-hoc, so its identity is just the hash of its own bytes, and the clone is rebuilt,
patched and re-signed from scratch on every launch. The hash is new, so nothing you
approved before matches. "Always Allow" grants access to a binary that is deleted on exit.

Uninstall: `rm -rf "/Applications/Conductor QoL Patched.app" ~/Library/Caches/conductor-qol`
