#!/bin/bash
# 既存の wg-quick の設定(/etc/wireguard/<iface>.conf)に、`Table = off` と、必要な PostUp を、追記する(kigawa-net/infra#238)。
# **インターフェースは、再起動しない**(再起動すると、IONOS との接続や、CI の SSH 経路が、切れる恐れがある)。設定は、次に wg-quick が起動するとき(再起動)から、効く。冪等。
#
# 背景: wg-quick は、起動のたびに、AllowedIPs の全てを、カーネルの経路として追加する(`ip route add`)。k8s4 は、wg1(IONOS)と wg-oracle(Oracle)の
#       両方の AllowedIPs に 10.255.10.12/32(Soichiro)があり、**再起動の起動順で、wg1 が先に経路を取ると、wg-oracle の `ip route add` が File exists で失敗し、
#       インターフェースごと消えた**(2026-10-18 14:21 UTC から 4 日間、wg-oracle が死んでいた)。さらに、wg1 は、起動のたびに、172.31.254.0/24 の
#       on-link の経路を作る(BGP の経路より優先される誤った経路。セットアップのスクリプトが 1 回だけ消す作りで、再起動で復活する)。
#       `Table = off` で、AllowedIPs からの経路の自動追加を止め(AllowedIPs 自体は変わらない。暗号鍵ルーティングは、そのまま)、
#       必要な経路だけを、PostUp の `ip route replace` で、明示的に入れる(replace なので、衝突しない)。
#
# 入力: SPEC(1 行ずつ。`<iface>|<PostUp のコマンド>`。コマンドが空なら、Table = off だけ)。WG_DIR(既定 /etc/wireguard。テスト用)
# 設定ファイルには、秘密鍵が入っている。**バックアップは作らず、中身を出力しない。**
set -euo pipefail

WG_DIR=${WG_DIR:-/etc/wireguard}
: "${SPEC:?SPEC が未設定}"

patch_iface() { # $1 = iface, $2... = PostUp のコマンド(複数可)
    local iface=$1; shift
    local conf="$WG_DIR/$iface.conf"
    if [ ! -f "$conf" ]; then echo "wg-conf-table-off: $iface.conf が無い。スキップ"; return 0; fi
    local changed=0
    local tmp; tmp=$(mktemp "$WG_DIR/.${iface}.conf.XXXXXX")
    chmod 600 "$tmp"
    cp "$conf" "$tmp"   # 内容は、出力しない

    # 1. Table = off(無ければ、[Interface] の直後に)
    if ! grep -qE '^[[:space:]]*Table[[:space:]]*=' "$tmp"; then
        sed -i '0,/^\[Interface\]/s//[Interface]\nTable = off/' "$tmp"
        changed=1
    elif ! grep -qE '^[[:space:]]*Table[[:space:]]*=[[:space:]]*off[[:space:]]*$' "$tmp"; then
        echo "wg-conf-table-off: $iface に、off 以外の Table の設定がある。上書きしない" >&2
        rm -f "$tmp"; return 1
    fi

    # 2. PostUp(無ければ、Table の行の直後に)
    local cmd
    for cmd in "$@"; do
        [ -n "$cmd" ] || continue
        if ! grep -qxF "PostUp = $cmd" "$tmp"; then
            # sed の置換に使う特殊文字(/ & \)を、エスケープする
            local esc; esc=$(printf '%s' "PostUp = $cmd" | sed -e 's/[\/&\\]/\\&/g')
            sed -i "0,/^Table = off\$/s//Table = off\n$esc/" "$tmp"
            changed=1
        fi
    done

    if [ "$changed" = 1 ]; then
        # 検証: [Interface] が壊れていない(Table = off が 1 つ)、PrivateKey の行が残っている(中身は出さない)
        [ "$(grep -cE '^[[:space:]]*Table[[:space:]]*=[[:space:]]*off' "$tmp")" = 1 ] || { echo "wg-conf-table-off: $iface の検証に失敗(Table の行の数)" >&2; rm -f "$tmp"; return 1; }
        grep -qE '^[[:space:]]*PrivateKey[[:space:]]*=' "$tmp" || { echo "wg-conf-table-off: $iface の検証に失敗(PrivateKey の行が無い)" >&2; rm -f "$tmp"; return 1; }
        chmod 600 "$tmp"
        mv "$tmp" "$conf"
        echo "wg-conf-table-off: $iface.conf を更新(Table = off。インターフェースは再起動しない。次の wg-quick の起動から有効)"
    else
        rm -f "$tmp"
        echo "wg-conf-table-off: $iface.conf は変更なし"
    fi
}

# SPEC を、iface ごとにまとめて処理する
ifaces=$(printf '%s\n' "$SPEC" | awk -F'|' 'NF>=1 && $1!="" {print $1}' | awk '!seen[$0]++')
for iface in $ifaces; do
    cmds=()
    while IFS= read -r line; do
        cmds+=("$line")
    done < <(printf '%s\n' "$SPEC" | awk -F'|' -v i="$iface" '$1==i { sub(/^[^|]*\|?/, ""); print }')
    patch_iface "$iface" "${cmds[@]}"
done
