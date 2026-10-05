#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
helper="$PWD/.github/scripts/package-release.py"

install_tools() {
  local platform="$1" tools="$RUNNER_TEMP/custom-tools" archive expected official url
  mkdir -p "$tools/bin"
  export TOOLS_DIR="$tools" PLATFORM="$platform"
  python3 - <<'PY'
import hashlib, json, os, pathlib, tarfile, urllib.request
p = os.environ['PLATFORM']; root = pathlib.Path(os.environ['TOOLS_DIR'])
def get(url):
    headers = {}
    if url.startswith('https://api.github.com/'):
        headers = {
            'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
        }
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=120) as r: return r.read()
items = []
if os.environ.get('INSTALL_BUILD_TOOLS') == '1':
    zig = json.loads(get('https://ziglang.org/download/index.json'))['0.16.0']['aarch64-' + ('macos' if p == 'darwin' else 'linux')]
    items.append(('zig', zig['tarball'], os.environ['ZIG_SHA'], zig['shasum']))
    if p == 'darwin':
        name = 'nu-0.116.1-aarch64-apple-darwin.tar.gz'
        metadata = json.loads(get('https://api.github.com/repos/nushell/nushell/releases/tags/0.116.1'))
        asset = next(a for a in metadata['assets'] if a['name'] == name)
        items.append(('nu', asset['browser_download_url'], os.environ['NU_SHA'], asset['digest'].removeprefix('sha256:')))
for name, url, expected, official in items:
    if expected != official: raise SystemExit(name + ' official checksum changed')
    data = get(url)
    if hashlib.sha256(data).hexdigest() != expected: raise SystemExit(name + ' download checksum mismatch')
    archive = root / (name + '.tar'); archive.write_bytes(data)
    dest = root / name; dest.mkdir(exist_ok=True)
    with tarfile.open(archive) as t: t.extractall(dest, filter='data')
    binary = next(x for x in dest.rglob(name) if x.is_file())
    link = root / 'bin' / name
    if link.is_symlink(): link.unlink()
    link.symlink_to(binary)
print(root / 'bin')
PY
  printf '%s\n' "$tools/bin" >> "$GITHUB_PATH"
}

validate() {
  python3 - <<'PY'
import json, os, pathlib, re, subprocess
run = lambda *args: subprocess.check_output(args, text=True).strip()
event = json.loads(pathlib.Path(os.environ['GITHUB_EVENT_PATH']).read_text())
assert os.environ['GITHUB_EVENT_NAME'] == 'release'
assert event['action'] == 'published' and event['repository']['full_name'] == 'cybito/ghostty'
r = event['release']; tag = r['tag_name']
assert not r['draft'], 'draft release cannot be published'
assert re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+-custom\.[1-9][0-9]*', tag), 'invalid release tag'
sha = run('git', 'rev-parse', '--verify', 'refs/tags/' + tag + '^{commit}')
assert re.fullmatch('[0-9a-f]{40}', sha)
subprocess.run(['git', 'merge-base', '--is-ancestor', sha, 'refs/remotes/origin/custom'], check=True)
assert run('git', 'rev-parse', 'HEAD') == sha, 'checkout is not exact release commit'
for name in ('.github/workflows/custom-release.yml', '.github/scripts/custom-release.sh', '.github/scripts/package-release.py'):
    subprocess.run(['git', 'cat-file', '-e', sha + ':' + name], check=True)
base = re.search(r'\.version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)', pathlib.Path('build.zig.zon').read_text()).group(1)
assert tag.startswith('v' + base + '-custom.'), 'release base differs from source version'
with open(os.environ['GITHUB_OUTPUT'], 'a') as out: out.write('commit=' + sha + '\nversion=' + tag + '\n')
PY
}

