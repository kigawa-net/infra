#!/bin/bash
# EasyTier の Overlay 上で GRE が通るかを試す、手動のテスト(Terraform の管理外)。root で実行する。
# 使い方: gre-test-side.sh <up|down|status> <bao02|k8s1>
# up: トンネル grechk を作り、Overlay の GRE を INPUT の先頭で一時的に許可する。bao02 では、続けて ping も試す。
# down: 許可とトンネルを消す。ノードの再起動でも消える。経路は足さない。
mode=${1:-status}; role=${2:-}
case "$role" in
  bao02) L=10.250.0.1;  R=10.250.0.12; IL=172.31.250.2; IR=172.31.250.3 ;;
  k8s1)  L=10.250.0.12; R=10.250.0.1;  IL=172.31.250.3; IR=172.31.250.2 ;;
  *) echo "role は bao02 か k8s1"; exit 2 ;;
esac
echo "== host: $(hostname) / $mode"
case "$mode" in
  up)
    echo "== tun0 の MTU"; ip -o link show tun0 | grep -o 'mtu [0-9]*'
    echo "== ip_gre"; modprobe ip_gre 2>&1 && echo "ip_gre: OK" || echo "ip_gre: NG"
    if ip link show grechk >/dev/null 2>&1; then
      echo "grechk は既にある。作り直さない"
    else
      ip tunnel add grechk mode gre local "$L" remote "$R" ttl 64 || { echo "tunnel add: NG"; exit 1; }
      ip addr add "$IL/31" dev grechk
      ip link set grechk mtu 1300 up
    fi
    iptables -C INPUT -i tun0 -p gre -s "$R" -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i tun0 -p gre -s "$R" -j ACCEPT
    echo "== grechk"; ip -d -o link show grechk | cut -c1-200; ip -o addr show grechk | cut -c1-120
    if [ "$role" = bao02 ]; then
      echo "== ping $IR(トンネルの対向。相手が up のときだけ通る)"
      ping -c 3 -W 2 "$IR" | tail -3
      echo "== 大きさ 1272 バイト(MTU 1300 いっぱい。分割なし)"
      ping -c 2 -W 2 -M do -s 1272 "$IR" | tail -3
      echo "== tun0 で GRE を見る(3 秒)"
      ( ping -c 2 -W 1 "$IR" >/dev/null 2>&1 & )
      command -v tcpdump >/dev/null && timeout 3 tcpdump -ni tun0 -c 4 "proto gre" 2>&1 | tail -5
    fi
    ;;
  lan)
    if [ "$role" = k8s1 ]; then
      echo "== k8s1: 転送の設定(読むだけ)"
      sysctl net.ipv4.ip_forward
      echo "== FORWARD の先頭"; iptables -S FORWARD | head -8
      echo "== 戻りの経路: bao-02 の Overlay のアドレスへ"; ip route get 10.250.0.1
    else
      ip link show grechk >/dev/null 2>&1 || { echo "NG: grechk が無い。先に up"; exit 1; }
      targets="192.168.1.130 10.0.0.120"
      trap 'for t in $targets; do ip route del "$t/32" dev grechk 2>/dev/null; done' EXIT
      for t in $targets; do ip route add "$t/32" via "$IR" dev grechk 2>&1; done
      echo "== 経路(トンネル経由の /32)"; for t in $targets; do ip route get "$t" from 10.250.0.1 | head -1; done
      echo "== ping(送信元は Overlay のアドレス 10.250.0.1。行きは GRE、戻りは Overlay の想定)"
      for t in $targets; do echo "-- $t"; ping -c 3 -W 2 -I 10.250.0.1 "$t" | tail -2; done
      echo "== grechk を見る(3 秒): 行きが GRE に入るか、戻りが grechk に来るか"
      ( ping -c 2 -W 1 -I 10.250.0.1 192.168.1.130 >/dev/null 2>&1 & )
      command -v tcpdump >/dev/null && timeout 3 tcpdump -ni grechk -c 4 'icmp' 2>&1 | tail -5
      echo "== tun0 を見る(3 秒): 戻りが Overlay に直接来るか"
      ( ping -c 2 -W 1 -I 10.250.0.1 192.168.1.130 >/dev/null 2>&1 & )
      command -v tcpdump >/dev/null && timeout 3 tcpdump -ni tun0 -c 4 'icmp and src host 192.168.1.130' 2>&1 | tail -5
    fi
    ;;
  diag)
    echo "== rp_filter(1 = 厳格。grechk で受けた 10.250.0.1 発のパケットを、戻りの経路が tun0 なので落とす可能性)"
    sysctl net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter net.ipv4.conf.tun0.rp_filter net.ipv4.conf.grechk.rp_filter 2>&1
    echo "== tcpdump: $(command -v tcpdump || echo なし)"
    echo "== k8s1 自身から LAN の宛先へ(対照)"
    for t in 192.168.1.130 10.0.0.120; do echo "-- $t"; ip route get "$t" | head -1; ping -c 2 -W 2 "$t" | tail -2; done
    ;;
  cap)
    timeout 10 tcpdump -ni any -c 40 'icmp and host 10.250.0.1' 2>&1 | tail -44
    ;;
  ping1)
    targets="192.168.1.130 10.0.0.120"
    trap 'for t in $targets; do ip route del "$t/32" dev grechk 2>/dev/null; done' EXIT
    for t in $targets; do ip route add "$t/32" via "$IR" dev grechk 2>&1; done
    for t in $targets; do echo "-- $t"; ping -c 4 -W 2 -I 10.250.0.1 "$t" 2>&1 | tail -4; done
    ;;
  nat)
    echo "== POSTROUTING の MASQUERADE(pkts/bytes のカウンター。テストの前後で見比べる)"
    iptables -t nat -L POSTROUTING -v -n -x | grep -E "^Chain|MASQUERADE.*(tun0|192.168.1.0/24)" | head -6
    ;;
  ping2)
    targets="192.168.1.150 192.168.1.228 192.168.1.121"
    trap 'for t in $targets; do ip route del "$t/32" dev grechk 2>/dev/null; done' EXIT
    for t in $targets; do ip route add "$t/32" via "$IR" dev grechk 2>&1; done
    for t in $targets; do echo "-- $t"; ping -c 4 -W 2 -I 10.250.0.1 "$t" 2>&1 | tail -3; done
    ;;
  down)
    for t in 192.168.1.130 10.0.0.120 192.168.1.150 192.168.1.228 192.168.1.121; do ip route del "$t/32" dev grechk 2>/dev/null; done
    iptables -D INPUT -i tun0 -p gre -s "$R" -j ACCEPT 2>/dev/null
    ip tunnel del grechk 2>/dev/null
    echo "== 残り"; ip link show grechk 2>&1 | head -1; iptables -S INPUT | grep -c ' gre ' | sed 's/^/gre の許可ルールの数: /'
    ;;
  status)
    ip -o link show grechk 2>&1 | cut -c1-160; iptables -S INPUT | grep ' gre ' ;;
esac
