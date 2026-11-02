"""files/maas-wol-webhook.py のテスト。マジックパケットの送信と ping は、差し替える(実機にも、ネットワークにも触れない)。
    python3 -I -m unittest hardware/modules/maas-rack/test_maas_wol_webhook.py
"""
import importlib.util
import json
import os
import shutil
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import HTTPServer
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("wol", os.path.join(HERE, "files", "maas-wol-webhook.py"))
wol = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wol)

MAC = "02:39:7a:2e:13:f0"

LEASES = """
lease 192.168.1.201 {
  starts 1 2026/10/26 10:00:00;
  binding state active;
  hardware ethernet 02:39:7a:2e:13:f0;
}
lease 192.168.1.202 {
  binding state active;
  hardware ethernet aa:bb:cc:dd:ee:01;
}
lease 192.168.1.203 {
  binding state free;
  hardware ethernet 02:39:7a:2e:13:f0;
}
lease 192.168.1.204 {
  binding state active;
  hardware ethernet 02:39:7a:2e:13:f0;
}
lease 192.168.1.204 {
  binding state free;
  hardware ethernet 02:39:7a:2e:13:f0;
}
"""


class Pure(unittest.TestCase):
    def test_magic_packet(self):
        p = wol.magic_packet(MAC)
        self.assertEqual(len(p), 102)
        self.assertEqual(p[:6], b"\xff" * 6)
        self.assertEqual(p[6:], bytes.fromhex(MAC.replace(":", "")) * 16)

    def test_normalize_mac(self):
        self.assertEqual(wol.normalize_mac("02-39-7A-2E-13-F0"), MAC)
        for bad in ("", "02:39:7a:2e:13", "zz:39:7a:2e:13:f0", "02:39:7a:2e:13:f0:00", None, "02:39:7a:2e:13:f0; rm"):
            with self.assertRaises(ValueError):
                wol.normalize_mac(bad)

    def test_valid_ipv4(self):
        self.assertTrue(wol.valid_ipv4("192.168.1.150"))
        for bad in ("", "192.168.1", "192.168.1.256", "a.b.c.d", "192.168.1.1; id", None):
            self.assertFalse(wol.valid_ipv4(bad))

    def test_lease_ips(self):
        with tempfile.NamedTemporaryFile("w", delete=False) as f:
            f.write(LEASES)
        try:
            # active で、その MAC のものだけ。同じ IP は、後のブロック(free)が新しいので、除く
            self.assertEqual(wol.lease_ips(f.name, MAC), ["192.168.1.201"])
        finally:
            os.unlink(f.name)

    def test_lease_ips_missing_file(self):
        self.assertEqual(wol.lease_ips("/nonexistent/dhcpd.leases", MAC), [])


NO_TABLE = "/nonexistent/shutdown-targets.json"  # 表が無い = /off は unsupported


