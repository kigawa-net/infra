"""files/maas-wol-webhook.py のテスト。マジックパケットの送信と ping は、差し替える(実機にも、ネットワークにも触れない)。
    python3 -I -m unittest hardware/modules/maas-rack/test_maas_wol_webhook.py
"""
import importlib.util
import json
import os
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


class Server(unittest.TestCase):
    def setUp(self):
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
        self.httpd = HTTPServer(("127.0.0.1", 0), wol.Handler)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.p1.stop()
        self.p2.stop()
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


class Main(unittest.TestCase):
    def test_refuses_non_loopback_bind(self):
        with mock.patch.dict(os.environ, {"BIND": "0.0.0.0"}):
            with self.assertRaises(SystemExit):
                wol.main()


if __name__ == "__main__":
    unittest.main()
