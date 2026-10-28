#!/usr/bin/env python3
"""Isolated SMB2 fixture server. pip install impacket; defaults to loopback:1445."""
from pathlib import Path
import os
import shutil
import tempfile
from impacket import smbserver
from impacket.ntlm import compute_lmhash, compute_nthash

source=Path(__file__).resolve().parents[1]/'Resources'
fixture=tempfile.TemporaryDirectory(prefix='iina-smb-fixture-',dir=os.environ.get('IINA_QA_WORK_DIR'))
root=Path(fixture.name)
for name in ['Sample-SDR.mkv','Sample-HDR.mkv','Sample.ass']:
    shutil.copyfile(source/name,root/name)
shutil.copyfile(source/'Sample.ass',root/'Sample-SDR.ass')
folder=root/'中文目录'
folder.mkdir()
shutil.copyfile(source/'Sample-SDR.mkv',folder/'电影 #100% 空格.mkv')
with (root/'Large.bin').open('wb') as large:
    large.seek((1<<32)+1024)
    large.write(b'IINA-large-offset')
server=smbserver.SimpleSMBServer(listenAddress='127.0.0.1',listenPort=1445)
server.addShare('QA',str(root),'IINA Mobile generated test media')
server.setSMB2Support(True)
server.addCredential('iinaqa',0,compute_lmhash('fixture-only'),compute_nthash('fixture-only'))
server.setLogFile('')
print('SMB2 QA share ready on 127.0.0.1:1445',flush=True)
server.start()
