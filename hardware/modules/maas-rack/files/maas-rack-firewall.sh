#!/bin/bash
# MAAS Rack の待ち受けポートを、LAN の送信元かつ、このホストの LAN のアドレス宛てだけに絞る(kigawa-net/infra#207、docs/maas-design.md)。
#
# 背景: Rack を入れると、TFTP(udp 69)が、ホストの全アドレス(API の VIP、LB の VIP、kube-ipvs0 のサービス IP の数百個)にバインドされ、
#       maas-proxy(tcp 3128 / 8000)、rsyslog(5247)、nginx(5248)、chrony(udp 123。MAAS の maas.conf の allow で LAN に時刻を配る)も、全体で待ち受ける。
#       control-plane の INPUT は ACCEPT で、ufw は無効(サービスは active でも、ファイアウォールは inactive)なので、LAN から、全部、届く。
#       ufw を有効にすると、control-plane の既定が変わり危険なので、専用の chain MAAS-RACK だけを、INPUT の先頭から呼ぶ(既存の ci-ssh-forward などと同じ方式)。
#
# ルール(対象は、下のポートだけ。SSH、etcd、kube-apiserver などには、触れない):
#   1. lo からは許可
#   2. 送信元が LAN_CIDR で、宛先が LAN_ADDRESS(このホストの LAN のアドレス)のときだけ許可
#      udp: 69(TFTP)、123(NTP)、5247(syslog)  tcp: 5247、5248(HTTP)、3128 / 8000(proxy)
#   3. それ以外は DROP(VIP 宛て、クラスタのサービス IP 宛て、Pod 経由、LAN の外からは届かない)
#   4. tcp 5249(rackd の内部 HTTP。nginx が localhost:5249 に proxy_pass するだけ)は、lo 以外すべて DROP
# DHCP(udp 67)と failover(tcp 647 / 7911)は、DHCP の切り替えの段階で、同じ方式で足す(今は、DHCP を有効にしない)。
#
# 使い方: maas-rack-firewall.sh apply | remove | status   (root。環境変数 LAN_CIDR、LAN_ADDRESS が必要。apply のとき)
set -euo pipefail

IPT=${IPTABLES:-iptables}
CHAIN=MAAS-RACK
ipt() { $IPT -w 5 "$@"; }

UDP_PORTS=69,123,5247
TCP_PORTS=5247,5248,3128,8000
TCP_LOCAL_ONLY=5249

remove() {
    while ipt -C INPUT -j "$CHAIN" 2>/dev/null; do ipt -D INPUT -j "$CHAIN"; done
    if ipt -S "$CHAIN" >/dev/null 2>&1; then
        ipt -F "$CHAIN"
        ipt -X "$CHAIN"
    fi
}

apply() {
    : "${LAN_CIDR:?LAN_CIDR が未設定}"
    : "${LAN_ADDRESS:?LAN_ADDRESS が未設定}"
    # 冪等: chain を作り直し、中身を入れ替える(INPUT からの呼び出しは、1 つだけにする)
    if ipt -S "$CHAIN" >/dev/null 2>&1; then ipt -F "$CHAIN"; else ipt -N "$CHAIN"; fi
    ipt -A "$CHAIN" -i lo -j RETURN
    ipt -A "$CHAIN" -s "$LAN_CIDR" -d "$LAN_ADDRESS" -p udp -m multiport --dports "$UDP_PORTS" -j RETURN
    ipt -A "$CHAIN" -s "$LAN_CIDR" -d "$LAN_ADDRESS" -p tcp -m multiport --dports "$TCP_PORTS" -j RETURN
    ipt -A "$CHAIN" -p udp -m multiport --dports "$UDP_PORTS" -j DROP
    ipt -A "$CHAIN" -p tcp -m multiport --dports "$TCP_PORTS,$TCP_LOCAL_ONLY" -j DROP
    ipt -A "$CHAIN" -j RETURN
    # INPUT の先頭から呼ぶ(重複を除いてから、1 つだけ入れる)
    while ipt -C INPUT -j "$CHAIN" 2>/dev/null; do ipt -D INPUT -j "$CHAIN"; done
    ipt -I INPUT 1 -j "$CHAIN"
}

case "${1:-}" in
    apply) apply; echo "maas-rack-firewall: applied (LAN=$LAN_CIDR dst=$LAN_ADDRESS)" ;;
    remove) remove; echo "maas-rack-firewall: removed" ;;
    status) ipt -S "$CHAIN" 2>&1 || true; ipt -S INPUT | grep -- "-j $CHAIN" || echo "(INPUT から呼ばれていない)" ;;
    *) echo "usage: $0 apply|remove|status" >&2; exit 2 ;;
esac
