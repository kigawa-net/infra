#!/usr/bin/env bash
# FRR 8.4.7 を 2 台、隔離した docker ネットワークで繋ぎ、`neighbor X timers 3 9` の構文と、
# ネゴシエーション結果(hold)、bgpd が止まったときの撤回までの時間を確認する(本番には触れない)。
# 要: docker と quay.io/frrouting/frr:8.4.7(CI には組み込んでいない。手元で確認するためのもの)。
# 使い方: bash hardware/modules/bgp-frr/test-ibgp-timers.sh
set -u
IMG=quay.io/frrouting/frr:8.4.7
NET=frr-timers-test
work=$(mktemp -d)
cleanup() { docker rm -f frr-a frr-b >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; rm -rf "$work"; }
trap cleanup EXIT

docker network create --subnet 10.99.0.0/24 "$NET" >/dev/null

# 本番のテンプレートの timers の行と同じ形(router bgp 階層の neighbor)。A だけ timers 指定、B は既定(60/180)。
cat > "$work/a.conf" <<'EOF'
frr defaults traditional
hostname a
service integrated-vtysh-config
router bgp 65000
 bgp router-id 10.99.0.2
 no bgp default ipv4-unicast
 neighbor 10.99.0.3 remote-as 65000
 neighbor 10.99.0.3 update-source 10.99.0.2
 neighbor 10.99.0.3 timers 3 9
 address-family ipv4 unicast
  network 10.99.100.1/32
  neighbor 10.99.0.3 activate
  neighbor 10.99.0.3 next-hop-self
 exit-address-family
EOF
cat > "$work/b.conf" <<'EOF'
frr defaults traditional
hostname b
service integrated-vtysh-config
router bgp 65000
 bgp router-id 10.99.0.3
 no bgp default ipv4-unicast
 neighbor 10.99.0.2 remote-as 65000
 neighbor 10.99.0.2 update-source 10.99.0.3
 address-family ipv4 unicast
  neighbor 10.99.0.2 activate
 exit-address-family
EOF
for n in a b; do sed -i 's/^$//' "$work/$n.conf"; done
printf 'zebra=yes\nbgpd=yes\nvtysh_enable=yes\nzebra_options="  -A 127.0.0.1 -s 90000000"\nbgpd_options="   -A 127.0.0.1"\n' > "$work/daemons"

start() { # name ip conf
  docker run -d --name "$1" --network "$NET" --ip "$2" --cap-add NET_ADMIN --cap-add SYS_ADMIN \
    -v "$work/$3.conf:/etc/frr/frr.conf" -v "$work/daemons:/etc/frr/daemons" "$IMG" >/dev/null
}
start frr-a 10.99.0.2 a
start frr-b 10.99.0.3 b
# 一時ファイルの所有者を frr に
for c in frr-a frr-b; do docker exec "$c" sh -c 'chown frr:frr /etc/frr/frr.conf /etc/frr/daemons' 2>/dev/null; docker restart "$c" >/dev/null; done

# network 文は、同じ prefix がカーネルの経路表に無いと広告されない(bgp network import-check)。
for c in frr-a frr-b; do docker exec "$c" sh -c 'touch /etc/frr/vtysh.conf' 2>/dev/null; done
docker exec frr-a ip addr add 10.99.100.1/32 dev lo
echo "== 起動待ち(セッション確立まで最大 40 秒)"
for i in $(seq 1 40); do
  st=$(docker exec frr-a vtysh -c 'show bgp neighbor 10.99.0.3 json' 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["10.99.0.3"]["bgpState"])' 2>/dev/null || echo "?")
  [ "$st" = "Established" ] && break
  sleep 1
done
echo "A 側のセッション: $st (${i}s)"

echo "== A の設定した timers と、ネゴシエーション結果"
docker exec frr-a vtysh -c 'show bgp neighbor 10.99.0.3 json' | python3 -c '
import sys,json
d=json.load(sys.stdin)["10.99.0.3"]
print("A: configuredHoldTimeMsecs=%s configuredKeepAliveIntervalMsecs=%s" % (d.get("bgpTimerConfiguredHoldTimeMsecs"), d.get("bgpTimerConfiguredKeepAliveIntervalMsecs")))
print("A: negotiated holdTime=%ss keepalive=%ss" % (d.get("bgpTimerHoldTimeMsecs",0)/1000, d.get("bgpTimerKeepAliveIntervalMsecs",0)/1000))'
docker exec frr-b vtysh -c 'show bgp neighbor 10.99.0.2 json' | python3 -c '
import sys,json
d=json.load(sys.stdin)["10.99.0.2"]
print("B(既定 60/180): negotiated holdTime=%ss keepalive=%ss" % (d.get("bgpTimerHoldTimeMsecs",0)/1000, d.get("bgpTimerKeepAliveIntervalMsecs",0)/1000))'

echo "== B が A の経路を受け取っている(最大 15 秒待つ)"
for i in $(seq 1 15); do
  docker exec frr-b vtysh -c 'show ip bgp 10.99.100.1/32' 2>&1 | grep -q "Paths:" && break
  sleep 1
done
docker exec frr-b vtysh -c 'show ip bgp 10.99.100.1/32' 2>&1 | head -4

echo "== A の bgpd を SIGSTOP(フリーズ)したとき、B が経路を撤回するまでの時間"
pid=$(docker exec frr-a pidof bgpd)
start_ts=$(date +%s)
docker exec frr-a kill -STOP "$pid"
for i in $(seq 1 60); do
  if ! docker exec frr-b vtysh -c 'show ip bgp 10.99.100.1/32' 2>&1 | grep -q "Paths:"; then break; fi
  sleep 1
done
echo "撤回まで: $(( $(date +%s) - start_ts )) 秒 (上限 hold=9 秒 + 検出の遅れ)"
docker exec frr-b vtysh -c 'show ip bgp 10.99.100.1/32' 2>&1 | head -2
