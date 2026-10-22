#!/bin/bash
# systemd-networkd が、自分で管理していないポリシールールと経路を、起動・再起動のたびに消さないようにする(kigawa-net/infra#238)。
#
# 背景: systemd-networkd は、既定で ManageForeignRoutingPolicyRules=yes / ManageForeignRoutes=yes。再起動すると、
#       他のもの(wg-quick の PostUp、FRR、手動)が入れた ip rule と、経路を、消す。
#       2026-10-21 06:21 UTC、k8s2 の networkd が再起動(パッケージの更新に伴う)され、wg1 の PostUp で入れた
#       `ip rule from 10.0.0.0/24 to 172.31.254.2/32 lookup 200` と table 200 の経路が消え、IONOS から API の VIP と k8s2 に届かなくなった。
#
# このスクリプトは、drop-in を置くだけ。**networkd は、再起動しない**(再起動すると、今ある外部のルール・経路が、消える可能性がある。
# また、CI の SSH 経路が切れる恐れがある)。設定は、次に networkd が起動するとき(再起動、パッケージの更新)から、効く。冪等。
# 環境変数: CONF_DIR(既定 /etc/systemd/networkd.conf.d。テスト用)
set -euo pipefail

CONF_DIR=${CONF_DIR:-/etc/systemd/networkd.conf.d}
FILE="$CONF_DIR/10-keep-foreign.conf"

install -d -m 0755 "$CONF_DIR"
tmp=$(mktemp)
cat > "$tmp" <<'EOF'
# kigawa-net/infra#238 で管理。networkd が、自分の管理外のポリシールールと経路を、消さないようにする。
# (wg-quick の PostUp、FRR(zebra)、手動で入れたものを、networkd の再起動で消されないようにするため)
[Network]
ManageForeignRoutingPolicyRules=no
ManageForeignRoutes=no
EOF
if [ -f "$FILE" ] && cmp -s "$tmp" "$FILE"; then
    echo "networkd-keep-foreign: 変更なし($FILE)"
    rm -f "$tmp"
else
    install -m 0644 "$tmp" "$FILE"
    rm -f "$tmp"
    echo "networkd-keep-foreign: 設置($FILE)。networkd の次の起動から有効(今は、再起動しない)"
fi

# 確認(読み取りだけ): 有効な設定に、2 行が入っているか
if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze cat-config systemd/networkd.conf 2>/dev/null | grep -E '^Manage(ForeignRoutingPolicyRules|ForeignRoutes)=' | sed 's/^/  effective: /' || true
fi
