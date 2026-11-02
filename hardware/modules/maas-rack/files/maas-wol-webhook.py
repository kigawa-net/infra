#!/usr/bin/env python3
"""MAAS の `webhook` 電源ドライバから呼ばれる、Wake on LAN の小さなサービス(kigawa-net/infra#316、#317、#416)。

MAAS には Wake on LAN の電源ドライバが無い。`webhook` ドライバ(power_on_uri / power_off_uri / power_query_uri)で、
この Rack 上の 127.0.0.1 のサービスを呼ぶ。サービスは、LAN にマジックパケットを送り、ping と DHCP のリースで、状態を返す。

  POST /wake?mac=<MAC>                       マジックパケットを送る(電源オン)。200 {"status": "sent"}
  POST /off?mac=<MAC>                        シャットダウンの表(SHUTDOWN_TARGETS)に、その MAC があるときだけ、
                                            対象ノードに SSH して shutdown を要求する(kigawa-net/infra#416)。
                                            ・表に無い MAC(表が無い・壊れている場合も含む): 200 {"status": "unsupported"}(従来どおり、何もしない)
                                            ・表にあり、ping が通らない(停止済み): 200 {"status": "stopped"}(SSH しない)
                                            ・表にあり、SSH が成功: 200 {"status": "stopping"}
                                            ・表にあり、SSH が失敗・タイムアウト: 502 {"error": ...}(MAAS は Power error として扱う)
  GET  /status?mac=<MAC>[&ip=<IPv4>]...      ping が通れば {"status": "running"}、通らなければ {"status": "stopped"}
                                            (確かめる IP: ip= で渡されたもの + dhcpd.leases にある、その MAC の有効なリース)
                                            **ただし、/wake の直後 WAKE_GRACE_SEC 秒(既定 300)は、ping が通らなくても running を返す。**
                                            MAAS は、電源オンの要求のあと、数十秒だけ、状態が off から on に変わるのを待つ。WoL の機械は、
                                            BIOS・PXE・カーネルの起動で、ネットワークに出るまで 1〜3 分かかる。猶予が無いと、MAAS が
                                            「BMC never transitioned from off to on」で、commission を中止する(2026-10-27、k8s-worker5)。

MAAS の power_on_regex 既定は `status.*\\:.*running`、power_off_regex 既定は `status.*\\:.*stopped`(この応答と合う)。
127.0.0.1 だけで待ち受ける。環境変数: BIND(既定 127.0.0.1)、PORT(既定 5290)、BCAST(既定 192.168.1.255)、LEASES(既定 /var/lib/maas/dhcp/dhcpd.leases)、WAKE_GRACE_SEC(既定 300。0 で無効)、
SHUTDOWN_TARGETS(既定 /etc/maas-wol-webhook/shutdown-targets.json)、SHUTDOWN_KEY(既定 /etc/maas-wol-webhook/shutdown.key)、
SHUTDOWN_KNOWN_HOSTS(既定 /etc/maas-wol-webhook/known_hosts)。

シャットダウンの表(JSON): {"<MAC 小文字コロン区切り>": {"host": "<IPv4>", "user": "<ユーザー名>"}}
SSH は、ノード側の forced command(authorized_keys の command=、sudo で shutdown だけ)が決める。ここではリモートコマンドを渡さない。
"""
import json
import os
import re
import socket
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

MAC_RE = re.compile(r"^[0-9A-Fa-f]{2}([:-][0-9A-Fa-f]{2}){5}$")
IPV4_RE = re.compile(r"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$")
LEASE_RE = re.compile(r"lease\s+(\d+\.\d+\.\d+\.\d+)\s*\{(.*?)\n\}", re.S)
# ssh の引数に渡す user。先頭の `-` を拒否する(オプションとして解釈されない)
SSH_USER_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")

DEFAULT_SHUTDOWN_TARGETS = "/etc/maas-wol-webhook/shutdown-targets.json"
DEFAULT_SHUTDOWN_KEY = "/etc/maas-wol-webhook/shutdown.key"
DEFAULT_SHUTDOWN_KNOWN_HOSTS = "/etc/maas-wol-webhook/known_hosts"
SSH_TIMEOUT_SEC = 15  # 対象ノードが応答しないとき、MAAS の要求を長く待たせないため


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


def probe(mac, extra_ips, leases_path):
    """状態を確かめる。ping が通る IP があれば up。確かめた IP の一覧も返す(/status と /off で同じ判定を使う)。"""
    ips = [ip for ip in extra_ips if valid_ipv4(ip)]
    for ip in lease_ips(leases_path, mac):
        if ip not in ips:
            ips.append(ip)
    return any(ping(ip) for ip in ips), ips


def warn(fmt, *args):
    sys.stderr.write("maas-wol-webhook: 警告: " + (fmt % args) + "\n")


