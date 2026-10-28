#!/usr/bin/env python3
"""Package an iOS device .app without any personal signing material."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('app', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
args.output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='iina-unsigned-') as temporary:
    payload = Path(temporary) / 'Payload'
    payload.mkdir()
    app = payload / args.app.name
    subprocess.run(['ditto', str(args.app), str(app)], check=True)
    for profile in app.rglob('embedded.mobileprovision'):
        profile.unlink()
    for signature in list(app.rglob('_CodeSignature')):
        if signature.is_dir():
            shutil.rmtree(signature)
    magic_numbers = [bytes.fromhex(value) for value in ['cffaedfe', 'feedfacf', 'cafebabe', 'bebafeca']]
    for path in app.rglob('*'):
        if not path.is_file():
            continue
        with path.open('rb') as stream:
            magic = stream.read(4)
        if magic in magic_numbers:
            signed = subprocess.run(['codesign', '-d', str(path)], capture_output=True)
            if signed.returncode == 0:
                subprocess.run(['codesign', '--remove-signature', str(path)], check=True)
    subprocess.run(['ditto', '-c', '-k', '--keepParent', str(payload), str(args.output.resolve())], check=True)
    with zipfile.ZipFile(args.output) as archive:
        assert archive.testzip() is None
        assert not any('_CodeSignature/' in name or name.endswith('.mobileprovision') for name in archive.namelist())
    signature = subprocess.run(['codesign', '-dv', str(app)], capture_output=True, text=True)
    assert signature.returncode != 0 and 'not signed' in signature.stderr
print(f'Unsigned package verified: {args.output}')