class Server(unittest.TestCase):
    def setUp(self):
        wol.WAKES.clear()
        self.sent = []
        self.pings = {}
        self.leases = tempfile.NamedTemporaryFile("w", delete=False)
        self.leases.write(LEASES)
        self.leases.close()
        wol.Handler.leases = self.leases.name
        wol.Handler.bcast = "192.168.1.255"
        self.p1 = mock.patch.object(wol, "send_magic", lambda mac, bcast: self.sent.append((mac, bcast)))
        self.p2 = mock.patch.object(wol, "ping", lambda ip: self.pings.get(ip, False))
        self.p1.start()
        self.p2.start()
        # 実機の /etc の表に触れないよう、環境変数を、テスト用のパスに固定する
        self.env = mock.patch.dict(os.environ, {"SHUTDOWN_TARGETS": NO_TABLE, "SHUTDOWN_KEY": "/nonexistent/key", "SHUTDOWN_KNOWN_HOSTS": "/nonexistent/kh"})
        self.env.start()
        self.httpd = HTTPServer(("127.0.0.1", 0), wol.Handler)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.p1.stop()
        self.p2.stop()
        self.env.stop()
        os.unlink(self.leases.name)

    def req(self, method, path):
        r = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}", method=method, data=b"" if method == "POST" else None)
        try:
            with urllib.request.urlopen(r, timeout=5) as resp:
                return resp.status, json.load(resp)
        except urllib.error.HTTPError as e:
            return e.code, json.load(e)

    def test_wake(self):
        code, body = self.req("POST", f"/wake?mac={MAC}")
        self.assertEqual((code, body["status"]), (200, "sent"))
        self.assertEqual(self.sent, [(MAC, "192.168.1.255")])

    def test_wake_normalizes_mac(self):
        self.req("POST", "/wake?mac=02-39-7A-2E-13-F0")
        self.assertEqual(self.sent, [(MAC, "192.168.1.255")])

    def test_wake_bad_requests(self):
        for path in ("/wake", "/wake?mac=bad", f"/wake?mac={MAC}&mac={MAC}", "/wake?mac=02:39:7a:2e:13:f0;id"):
            code, _ = self.req("POST", path)
            self.assertEqual(code, 400, path)
        self.assertEqual(self.sent, [])

    def test_off_is_noop(self):
        code, body = self.req("POST", f"/off?mac={MAC}")
        self.assertEqual((code, body["status"]), (200, "unsupported"))
        self.assertEqual(self.sent, [])

    def test_status_running_by_ip_param(self):
        self.pings["192.168.1.150"] = True
        code, body = self.req("GET", f"/status?mac={MAC}&ip=192.168.1.150")
        self.assertEqual((code, body["status"]), (200, "running"))

    def test_status_running_by_lease(self):
        self.pings["192.168.1.201"] = True
        code, body = self.req("GET", f"/status?mac={MAC}&ip=192.168.1.150")
        self.assertEqual(body["status"], "running")
        self.assertIn("192.168.1.201", body["checked"])

    def test_status_stopped(self):
        code, body = self.req("GET", f"/status?mac={MAC}&ip=192.168.1.150")
        self.assertEqual((code, body["status"]), (200, "stopped"))

    def test_status_running_during_wake_grace(self):
        # /wake の直後は、ping が通らなくても running(MAAS が、off から on への遷移を待つため)
        self.req("POST", f"/wake?mac={MAC}")
        code, body = self.req("GET", f"/status?mac={MAC}&ip=192.168.1.150")
        self.assertEqual((code, body["status"], body["wake_grace"]), (200, "running", True))

    def test_status_stopped_after_wake_grace(self):
        t = [1000.0]
        with mock.patch.object(wol, "now", lambda: t[0]):
            self.req("POST", f"/wake?mac={MAC}")
            t[0] += 299
            self.assertEqual(self.req("GET", f"/status?mac={MAC}")[1]["status"], "running")
            t[0] += 2  # 301 秒後
            code, body = self.req("GET", f"/status?mac={MAC}")
            self.assertEqual((body["status"], body["wake_grace"]), ("stopped", False))

    def test_wake_grace_is_per_mac(self):
        self.req("POST", f"/wake?mac={MAC}")
        code, body = self.req("GET", "/status?mac=aa:bb:cc:dd:ee:ff")
        self.assertEqual(body["status"], "stopped")

    def test_off_ends_wake_grace(self):
        self.req("POST", f"/wake?mac={MAC}")
        self.req("POST", f"/off?mac={MAC}")
        code, body = self.req("GET", f"/status?mac={MAC}")
        self.assertEqual(body["status"], "stopped")

    def test_wake_grace_can_be_disabled(self):
        with mock.patch.dict(os.environ, {"WAKE_GRACE_SEC": "0"}):
            self.req("POST", f"/wake?mac={MAC}")
            code, body = self.req("GET", f"/status?mac={MAC}")
        self.assertEqual(body["status"], "stopped")

    def test_status_running_still_by_ping_without_wake(self):
        self.pings["192.168.1.150"] = True
        code, body = self.req("GET", f"/status?mac={MAC}&ip=192.168.1.150")
        self.assertEqual((body["status"], body["wake_grace"]), ("running", False))

    def test_status_matches_maas_regex(self):
        import re
        self.pings["192.168.1.150"] = True
        r = urllib.request.urlopen(f"http://127.0.0.1:{self.port}/status?mac={MAC}&ip=192.168.1.150", timeout=5).read().decode()
        self.assertIsNotNone(re.search(r"status.*\:.*running", r))
        self.assertIsNone(re.search(r"status.*\:.*stopped", r))
        r = urllib.request.urlopen(f"http://127.0.0.1:{self.port}/status?mac={MAC}", timeout=5).read().decode()
        self.assertIsNotNone(re.search(r"status.*\:.*stopped", r))

    def test_status_ignores_invalid_ip(self):
        code, body = self.req("GET", f"/status?mac={MAC}&ip=1.2.3.4;id&ip=999.1.1.1")
        self.assertEqual(code, 200)
        self.assertNotIn("1.2.3.4;id", body["checked"])
        self.assertNotIn("999.1.1.1", body["checked"])

    def test_unknown_paths(self):
        self.assertEqual(self.req("GET", "/wake")[0], 404)
        self.assertEqual(self.req("POST", "/status?mac=" + MAC)[0], 404)
        self.assertEqual(self.req("GET", "/other")[0], 404)


