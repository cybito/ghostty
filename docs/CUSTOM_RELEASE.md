# Custom release provenance

- GitHub fork: `https://github.com/cybito/ghostty` (upstream: `https://github.com/ghostty-org/ghostty.git`). `custom` is the custom build and release source.
- Historical Forgejo source repository: none; `cybit/ghostty` was created solely as an associated artifact repository. No historical Forgejo package or digest exists.
- Custom DMG and Linux ARM64 installation archive are GitHub Release assets. No Forgejo registry, package token, or PAT is used by current builds.
- macOS app uses ad-hoc signing without notarization; Gatekeeper may require manual approval.

## Release contract

Only a published GitHub Release in `cybito/ghostty` starts `custom-release.yml`.
Pushes (including tag pushes) do not publish. Use `v<base>-custom.<positive integer>`
and point the release at the exact pushed `custom` commit. The version base must
match `build.zig.zon` (currently `1.3.2`; this migration's first fully validated
asset release uses `v1.3.2-custom.4`). Existing tags/releases are never moved.
Both regular custom releases and prereleases are supported.

Validation dereferences the tag to a commit and checks its ancestry against
`origin/custom`, not merely the release's `target_commitish`. Both native builds
check out that same SHA, even if `custom` advances during the run. The workflow
preserves user-authored release notes and updates only the managed
`<!-- custom-builds:start -->` / `<!-- custom-builds:end -->` block after both
platforms' assets have been independently read back and validated.

| Platform | Hosted runner | Build |
| --- | --- | --- |
| macOS ARM64 | `macos-26` | Zig 0.16.0; Xcode 26.6; Nushell 0.116.1; ReleaseLocal |
| Omarchy ARM64 | `ubuntu-26.04-arm` | Zig 0.16.0; native baseline CPU; complete `bin/share` prefix |

Every downloaded tool is checked against the checksum pinned in the workflow
and official release checksum/metadata. Toolchains in `release.json` are the
actual versions used. Smoke diagnostics are uploaded using the pinned
`actions/upload-artifact` action and retained for 7 days. There are no Forgejo
publication dependencies. Disable inherited upstream workflows externally;
keep only this workflow enabled. This file does not claim that provisioning has
been performed.

## Assets and collision policy

Each platform contributes uniquely prefixed assets:

`<release-tag>-<platform>-<original-package-filename>`

This covers the original payload archive/DMG, `release.json`, and `SHA256SUMS`.
The receipt has schema 1, project/source SHA/release/platform/architecture,
actual toolchain strings, and each payload's name/hash/size. It is outside the
archive, avoiding recursive hashes. SHA256SUMS includes the receipt and package.

Before compiling, the workflow checks `gh release view --json assets` and
reads back matching assets with `gh release download`. A complete existing
platform is reused only after source/tag/platform, receipt, hashes, and payload
validation. A partial set is reconciled by downloading its existing assets,
validating their bytes, and uploading only absent names. Mismatching existing
bytes fail closed. Uploads use `gh release upload` without `--clobber`; distinct
names are never overwritten. The helper enforces GitHub's 1000 assets/release
and less-than-2-GiB per-file limits before upload. After upload, all platform
files are independently downloaded and validated again. Reruns resume missing
assets without changing existing assets.

## Download and install

Download all files for a platform into an empty directory using GitHub CLI:

```sh
tag=v1.3.2-custom.4
platform=linux # use darwin for macOS ARM64
mkdir -p /absolute/empty/download
cd /absolute/empty/download
gh release download "$tag" --repo cybito/ghostty --pattern "$tag-$platform-*"
prefix="$tag-$platform-"
for file in "$prefix"*; do mv "$file" "${file#"$prefix"}"; done
if [ "$platform" = linux ]; then sha256sum -c SHA256SUMS; else shasum -a 256 -c SHA256SUMS; fi
```

The helper first compares the expected platform set with release assets. No
matching assets means missing; incomplete sets are reported partial, and all
existing files are downloaded and validated before reuse or reconciliation.
Each asset filename adds `<tag>-<platform>-` before its original package name.
After restoring original names, extract and install Linux with:

```sh
tar -xzf "ghostty-$tag-linux-arm64.tar.gz"
cd "ghostty-$tag-linux-arm64"
./install.sh --prefix /absolute/prefix
```

