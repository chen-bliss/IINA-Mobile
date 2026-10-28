#!/usr/bin/env python3
"""Generate an original app icon and SDR/HDR10 test clips (requires ffmpeg)."""
from array import array
from pathlib import Path
import math
import struct
import subprocess
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
assets = ROOT / 'App/Assets.xcassets'
(assets / 'AppIcon.appiconset').mkdir(parents=True, exist_ok=True)
def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
rows = bytearray()
for y in range(1024):
    rows.append(0)
    for x in range(1024):
        glow = max(0, 1 - math.hypot(x-330, y-250)/1000)
        color = (int(14+10*glow), int(22+18*glow), int(31+20*glow))
        dx,dy=max(abs(x-512)-267,0),max(abs(y-480)-170,0)
        distance=math.hypot(dx,dy)-85
        if abs(distance)<11 and 149<x<875 and 214<y<746: color=(99,227,205)
        if 436<=x<=650 and abs(y-480)<(650-x)*130/214: color=(116,238,215)
        if 386<x<638 and 794<y<816: color=(99,227,205)
        rows.extend(color)
png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',1024,1024,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(rows))+chunk(b'IEND',b'')
(assets/'AppIcon.appiconset/AppIcon.png').write_bytes(png)
(assets/'Contents.json').write_text('{"info":{"author":"xcode","version":1}}')
(assets/'AppIcon.appiconset/Contents.json').write_text('{"images":[{"filename":"AppIcon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}')

resources=ROOT/'Resources'
resources.mkdir(exist_ok=True)
subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-f','lavfi','-i','smptebars=size=960x540:rate=24','-f','lavfi','-i','sine=frequency=440:sample_rate=48000','-t','30','-c:v','libx264','-pix_fmt','yuv420p','-crf','22','-c:a','aac','-b:a','64k','-y',str(resources/'Sample-SDR.mkv')],check=True)

w,h=960,540
bars=[(203,203,203),(203,203,0),(0,203,203),(0,203,0),(203,0,203),(203,0,0),(0,0,203),(6,6,6)]
def pq(nits):
    n=(nits/10000)**(2610/16384)
    return ((3424/4096+2413/128*n)/(1+2392/128*n))**(2523/32)
planes=[array('H'),array('H'),array('H')]
for y in range(h):
    for x in range(w):
        nits=bars[x//120] if y<360 else (1000*x/(w-1),)*3
        r,g,b=map(pq,nits)
        luma=.2627*r+.6780*g+.0593*b
        planes[0].append(round(64+876*luma))
        if x%2==0 and y%2==0:
            planes[1].append(round(512+896*(b-luma)/(2*(1-.0593))))
            planes[2].append(round(512+896*(r-luma)/(2*(1-.2627))))
with tempfile.TemporaryDirectory() as temp:
    raw=Path(temp)/'frame.yuv'
    raw.write_bytes(b''.join(p.tobytes() for p in planes))
    subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-f','rawvideo','-pixel_format','yuv420p10le','-video_size','960x540','-framerate','24','-stream_loop','-1','-i',str(raw),'-f','lavfi','-i','sine=frequency=660:sample_rate=48000','-t','30','-c:v','libx265','-pix_fmt','yuv420p10le','-x265-params','log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400','-crf','22','-c:a','aac','-b:a','64k','-y',str(resources/'Sample-HDR.mkv')],check=True)
print('Created icon and 30-second SDR/HDR10 clips.')
