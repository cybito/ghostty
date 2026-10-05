# Custom release provenance

- GitHub fork: `https://github.com/cybito/ghostty` (upstream: `https://github.com/ghostty-org/ghostty.git`). `custom` is the custom build and release source.
- Historical Forgejo source repository: none; `cybit/ghostty` is created solely as the associated artifact repository. No historical Forgejo package or digest exists.
- The GitHub fork preserves custom source history; `custom` is the release source branch.
- Custom DMG installs are stored as OCI package `ias-ghostty`; immutable download: `oras pull git.cybit.top/cybit/ias-ghostty@sha256:<digest>`.
- macOS app uses ad-hoc signing without notarization; Gatekeeper may require manual approval.

## Release contract

Only a published GitHub Release in `cybito/ghostty` starts `custom-release.yml`.
Pushes (including tag pushes) do not publish. Use `v<base>-custom.<positive integer>`
and point the release at the exact pushed `custom` commit. The version base must
match `build.zig.zon` (currently `1.3.2`, so the first planned tag is
`v1.3.2-custom.1`). An existing release/tag is never repointed; choose the next
unused custom integer. Both regular releases and prereleases are supported.

Validation dereferences the tag to a commit and checks its ancestry against
`origin/custom`, not merely the release's `target_commitish`. Both native builds
check out that same SHA, even if `custom` advances during the run. GitHub Release
assets must stay empty. The notes job preserves the user's notes and updates only
the `<!-- custom-builds:start -->` / `<!-- custom-builds:end -->` section after
both platforms are published and anonymously verified.

| Platform | Hosted runner | Build |
| --- | --- | --- |
| macOS ARM64 | `macos-26` | Zig 0.16.0; Xcode 26.6; Nushell 0.116.1; ReleaseLocal |
| Omarchy ARM64 | `ubuntu-26.04-arm` | Zig 0.16.0; native baseline CPU; complete `bin/share` prefix |

ORAS is pinned to 1.3.3. Every downloaded tool is checked against the checksum
pinned in the workflow **and** its official release checksum/metadata. Toolchains
in `release.json` are the actual versions used. There are no GitHub build
artifacts, caches, GHCR images, or Release attachments, and no source push mirror
to Forgejo. Disable all inherited upstream workflows externally; keep only this
workflow enabled. This file does not claim that provisioning has been performed.

## Forgejo storage and credentials

The owner-level OCI package is `git.cybit.top/cybit/ias-ghostty`; associate it with
`cybit/ghostty` in Forgejo's package settings. GitHub source annotations remain
`https://github.com/cybito/ghostty.git`; association must not falsify provenance.
Ghostty had no historical native OCI artifact. The original four CLI packages'
`application/vnd.ias.native.v1` versions are not affected by this workflow.

Installation artifacts use `application/vnd.cybito.install-package.v1` and tags
`<release-tag>-darwin-arm64` / `<release-tag>-linux-arm64`. Layers are the DMG or
gzip archive, `release.json`, and `SHA256SUMS`, with explicit media types. The
receipt has schema 1, project/source SHA/release/platform/architecture, actual
toolchain strings, and each payload's name/hash/size. It is outside the archive,
avoiding recursive hashes. SHA256SUMS includes the receipt and package.
Manifest creation time is the source commit's UTC time.

Use a new human-created Forgejo PAT named `github-custom-builds`, username
`cybit`, with package-write permission (prefer public-only). Package scope is
owner-wide: it is **not** limited to these six packages. Never export existing
OAuth credentials, Docker helpers, or passwords. Provision GitHub environment
`forgejo-registry`, tag-only deployment policy `v*-custom.*`, and environment
secret `FORGEJO_REGISTRY_TOKEN`. No approval gate is needed per subsequent release.
Only the post-smoke upload step receives this token; mode-0700/mode-0600 temporary
auth is removed even on failure. The notes job has no Forgejo write credential.
Provisioning, initial real release, and credential scope verification remain
operator actions, not something demonstrated by adding these files.

Before building, `check` resolves and verifies the complete existing artifact by
digest. Only explicit `manifest_unknown` / `name_unknown` means absent; auth,
network, TLS, or identity mismatches fail closed. Reruns reuse the exact verified
identity without rebuilding. Publishing first builds a local OCI layout,
determines its digest, copies it to Forgejo, then checks manifest bytes, every
descriptor, an independent pull and SHA256SUMS. Different published bytes are
never silently overwritten. A failed platform does not remove the successful
other platform; rerunning fills the missing platform.

## Download and install

Copy the immutable references from the successful release notes/job summary:

```sh
mkdir ghostty-download && cd ghostty-download
oras pull git.cybit.top/cybit/ias-ghostty@sha256:<digest>
shasum -a 256 -c SHA256SUMS
```

