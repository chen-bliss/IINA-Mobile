#!/usr/bin/env python3
"""Isolated UPnP AVTransport receiver for integration tests; loopback only."""
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET
import subprocess
import socket
import threading
from urllib.parse import urlsplit

STATE = {"uri": "", "position": "00:00:00", "state": "STOPPED"}
SAMPLE = Path(__file__).resolve().parents[1] / "Resources" / "QA-PiP.mp4"
TYPE = "urn:schemas-upnp-org:service:AVTransport:1"

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def write_xml(self, body, status=200):
        data = body.encode()
        self.send_response(status); self.send_header("Content-Type", "text/xml; charset=utf-8")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        if self.path != "/device.xml": self.send_error(404); return
        self.write_xml(f'<root><device><friendlyName>QA Renderer</friendlyName><serviceList><service><serviceType>{TYPE}</serviceType><controlURL>/control</controlURL></service></serviceList></device></root>')
    def do_POST(self):
        if self.path != "/control": self.send_error(404); return
        action = self.headers.get("SOAPACTION", "").strip('"').split("#")[-1]
        try:
            root = ET.fromstring(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
            values = {node.tag.split("}")[-1]: (node.text or "") for node in root.iter()}
            if action == "SetAVTransportURI":
                uri = values["CurrentURI"]
                wifi = subprocess.check_output(["ipconfig", "getifaddr", "en0"], text=True).strip()
                parsed = urlsplit(uri)
                assert parsed.scheme == "http" and parsed.hostname == wifi
                with urlopen(Request(uri, headers={"Range": "bytes=0-31"}), timeout=10) as response:
                    header = response.read()
                    assert response.status == 206 and (header == SAMPLE.read_bytes()[:32] or header[4:8] == b"ftyp")
                STATE["uri"] = uri; STATE["position"] = "00:00:00"
            elif action == "Play": STATE["state"] = "PLAYING"
            elif action == "Pause": STATE["state"] = "PAUSED_PLAYBACK"
            elif action == "Stop": STATE["state"] = "STOPPED"
            elif action == "Seek": STATE["position"] = values["Target"]
            elif action not in ("GetPositionInfo", "GetTransportInfo"): raise ValueError("unsupported")
            extra = ""
            if action == "GetPositionInfo": extra = f'<RelTime>{STATE["position"]}</RelTime><TrackDuration>00:00:30</TrackDuration>'
            if action == "GetTransportInfo": extra = f'<CurrentTransportState>{STATE["state"]}</CurrentTransportState>'
            self.write_xml(f'<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:{action}Response xmlns:u="{TYPE}">{extra}</u:{action}Response></s:Body></s:Envelope>')
        except Exception:
            self.write_xml('<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault><detail><errorDescription>QA request failed</errorDescription></detail></s:Fault></s:Body></s:Envelope>', 500)

def discovery():
    wifi = subprocess.check_output(["ipconfig", "getifaddr", "en0"], text=True).strip()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("", 1900))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, socket.inet_aton("239.255.255.250") + socket.inet_aton(wifi))
    while True:
        data, address = sock.recvfrom(8192)
        if data.startswith(b"M-SEARCH") and b"urn:schemas-upnp-org:device:MediaRenderer:1" in data:
            response = ("HTTP/1.1 200 OK\r\nLOCATION: http://" + wifi + ":18629/device.xml\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n").encode()
            sock.sendto(response, address)

if __name__ == '__main__':
    threading.Thread(target=discovery, daemon=True).start()
    print('DLNA QA renderer ready on 127.0.0.1:18629', flush=True)
    HTTPServer(('127.0.0.1', 18629), Handler).serve_forever()
