#!/bin/bash
# bao-02 の GRE トンネル(Terraform で入れたもの)の状態と、k8s1 とのトンネルの疎通を、読むだけで確認する。手元から実行する。
# 鍵は ~/.ssh/bao02_key2 があればそれを、なければ /tmp/bao02_key(fetch-bao02-key.sh で作る)を使う。
key=""
for k in "$HOME/.ssh/bao02_key2" /tmp/bao02_key; do [ -s "$k" ] && { key="$k"; break; }; done
[ -n "$key" ] || { echo "NG: 鍵が無い。fetch-bao02-key.sh を先に"; exit 1; }
ssh -i "$key" -o IdentitiesOnly=yes root@207.231.111.196 bash -s <<'REMOTE'
echo "== host: $(hostname)"
echo "== gre-overlay.service"; systemctl is-active gre-overlay.service; systemctl is-enabled gre-overlay.service
echo "== トンネル"; ip -d -o link show type gre | grep -v 'gre0@' | cut -c1-150
echo "== 定義"; cat /etc/gre-overlay/tunnels.conf
echo "== INPUT の先頭(GRE と 179/tcp の許可)"; iptables -S INPUT | head -9
echo "== 一時的な経路(wg0 の 10.0.0.0/24。手動で入れたもの)"; ip route show 10.0.0.0/24
echo "== トンネルの疎通: k8s1 の gre-bao02(172.31.250.3)"
ping -c 3 -W 2 172.31.250.3 | tail -3
echo "== 大きさ 1272 バイト(分割なし)"
ping -c 2 -W 2 -M do -s 1272 172.31.250.3 | tail -2
echo "== トンネルの疎通: k8s4(172.31.250.1)と k8s2(172.31.250.5)(まだ有効でないので、通らないはず)"
ping -c 2 -W 2 172.31.250.1 | tail -2
ping -c 2 -W 2 172.31.250.5 | tail -2
echo "== easytier"; systemctl is-active easytier.service
echo "== openbao"; systemctl is-active openbao.service 2>/dev/null || systemctl list-units 'openbao*' --no-legend | head -2
REMOTE