The installer needs Python 3 and copies the full `bin/share` tree: terminal
executable, terminfo, shell integration, GTK resources, desktop files, and icons.
Put `<prefix>/bin` on PATH and `<prefix>/share` on XDG_DATA_DIRS as appropriate.
It does not install distribution dependencies: Omarchy needs native GTK4,
libadwaita, gtk4-layer-shell, oniguruma, and bzip2 runtime libraries.

On macOS, mount the original DMG read-only and run its explicit-prefix installer:

```sh
hdiutil attach "ghostty-$tag-darwin-arm64.dmg" -readonly -nobrowse -mountpoint /tmp/ghostty
/tmp/ghostty/install.sh --prefix /absolute/prefix
hdiutil detach /tmp/ghostty
```

It contains `Ghostty.app`, the conventional Applications link, license/README,
and `install.sh`. The installer places the app at
`<prefix>/share/applications/Ghostty.app` and a relative CLI symlink at
`<prefix>/bin/ghostty`. It never copies to system Applications automatically.
Launch with `open -na /absolute/prefix/share/applications/Ghostty.app`. The app
is ad-hoc signed, **not** Apple Developer signed/notarized; Gatekeeper may
require manual approval. Do not describe this as an official signed product.

Both installers default to `$HOME/.local`, accept only an absolute `--prefix`,
preflight conflicts before copying, reject differing existing files/symlinks,
and leave identical files unchanged on rerun. They do not restart services,
replace configuration, uninstall system packages, or update the production app.
Upgrading a different installed version requires a different prefix or deliberate
operator-managed replacement; there is no destructive force flag.

## Native and GUI smoke evidence

The workflow mounts/extracts the actual package into an isolated fixture,
installs it twice, checks version/Zig/ARM64, and validates signing on macOS or
`ldd`/desktop entries on Linux. It reads the newly built native `--help` and
config documentation before using terminal-launch arguments.

Linux uses X11 under `dbus-run-session` and `xvfb-run`, with Mesa software
rendering; a shell prints `custom-ci-ok`, the window title is checked with
`xwininfo`, and the captured window must contain the marker according to OCR.
macOS uses the fixture app via LaunchServices because Ghostty's actual native
help explicitly says terminal launch from the CLI is unsupported. Quartz checks
the visible Ghostty window/title, captures that window, and Vision OCR confirms
the marker. Missing GUI/session/screenshot permission or missing OCR evidence
fails smoke, rather than claiming success from `+version`.

Smoke diagnostics are uploaded as a separate GitHub Actions artifact named
`<release-tag>-<platform>-arm64-smoke`, retained for 7 days. The upload step runs
with `if: always()` after smoke attempts, so diagnostic files are preserved when
smoke fails where files were produced. Diagnostics are not product release
assets and are not included in the package receipt.

## Maintainer entry points

```sh
bash .github/scripts/custom-release.sh build darwin v1.3.2-custom.4 <40-char-source-sha> /absolute/build-output
python3 .github/scripts/package-release.py check --tag v1.3.2-custom.4 --commit <sha> --platform darwin --output-dir /absolute/empty/check
python3 .github/scripts/package-release.py pack --tag v1.3.2-custom.4 --commit <sha> --platform darwin --input-dir /absolute/build-output --output-dir /absolute/empty/package
python3 .github/scripts/package-release.py publish --tag v1.3.2-custom.4 --commit <sha> --platform darwin --directory /absolute/package
```

`check`, `pack`, and `publish` emit JSON describing verified assets, output
directory, and uploaded assets. The helper uses `GH_TOKEN` for the repository's
GitHub Release only; the workflow uses the built-in token and `contents: write`
where publishing or release-note updates occur. It never accesses Forgejo or
requires a PAT. Project, repository, and owner are fixed in the helper, not
caller options. Use `linux` for Linux equivalents. Do not run upstream
release/update scripts: some merge source, install locally, or upload elsewhere.

Maintainer boundary checks, also invoked by release validation:
`bash .github/scripts/custom-release.sh regressions`. They create isolated Git,
event, and asset fixtures and cover custom ancestry, unrelated upstream commits,
non-custom and malicious tags, installer conflict handling, missing/full/partial
asset sets, mismatching bytes, source identity and checksum validation, and
no-overwrite behavior. Tests are not run as part of this change; hosted builds,
native GUI launches, upload, and immutable download verification must be
observed before claiming delivery.