def load_shutdown_targets(path):
    """シャットダウンの表を返す(MAC -> {host, user})。ファイルが無ければ {}。壊れていれば、警告を出して {}(unsupported として扱う)。"""
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except FileNotFoundError:
        return {}
    except OSError as e:
        warn("シャットダウンの表を読めない(%s): %s", path, e)
        return {}
    try:
        raw = json.loads(text)
        if not isinstance(raw, dict):
            raise ValueError("トップレベルが object ではない")
        table = {}
        for mac, ent in raw.items():
            key = normalize_mac(mac)
            if not isinstance(ent, dict):
                raise ValueError("%s の値が object ではない" % key)
            host, user = ent.get("host"), ent.get("user")
            if not valid_ipv4(host):
                raise ValueError("%s の host が IPv4 ではない" % key)
            if not (isinstance(user, str) and SSH_USER_RE.match(user)):
                raise ValueError("%s の user が不正" % key)
            table[key] = {"host": host, "user": user}
        return table
    except ValueError as e:  # json.JSONDecodeError も ValueError
        warn("シャットダウンの表が壊れている(%s): %s。unsupported として扱う", path, e)
        return {}


def ssh_shutdown(entry, key_path, known_hosts_path):
    """対象ノードに SSH して、シャットダウンを要求する。成功なら True。

    stderr の内容は、呼び出し元(HTTP 応答)には返さず、ログ(journald)にだけ出す。
    ssh の引数は、リストで渡す(shell を通さない)。user と host は、ここでも検証する(表の検証をすり抜けても、オプションにならないように)。
    """
    user, host = entry.get("user"), entry.get("host")
    if not (isinstance(user, str) and SSH_USER_RE.match(user)) or not valid_ipv4(host):
        raise ValueError("ssh の宛先が不正")
    argv = [
        "ssh",
        "-F", "/dev/null",  # ~/.ssh/config を読まない(ProtectHome でも、見えないが、念のため)
        "-i", key_path,
        "-o", "BatchMode=yes",
        "-o", "IdentitiesOnly=yes",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "UserKnownHostsFile=" + known_hosts_path,
        "-o", "ConnectTimeout=5",
        "-o", "ServerAliveInterval=5",
        "-o", "ServerAliveCountMax=2",
        "%s@%s" % (user, host),  # リモートコマンドは渡さない。ノード側の forced command が決める
    ]
    try:
        r = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=SSH_TIMEOUT_SEC)
    except (OSError, subprocess.TimeoutExpired) as e:
        sys.stderr.write("maas-wol-webhook: ssh が実行できない、または時間切れ(%s): %s\n" % (host, e))
        return False
    if r.returncode != 0:
        detail = r.stderr.decode("utf-8", errors="replace").strip()[:500]
        sys.stderr.write("maas-wol-webhook: ssh が失敗(%s、終了コード %d): %s\n" % (host, r.returncode, detail))
        return False
    return True


WAKES = {}  # MAC -> 最後に /wake を受けた時刻(time.monotonic)。このサービスの中だけ。MAAS は、電源オンの要求と、その後の問い合わせを、同じ Rack に出す


def now():
    return time.monotonic()


def wake_grace_sec():
    try:
        return float(os.environ.get("WAKE_GRACE_SEC", "300"))
    except ValueError:
        return 300.0


def shutdown_paths():
    return (
        os.environ.get("SHUTDOWN_TARGETS", DEFAULT_SHUTDOWN_TARGETS),
        os.environ.get("SHUTDOWN_KEY", DEFAULT_SHUTDOWN_KEY),
        os.environ.get("SHUTDOWN_KNOWN_HOSTS", DEFAULT_SHUTDOWN_KNOWN_HOSTS),
    )


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
            WAKES[mac] = now()
            self.log_message("wake %s -> %s", mac, self.bcast)
            return self._reply(200, {"status": "sent", "mac": mac})
        if path == "/off":
            WAKES.pop(mac, None)  # 猶予は終わりにする(以後、ping の結果だけで判定)
            return self._off(mac)
        return self._reply(404, {"error": "not found"})

    def _off(self, mac):
        targets_path, key_path, known_hosts_path = shutdown_paths()
        ent = load_shutdown_targets(targets_path).get(mac)
        if ent is None:
            self.log_message("off %s: シャットダウンの表に無い(何もしない)", mac)
            return self._reply(200, {"status": "unsupported", "mac": mac})
        up, checked = probe(mac, [ent["host"]], self.leases)
        if not up:
            self.log_message("off %s: 既に停止(ping が通らない)。SSH しない", mac)
            return self._reply(200, {"status": "stopped", "mac": mac, "checked": checked})
        self.log_message("off %s: %s@%s に shutdown を要求", mac, ent["user"], ent["host"])
        if ssh_shutdown(ent, key_path, known_hosts_path):
            return self._reply(200, {"status": "stopping", "mac": mac})
        return self._reply(502, {"error": "ssh によるシャットダウンが失敗(journalctl -u maas-wol-webhook を確認)", "mac": mac})

    def do_GET(self):
        path = urlparse(self.path).path.rstrip("/")
        if path != "/status":
            return self._reply(404, {"error": "not found"})
        try:
            mac = self._mac()
        except ValueError as e:
            return self._reply(400, {"error": str(e)})
        up, ips = probe(mac, self._params().get("ip", []), self.leases)
        grace = False
        if not up:
            woke = WAKES.get(mac)
            grace = woke is not None and now() - woke < wake_grace_sec()
        return self._reply(200, {"status": "running" if (up or grace) else "stopped", "mac": mac, "checked": ips, "wake_grace": grace})

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