class FakeSsh:
    """偽の ssh(PATH の先頭に置く)。呼ばれた引数を、log に書き、stderr と終了コードを返す。実際には接続しない。"""

    def __init__(self, code=0, stderr=""):
        self.dir = tempfile.mkdtemp()
        self.log = os.path.join(self.dir, "calls.txt")
        path = os.path.join(self.dir, "ssh")
        with open(path, "w") as f:
            f.write("#!/bin/sh\nprintf '%%s\\n' \"$@\" '--' >> '%s'\necho '%s' >&2\nexit %d\n" % (self.log, stderr, code))
        os.chmod(path, 0o755)

    def calls(self):
        if not os.path.exists(self.log):
            return []
        calls, cur = [], []
        for line in open(self.log).read().splitlines():
            if line == "--":
                calls.append(cur)
                cur = []
            else:
                cur.append(line)
        return calls


class Shutdown(unittest.TestCase):
    """/off の、シャットダウン(SSH)の経路。ssh は偽物。表は、テストごとの一時ファイル。Server の準備と HTTP の補助を借りる(継承はしない)。"""

    setUp_base = Server.setUp
    tearDown = Server.tearDown
    req = Server.req

    def setUp(self):
        self.setUp_base()
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(lambda: shutil.rmtree(self.tmp, ignore_errors=True))
        self.table = os.path.join(self.tmp, "shutdown-targets.json")
        os.environ["SHUTDOWN_TARGETS"] = self.table  # self.env(mock.patch.dict)が、tearDown で元に戻す
        os.environ["SHUTDOWN_KEY"] = "/tmp/fake-key-for-test"
        os.environ["SHUTDOWN_KNOWN_HOSTS"] = "/tmp/fake-kh-for-test"
        self.pings["192.168.1.150"] = True  # 対象は、起動している

    def use_table(self, obj):
        with open(self.table, "w") as f:
            f.write(obj if isinstance(obj, str) else json.dumps(obj))

    def use_ssh(self, code=0, stderr=""):
        fake = FakeSsh(code, stderr)
        old = os.environ.get("PATH", "")
        os.environ["PATH"] = fake.dir + os.pathsep + old
        self.addCleanup(lambda: shutil.rmtree(fake.dir, ignore_errors=True))
        return fake

    GOOD = {MAC: {"host": "192.168.1.150", "user": "maas-shutdown"}}

    def test_off_runs_ssh_with_fixed_args(self):
        self.use_table(self.GOOD)
        fake = self.use_ssh(0)
        code, body = self.req("POST", f"/off?mac={MAC}")
        self.assertEqual((code, body["status"]), (200, "stopping"))
        calls = fake.calls()
        self.assertEqual(len(calls), 1)
        args = calls[0]
        for want in ("-F", "/dev/null", "BatchMode=yes", "IdentitiesOnly=yes", "StrictHostKeyChecking=yes", "ConnectTimeout=5"):
            self.assertIn(want, args)
        self.assertEqual(args[args.index("-i") + 1], "/tmp/fake-key-for-test")
        self.assertIn("UserKnownHostsFile=/tmp/fake-kh-for-test", args)
        self.assertEqual(args[-1], "maas-shutdown@192.168.1.150")  # リモートコマンドは無い

    def test_off_ssh_failure_is_502_without_stderr(self):
        self.use_table(self.GOOD)
        self.use_ssh(255, stderr="SECRET-DETAIL-xyz")
        code, body = self.req("POST", f"/off?mac={MAC}")
        self.assertEqual((code, body["mac"]), (502, MAC))
        self.assertIn("error", body)
        self.assertNotIn("SECRET-DETAIL", json.dumps(body))

    def test_off_ssh_binary_missing_is_502(self):
        self.use_table(self.GOOD)
        old = os.environ.get("PATH", "")
        os.environ["PATH"] = "/nonexistent-dir-for-test"
        self.addCleanup(lambda: os.environ.__setitem__("PATH", old))
        code, body = self.req("POST", f"/off?mac={MAC}")
        self.assertEqual(code, 502)

    def test_off_unknown_mac_is_unsupported_and_no_ssh(self):
        self.use_table({"aa:bb:cc:dd:ee:ff": {"host": "192.168.1.151", "user": "maas-shutdown"}})
        fake = self.use_ssh(0)
        code, body = self.req("POST", f"/off?mac={MAC}")
        self.assertEqual((code, body["status"]), (200, "unsupported"))
        self.assertEqual(fake.calls(), [])

    def test_off_missing_table_is_unsupported(self):
        os.environ["SHUTDOWN_TARGETS"] = os.path.join(self.tmp, "absent.json")
        fake = self.use_ssh(0)
        code, body = self.req("POST", f"/off?mac={MAC}")
        self.assertEqual((code, body["status"]), (200, "unsupported"))
        self.assertEqual(fake.calls(), [])

    def test_off_broken_table_is_unsupported_and_no_ssh(self):
        for broken in ("{not json", "[1, 2]", json.dumps({MAC: "x"}), json.dumps({MAC: {"host": "192.168.1.150"}})):
            self.use_table(broken)
            fake = self.use_ssh(0)
            code, body = self.req("POST", f"/off?mac={MAC}")
            self.assertEqual((code, body["status"]), (200, "unsupported"), broken)
            self.assertEqual(fake.calls(), [], broken)

    def test_off_rejects_option_injection_in_table(self):
        for bad in ({"host": "192.168.1.150", "user": "-oProxyCommand=x"},
                    {"host": "192.168.1.150", "user": "a b"},
                    {"host": "192.168.1.150;id", "user": "maas-shutdown"},
                    {"host": "192.168.1.150", "user": "x" * 40}):
            self.use_table({MAC: bad})
            fake = self.use_ssh(0)
            code, body = self.req("POST", f"/off?mac={MAC}")
            self.assertEqual((code, body["status"]), (200, "unsupported"), bad)
            self.assertEqual(fake.calls(), [], bad)

    def test_ssh_shutdown_validates_its_own_arguments(self):
        for bad in ({"host": "192.168.1.150", "user": "-oProxyCommand=x"}, {"host": "x;id", "user": "maas-shutdown"}):
            with self.assertRaises(ValueError):
                wol.ssh_shutdown(bad, "/k", "/kh")

    def test_off_stopped_does_not_ssh(self):
        self.use_table(self.GOOD)
        self.pings.clear()  # ping が通らない = 停止済み
        fake = self.use_ssh(0)
        code, body = self.req("POST", f"/off?mac={MAC}")
        self.assertEqual((code, body["status"]), (200, "stopped"))
        self.assertEqual(fake.calls(), [])

    def test_status_after_off_stays_running_until_ping_fails(self):
        self.use_table(self.GOOD)
        self.use_ssh(0)
        self.req("POST", f"/off?mac={MAC}")
        self.assertEqual(self.req("GET", f"/status?mac={MAC}&ip=192.168.1.150")[1]["status"], "running")
        self.pings.clear()
        self.assertEqual(self.req("GET", f"/status?mac={MAC}&ip=192.168.1.150")[1]["status"], "stopped")

    def test_load_targets_normalizes_mac(self):
        self.use_table({"02-39-7A-2E-13-F0": {"host": "192.168.1.150", "user": "maas-shutdown"}})
        self.assertEqual(wol.load_shutdown_targets(self.table), {MAC: {"host": "192.168.1.150", "user": "maas-shutdown"}})


class Main(unittest.TestCase):
    def test_refuses_non_loopback_bind(self):
        with mock.patch.dict(os.environ, {"BIND": "0.0.0.0"}):
            with self.assertRaises(SystemExit):
                wol.main()


if __name__ == "__main__":
    unittest.main()
