#!/usr/bin/env python3
"""Copy available Cargo crate notices into an auditable native supplement.

Run with Python 3.9+: python3 scripts/native-license-audit.py [--offline]
Does not modify app, lockfile, build configuration, or dist. Cargo may download
missing registry sources unless --offline is passed. This is not legal clearance.
"""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VERSION = json.loads((ROOT / 'package.json').read_text())['version']
TARGETS = [
    'aarch64-apple-darwin', 'x86_64-apple-darwin',
    'x86_64-pc-windows-msvc', 'x86_64-unknown-linux-gnu',
    'aarch64-linux-android', 'x86_64-linux-android',
    'aarch64-apple-ios', 'aarch64-apple-ios-sim',
]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def metadata(offline=False, target=None):
    command = ['cargo', 'metadata', '--manifest-path', 'src-tauri/Cargo.toml',
               '--locked', '--format-version', '1']
    if offline:
        command.append('--offline')
    if target:
        command.extend(['--filter-platform', target])
    return json.loads(subprocess.check_output(command, cwd=ROOT))


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n', encoding='utf-8')


def target_membership(data):
    """Conservative normal/build reachability; exclude dev-only edges."""
    packages = {p['id']: p for p in data['packages']}
    nodes = {n['id']: n for n in data['resolve']['nodes']}
    pending = [(data['resolve']['root'], 'normal')]
    reached = set()
    while pending:
        ident, use = pending.pop()
        if (ident, use) in reached:
            continue
        reached.add((ident, use))
        for dep in nodes[ident].get('deps', []):
            for kind in dep.get('dep_kinds', []):
                if kind['kind'] == 'dev':
                    continue
                proc_macro = any('proc-macro' in t['kind'] for t in packages[dep['pkg']]['targets'])
                next_use = 'build' if use == 'build' or kind['kind'] == 'build' or proc_macro else 'normal'
                pending.append((dep['pkg'], next_use))
    result = {}
    for ident, use in sorted(reached):
        result.setdefault(ident, {'dependencyUses': [], 'enabledFeatures': sorted(nodes[ident]['features'])})['dependencyUses'].append(use)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--offline', action='store_true', help='Use already downloaded Cargo registry sources only.')
    args = parser.parse_args()
    data = metadata(args.offline)
    memberships = {target: target_membership(metadata(True, target)) for target in TARGETS}
    output = ROOT / 'artifacts/native-notices'
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    packages, missing, copied = [], [], 0
    for package in sorted(data['packages'], key=lambda p: (p['name'], p['version'], p['id'])):
        if package['id'] in data['workspace_members']:
            continue  # Do not impose a license on product code.
        source_root = Path(package['manifest_path']).parent
        directory = 'crates/' + package['name'] + '-' + package['version']
        destination = output / directory
        destination.mkdir(parents=True)
        notices = set()
        for file in source_root.rglob('*'):
            if file.is_file() and re.match(r'^(licen[cs]e|copying|notice|copyright|authors)(?:[._-]|$)', file.name, re.I):
                notices.add(file)
        declared = package.get('license_file')
        if declared:
            declared_path = Path(declared)
            if not declared_path.is_absolute():
                declared_path = source_root / declared_path
            if declared_path.is_file() and source_root.resolve() in declared_path.resolve().parents:
                notices.add(declared_path)
        files = []
        for file in sorted(notices):
            relative = file.relative_to(source_root)
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            content = file.read_bytes()
            target.write_bytes(content)
            files.append({'path': directory + '/' + relative.as_posix(), 'bytes': len(content), 'sha256': digest(content)})
            copied += 1
        vcs, checksum = {}, None
        for name in ['.cargo_vcs_info.json', '.cargo-checksum.json']:
            file = source_root / name
            if file.exists():
                parsed = json.loads(file.read_text(encoding='utf-8'))
                if name == '.cargo_vcs_info.json':
                    vcs = parsed
                else:
                    checksum = parsed.get('package')
        entry = {
            'name': package['name'], 'version': package['version'],
            'declaredLicense': package.get('license'), 'declaredLicenseFile': bool(declared),
            'source': package['source'], 'repository': package.get('repository'),
            'crateSource': 'https://crates.io/crates/' + package['name'] + '/' + package['version'] if package['source'] and package['source'].startswith('registry+') else None,
            'crateArchive': 'https://crates.io/api/v1/crates/' + package['name'] + '/' + package['version'] + '/download' if package['source'] and package['source'].startswith('registry+') else None,
            'cargoArchiveChecksum': checksum, 'packageVcsInfo': vcs,
            'targetMembership': {target: members[package['id']] for target, members in memberships.items() if package['id'] in members},
            'copiedNotices': files,
        }
        packages.append(entry)
        if not files or not package.get('license'):
            missing.append({'name': package['name'], 'version': package['version'], 'declaredLicense': package.get('license'),
                            'reason': 'No available named/referenced license or notice file in downloaded crate' if not files else 'No declared license expression',
                            'crateSource': entry['crateSource'], 'repository': entry['repository']})
    manifest = {'scope': 'All non-workspace packages resolved from the locked Cargo project; includes build tooling and target-specific packages, not a binary linkage proof.',
                'cargoLockSha256': digest((ROOT / 'src-tauri/Cargo.lock').read_bytes()),
                'targetsExamined': TARGETS, 'packages': packages}
    write_json(output / 'inventory.json', manifest)
    write_json(output / 'missing-notices.json', {'scope': 'Report missing source-archive notice files/metadata; do not infer missing rights or fabricate license texts.', 'packages': missing})
    (output / 'README.txt').write_text(
        f'Shenzhen 3D {VERSION} native dependency attribution supplement\n\n'
        'Generated from src-tauri/Cargo.lock and cargo metadata --locked.\n'
        'inventory.json records actual resolved crate versions, declared licenses,\n'
        'registry archive checksums, repository/VCS information, available notice\n'
        'hashes, and normal/build dependency reachability for the listed targets.\n'
        'crates/ preserves available LICENSE/COPYING/NOTICE/COPYRIGHT/AUTHORS files\n'
        'from the downloaded sources. missing-notices.json records omissions.\n\n'
        'This conservative inventory includes build tools, proc macros and crates\n'
        'for other targets; it does not prove which code is linked in an installer.\n'
        'SDK/system libraries, downloaded native SDK binaries, installer runtimes,\n'
        'compiler runtime libraries and app-store terms need separate review.\n'
        'License expressions and copied files are upstream evidence, not legal\n'
        'clearance or a guarantee that each archive contains every required notice.\n'
        'No absent license text is replaced by a guessed generic license.\n\n'
        'This supplement accompanies the frontend THIRD_PARTY.txt/licenses bundle,\n'
        'which covers OCCT, LibreDWG, Draco and npm dependencies. It does not replace\n'
        'required corresponding-source delivery. Product licensing is unchanged.\n\n'
        'Reproduce: python3 scripts/native-license-audit.py [--offline]\n', encoding='utf-8')
    archive = ROOT / f'artifacts/releases/shenzhen-3d-{VERSION}-native-notices.zip'
    archive.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as bundle:
        for file in sorted(output.rglob('*')):
            if not file.is_file():
                continue
            info = zipfile.ZipInfo('native-notices/' + file.relative_to(output).as_posix(), date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            bundle.writestr(info, file.read_bytes())
    print(json.dumps({'packages': len(packages), 'copiedNoticeFiles': copied, 'missingNoticeOrLicenseEntries': len(missing),
                      'archive': str(archive.relative_to(ROOT)), 'archiveBytes': archive.stat().st_size,
                      'archiveSha256': digest(archive.read_bytes())}, indent=2))


if __name__ == '__main__':
    main()
