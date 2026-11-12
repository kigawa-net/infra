#!/bin/bash
# bao-02 から、Inuyama の LAN への通信が、tun0 の先で届くかを切り分ける。bash -s で流す。読み取りだけ。
# 設定ファイルの中身は出さない(network_secret を含むため)。
echo "== easytier のルート(proxy_cidrs の列に 10.0.0.0/24 などがあるか)"
easytier-cli route 2>&1 | head -12

echo "== 設定に proxy_network があるか(件数だけ)"
grep -c 'proxy_network' /etc/easytier/easytier.toml 2>&1

echo "== rp_filter"
sysctl net.ipv4.conf.all.rp_filter net.ipv4.conf.tun0.rp_filter 2>&1

probe() { # ping 2 回の結果の 1 行
  r=$(ping -c 2 -W 2 "$1" 2>&1 | grep -E 'packet loss')
  echo "$1: $r"
}
echo "== ping(LAN 側。10.0.0.103/120/140 は control-plane の LAN の IP)"
for ip in 10.0.0.103 10.0.0.120 10.0.0.140 10.0.0.100 192.168.1.130; do probe "$ip"; done
echo "== ping(対照。Overlay の control-plane。つながるはず)"
probe 10.250.0.12

echo "== ping 中の tun0 を 5 秒だけ見る(10.0.0.103 宛ての ICMP が tun0 を出ていくか、返りが来るか)"
if command -v tcpdump >/dev/null 2>&1; then
  ( ping -c 3 -W 1 10.0.0.103 >/dev/null 2>&1 & )
  timeout 5 tcpdump -ni tun0 -c 8 'icmp and host 10.0.0.103' 2>&1 | tail -10
else
  echo "tcpdump が無い(スキップ)"
fi
