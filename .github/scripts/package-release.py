#!/usr/bin/env python3
"""Ghostty install-package OCI contract. Registry targets cannot be overridden."""
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
PACKAGE = 'git.cybit.top/cybit/ias-ghostty'
TYPE = 'application/vnd.cybito.install-package.v1'
TAG = re.compile(r'v[0-9]+\.[0-9]+\.[0-9]+-custom\.[1-9][0-9]*\Z')
SHA = re.compile(r'[0-9a-f]{40}\Z')
DIGEST = re.compile(r'sha256:[0-9a-f]{64}\Z')
FIELDS = {'schema', 'project', 'source_repo', 'source_commit', 'release_tag', 'platform', 'architecture', 'toolchains', 'files'}


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


def identity(tag, commit, platform):
    require(TAG.fullmatch(tag) and SHA.fullmatch(commit), 'invalid tag or source SHA')
    require(platform in ('darwin', 'linux'), 'invalid platform')
    return {'schema': 1, 'project': PROJECT, 'source_repo': SOURCE, 'source_commit': commit,
            'release_tag': tag, 'platform': platform, 'architecture': 'arm64'}


def validate_receipt(receipt, directory):
    require(set(receipt) == FIELDS, 'unexpected release.json fields')
    require(type(receipt['schema']) is int and receipt['schema'] == 1, 'invalid schema')
    expected = identity(receipt['release_tag'], receipt['source_commit'], receipt['platform'])
    require(all(receipt[k] == v for k, v in expected.items()), 'release identity mismatch')
    require(isinstance(receipt['toolchains'], dict) and receipt['toolchains'] and
            all(isinstance(k, str) and isinstance(v, str) and v for k, v in receipt['toolchains'].items()), 'invalid toolchains')
    names = set()
    require(isinstance(receipt['files'], list) and receipt['files'], 'missing payload')
    for item in receipt['files']:
        require(set(item) == {'name', 'sha256', 'size'}, 'invalid file record')
        name = item['name']
        require(isinstance(name, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', name) and name not in names and
                name not in ('release.json', 'SHA256SUMS'), 'unsafe or duplicate filename')
        names.add(name)
        path = directory / name
        require(path.is_file() and not path.is_symlink(), 'missing regular payload file')
        require(type(item['size']) is int and path.stat().st_size == item['size'] and sha(path) == item['sha256'], 'payload hash/size mismatch')
    expected_name = f"ghostty-{receipt['release_tag']}-{receipt['platform']}-arm64.{'dmg' if receipt['platform'] == 'darwin' else 'tar.gz'}"
    require(names == {expected_name}, 'unexpected Ghostty payload set')
    checksums = ''.join(f"{sha(directory / name)}  {name}\n" for name in sorted(names | {'release.json'}))
    require((directory / 'SHA256SUMS').read_text() == checksums, 'SHA256SUMS mismatch')
    return names | {'release.json', 'SHA256SUMS'}


# A two-pass installer refuses all conflicts before copying anything. No config,
# service, package manager, or system Applications directory is touched.
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


def media(name):
    if name == 'release.json': return 'application/json'
    if name == 'SHA256SUMS': return 'text/plain'
    if name.endswith('.tar.gz'): return 'application/gzip'
    return 'application/octet-stream'


def fetch_manifest(reference, config):
    return run(['oras', 'manifest', 'fetch', '--registry-config', str(config), reference])


def verify(reference, out, config):
    require(reference.startswith(PACKAGE + '@') and DIGEST.fullmatch(reference.split('@')[-1]), 'verification requires this package digest reference')
    require(not out.exists() or not any(out.iterdir()), 'verification output must be empty')
    out.mkdir(parents=True, exist_ok=True)
    raw = fetch_manifest(reference, config)
    require('sha256:' + hashlib.sha256(raw).hexdigest() == reference.split('@')[1], 'manifest byte digest mismatch')
    manifest = json.loads(raw)
    require(manifest.get('schemaVersion') == 2 and manifest.get('artifactType') == TYPE, 'wrong artifact type')
    layers = manifest.get('layers', [])
    names = set()
    with tempfile.TemporaryDirectory() as temp:
        for descriptor in [manifest['config'], *layers]:
            digest = descriptor['digest']
            require(DIGEST.fullmatch(digest), 'invalid descriptor digest')
            blob = Path(temp) / digest.split(':')[1]
            run(['oras', 'blob', 'fetch', '--registry-config', str(config), '--output', str(blob), PACKAGE + '@' + digest])
            require(blob.stat().st_size == descriptor['size'] and 'sha256:' + sha(blob) == digest, 'OCI blob mismatch')
            if descriptor in layers:
                name = descriptor.get('annotations', {}).get('org.opencontainers.image.title', '')
                require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', name) and name not in names, 'unsafe layer title')
                require(descriptor['mediaType'] == media(name), 'incorrect layer media type')
                names.add(name)
        run(['oras', 'pull', '--registry-config', str(config), '--output', str(out), reference])
    receipt = json.loads((out / 'release.json').read_text())
    expected = validate_receipt(receipt, out)
    require(names == expected and {p.name for p in out.iterdir()} == expected, 'unexpected OCI layers or pulled files')
    for descriptor in layers:
        path = out / descriptor['annotations']['org.opencontainers.image.title']
        require('sha256:' + sha(path) == descriptor['digest'] and path.stat().st_size == descriptor['size'], 'independent pull mismatch')
    annotations = manifest.get('annotations', {})
    require(annotations.get('org.opencontainers.image.source') == SOURCE and
            annotations.get('org.opencontainers.image.revision') == receipt['source_commit'] and
            annotations.get('org.opencontainers.image.version') == receipt['release_tag'], 'source annotations mismatch')
    return receipt


def existing(tag, commit, platform, out, config):
    expected = identity(tag, commit, platform)
    reference = f'{PACKAGE}:{tag}-{platform}-arm64'
    result = subprocess.run(['oras', 'manifest', 'fetch', '--registry-config', str(config), reference], capture_output=True)
    if result.returncode:
        error = result.stderr.decode(errors='replace')
        missing = re.search(r'\b(?:MANIFEST_UNKNOWN|NAME_UNKNOWN|manifest_unknown|name_unknown)\b', error)
        require(missing and not re.search(r'(?i)unauthorized|denied|timeout|tls|connection', error), error)
        return {'exists': False}
    digest = 'sha256:' + hashlib.sha256(result.stdout).hexdigest()
    immutable = PACKAGE + '@' + digest
    receipt = verify(immutable, out, config)
    require(all(receipt[k] == v for k, v in expected.items()), 'existing tag belongs to a different release identity')
    return {'exists': True, 'reference': immutable}


def publish(args):
    directory, config = absolute(args.directory), absolute(args.registry_config)
    receipt = json.loads((directory / 'release.json').read_text())
    names = validate_receipt(receipt, directory)
    with tempfile.TemporaryDirectory() as temp:
        prior = existing(receipt['release_tag'], receipt['source_commit'], receipt['platform'], Path(temp) / 'prior', config)
        if prior['exists']:
            old = Path(temp) / 'prior'
            require(all(sha(old / n) == sha(directory / n) for n in names), 'refusing overwrite of different published bytes')
            return {'reference': prior['reference'], 'digest': prior['reference'].split('@')[1]}
        layout = Path(temp) / 'layout'
        blobs = layout / 'blobs/sha256'
        blobs.mkdir(parents=True)
        def blob(raw, kind, title=None):
            digest = hashlib.sha256(raw).hexdigest()
            (blobs / digest).write_bytes(raw)
            descriptor = {'mediaType': kind, 'digest': 'sha256:' + digest, 'size': len(raw)}
            if title: descriptor['annotations'] = {'org.opencontainers.image.title': title}
            return descriptor
        created = run(['git', 'show', '-s', '--format=%cI', receipt['source_commit']]).decode().strip()
        # Normalize UTC instead of preserving the author's timezone offset.
        from datetime import datetime, timezone
        created = datetime.fromisoformat(created).astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        config_descriptor = blob(b'{}', 'application/vnd.oci.empty.v1+json')
        manifest = {'schemaVersion': 2, 'mediaType': 'application/vnd.oci.image.manifest.v1+json', 'artifactType': TYPE,
                    'config': config_descriptor, 'layers': [blob((directory / n).read_bytes(), media(n), n) for n in sorted(names)],
                    'annotations': {'org.opencontainers.image.created': created, 'org.opencontainers.image.source': SOURCE,
                                    'org.opencontainers.image.revision': receipt['source_commit'], 'org.opencontainers.image.version': receipt['release_tag']}}
        desc = blob(encoded(manifest), manifest['mediaType'])
        tag = f"{receipt['release_tag']}-{receipt['platform']}-arm64"
        desc['annotations'] = {'org.opencontainers.image.ref.name': tag}
        (layout / 'oci-layout').write_bytes(encoded({'imageLayoutVersion': '1.0.0'}))
        (layout / 'index.json').write_bytes(encoded({'schemaVersion': 2, 'manifests': [desc]}))
        late = existing(receipt['release_tag'], receipt['source_commit'], receipt['platform'], Path(temp) / 'late', config)
        if late['exists']:
            old = Path(temp) / 'late'
            require(all(sha(old / n) == sha(directory / n) for n in names), 'refusing overwrite of bytes published during this build')
            return {'reference': late['reference'], 'digest': late['reference'].split('@')[1]}
        run(['oras', 'cp', '--from-oci-layout', '--to-registry-config', str(config), str(layout) + ':' + tag, PACKAGE + ':' + tag])
        reference = PACKAGE + '@' + desc['digest']
        verified = verify(reference, Path(temp) / 'verified', config)
        require(verified == receipt, 'uploaded receipt differs')
        return {'reference': reference, 'digest': desc['digest']}


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
    p.add_argument('--registry-config', required=True)
    p = commands.add_parser('verify')
    p.add_argument('--reference', required=True)
    p.add_argument('--output-dir', required=True)
    args = parser.parse_args()
    if args.command == 'pack': result = pack(args)
    elif args.command == 'publish': result = publish(args)
    else:
        with tempfile.TemporaryDirectory() as temp:
            config = Path(temp) / 'anonymous.json'
            config.write_text('{"auths":{}}')
            config.chmod(0o600)
            if args.command == 'verify': result = verify(args.reference, absolute(args.output_dir), config)
            else: result = existing(args.tag, args.commit, args.platform, absolute(args.output_dir), config)
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr.decode(errors='replace'), file=sys.stderr)
        sys.exit(1)
