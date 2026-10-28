from pathlib import Path
import concurrent.futures, hashlib, json, subprocess, tarfile, tomllib

root=Path('work/third-party-sources')
records=json.loads((root/'manifest.json').read_text())
source=next(item for item in records if item['repository']=='quietvoid/dovi_tool')
with tarfile.open(root/source['archive']) as archive:
    member=next(m for m in archive.getmembers() if m.name.endswith('/dolby_vision/Cargo.lock'))
    packages=tomllib.loads(archive.extractfile(member).read().decode())['package']

def fetch(package):
    name=package['name']; version=package['version']; expected=package['checksum']
    url=f'https://static.crates.io/crates/{name}/{name}-{version}.crate'
    filename=f'crate--{name}-{version}.crate'
    path=root/filename
    if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest()!=expected:
        subprocess.run(['curl','-sSfL','--retry','3','--retry-all-errors','--connect-timeout','15','--max-time','90',url,'-o',str(path)],check=True)
    assert hashlib.sha256(path.read_bytes()).hexdigest()==expected, name
    return {'name':name,'version':version,'source_url':url,'archive':filename,'sha256':expected}

packages=[p for p in packages if p.get('source','').startswith('registry+')]
with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
    results=list(pool.map(fetch,packages))
(root/'rust-crates.json').write_text(json.dumps(results,indent=2)+'\n')
print(f'Verified {len(results)} Rust dependency source archives')
