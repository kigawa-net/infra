#!/bin/bash
# control-plane 3 台(Overlay)の遮断の確認。bao-02 から、bash -s で流す。読み取りだけ(接続を試すだけ)。
# 対象: k8s4=10.250.0.11, k8s1=10.250.0.12, k8s2=10.250.0.13
probe() {
  if timeout 3 bash -c "echo > /dev/tcp/$1/$2" 2>/dev/null; then
    echo "$1:$2 CONNECTED"
  else
    echo "$1:$2 blocked/timeout"
  fi
}

echo "== 対照(つながるはず。ここが blocked なら、この確認の方法が壊れている)"
probe 127.0.0.1 22
probe 74.208.55.86 22

for ip in 10.250.0.11 10.250.0.12 10.250.0.13; do
  echo "== $ip"
  ping -c 2 "$ip" | tail -1
  for p in 6443 10250 2379 22; do
    probe "$ip" "$p"
  done
done