For descriptor, source-identity, and independent-pull validation, use this
checkout's helper rather than trusting only a mutable tag:

```sh
python3 .github/scripts/package-release.py verify \
  --reference git.cybit.top/cybit/ias-ghostty@sha256:<digest> \
  --output-dir /absolute/empty/verification-directory
```

On Linux, extract `ghostty-<release-tag>-linux-arm64.tar.gz`, enter the package
directory, and run `./install.sh --prefix /absolute/prefix`. The installer needs
Python 3 and copies the full `bin/share` tree: terminal executable, terminfo,
shell integration, GTK resources, desktop files, and icons. Put
`<prefix>/bin` on PATH and `<prefix>/share` on XDG_DATA_DIRS as appropriate.
It does not install distribution dependencies: Omarchy needs the native GTK4,
libadwaita, gtk4-layer-shell, oniguruma, and bzip2 runtime libraries.

On macOS, mount `ghostty-<release-tag>-darwin-arm64.dmg` read-only. It contains
`Ghostty.app`, the conventional Applications link, license/README, and
`install.sh`. Drag the app to Applications manually, or use the explicit-prefix
installer from the mounted volume. The installer places it at
`<prefix>/share/applications/Ghostty.app` and a relative CLI symlink at
`<prefix>/bin/ghostty`. It never copies to system Applications automatically.
Launch with `open -na /absolute/prefix/share/applications/Ghostty.app`.
The app is ad-hoc signed, **not** Apple Developer signed/notarized; Gatekeeper
may require manual approval. Do not describe this as an official signed product.

Both installers default to `$HOME/.local`, accept only an absolute `--prefix`,
preflight conflicts before copying, reject differing existing files/symlinks,
and leave identical files unchanged on rerun. They do not restart services,
replace configuration, uninstall system packages, or update the production app.
Upgrading a different installed version requires a different prefix or deliberate
operator-managed replacement; there is no destructive force flag.

## Native and GUI smoke evidence

The workflow mounts/extracts the actual package into an isolated fixture,
installs it twice, checks version/Zig/ARM64, and validates signing on macOS or
`ldd`/desktop entries on Linux. It reads the newly built native `--help` and config
documentation before using terminal-launch arguments.

Linux uses X11 under `dbus-run-session` and `xvfb-run`, with Mesa software
rendering; a shell prints `custom-ci-ok`, the window title is checked with
`xwininfo`, and the captured window must contain the marker according to OCR.
macOS uses the fixture app via LaunchServices because Ghostty's actual native
help explicitly says terminal launch from the CLI is unsupported. Quartz checks
the visible Ghostty window/title, captures that window, and Vision OCR confirms
the marker. Missing GUI/session/screenshot permission or missing OCR evidence
fails smoke, rather than claiming success from `+version`.

Screenshot and logs are separate OCI diagnostics
`<release-tag>-<platform>-arm64-smoke`, artifact type
`application/vnd.cybito.smoke-diagnostics.v1`, in the same package. The immutable
diagnostics digest appears in the job summary and can be pulled with ORAS.
Diagnostics are uploaded after a smoke attempt even when it fails; installation
packages are published only after successful smoke. Diagnostics do not appear
in installation receipts or GitHub assets.

## Maintainer entry points

```sh
bash .github/scripts/custom-release.sh build darwin v1.3.2-custom.1 <40-char-source-sha> /absolute/build-output
python3 .github/scripts/package-release.py check --tag v1.3.2-custom.1 --commit <sha> --platform darwin --output-dir /absolute/empty/check
python3 .github/scripts/package-release.py pack --tag v1.3.2-custom.1 --commit <sha> --platform darwin --input-dir /absolute/build-output --output-dir /absolute/empty/package
python3 .github/scripts/package-release.py publish --directory /absolute/package --registry-config /absolute/private-auth.json
```

`check`, `pack`, and `publish` emit JSON (`exists/reference`, `directory`, and
`reference/digest` respectively); `verify` emits the validated receipt. All
projects, owners, and package names are fixed in the helper, not caller options.
Use `linux` for the Linux equivalents. Do not run upstream release/update
scripts: some merge source, install locally, or upload elsewhere.

Maintainer boundary checks, also invoked by the release validation job:
`bash .github/scripts/custom-release.sh regressions`. They create an isolated
Git/event fixture and cover custom ancestry, unrelated upstream commits,
non-custom and malicious tags, missing-vs-auth/network registry errors,
wrong-source receipts, and rejection of conflicting published identities.
The release validation job runs the boundary and installer regressions
automatically; `bash .github/scripts/custom-release.sh regressions` also passed
locally, as did Python, Bash, and YAML syntax checks. The local regression run
does not prove hosted builds, native GUI launches, external package publication,
or immutable pull verification; those must be observed before claiming delivery.
