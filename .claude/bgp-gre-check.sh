#!/bin/bash
# GRE トンネル内の BGP(bao 側)の状態を確認する。bash -s で流す。読み取りだけ。
echo "== host: $(hostname)"
echo "== BGP の隣接(172.31.250.x が Established か)"
vtysh -c 'show bgp ipv4 unicast summary' 2>&1 | head -20
echo "== BGP で学んだ経路"
vtysh -c 'show bgp ipv4 unicast' 2>&1 | head -20
echo "== カーネルの経路"
ip route show 10.0.0.0/24; ip route show 192.168.1.0/24
echo "== 実際の経路の選択"
ip route get 10.0.0.245
