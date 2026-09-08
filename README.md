# conductor-patch

Launches Conductor with quality-of-life patches applied. macOS, arm64.

## What it does

Nine patches to Conductor's frontend:

- Chat column, composer, turns, loading skeleton and scroll-to-bottom bar fill the
  middle panel instead of stopping at 56rem.
- Your own message bubbles and system-summary blocks lose their 48rem cap.
- Collapsed tool rows (Thinking, Bash, Error) use the full panel width instead of
  ellipsising at a hard-coded 400px.
- Sidebar repository groups show `owner/repo` instead of `repo`, derived from the git
  remote. Anything that is not `host.tld[:/]owner/repo` keeps its plain name.
- Sidebar repository labels use the full sidebar foreground colour rather than the muted
  one.
- Alternating background tints per repository group, header and sessions together.

`/Applications/Conductor.app` is never modified. Each launch clones it (APFS, ~6ms),
patches the clone, ad-hoc re-signs it, launches that, and deletes it on exit. Conductor's
own auto-update keeps working; if the clone updates itself mid-session the update is moved
into `/Applications` rather than thrown away.

Conductor's frontend is embedded in its Mach-O as brotli blobs in `__TEXT,__const`, indexed
by a phf table in `__DATA_CONST`. The tool decompresses what it needs, edits it,
recompresses to fit the original slot, and lowers the length field. Eight of the nine
patches are CSS rules appended to the stylesheet, which need no anchor; only the
`owner/repo` rewrite pattern-matches minified JS.

Patches are independent. One whose anchor has moved is reported and skipped; the rest
still apply and launch. `--doctor` reports which anchors still match without patching
anything. `--help` lists the flags.

A full run takes about 1.8 seconds.

## Build

Needs Xcode. Everything else — brotli, cmake — is fetched and built by
[envy](https://github.com/envy-package-manager/envy) into a project-local `.envy` cache on
first build. The resulting binary links only against libSystem, Foundation, AppKit and the
OS Swift runtime.

```sh
./build.sh              # build into out/
./build.sh --install    # build, then install to /Applications
```

Then launch **Conductor QoL Patched** from Spotlight. It is an agent app: it sits in the
menu bar for the length of the session and quits when Conductor does.

Quit Conductor before launching it — the tool refuses to start while one is running,
because two instances share one `conductor.db` and Conductor has no single-instance guard.

The first launch prompts for microphone and folder access, and possibly Keychain: the
ad-hoc signature is a different code identity from Conductor's Developer ID. Once per
Conductor version, not per launch.

To use the shared envy cache instead of the project-local one:

```sh
./bin/envy cache --shared
```

Uninstall:

```sh
rm -rf "/Applications/Conductor QoL Patched.app" ~/Library/Caches/conductor-qol
```
