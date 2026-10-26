#!/usr/bin/env python3
"""MAAS の `webhook` 電源ドライバから呼ばれる、Wake on LAN の小さなサービス(kigawa-net/infra#316、#317)。

MAAS には Wake on LAN の電源ドライバが無い。`webhook` ドライバ(power_on_uri / power_off_uri / power_query_uri)で、
この Rack 上の 127.0.0.1 のサービスを呼ぶ。サービスは、LAN にマジックパケットを送り、ping と DHCP のリースで、状態を返す。

  POST /wake?mac=<MAC>                       マジックパケットを送る(電源オン)。200 {"status": "sent"}
  POST /off?mac=<MAC>                        WoL では電源を切れない。何もしない。200 {"status": "unsupported"}
  GET  /status?mac=<MAC>[&ip=<IPv4>]...      ping が通れば {"status": "running"}、通らなければ {"status": "stopped"}
                                            (確かめる IP: ip= で渡されたもの + dhcpd.leases にある、その MAC の有効なリース)

MAAS の power_on_regex 既定は `status.*\\:.*running`、power_off_regex 既定は `status.*\\:.*stopped`(この応答と合う)。
127.0.0.1 だけで待ち受ける。環境変数: BIND(既定 127.0.0.1)、PORT(既定 5290)、BCAST(既定 192.168.1.255)、LEASES(既定 /var/lib/maas/dhcp/dhcpd.leases)
"""
import json
import os
import re
import socket
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

MAC_RE = re.compile(r"^[0-9A-Fa-f]{2}([:-][0-9A-Fa-f]{2}){5}$")
IPV4_RE = re.compile(r"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$")
LEASE_RE = re.compile(r"lease\s+(\d+\.\d+\.\d+\.\d+)\s*\{(.*?)\n\}", re.S)


def normalize_mac(mac):
    if not MAC_RE.match(mac or ""):
        raise ValueError("MAC の形が不正")
    return mac.replace("-", ":").lower()


def valid_ipv4(ip):
    m = IPV4_RE.match(ip or "")
    return bool(m) and all(0 <= int(g) <= 255 for g in m.groups())


def magic_packet(mac):
    raw = bytes.fromhex(normalize_mac(mac).replace(":", ""))
    return b"\xff" * 6 + raw * 16


def send_magic(mac, bcast):
    payload = magic_packet(mac)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        for port in (9, 7):
            s.sendto(payload, (bcast, port))
    finally:
        s.close()


def lease_ips(path, mac):
    """dhcpd.leases から、その MAC の有効(binding state active)なリースの IP を返す。"""
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return []
    want = normalize_mac(mac)
    latest = {}
    for ip, body in LEASE_RE.findall(text):
        hw = re.search(r"hardware ethernet\s+([0-9A-Fa-f:]+);", body)
        st = re.search(r"binding state\s+(\w+);", body)
        latest[ip] = (hw.group(1).lower() if hw else None, st.group(1) if st else None)  # 同じ IP は、後のブロックが新しい
    return sorted(ip for ip, (hw, st) in latest.items() if hw == want and st == "active")


def ping(ip):
    try:
        return subprocess.run(["ping", "-c", "1", "-W", "1", ip], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


class Handler(BaseHTTPRequestHandler):
    server_version = "maas-wol-webhook"
    bcast = os.environ.get("BCAST", "192.168.1.255")
    leases = os.environ.get("LEASES", "/var/lib/maas/dhcp/dhcpd.leases")

    def _reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _params(self):
        return parse_qs(urlparse(self.path).query)

    def _mac(self):
        vals = self._params().get("mac", [])
        if len(vals) != 1:
            raise ValueError("mac が 1 つ必要")
        return normalize_mac(vals[0])

    def do_POST(self):
        path = urlparse(self.path).path.rstrip("/")
        try:
            mac = self._mac()
        except ValueError as e:
            return self._reply(400, {"error": str(e)})
        if path == "/wake":
            send_magic(mac, self.bcast)
            self.log_message("wake %s -> %s", mac, self.bcast)
            return self._reply(200, {"status": "sent", "mac": mac})
        if path == "/off":
            self.log_message("off %s: WoL では電源を切れない(何もしない)", mac)
            return self._reply(200, {"status": "unsupported", "mac": mac})
        return self._reply(404, {"error": "not found"})

    def do_GET(self):
        path = urlparse(self.path).path.rstrip("/")
        if path != "/status":
            return self._reply(404, {"error": "not found"})
        try:
            mac = self._mac()
        except ValueError as e:
            return self._reply(400, {"error": str(e)})
        ips = [ip for ip in self._params().get("ip", []) if valid_ipv4(ip)]
        for ip in lease_ips(self.leases, mac):
            if ip not in ips:
                ips.append(ip)
        up = any(ping(ip) for ip in ips)
        return self._reply(200, {"status": "running" if up else "stopped", "mac": mac, "checked": ips})

    def log_message(self, fmt, *args):  # journald に出す(標準エラー)
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


def main():
    bind = os.environ.get("BIND", "127.0.0.1")
    port = int(os.environ.get("PORT", "5290"))
    if bind not in ("127.0.0.1", "::1", "localhost"):
        sys.exit("ABORT: BIND は、ループバックだけ(認証が無いため)")
    HTTPServer((bind, port), Handler).serve_forever()


if __name__ == "__main__":
    main()
