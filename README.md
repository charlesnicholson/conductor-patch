# conductor-patch

Launches Conductor with quality-of-life patches applied. macOS, arm64.

## What it does

- Chat column, composer, turns and message bubbles fill the middle panel.
- Collapsed tool rows (Thinking, Bash, Error) stop ellipsising at 400px.
- Sidebar repository groups show `owner/repo`, brighter, with alternating tints per group.

`/Applications/Conductor.app` is never modified. Each launch clones it, patches the clone,
ad-hoc re-signs it, launches that, and deletes it on exit. Auto-update keeps working; an
update the clone installs is moved into `/Applications` rather than thrown away.

Conductor's frontend lives in its Mach-O as brotli blobs. The tool rewrites them in place,
recompressed to fit their original slots. Eight of the nine patches are CSS rules appended
to the stylesheet; only the `owner/repo` rewrite touches minified JS. A patch whose anchor
has moved is reported and skipped, not fatal. `--doctor` checks the anchors, `--help` lists
the flags. A run takes about 1.8s.

## Build

Needs Xcode; envy fetches brotli and cmake into a project-local `.envy` on first build.

```sh
./build.sh              # build into out/
./build.sh --install    # build, then install to /Applications
```

Launch **Conductor QoL Patched** from Spotlight. Quit Conductor first — two instances share
one `conductor.db`. The first launch re-prompts for microphone and folder access, because
the ad-hoc signature is a different code identity from Conductor's Developer ID.

Uninstall: `rm -rf "/Applications/Conductor QoL Patched.app" ~/Library/Caches/conductor-qol`
