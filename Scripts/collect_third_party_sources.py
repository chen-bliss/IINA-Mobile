import concurrent.futures, hashlib, io, json, re, subprocess, tarfile, threading, time
from pathlib import Path
from urllib.parse import quote

root=Path('work/third-party-sources')
root.mkdir(parents=True,exist_ok=True)
lock=threading.Lock()
records={}
manifest_path=root/"manifest.json"
if manifest_path.exists():
    records={x["repository"]+"@"+x["requested_ref"]:x for x in json.loads(manifest_path.read_text()) if x["status"]=="ok"}

def run_json(endpoint):
    for attempt in range(3):
        try: return json.loads(subprocess.check_output(['gh','api',endpoint],timeout=60))
        except subprocess.SubprocessError:
            if attempt == 2: raise
            time.sleep(2)

def fetch(repo,ref):
    key=repo+'@'+ref
    with lock:
        if key in records: return []
        records[key]={'repository':repo,'requested_ref':ref,'status':'pending'}
    try:
        commit=run_json('repos/'+repo+'/commits/'+quote(ref,safe=''))['sha']
        filename=repo.replace('/','--')+'--'+commit[:12]+'.tar.gz'
        target=root/filename
        archive_url='https://codeload.github.com/'+repo+'/tar.gz/'+commit
        if not target.exists():
            subprocess.run(['curl','-sSfL','--retry','2','--connect-timeout','15','--max-time','240',archive_url,'-o',str(target)],check=True)
        data=target.read_bytes()
        found=[]
        with tarfile.open(fileobj=io.BytesIO(data),mode='r:gz') as archive:
            members=archive.getmembers()
            main=next((m for m in members if m.name.endswith('/Sources/BuildScripts/XCFrameworkBuild/main.swift')),None)
            if main:
                source=archive.extractfile(main).read().decode()
                version_section=source.split('var version:',1)[1].split('var url:',1)[0]
                url_section=source.split('var url:',1)[1].split('// for generate',1)[0]
                def cases(section):
                    result={}
                    for match in re.finditer(r'case \.(\w+)\s*:(.*?)(?=\n\s*case |\n\s*}\n)',section,re.S):
                        returned=re.search(r'return\s*"([^"]+)"',match.group(2))
                        if returned: result[match.group(1)]=returned.group(1)
                    return result
                versions=cases(version_section)
                for name,url in cases(url_section).items():
                    version=versions.get(name)
                    if not version: continue
                    match=re.match(r'https://github.com/([^/]+/[^/]+?)(?:\.git)?/?$',url)
                    if match: found.append((match.group(1),version))
                    match=re.match(r'https://github.com/(mpvkit/[^/]+)/releases/download/',url)
                    if match: found.append((match.group(1),version))
            # GitHub tarballs omit submodule contents. Fetch pinned gitlinks too.
            modules=next((m for m in members if m.name.count('/')==1 and m.name.endswith('/.gitmodules')),None)
            if modules:
                import configparser
                config=configparser.ConfigParser()
                config.read_string(archive.extractfile(modules).read().decode())
                tree=run_json('repos/'+repo+'/git/trees/'+commit+'?recursive=1')['tree']
                links={entry['path']:entry['sha'] for entry in tree if entry['mode']=='160000'}
                for section in config.sections():
                    path=config[section].get('path'); url=config[section].get('url','')
                    match=re.match(r'(?:https://github.com/|git@github.com:)([^/]+/[^/]+?)(?:\.git)?/?$',url)
                    if match and path in links: found.append((match.group(1),links[path]))
        with lock:
            records[key].update(commit=commit,archive=filename,sha256=hashlib.sha256(data).hexdigest(),source_url=archive_url,status='ok')
        print('Archived '+key,flush=True)
        return found
    except Exception as error:
        with lock: records[key].update(status='error',error=str(error))
        print('FAILED '+key+': '+str(error),flush=True)
        return []

pending=[('mpvkit/MPVKit','d9194243bdc68b87d8989376ab52aee7da6c8e0b'),('sahlberg/libsmb2','727feaaa6d0f4fed1bae57745fbc2c5db9a30e64'),('iina/iina','3c72aa0593d25d67e52e249b99708baf908bca43')]
if manifest_path.exists():
    pending += [(x["repository"],x["requested_ref"]) for x in json.loads(manifest_path.read_text()) if x["status"] != "ok"]
for item in records.values():
    item["source_url"]="https://codeload.github.com/"+item["repository"]+"/tar.gz/"+item["commit"]
pending += [('mpvkit/BuildShared', 'main'), ('abseil/abseil-cpp', '1315c900e1ddbb08a23e06eeb9a06450052ccb5e'), ('google/effcee', '08da24ec245a274fea3a128ba50068f163390565'), ('KhronosGroup/glslang', '7a47e2531cb334982b2a2dd8513dca0a3de4373d'), ('google/googletest', '1d17ea141d2c11b8917d2c7d029f1c4e2b9769b2'), ('google/re2', '4a8cee3dd3c3d81b6fe8b867811e193d5819df07'), ('KhronosGroup/SPIRV-Headers', 'b824a462d4256d720bebb40e78b9eb8f78bbb305'), ('KhronosGroup/SPIRV-Tools', '262bdab48146c937467f826699a40da0fdfc0f1a')]
while pending:
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
        results=list(pool.map(lambda item:fetch(*item),pending))
    pending=[item for result in results for item in result if item[0]+'@'+item[1] not in records]
    (root/'manifest.json').write_text(json.dumps(list(records.values()),indent=2)+'\n')
errors=[item for item in records.values() if item['status']!='ok']
print('Source archives:',len(records),'Errors:',len(errors),flush=True)
raise SystemExit(1 if errors else 0)
