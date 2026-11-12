#!/bin/bash
# bao-02/03 で、10.0.0.0/24 が LAN に届くかを確認し、届かなければ、wg0 の経路を一時的に足す(metric 10)。bash -s で流す。
# 戻すとき: ip route del 10.0.0.0/24 dev wg0
echo "== host: $(hostname)"
echo "== 対照: Overlay の control-plane(つながるはず)"
ping -c 2 -W 2 10.250.0.12 | grep 'packet loss'
echo "== 前: 10.0.0.103 への ping(LAN 側)"
ping -c 2 -W 2 10.0.0.103 | grep 'packet loss'
echo "== 現在の 10.0.0.0/24 の経路"
ip route show 10.0.0.0/24
if ip route show 10.0.0.0/24 | grep -q 'dev wg0'; then
  echo "== すでに wg0 の経路がある。何もしない"
else
  echo "== wg0 の経路を足す(metric 10)"
  ip route add 10.0.0.0/24 dev wg0 metric 10
fi
echo "== 後: 10.0.0.103 への ping"
ping -c 2 -W 2 10.0.0.103 | grep 'packet loss'
echo "== 後の経路"
ip route show 10.0.0.0/24
