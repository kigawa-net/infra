#!/bin/bash
# bao-02 / bao-03 で、overlay 上の eBGP(PR #413)の状態を確認する。bash -s で流す。読み取りだけ(接続を試すだけ)。
echo "== host: $(hostname)"

echo "== BGP の隣接(3 台が Established か)"
vtysh -c 'show bgp ipv4 unicast summary' 2>&1 | head -20

echo "== BGP で学んだ経路(10.0.0.0/24 と 192.168.1.0/24 が、10.250.0.x の next-hop で入っているか)"
vtysh -c 'show bgp ipv4 unicast' 2>&1 | head -20

echo "== カーネルの経路(10.0.0.0/24 が tun0、172.31.254.0/24 が wg0 か)"
ip route show 10.0.0.0/24
ip route show 192.168.1.0/24
ip route show 172.31.254.0/24
ip route get 10.0.0.100
ip route get 192.168.1.130

echo "== wg0 の AllowedIPs(変わっていないか)"
wg show wg0 allowed-ips 2>&1 | head -5

echo "== 到達性(ping と TCP)。10.0.0.100 は API VIP"
ping -c 2 -W 2 10.0.0.100 | tail -2
probe() {
  if timeout 3 bash -c "echo > /dev/tcp/$1/$2" 2>/dev/null; then echo "$1:$2 CONNECTED"; else echo "$1:$2 blocked/timeout"; fi
}
probe 127.0.0.1 22
probe 10.0.0.100 6443

echo "== 経路が、3 台のどの control-plane を通るか(traceroute、最大 4 ホップ)"
traceroute -n -m 4 -w 2 10.0.0.100 2>&1 | head -6

echo "== easytier の状態"
easytier-cli peer 2>&1 | head -12