build() {
  [[ $# == 4 ]] || { echo 'build PLATFORM TAG SHA ABS_OUTPUT' >&2; exit 2; }
  local platform="$1" tag="$2" sha="$3" out="$4" version="${2#v}"
  [[ "$out" == /* && "$sha" =~ ^[a-f0-9]{40}$ && "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-custom\.[1-9][0-9]*$ ]]
  [[ "$(git rev-parse HEAD)" == "$sha" && "$(uname -m)" =~ ^(arm64|aarch64)$ ]]
  [[ "$(zig version)" == 0.16.0 ]]
  mkdir -p "$out"
  cp LICENSE README.md "$out/"
  for file in NOTICE NOTICE.md LICENSE.md; do [[ ! -f "$file" ]] || cp "$file" "$out/"; done
  if [[ "$platform" == darwin ]]; then
    sudo xcode-select --switch /Applications/Xcode_26.6.app/Contents/Developer
    xcodebuild -version | tee "$out/xcode-version.txt"
    grep -qx 'Xcode 26.6' "$out/xcode-version.txt"
    xcrun --sdk macosx --show-sdk-path
    if ! xcrun --sdk macosx --find metal; then xcodebuild -downloadComponent MetalToolchain; fi
    xcrun --sdk macosx --find metal
    zig build -Doptimize=ReleaseFast -Demit-macos-app=false -Dversion-string="$version"
    nu macos/build.nu --scheme Ghostty --configuration ReleaseLocal --action build
    local app="$PWD/macos/build/ReleaseLocal/Ghostty.app"
    if ! codesign --verify --deep --strict "$app"; then
      while IFS= read -r -d '' bundle; do codesign --force --sign - --entitlements macos/GhosttyReleaseLocal.entitlements "$bundle"; done < <(find "$app/Contents" -depth \( -name '*.app' -o -name '*.appex' -o -name '*.xpc' -o -name '*.plugin' -o -name '*.framework' -o -name '*.dylib' \) -print0)
      codesign --force --sign - --entitlements macos/GhosttyReleaseLocal.entitlements "$app"
    fi
    codesign --verify --deep --strict "$app"
    codesign -dv --verbose=4 "$app" 2> "$out/signature.txt"
    grep -q 'Signature=adhoc' "$out/signature.txt"
    local stage="$out/dmg-root"; mkdir -p "$stage"; ditto "$app" "$stage/Ghostty.app"; ln -s /Applications "$stage/Applications"
    cp "$out/LICENSE" "$out/README.md" "$stage/"
    for file in "$out"/NOTICE*; do [[ ! -f "$file" ]] || cp "$file" "$stage/"; done
    export HELPER="$helper" STAGE="$stage"
    python3 - <<'PY'
import os, pathlib, runpy
module = runpy.run_path(os.environ['HELPER']); installer = module['INSTALLER']
installer = installer.replace("source = root / 'root'", "import tempfile\ntemp = tempfile.TemporaryDirectory()\nsource = pathlib.Path(temp.name)\n(source / 'share/applications').mkdir(parents=True)\nshutil.copytree(root / 'Ghostty.app', source / 'share/applications/Ghostty.app', symlinks=True)\n(source / 'bin').mkdir()\n(source / 'bin/ghostty').symlink_to('../share/applications/Ghostty.app/Contents/MacOS/ghostty')")
p = pathlib.Path(os.environ['STAGE']) / 'install.sh'; p.write_text(installer); p.chmod(0o755)
PY
    hdiutil create -volname "Ghostty $tag" -srcfolder "$stage" -format UDZO "$out/Ghostty.dmg"
  elif [[ "$platform" == linux ]]; then
    python3 - <<'PY'
import re, subprocess
v = subprocess.check_output(['blueprint-compiler', '--version'], text=True); n = re.search(r'(\d+)\.(\d+)', v)
assert n and tuple(map(int, n.groups())) >= (0, 16), 'blueprint-compiler >=0.16 required'
PY
    zig build -Doptimize=ReleaseFast -Dcpu=baseline -Dversion-string="$version" --prefix "$out/root"
    [[ -x "$out/root/bin/ghostty" && -d "$out/root/share/terminfo" && -d "$out/root/share/ghostty" ]]
  else exit 2; fi
  export OUT="$out" PLATFORM="$platform"
  python3 - <<'PY'
import json, os, pathlib, subprocess
v = lambda *a: subprocess.check_output(a, text=True).strip()
tools = {'zig': v('zig', 'version')}
if os.environ['PLATFORM'] == 'darwin': tools.update(nushell=v('nu', '--version'), xcode=v('xcodebuild', '-version'), macos_sdk=v('xcrun', '--sdk', 'macosx', '--show-sdk-version'))
else: tools.update(blueprint=v('blueprint-compiler', '--version'), cc=v('cc', '--version').splitlines()[0])
(pathlib.Path(os.environ['OUT']) / 'toolchains.json').write_text(json.dumps(tools))
PY
}

smoke() {
  local runner_temp="${RUNNER_TEMP:?}"
  local platform="$1" tag="$2" directory="$3" fixture="$runner_temp/ghostty-fixture" diag="${GHOSTTY_SMOKE_DIAG:-$runner_temp/ghostty-smoke}" binary
  mkdir -p "$fixture/home" "$fixture/config" "$fixture/prefix" "$diag"
  printf 'smoke diagnostics: %s\n' "$diag"
  export HOME="$fixture/home" XDG_CONFIG_HOME="$fixture/config" XDG_CACHE_HOME="$fixture/cache" XDG_DATA_HOME="$fixture/data"
  if [[ "$platform" == darwin ]]; then
    local mount="$fixture/mount"; mkdir -p "$mount"; hdiutil attach -readonly -nobrowse -mountpoint "$mount" "$directory/ghostty-$tag-darwin-arm64.dmg"; trap 'hdiutil detach "$mount" || true' EXIT
    "$mount/install.sh" --prefix "$fixture/prefix"; "$mount/install.sh" --prefix "$fixture/prefix"
    binary="$fixture/prefix/share/applications/Ghostty.app/Contents/MacOS/ghostty"
    codesign --verify --deep --strict "$fixture/prefix/share/applications/Ghostty.app"; lipo -archs "$binary" | grep -qx arm64
  else
    tar -xzf "$directory/ghostty-$tag-linux-arm64.tar.gz" -C "$fixture"
    "$fixture/ghostty-$tag-linux-arm64/install.sh" --prefix "$fixture/prefix"; "$fixture/ghostty-$tag-linux-arm64/install.sh" --prefix "$fixture/prefix"
    binary="$fixture/prefix/bin/ghostty"
    file "$binary" | tee "$diag/architecture.txt" | grep -q 'ARM aarch64'
    ldd "$binary" | tee "$diag/ldd.txt"; ! grep -q 'not found' "$diag/ldd.txt"
    find "$fixture/prefix/share/applications" -name '*.desktop' -exec desktop-file-validate '{}' \;
  fi
  "$binary" +version > "$diag/version.txt"; grep -qx "Ghostty ${tag#v}" "$diag/version.txt"
  grep -Eq 'Zig version[[:space:]]*:[[:space:]]*0\.16\.0' "$diag/version.txt"
  "$binary" --help > "$diag/help.txt"; grep -q 'All configuration keys are available as command line options' "$diag/help.txt"; grep -q 'special command line argument.*-e' "$diag/help.txt"
  "$binary" +show-config --default --docs > "$diag/config-options.txt"
  for option in title config-default-files; do grep -q "$option" "$diag/config-options.txt"; done
  printf 'CLI identity, help, and configuration checks passed\n'
  export SMOKE_BINARY="$binary" SMOKE_DIAG="$diag"
  if [[ "$platform" == linux ]]; then
    GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe GSK_RENDERER=cairo dbus-run-session -- xvfb-run -a bash -euo pipefail <<'SH'
"$SMOKE_BINARY" --config-default-files=false --title=custom-ci-ok -e /bin/sh -c 'printf "custom-ci-ok\n"; sleep 120' > "$SMOKE_DIAG/gui.log" 2>&1 &
pid=$!; trap 'kill "$pid" 2>/dev/null || true' EXIT
window=''
for attempt in {1..60}; do
  kill -0 "$pid"; xwininfo -root -tree > "$SMOKE_DIAG/windows.txt"; window=$(awk '/"custom-ci-ok"/ {print $1; exit}' "$SMOKE_DIAG/windows.txt"); [[ -z "$window" ]] || break; sleep 1
done
[[ -n "$window" ]]; xwininfo -id "$window" > "$SMOKE_DIAG/window.txt"; sleep 3
import -window "$window" "$SMOKE_DIAG/window.png"; tesseract "$SMOKE_DIAG/window.png" stdout > "$SMOKE_DIAG/ocr.txt"; grep -q custom-ci-ok "$SMOKE_DIAG/ocr.txt"
SH
  else
    grep -q 'open -na' "$diag/help.txt"
    open -na "$fixture/prefix/share/applications/Ghostty.app" --env "HOME=$HOME" --env "XDG_CONFIG_HOME=$XDG_CONFIG_HOME" --args --config-default-files=false --title=custom-ci-ok -e /bin/sh -c 'printf "custom-ci-ok\n"; sleep 120'
    printf 'Opened Ghostty; searching for titled terminal window and screenshot\n'
    cat > "$diag/window.swift" <<'SWIFT'
import Cocoa
import Vision
let out = CommandLine.arguments[1]
var id: UInt32 = 0
for _ in 0..<60 {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    if let w = windows.first(where: { ($0[kCGWindowOwnerName as String] as? String) == "Ghostty" && ($0[kCGWindowName as String] as? String)?.contains("custom-ci-ok") == true }) {
        id = (w[kCGWindowNumber as String] as! NSNumber).uint32Value; try String(describing: w).write(toFile: out + "/window.txt", atomically: true, encoding: .utf8); break
    }
    Thread.sleep(forTimeInterval: 1)
}
guard id != 0 else { fatalError("no Ghostty custom-ci-ok window") }
Thread.sleep(forTimeInterval: 3)
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); p.arguments = ["-x", "-l", String(id), out + "/window.png"]; try p.run(); p.waitUntilExit()
guard p.terminationStatus == 0 else { fatalError("window screenshot denied") }
let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
try VNImageRequestHandler(url: URL(fileURLWithPath: out + "/window.png")).perform([request])
let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
try text.write(toFile: out + "/ocr.txt", atomically: true, encoding: .utf8); guard text.contains("custom-ci-ok") else { fatalError("screenshot lacks terminal marker") }
SWIFT
    swift "$diag/window.swift" "$diag" 2>&1 | tee "$diag/gui.log"
    pkill -f "$fixture/prefix/share/applications/Ghostty.app/Contents/MacOS/ghostty" || true
  fi
  printf 'GUI window and screenshot marker verified\n' > "$diag/result.txt"
}

summarize() {
  python3 - <<'PY'
import json, os, pathlib, urllib.request, runpy
m = runpy.run_path('.github/scripts/package-release.py'); tag, sha = os.environ['RELEASE_TAG'], os.environ['SOURCE_SHA']; results = {}
for platform in ('darwin', 'linux'):
    output = pathlib.Path(os.environ['RUNNER_TEMP']) / ('summary-' + platform)
    result = m['check'](type('Args', (), {'tag': tag, 'commit': sha, 'platform': platform, 'output_dir': str(output)})())
    if not result['exists']: raise SystemExit('missing or invalid ' + platform + ' release assets')
    results[platform] = result
lines = ['<!-- custom-builds:start -->', '## Custom ARM64 builds', '', 'Source: `' + sha + '`; release: `' + tag + '`.', '', 'GitHub Release assets: https://github.com/cybito/ghostty/releases/tag/' + tag, '']
for platform, result in results.items():
    lines.extend(['### ' + platform, ''])
    lines.extend('- [' + name + '](https://github.com/cybito/ghostty/releases/download/' + tag + '/' + name + ')' for name in result['assets']); lines.append('')
lines.append('<!-- custom-builds:end -->')
event = json.loads(pathlib.Path(os.environ['GITHUB_EVENT_PATH']).read_text()); url = 'https://api.github.com/repos/cybito/ghostty/releases/' + str(event['release']['id'])
headers = {'Authorization': 'Bearer ' + os.environ['GH_TOKEN'], 'Accept': 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28'}
with urllib.request.urlopen(urllib.request.Request(url, headers=headers)) as r: release = json.load(r)
assert release['tag_name'] == tag and not release['draft']
body = release['body'] or ''; start = '<!-- custom-builds:start -->'; end = '<!-- custom-builds:end -->'
assert body.count(start) == body.count(end) and body.count(start) <= 1, 'malformed custom-builds block'
block = '\n'.join(lines)
if start in body:
    before, tail = body.split(start, 1); _, after = tail.split(end, 1); body = before + block + after
else: body = body.rstrip() + '\n\n' + block + '\n'
request = urllib.request.Request(url, data=json.dumps({'body': body}).encode(), headers={**headers, 'Content-Type': 'application/json'}, method='PATCH')
with urllib.request.urlopen(request) as r: json.load(r)
PY
}

regressions() {
  export RELEASE_SCRIPT="$PWD/.github/scripts/custom-release.sh" RELEASE_HELPER="$helper"
  python3 - <<'PY'
import json, os, pathlib, runpy, shutil, subprocess, tempfile
from argparse import Namespace
from unittest.mock import patch
m = runpy.run_path(os.environ['RELEASE_HELPER'])
with tempfile.TemporaryDirectory() as temp:
    root = pathlib.Path(temp); repo = root / 'repo'; repo.mkdir()
    def git(*args): return subprocess.check_output(['git', '-C', str(repo), *args], stderr=subprocess.DEVNULL, text=True).strip()
    git('init'); git('config', 'user.name', 'Fixture'); git('config', 'user.email', 'fixture@example.invalid')
    script = repo / '.github/scripts/custom-release.sh'; script.parent.mkdir(parents=True); shutil.copy2(os.environ['RELEASE_SCRIPT'], script); shutil.copy2(os.environ['RELEASE_HELPER'], script.parent / 'package-release.py')
    workflow = repo / '.github/workflows/custom-release.yml'; workflow.parent.mkdir(); workflow.write_text('fixture\n'); (repo / 'build.zig.zon').write_text('.version = "1.3.2-dev",\n')
    git('add', '.'); git('commit', '-m', 'custom fixture'); sha = git('rev-parse', 'HEAD'); git('branch', 'custom'); git('update-ref', 'refs/remotes/origin/custom', sha); git('tag', 'v1.3.2-custom.1')
    event = root / 'event.json'; output = root / 'output'
    def validate(tag, success):
        event.write_text(json.dumps({'action': 'published', 'repository': {'full_name': 'cybito/ghostty'}, 'release': {'tag_name': tag, 'draft': False, 'assets': []}}))
        env = {**os.environ, 'GITHUB_EVENT_NAME': 'release', 'GITHUB_EVENT_PATH': str(event), 'GITHUB_OUTPUT': str(output)}
        result = subprocess.run(['bash', str(script), 'validate'], cwd=repo, env=env, capture_output=True); assert (result.returncode == 0) == success, result.stderr.decode()
    validate('v1.3.2-custom.1', True); validate('v1.3.2', False)
    marker = root / 'injection-marker'; validate('v1.3.2-custom.2;touch ' + str(marker), False); assert not marker.exists()
    git('checkout', '--orphan', 'upstream-only'); git('commit', '-m', 'unrelated upstream'); git('tag', 'v1.3.2-custom.2'); validate('v1.3.2-custom.2', False); git('checkout', 'custom')
    source = root / 'input'; (source / 'root/bin').mkdir(parents=True); (source / 'root/share').mkdir(); (source / 'root/bin/ghostty').write_bytes(b'fixture executable')
    (source / 'toolchains.json').write_text('{"zig":"0.16.0"}'); (source / 'README.md').write_text('fixture'); (source / 'LICENSE').write_text('fixture')
    package = root / 'package'; m['pack'](Namespace(tag='v1.3.2-custom.1', commit=sha, platform='linux', input_dir=str(source), output_dir=str(package)))
    receipt = json.loads((package / 'release.json').read_text()); m['validate_receipt'](receipt, package)
    originals = sorted(p.name for p in package.iterdir()); names = [m['asset_name']('v1.3.2-custom.1', 'linux', n) for n in originals]
    assets_path = root / 'assets.json'; assets_path.write_text(json.dumps({'assets': [{'name': n, 'size': (package / o).stat().st_size} for n, o in zip(names, originals)]}))
    def fake(args, **kwargs):
        if args[:4] == ['gh', 'release', 'view', 'v1.3.2-custom.1']: return subprocess.CompletedProcess(args, 0, stdout=assets_path.read_bytes(), stderr=b'')
        if args[:3] == ['gh', 'release', 'download']:
            dest = pathlib.Path(args[args.index('--dir') + 1])
            for n in args:
                if n in names: shutil.copy2(package / n.removeprefix('v1.3.2-custom.1-linux-'), dest / n)
            return subprocess.CompletedProcess(args, 0, stdout=b'', stderr=b'')
        raise AssertionError(args)
    with patch.object(subprocess, 'run', side_effect=fake):
        full = m['check'](Namespace(tag='v1.3.2-custom.1', commit=sha, platform='linux', output_dir=str(root / 'full'))); assert full['exists'] and len(full['assets']) == 3
    # Publish resumes from a partial set, verifies existing bytes, uploads only
    # absent assets, then independently downloads and validates the complete set.
    partial_assets = [{'name': names[0], 'size': (package / originals[0]).stat().st_size}]
    assets_path.write_text(json.dumps({'assets': partial_assets}))
    uploaded = []
    def resume_run(args, **kwargs):
        if args[:4] == ['gh', 'release', 'view', 'v1.3.2-custom.1']:
            return subprocess.CompletedProcess(args, 0, stdout=assets_path.read_bytes(), stderr=b'')
        if args[:3] == ['gh', 'release', 'download']:
            dest = pathlib.Path(args[args.index('--dir') + 1])
            for n in args:
                if n in names: shutil.copy2(package / n.removeprefix('v1.3.2-custom.1-linux-'), dest / n)
            return subprocess.CompletedProcess(args, 0, stdout=b'', stderr=b'')
        if args[:3] == ['gh', 'release', 'upload']:
            assert '--clobber' not in args
            path = pathlib.Path(args[4]); uploaded.append(path.name)
            original = path.name.removeprefix('v1.3.2-custom.1-linux-')
            partial_assets.append({'name': path.name, 'size': (package / original).stat().st_size})
            assets_path.write_text(json.dumps({'assets': partial_assets}))
            return subprocess.CompletedProcess(args, 0, stdout=b'', stderr=b'')
        raise AssertionError(args)
    with patch.object(subprocess, 'run', side_effect=resume_run):
        resumed = m['publish'](Namespace(tag='v1.3.2-custom.1', commit=sha, platform='linux', directory=str(package)))
    assert len(uploaded) == 2 and len(resumed['assets']) == 3
    bad = [{'name': names[0] + '.wrong', 'size': (package / originals[0]).stat().st_size}]; assets_path.write_text(json.dumps({'assets': bad}))
    with patch.object(subprocess, 'run', side_effect=fake):
        try: m['check'](Namespace(tag='v1.3.2-custom.1', commit=sha, platform='linux', output_dir=str(root / 'unknown')))
        except ValueError: pass
        else: raise AssertionError('accepted unknown same-platform asset')
    assets_path.write_text(json.dumps({'assets': [{'name': n, 'size': (package / o).stat().st_size} for n, o in zip(names, originals)]}))
    def corrupt(args, **kwargs):
        result = fake(args, **kwargs)
        if args[:3] == ['gh', 'release', 'download']:
            d = pathlib.Path(args[args.index('--dir') + 1]); next(d.iterdir()).write_bytes(b'altered')
        return result
    with patch.object(subprocess, 'run', side_effect=corrupt):
        try: m['check'](Namespace(tag='v1.3.2-custom.1', commit=sha, platform='linux', output_dir=str(root / 'corrupt')))
        except ValueError: pass
        else: raise AssertionError('accepted mismatching downloaded bytes')
    import tarfile
    extracted = root / 'extracted'; extracted.mkdir()
    with tarfile.open(package / receipt['files'][0]['name'], 'r:gz') as archive: archive.extractall(extracted, filter='data')
    staged = next(extracted.iterdir()); installer = staged / 'install.sh'; prefix = root / 'prefix'
    subprocess.run([str(installer), '--prefix', str(prefix)], check=True); subprocess.run([str(installer), '--prefix', str(prefix)], check=True)
    conflict = root / 'conflict'; doc = conflict / 'share/doc/ghostty-custom'; doc.mkdir(parents=True); (doc / 'README.md').write_text('unknown local file')
    rejected = subprocess.run([str(installer), '--prefix', str(conflict)], capture_output=True); assert rejected.returncode != 0 and not (conflict / 'bin/ghostty').exists()
    receipt['source_repo'] = 'https://example.invalid/wrong.git'
    try: m['validate_receipt'](receipt, package)
    except ValueError: pass
    else: raise AssertionError('accepted wrong source identity')
print('Ghostty release asset regressions passed')
PY
}

case "${1:-}" in
  tools) shift; install_tools "$@";;
  validate) validate;;
  regressions) regressions;;
  build) shift; build "$@";;
  smoke) shift; smoke "$@";;
  summarize) summarize;;
  *) echo 'expected tools, validate, build, smoke, summarize, or regressions' >&2; exit 2;;
esac
