#!/bin/bash
# files/wg-conf-table-off.sh と、../networkd-keep-foreign/files/networkd-keep-foreign.sh のテスト。
# 使い捨てのディレクトリで実行する(/etc には書かない)。秘密鍵は、ダミー。
#   bash hardware/modules/wg-conf-table-off/test-wg-conf-table-off.sh
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WG="$here/files/wg-conf-table-off.sh"
NW="$here/../networkd-keep-foreign/files/networkd-keep-foreign.sh"
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
ng() { fail=$((fail + 1)); echo "FAIL - $1"; [ -f "${sb:-/nonexistent}/out" ] && tail -5 "$sb/out" | sed 's/^/       | /'; }
chk() { if ( eval "$2" ); then ok "$1"; else ng "$1"; fi; }

KEY_VALUE="DUMMY-PRIVATE-KEY-DO-NOT-LEAK-$$"
mk_conf() { # $1 = path, $2 = Table 行(空なら無し)
  {
    echo "[Interface]"
    echo "Address = 172.31.254.1/30"
    echo "PrivateKey = $KEY_VALUE"
    echo "MTU = 1420"
    [ -n "${2:-}" ] && echo "$2"
    echo
    echo "[Peer]"
    echo "PublicKey = DUMMYPUBLICKEY="
    echo "AllowedIPs = 172.31.254.0/24, 10.255.10.12/32"
    echo "Endpoint = 74.208.55.86:51820"
    echo "PersistentKeepalive = 25"
  } > "$1"
  chmod 600 "$1"
}
run_wg() { env WG_DIR="$sb/wg" SPEC="$1" bash "$WG" > "$sb/out" 2>&1; }

# ---- 1. Table = off と PostUp を追記 ----
sb=$(mktemp -d); mkdir -p "$sb/wg"
mk_conf "$sb/wg/wg1.conf"
mk_conf "$sb/wg/wg-oracle.conf"
run_wg $'wg1|\nwg-oracle|ip route replace 10.255.10.12/32 dev %i'; rc=$?
chk "終了コード 0" '[ "$rc" = 0 ]'
chk "wg1: Table = off を [Interface] に追記" 'sed -n "/^\[Interface\]/,/^\[Peer\]/p" "$sb/wg/wg1.conf" | grep -qx "Table = off"'
chk "wg1: PostUp は足さない" '! grep -q "^PostUp" "$sb/wg/wg1.conf"'
chk "wg-oracle: Table = off と PostUp(ip route replace)を追記" 'grep -qx "Table = off" "$sb/wg/wg-oracle.conf" && grep -qx "PostUp = ip route replace 10.255.10.12/32 dev %i" "$sb/wg/wg-oracle.conf"'
chk "wg-oracle: PostUp は [Interface] の中(Peer より前)" '[ "$(grep -n "^PostUp" "$sb/wg/wg-oracle.conf" | cut -d: -f1)" -lt "$(grep -n "^\[Peer\]" "$sb/wg/wg-oracle.conf" | cut -d: -f1)" ]'
chk "AllowedIPs は変わらない(暗号鍵ルーティングは、そのまま)" 'grep -qx "AllowedIPs = 172.31.254.0/24, 10.255.10.12/32" "$sb/wg/wg1.conf"'
chk "他の行(Address / MTU / Endpoint / PersistentKeepalive)は残る" 'grep -qx "Address = 172.31.254.1/30" "$sb/wg/wg1.conf" && grep -qx "MTU = 1420" "$sb/wg/wg1.conf" && grep -qx "Endpoint = 74.208.55.86:51820" "$sb/wg/wg1.conf" && grep -qx "PersistentKeepalive = 25" "$sb/wg/wg1.conf"'
chk "PrivateKey の行は残る" 'grep -qx "PrivateKey = $KEY_VALUE" "$sb/wg/wg1.conf"'
chk "秘密鍵が、出力に出ない" '! grep -qF "$KEY_VALUE" "$sb/out"'
chk "権限は 600 のまま" '[ "$(stat -c %a "$sb/wg/wg1.conf")" = 600 ] && [ "$(stat -c %a "$sb/wg/wg-oracle.conf")" = 600 ]'
chk "バックアップや一時ファイルを残さない(秘密鍵のコピーを作らない)" '[ "$(ls -A "$sb/wg" | wc -l)" = 2 ]'

