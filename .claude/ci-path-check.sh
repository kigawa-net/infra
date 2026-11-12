#!/bin/bash
# CI の Runner(172.31.254.21)から k8s1 / k8s2 への SSH が通らない原因の切り分け。k8s1 で sudo bash -s で流す。読み取りだけ。
echo "== host: $(hostname)"
echo "== 戻りの経路(Runner のアドレス宛て)"
ip route get 172.31.254.21
echo "== 172.31.254.0/24 の経路"
ip route show 172.31.254.0/24
echo "== FRR の BGP(隣接の状態。外部 peer が Established か)"
vtysh -c 'show bgp ipv4 unicast summary' 2>&1 | head -25
echo "== FRR が 172.31.254.0/24 をどう見ているか"
vtysh -c 'show ip route 172.31.254.21' 2>&1 | head -12
echo "== rp_filter"
sysctl net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter 2>&1
echo "== Runner からの SSH が来るか(15 秒。CI を再実行してもらうか、何も出なければ来ていない)"
command -v tcpdump >/dev/null && timeout 15 tcpdump -ni any -c 6 'tcp port 22 and host 172.31.254.21' 2>&1 | tail -8
