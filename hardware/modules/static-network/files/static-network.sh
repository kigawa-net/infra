#!/bin/bash
# ノードの NIC に、固定のアドレスとデフォルト経路を足す(networkd のドロップイン。kigawa-net/infra#317)。
# k8s-worker1 は、DHCP が付けていた 192.168.1.228 とデフォルト経路(192.168.1.1)が、DHCP の停止(2026-10-24 23:05 JST)で消え、
# kubelet が API サーバー(10.0.0.100)に届かず、NotReady になった(Ceph の OSD 4 台と mon も down)。DHCP に依存しないよう、固定にする。
#
# netplan が生成する /run/systemd/network/10-netplan-<IFACE>.network は触らず、/etc/systemd/network/10-netplan-<IFACE>.network.d/ にドロップインを置く
# (netplan の YAML を読まなくてよい。netplan が再生成しても、ドロップインは残る)。既存のアドレス(例: 192.168.1.105)は、そのまま残す。
# 冪等。反映の後に、アドレスとデフォルト経路が付いたことを確認する。付かなければ、ドロップインを消して戻し、失敗する。
# 環境変数: IFACE(必須。例 ens18)、ADDRESS(必須。CIDR。例 192.168.1.228/24)、GATEWAY(必須。例 192.168.1.1)、
#           DROPIN_BASE(既定 /etc/systemd/network。テスト用)、VERIFY_WAIT_SEC(既定 20)
set -euo pipefail

export PATH="${EXTRA_PATH:+$EXTRA_PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"  # EXTRA_PATH は、テストで偽のコマンドを差し込むためだけに使う
: "${IFACE:?IFACE が未設定}"
: "${ADDRESS:?ADDRESS が未設定(CIDR)}"
: "${GATEWAY:?GATEWAY が未設定}"
DROPIN_BASE=${DROPIN_BASE:-/etc/systemd/network}
VERIFY_WAIT_SEC=${VERIFY_WAIT_SEC:-20}

case "$IFACE" in *[!A-Za-z0-9_.-]*|"") echo "ABORT: IFACE の形が不正($IFACE)" >&2; exit 1;; esac
printf '%s' "$ADDRESS" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' || { echo "ABORT: ADDRESS は IPv4 の CIDR(例 192.168.1.228/24)にする($ADDRESS)" >&2; exit 1; }
printf '%s' "$GATEWAY" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || { echo "ABORT: GATEWAY は IPv4 アドレスにする($GATEWAY)" >&2; exit 1; }
ADDR_IP=${ADDRESS%/*}

DIR="$DROPIN_BASE/10-netplan-$IFACE.network.d"
FILE="$DIR/50-static-address-route.conf"
NEW=$(printf '[Network]\nAddress=%s\n\n[Route]\nGateway=%s\n' "$ADDRESS" "$GATEWAY")

verify() { # アドレスとデフォルト経路が付いているか
    ip -4 -o addr show dev "$IFACE" 2>/dev/null | grep -qE "[[:space:]]${ADDR_IP//./\\.}/" \
        && ip -4 route show default 2>/dev/null | grep -qF "via $GATEWAY"
}

if [ -f "$FILE" ] && [ "$(cat "$FILE")" = "$NEW" ] && verify 2>/dev/null; then
    echo "static-network: すでに設定済み($IFACE $ADDRESS via $GATEWAY)。何もしない"
    exit 0
fi

had_old=0; old=""
if [ -f "$FILE" ]; then had_old=1; old=$(cat "$FILE"); fi
install -d -m 0755 "$DIR"
printf '%s\n' "$NEW" > "$FILE"
chmod 0644 "$FILE"

# 反映。アドレスの追加は、既存のアドレス(SSH の接続先)を切らない。
networkctl reload
networkctl reconfigure "$IFACE"

ok=0
for _ in $(seq 1 "$VERIFY_WAIT_SEC"); do
    if verify 2>/dev/null; then ok=1; break; fi
    sleep 1
done
if [ "$ok" != 1 ]; then
    echo "ABORT: 反映したが、アドレス($ADDRESS)またはデフォルト経路(via $GATEWAY)が付かない。ドロップインを戻す" >&2
    if [ "$had_old" = 1 ]; then printf '%s\n' "$old" > "$FILE"; else rm -f "$FILE"; rmdir "$DIR" 2>/dev/null || true; fi
    networkctl reload || true
    networkctl reconfigure "$IFACE" || true
    exit 1
fi
echo "static-network: 設定した($IFACE $ADDRESS via $GATEWAY)"
ip -4 -br addr show dev "$IFACE" 2>/dev/null | cut -c1-120 || true
ip -4 route show default 2>/dev/null | head -2
