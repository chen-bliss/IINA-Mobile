#!/usr/bin/env python3
"""Package a signed device build, omitting redundant embedded static archives."""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

p=argparse.ArgumentParser()
p.add_argument('app',type=Path)
p.add_argument('output',type=Path)
p.add_argument('--identity',required=True,help='Apple Development signing identity or SHA-1')
p.add_argument('--work-dir',type=Path,default=Path('work'))
p.add_argument('--app-output',type=Path,help='Optionally keep the cleaned, signed app for device installation')
args=p.parse_args()
args.work_dir.mkdir(parents=True,exist_ok=True)
args.output.parent.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix='iina-package-',dir=args.work_dir) as temp:
    payload=Path(temp)/'Payload'
    payload.mkdir()
    app=payload/args.app.name
    subprocess.run(['ditto',str(args.app),str(app)],check=True)
    removed=[]
    for framework in (app/'Frameworks').glob('*.framework'):
        info=plistlib.loads((framework/'Info.plist').read_bytes())
        binary=framework/info['CFBundleExecutable']
        description=subprocess.check_output(['file','-b',str(binary)],text=True)
        if 'ar archive' in description:
            # These have already been linked into the executable. They are not dylibs.
            removed.append(framework.name)
            shutil.rmtree(framework)
    subprocess.run(['codesign','--force','--sign',args.identity,'--timestamp=none',
                    '--preserve-metadata=identifier,entitlements,flags','--generate-entitlement-der',str(app)],check=True)
    subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
    if args.app_output:
        args.app_output.parent.mkdir(parents=True,exist_ok=True)
        if args.app_output.exists(): shutil.rmtree(args.app_output)
        subprocess.run(['ditto',str(app),str(args.app_output)],check=True)
    subprocess.run(['ditto','-c','-k','--keepParent',str(payload),str(args.output.resolve())],check=True)
    print(f'Packaged {args.output.name}; omitted {len(removed)} redundant static frameworks.')