# ---- 2. 冪等 ----
cp "$sb/wg/wg-oracle.conf" "$sb/before.conf"
run_wg $'wg1|\nwg-oracle|ip route replace 10.255.10.12/32 dev %i'; rc=$?
chk "冪等: 2 回目も終了コード 0" '[ "$rc" = 0 ]'
chk "冪等: ファイルは変わらない" 'cmp -s "$sb/wg/wg-oracle.conf" "$sb/before.conf"'
chk "冪等: Table の行が、1 つのまま" '[ "$(grep -c "^Table" "$sb/wg/wg-oracle.conf")" = 1 ] && [ "$(grep -c "^PostUp" "$sb/wg/wg-oracle.conf")" = 1 ]'
chk "冪等: 「変更なし」と表示" 'grep -q "変更なし" "$sb/out"'
rm -rf "$sb"

# ---- 3. 既に Table = off(wg-ionos-gw と同じ) ----
sb=$(mktemp -d); mkdir -p "$sb/wg"
mk_conf "$sb/wg/wg-ionos-gw.conf" "Table = off"
cp "$sb/wg/wg-ionos-gw.conf" "$sb/before.conf"
run_wg 'wg-ionos-gw|'; rc=$?
chk "既に Table = off: 変更しない" '[ "$rc" = 0 ] && cmp -s "$sb/wg/wg-ionos-gw.conf" "$sb/before.conf"'
rm -rf "$sb"

# ---- 4. off 以外の Table: 上書きせず、失敗する ----
sb=$(mktemp -d); mkdir -p "$sb/wg"
mk_conf "$sb/wg/wg1.conf" "Table = 123"
cp "$sb/wg/wg1.conf" "$sb/before.conf"
run_wg 'wg1|'; rc=$?
chk "Table = 123: 失敗する(終了コード 非 0)" '[ "$rc" != 0 ]'
chk "Table = 123: ファイルは変わらない" 'cmp -s "$sb/wg/wg1.conf" "$sb/before.conf"'
rm -rf "$sb"

# ---- 5. 設定ファイルが無い: スキップ ----
sb=$(mktemp -d); mkdir -p "$sb/wg"
run_wg 'wg-oracle|ip route replace 10.255.10.12/32 dev %i'; rc=$?
chk "設定ファイルが無い: スキップして終了コード 0" '[ "$rc" = 0 ] && grep -q "スキップ" "$sb/out"'
rm -rf "$sb"

# ---- 6. PostUp に特殊文字(/ & \) ----
sb=$(mktemp -d); mkdir -p "$sb/wg"
mk_conf "$sb/wg/wg1.conf"
run_wg 'wg1|ip route replace 10.0.0.0/8 dev %i && echo "a&b"'; rc=$?
chk "特殊文字を含む PostUp が、そのまま入る" '[ "$rc" = 0 ] && grep -qxF "PostUp = ip route replace 10.0.0.0/8 dev %i && echo \"a&b\"" "$sb/wg/wg1.conf"'
rm -rf "$sb"

# ---- 7. networkd-keep-foreign ----
sb=$(mktemp -d)
env CONF_DIR="$sb/conf.d" bash "$NW" > "$sb/out" 2>&1; rc=$?
chk "networkd: 終了コード 0" '[ "$rc" = 0 ]'
chk "networkd: ManageForeignRoutingPolicyRules=no と ManageForeignRoutes=no を置く" 'grep -qx "ManageForeignRoutingPolicyRules=no" "$sb/conf.d/10-keep-foreign.conf" && grep -qx "ManageForeignRoutes=no" "$sb/conf.d/10-keep-foreign.conf" && grep -qx "\[Network\]" "$sb/conf.d/10-keep-foreign.conf"'
chk "networkd: 権限 644" '[ "$(stat -c %a "$sb/conf.d/10-keep-foreign.conf")" = 644 ]'
cp "$sb/conf.d/10-keep-foreign.conf" "$sb/before"
env CONF_DIR="$sb/conf.d" bash "$NW" > "$sb/out" 2>&1; rc=$?
chk "networkd 冪等: 2 回目は変更なし" '[ "$rc" = 0 ] && cmp -s "$sb/conf.d/10-keep-foreign.conf" "$sb/before" && grep -q "変更なし" "$sb/out"'
chk "networkd: networkd を再起動しない(スクリプトに restart が無い)" '! grep -v "^[[:space:]]*#" "$NW" | grep -qE "systemctl[^|;]*(restart|reload|try-restart)"'
rm -rf "$sb"

# ---- 8. 構文 ----
chk "wg-conf-table-off.sh の構文" 'bash -n "$WG"'
chk "networkd-keep-foreign.sh の構文" 'bash -n "$NW"'

echo "---"
echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
