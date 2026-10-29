#!/usr/bin/env bash
# overlay-fw-iptables.sh のオフラインテスト。状態を持つ偽の iptables と systemctl を使うので、実機のファイアウォールには触れない。
# 使い方: bash hardware/modules/easytier/test-overlay-fw-iptables.sh
set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$here/files/overlay-fw-iptables.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fails=0
check() { # 名前 期待 実際
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 (expected=$2 actual=$3)"; fails=$((fails + 1)); fi
}

mkdir -p "$work/fakebin"
# 偽 iptables: $FAKE_STATE に「chain:名前」と「rule:チェイン 引数」を、追加順に持つ。
cat > "$work/fakebin/iptables" <<'EOS'
#!/usr/bin/env bash
st="$FAKE_STATE"; touch "$st"
op="$1"; shift
case "$op" in
  -N) grep -qxF "chain:$1" "$st" && exit 1; echo "chain:$1" >> "$st" ;;
  -F) grep -qxF "chain:$1" "$st" || exit 1; grep -vF "rule:$1 " "$st" > "$st.n"; mv "$st.n" "$st" ;;
  -X) grep -qxF "chain:$1" "$st" || exit 1; grep -vxF "chain:$1" "$st" > "$st.n"; mv "$st.n" "$st" ;;
  -A) c="$1"; shift; echo "rule:$c $*" >> "$st" ;;
  -I) c="$1"; shift; shift; echo "rule:$c $*" >> "$st" ;;
  -C) c="$1"; shift; grep -qxF "rule:$c $*" "$st" ;;
  -D) c="$1"; shift; grep -qxF "rule:$c $*" "$st" || exit 1; grep -vxF "rule:$c $*" "$st" > "$st.n"; mv "$st.n" "$st" ;;
  -S) grep -F "rule:$1 " "$st" ;;
esac
EOS
printf '#!/bin/sh\necho "systemctl $*" >> "$FAKE_LOG"\n' > "$work/fakebin/systemctl"
chmod +x "$work/fakebin/"*

run() { # 環境変数は呼び出し側で渡す
  PATH="$work/fakebin:$PATH" FAKE_STATE="$work/state" FAKE_LOG="$work/log" \
    OF_CONF="$work/root/etc/overlay-fw.conf" OF_HELPER="$work/root/sbin/easytier-overlay-fw" \
    OF_DROPIN_DIR="$work/root/dropin" bash "$script" > "$work/out" 2>&1
}
reset() { rm -rf "$work/root" "$work/state" "$work/log"; : > "$work/log"; }
chain_rules() { grep '^rule:EASYTIER-OVERLAY ' "$work/state" | sed 's/^rule:EASYTIER-OVERLAY //'; }
helper() { PATH="$work/fakebin:$PATH" FAKE_STATE="$work/state" bash "$work/root/sbin/easytier-overlay-fw" "$@"; }

# 1. 許可リストなし: established / icmp / DROP だけ。DROP が最後
reset; OF_CIDR=10.250.0.0/24 run; rc=$?
check "許可リストなしでも成功する" 0 "$rc"
check "チェインを作る" 1 "$(grep -cxF 'chain:EASYTIER-OVERLAY' "$work/state")"
check "INPUT から Overlay の送信元だけをチェインへ飛ばす" 1 "$(grep -cxF 'rule:INPUT -s 10.250.0.0/24 -j EASYTIER-OVERLAY' "$work/state")"
check "許可リストなしのルール数は 3(established・icmp・DROP)" 3 "$(chain_rules | wc -l)"
check "DROP が最後" "-j DROP" "$(chain_rules | tail -n1)"
check "established を許可する" 1 "$(chain_rules | grep -c 'ESTABLISHED,RELATED -j ACCEPT')"
check "icmp を許可する" 1 "$(chain_rules | grep -c '^-p icmp -j ACCEPT')"

# 2. 許可リストあり: ポートの ACCEPT が DROP より前
reset; OF_CIDR=10.250.0.0/24 OF_ALLOW="22/tcp 8201/tcp 53/udp" run; rc=$?
check "許可リストありでも成功する" 0 "$rc"
check "22/tcp を許可する" 1 "$(chain_rules | grep -cxF -- '-p tcp --dport 22 -j ACCEPT')"
check "8201/tcp を許可する" 1 "$(chain_rules | grep -cxF -- '-p tcp --dport 8201 -j ACCEPT')"
check "53/udp を許可する" 1 "$(chain_rules | grep -cxF -- '-p udp --dport 53 -j ACCEPT')"
check "許可リストありでも DROP が最後" "-j DROP" "$(chain_rules | tail -n1)"
check "ルール数は 6(established・icmp・3 ポート・DROP)" 6 "$(chain_rules | wc -l)"

# 3. 冪等: 2 回 apply しても、INPUT の飛ばし先が重複せず、チェインのルールも増えない
helper apply; helper apply
check "再 apply で INPUT のルールが重複しない" 1 "$(grep -cxF 'rule:INPUT -s 10.250.0.0/24 -j EASYTIER-OVERLAY' "$work/state")"
check "再 apply でチェインのルールが増えない" 6 "$(chain_rules | wc -l)"
check "再 apply でチェインが重複しない" 1 "$(grep -cxF 'chain:EASYTIER-OVERLAY' "$work/state")"

# 4. remove: 飛ばし先とチェインが消える
helper remove
check "remove で INPUT のルールが消える" 0 "$(grep -c '^rule:INPUT ' "$work/state")"
check "remove でチェインが消える" 0 "$(grep -c 'EASYTIER-OVERLAY' "$work/state")"
helper remove; check "remove は何度でも成功する" 0 "$?"

# 5. systemd の drop-in と設定
reset; OF_CIDR=10.250.0.0/24 OF_ALLOW="22/tcp" run
d="$work/root/dropin/overlay-fw.conf"
check "drop-in に ExecStartPost(apply)がある" 1 "$(grep -c "^ExecStartPost=$work/root/sbin/easytier-overlay-fw apply" "$d")"
check "drop-in の ExecStopPost は失敗を無視する(-)" 1 "$(grep -c "^ExecStopPost=-$work/root/sbin/easytier-overlay-fw remove" "$d")"
check "設定に CIDR を書く" 1 "$(grep -c '^CIDR="10.250.0.0/24"' "$work/root/etc/overlay-fw.conf")"
check "daemon-reload する" 1 "$(grep -c 'systemctl daemon-reload' "$work/log")"
check "easytier は再起動しない(tunnel を切らない)" 0 "$(grep -c 'restart\|stop' "$work/log")"

# 6. OF_CIDR なしは失敗する(何も作らない)
reset; run; rc=$?
check "OF_CIDR なしは失敗する" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "OF_CIDR なしでは何も作らない" 0 "$([ -e "$work/state" ] && wc -l < "$work/state" || echo 0)"

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
