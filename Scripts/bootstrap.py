#!/usr/bin/env python3
"""Fetch pinned, SHA-256-verified MPVKit binaries; keep only iPhone and simulator slices."""
import concurrent.futures
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'Vendor/MPVKit-Package.upstream.swift').read_text()
DEST = ROOT / 'Vendor/MPVKit'
CACHE = ROOT / '.downloads'
CACHE.mkdir(exist_ok=True)
DEST.mkdir(exist_ok=True)
artifacts = re.findall(r'\.binaryTarget\(\s*name: "([^"]+)",\s*url: "([^"]+)",\s*checksum: "([^"]+)"\s*\)', SOURCE)
artifacts = [a for a in artifacts if a[0].endswith('-GPL') or not a[0].startswith(('Libmpv', 'Libav', 'Libsw', 'Libluajit'))]

def fetch(artifact):
    name, url, expected = artifact
    archive = CACHE / (name + '.zip')
    target = DEST / 'Artifacts' / name
    stamp = target / '.sha256'
    if stamp.exists() and stamp.read_text() == expected:
        return name, next(target.glob('*.xcframework')).relative_to(DEST).as_posix()
    if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
        subprocess.run(['curl', '-sSfL', '--retry', '2', '--connect-timeout', '15', '--max-time', '240', url, '-o', str(archive)], check=True)
    actual = hashlib.sha256(archive.read_bytes()).hexdigest()
    if actual != expected:
        raise RuntimeError(f'Checksum mismatch: {name}')
    if target.exists(): shutil.rmtree(target)
    target.mkdir(parents=True)
    with zipfile.ZipFile(archive) as z:
        framework = next(n.split('/')[0] for n in z.namelist() if '.xcframework/' in n)
        info_path = framework + '/Info.plist'
        info = plistlib.loads(z.read(info_path))
        slices = [s for s in info['AvailableLibraries'] if s['SupportedPlatform'] == 'ios' and s.get('SupportedPlatformVariant', '') in ('', 'simulator')]
        prefixes = tuple(framework + '/' + s['LibraryIdentifier'] + '/' for s in slices)
        for entry in z.infolist():
            if entry.filename.startswith(prefixes):
                # Reject traversal even though archives are upstream checksum-verified.
                if '..' in Path(entry.filename).parts: raise RuntimeError('Unsafe archive')
                z.extract(entry, target)
        info['AvailableLibraries'] = slices
        (target / framework).mkdir(exist_ok=True)
        (target / info_path).write_bytes(plistlib.dumps(info))
    stamp.write_text(expected)
    print(f'Verified {name}', flush=True)
    return name, (target / framework).relative_to(DEST).as_posix()

with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
    paths = dict(pool.map(fetch, artifacts))

# Keep upstream GPL source targets and their exact linker dependencies.
start = SOURCE.index('        .target(\n            name: "_MPVKit-GPL"')
end = SOURCE.index('        .binaryTarget(', start)
source_targets = SOURCE[start:end]
source_targets = source_targets.replace('.target(name: "Libluajit", condition: .when(platforms: [.macOS])),', '')
binary_targets = ',\n'.join(f'        .binaryTarget(name: "{name}", path: "{path}")' for name, path in paths.items())
manifest = '''// swift-tools-version:5.9
// MPVKit GPL dependencies pinned at d9194243bdc68b87d8989376ab52aee7da6c8e0b.
// Only Apple iOS slices retained; all binaries verified against upstream SHA-256.
import PackageDescription
let package = Package(name: "MPVKit", platforms: [.iOS(.v17)],
    products: [.library(name: "MPVKit-GPL", targets: ["_MPVKit-GPL"])],
    targets: [
''' + source_targets + binary_targets + '\n    ])\n'
(DEST / 'Package.swift').write_text(manifest)
print('MPVKit ready. Generate the Xcode project with xcodegen generate.', flush=True)
