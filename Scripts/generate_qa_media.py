#!/usr/bin/env python3
"""Generate original track-memory and native-PiP fixtures from Sample-SDR.mkv."""
from pathlib import Path
import subprocess
import tempfile

resources = Path(__file__).resolve().parents[1] / 'Resources'
with tempfile.TemporaryDirectory() as directory:
    subtitles = []
    for title, text in [('Main', 'English main subtitles'), ('SDH', '[Music] English SDH subtitles')]:
        path = Path(directory) / f'English-{title}.srt'
        path.write_text(f'1\n00:00:00,000 --> 00:00:30,000\n{text}\n')
        subtitles.append(path)
    subprocess.run(['ffmpeg', '-y', '-v', 'error', '-i', str(resources / 'Sample-SDR.mkv'),
                    '-i', str(subtitles[0]), '-i', str(subtitles[1]), '-map', '0:v', '-map', '0:a', '-map', '1', '-map', '2',
                    '-c', 'copy', '-c:s', 'srt', '-metadata:s:s:0', 'language=eng', '-metadata:s:s:0', 'title=English Main',
                    '-metadata:s:s:1', 'language=eng', '-metadata:s:s:1', 'title=English SDH', str(resources / 'QA-Tracks.mkv')], check=True)
subprocess.run(['ffmpeg', '-y', '-v', 'error', '-i', str(resources / 'Sample-SDR.mkv'), '-map', '0:v', '-map', '0:a',
                '-c', 'copy', '-movflags', '+faststart', str(resources / 'QA-PiP.mp4')], check=True)
