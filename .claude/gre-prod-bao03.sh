#!/bin/bash
# bao-03 の GRE トンネル(Terraform で入れたもの)の状態と、control-plane 3 台とのトンネルの疎通を、読むだけで確認する。手元から実行する。
# 鍵は /tmp/bao03_key(fetch-bao03-key.sh で作る。終わったら rm -f /tmp/bao03_key)を使う。
[ -s /tmp/bao03_key ] || { echo "NG: /tmp/bao03_key が無い。fetch-bao03-key.sh を先に"; exit 1; }
ssh -i /tmp/bao03_key -o IdentitiesOnly=yes root@143.203.220.195 bash -s <<'REMOTE'
echo "== host: $(hostname)"
echo "== gre-overlay.service"; systemctl is-active gre-overlay.service; systemctl is-enabled gre-overlay.service
echo "== トンネル"; ip -d -o link show type gre | grep -v 'gre0@' | cut -c1-150
echo "== INPUT の先頭(GRE と 179/tcp の許可)"; iptables -S INPUT | head -9
echo "== 一時的な経路(10.0.0.0/24)"; ip route show 10.0.0.0/24
for p in "k8s4 172.31.250.7" "k8s1 172.31.250.9" "k8s2 172.31.250.11"; do
  set -- $p
  echo "== トンネルの疎通: $1($2)"
  ping -c 3 -W 2 "$2" | tail -2
  ping -c 1 -W 2 -M do -s 1272 "$2" | tail -2 | head -1
done
echo "== easytier"; systemctl is-active easytier.service
echo "== openbao"; systemctl is-active openbao.service 2>/dev/null || systemctl list-units 'openbao*' --no-legend | head -2
REMOTE
