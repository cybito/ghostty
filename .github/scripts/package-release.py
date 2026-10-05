#!/usr/bin/env python3
"""Ghostty GitHub Release asset contract."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

PROJECT = 'ghostty'
SOURCE = 'https://github.com/cybito/ghostty.git'
TAG = re.compile(r'v[0-9]+\.[0-9]+\.[0-9]+-custom\.[1-9][0-9]*\Z')
SHA = re.compile(r'[0-9a-f]{40}\Z')
FIELDS = {'schema', 'project', 'source_repo', 'source_commit', 'release_tag', 'platform', 'architecture', 'toolchains', 'files'}
MAX_ASSETS = 1000
MAX_ASSET_SIZE = 2 * 1024**3


def require(ok, message):
    if not ok:
        raise ValueError(message)


def absolute(value):
    path = Path(value)
    require(path.is_absolute(), 'directory must be absolute')
    return path


def run(args, **kw):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kw).stdout


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def asset_name(tag, platform, filename):
    require(TAG.fullmatch(tag) and platform in ('darwin', 'linux'), 'invalid asset identity')
    require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', filename), 'unsafe asset filename')
    return f'{tag}-{platform}-{filename}'


def release_assets(tag):
    raw = run(['gh', 'release', 'view', tag, '--repo', 'cybito/ghostty', '--json', 'assets'])
    return json.loads(raw)['assets']


def identity(tag, commit, platform):
    require(TAG.fullmatch(tag) and SHA.fullmatch(commit), 'invalid tag or source SHA')
    require(platform in ('darwin', 'linux'), 'invalid platform')
    return {'schema': 1, 'project': PROJECT, 'source_repo': SOURCE, 'source_commit': commit,
            'release_tag': tag, 'platform': platform, 'architecture': 'arm64'}


def validate_receipt(receipt, directory):
    require(set(receipt) == FIELDS, 'unexpected release.json fields')
    expected = identity(receipt['release_tag'], receipt['source_commit'], receipt['platform'])
    require(all(receipt[k] == v for k, v in expected.items()), 'release identity mismatch')
    require(isinstance(receipt['toolchains'], dict) and receipt['toolchains'] and
            all(isinstance(k, str) and isinstance(v, str) and v for k, v in receipt['toolchains'].items()), 'invalid toolchains')
    names = set()
    require(isinstance(receipt['files'], list) and receipt['files'], 'missing payload')
    for item in receipt['files']:
        require(set(item) == {'name', 'sha256', 'size'}, 'invalid file record')
        name = item['name']
        require(isinstance(name, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', name) and name not in names and name not in ('release.json', 'SHA256SUMS'), 'unsafe or duplicate filename')
        names.add(name)
        path = directory / name
        require(path.is_file() and not path.is_symlink(), 'missing regular payload file')
        require(type(item['size']) is int and path.stat().st_size == item['size'] and sha(path) == item['sha256'], 'payload hash/size mismatch')
    expected_name = f"ghostty-{receipt['release_tag']}-{receipt['platform']}-arm64.{'dmg' if receipt['platform'] == 'darwin' else 'tar.gz'}"
    require(names == {expected_name}, 'unexpected Ghostty payload set')
    checksums = ''.join(f'{sha(directory / name)}  {name}\n' for name in sorted(names | {'release.json'}))
    require((directory / 'SHA256SUMS').read_text() == checksums, 'SHA256SUMS mismatch')
    return names | {'release.json', 'SHA256SUMS'}


INSTALLER = '''#!/bin/sh
set -eu
prefix="${HOME}/.local"
if [ "$#" -gt 0 ]; then
  [ "$#" -eq 2 ] && [ "$1" = --prefix ] || { echo 'usage: install.sh [--prefix /absolute/path]' >&2; exit 2; }
  prefix="$2"
fi
case "$prefix" in /*) ;; *) echo 'prefix must be absolute' >&2; exit 2;; esac
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
python3 - "$root" "$prefix" <<'PY'
import hashlib, os, pathlib, shutil, sys
root, prefix = map(pathlib.Path, sys.argv[1:])
source = root / 'root'
entries = sorted(source.rglob('*'))
def digest(p):
    h = hashlib.sha256()
    with p.open('rb') as f:
        for block in iter(lambda: f.read(1048576), b''): h.update(block)
    return h.digest()
for p in entries:
    d = prefix / p.relative_to(source)
    for parent in [prefix, *d.parents]:
        if parent == prefix.parent: break
        if parent.is_symlink(): raise SystemExit('refusing symlink parent: ' + str(parent))
    if os.path.lexists(d):
        same = (p.is_symlink() and d.is_symlink() and os.readlink(p) == os.readlink(d)) or (not p.is_symlink() and not d.is_symlink() and ((p.is_dir() and d.is_dir()) or (p.is_file() and d.is_file() and digest(p) == digest(d))))
        if not same: raise SystemExit('refusing to overwrite: ' + str(d))
for p in entries:
    d = prefix / p.relative_to(source)
    if os.path.lexists(d): continue
    d.parent.mkdir(parents=True, exist_ok=True)
    if p.is_symlink(): d.symlink_to(os.readlink(p))
    elif p.is_dir(): d.mkdir()
    else: shutil.copy2(p, d)
print('Installed into ' + str(prefix))
PY
'''


def pack(args):
    data = identity(args.tag, args.commit, args.platform)
    source, out = absolute(args.input_dir), absolute(args.output_dir)
    require(not out.exists() or not any(out.iterdir()), 'output must be empty')
    out.mkdir(parents=True, exist_ok=True)
    tools = json.loads((source / 'toolchains.json').read_text())
    name = f'ghostty-{args.tag}-{args.platform}-arm64'
    if args.platform == 'darwin':
        payload = out / (name + '.dmg')
        shutil.copy2(source / 'Ghostty.dmg', payload)
    else:
        payload = out / (name + '.tar.gz')
        with tempfile.TemporaryDirectory(dir=out) as temp:
            stage = Path(temp) / name
            stage.mkdir()
            shutil.copytree(source / 'root', stage / 'root', symlinks=True)
            require((stage / 'root/bin/ghostty').is_file() and (stage / 'root/share').is_dir(), 'incomplete Ghostty prefix')
            doc = stage / 'root/share/doc/ghostty-custom'
            doc.mkdir(parents=True, exist_ok=True)
            for path in source.glob('LICENSE*'):
                shutil.copy2(path, doc / path.name)
            for path in source.glob('NOTICE*'):
                shutil.copy2(path, doc / path.name)
            shutil.copy2(source / 'README.md', doc / 'README.md')
            (stage / 'README.md').write_text('Ghostty custom ARM64 package. Run ./install.sh --prefix /absolute/prefix. See root/share/doc/ghostty-custom.\n')
            (stage / 'install.sh').write_text(INSTALLER)
            (stage / 'install.sh').chmod(0o755)
            with tarfile.open(payload, 'w:gz') as archive:
                archive.add(stage, arcname=name)
    data.update(toolchains=tools, files=[{'name': payload.name, 'sha256': sha(payload), 'size': payload.stat().st_size}])
    (out / 'release.json').write_bytes(encoded(data))
    (out / 'SHA256SUMS').write_text(''.join(f'{sha(out / n)}  {n}\n' for n in sorted([payload.name, 'release.json'])))
    validate_receipt(data, out)
    return {'directory': str(out)}


def verify(directory, tag, commit, platform):
    receipt = json.loads((directory / 'release.json').read_text())
    expected = identity(tag, commit, platform)
    require(all(receipt.get(k) == v for k, v in expected.items()), 'asset receipt identity mismatch')
    names = validate_receipt(receipt, directory)
    require(all((directory / n).stat().st_size < MAX_ASSET_SIZE for n in names), 'GitHub per-file limit exceeded')
    return receipt, names


def check(args):
    identity(args.tag, args.commit, args.platform)
    directory = absolute(args.output_dir)
    require(not directory.exists() or not any(directory.iterdir()), 'output must be empty')
    directory.mkdir(parents=True, exist_ok=True)
    assets = release_assets(args.tag)
    originals = ('release.json', 'SHA256SUMS', f"ghostty-{args.tag}-{args.platform}-arm64.{'dmg' if args.platform == 'darwin' else 'tar.gz'}")
    expected = {asset_name(args.tag, args.platform, n): n for n in originals}
    present = {a['name']: a for a in assets}
    prefixes = [a['name'] for a in assets if a['name'].startswith(f'{args.tag}-{args.platform}-')]
    require(all(name in expected for name in prefixes), 'unexpected asset under platform release prefix')
    matched = [name for name in expected if name in present]
    if len(matched) == 0:
        return {'exists': False}
    with tempfile.TemporaryDirectory() as temp:
        download = Path(temp)
        run(['gh', 'release', 'download', args.tag, '--repo', 'cybito/ghostty', '--dir', str(download), *sum((['--pattern', n] for n in matched), [])])
        for unique in matched:
            local = download / unique
            require(local.is_file() and not local.is_symlink(), 'missing downloaded release asset')
            published = present[unique]
            require(local.stat().st_size == published['size'], 'release asset size metadata mismatch')
            shutil.copy2(local, directory / expected[unique])
    if len(matched) != len(expected):
        return {'exists': False, 'partial': True}
    receipt, names = verify(directory, args.tag, args.commit, args.platform)
    require(set(directory.iterdir()) == {directory / n for n in originals}, 'unexpected file in downloaded platform assets')
    return {'exists': True, 'assets': list(expected), 'receipt': receipt}


def publish(args):
    directory = absolute(args.directory)
    receipt, names = verify(directory, args.tag, args.commit, args.platform)
    assets = release_assets(args.tag)
    require(len(assets) <= MAX_ASSETS, 'GitHub release asset limit exceeded')
    expected = {asset_name(args.tag, args.platform, n): n for n in names}
    existing = {a['name']: a for a in assets}
    require(len(existing) + len([n for n in expected if n not in existing]) <= MAX_ASSETS, 'GitHub release asset limit exceeded')
    with tempfile.TemporaryDirectory() as temp:
        downloaded = Path(temp)
        for unique, original in expected.items():
            path = directory / original
            require(path.stat().st_size < MAX_ASSET_SIZE, 'GitHub per-file limit exceeded')
            if unique in existing:
                run(['gh', 'release', 'download', args.tag, '--repo', 'cybito/ghostty', '--dir', str(downloaded), '--pattern', unique])
                prior = downloaded / unique
                require(prior.is_file() and prior.stat().st_size == path.stat().st_size and sha(prior) == sha(path), 'refusing to overwrite different existing asset bytes')
            else:
                renamed = directory / unique
                shutil.copy2(path, renamed)
                try:
                    run(['gh', 'release', 'upload', args.tag, str(renamed), '--repo', 'cybito/ghostty'])
                finally:
                    renamed.unlink(missing_ok=True)
        check_args = argparse.Namespace(tag=args.tag, commit=args.commit, platform=args.platform, output_dir=str(Path(temp) / 'readback'))
        result = check(check_args)
        require(result.get('exists'), 'release asset readback failed')
        return {'assets': result['assets'], 'release_tag': args.tag, 'platform': args.platform}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for command in ('check', 'pack'):
        p = commands.add_parser(command)
        p.add_argument('--tag', required=True)
        p.add_argument('--commit', required=True)
        p.add_argument('--platform', choices=('darwin', 'linux'), required=True)
        p.add_argument('--output-dir', required=True)
        if command == 'pack': p.add_argument('--input-dir', required=True)
    p = commands.add_parser('publish')
    p.add_argument('--directory', required=True)
    p.add_argument('--tag', required=True)
    p.add_argument('--commit', required=True)
    p.add_argument('--platform', choices=('darwin', 'linux'), required=True)
    args = parser.parse_args()
    if args.command == 'pack': result = pack(args)
    elif args.command == 'publish': result = publish(args)
    else: result = check(args)
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr.decode(errors='replace'), file=sys.stderr)
        sys.exit(1)
