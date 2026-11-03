#!/usr/bin/env bash
# gre-overlay-ufw.sh のオフラインテスト。状態を持つ偽の ufw を使うので、実機のファイアウォールには触れない。
# 使い方: bash hardware/modules/gre-overlay-ufw/test-gre-overlay-ufw.sh
set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$here/files/gre-overlay-ufw.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fails=0
check() { # 名前 期待 実際
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 (expected=$2 actual=$3)"; fails=$((fails + 1)); fi
}

mkdir -p "$work/fakebin"
# 偽 ufw: $FAKE_STATE に、規則を「<規則> # <コメント>」の 1 行で、先頭に入れた順(insert 1)に持つ。
cat > "$work/fakebin/ufw" <<'EOS'
#!/usr/bin/env bash
st="$FAKE_STATE"; touch "$st"
case "$1" in
  status) cat "$st" ;;
  insert)
    shift 2   # insert 1
    rule=(); comment=""
    while [ $# -gt 0 ]; do
      if [ "$1" = comment ]; then comment=$2; shift 2; else rule+=("$1"); shift; fi
    done
    { echo "${rule[*]} # $comment"; cat "$st"; } > "$st.n"; mv "$st.n" "$st" ;;
esac
EOS
chmod +x "$work/fakebin/ufw"

run() { PATH="$work/fakebin:$PATH" FAKE_STATE="$work/state" bash "$script" > "$work/out" 2>&1; }
reset() { rm -f "$work/state"; }
rules() { grep -c . "$work/state" 2>/dev/null || echo 0; }

# 1. 相手 2 つ: 1 つあたり gre と 179/tcp の 2 規則
reset; GU_PEERS="k8s4,10.250.0.11,172.31.250.1;k8s1,10.250.0.12,172.31.250.3" run; rc=$?
check "成功する" 0 "$rc"
check "規則は 4 つ(相手 2 × 2)" 4 "$(rules)"
check "gre を tun0 で、相手の Overlay から許可する" 1 "$(grep -cxF 'allow in on tun0 proto gre from 10.250.0.11 # gre-overlay-k8s4-gre' "$work/state")"
check "179/tcp を gre-k8s4 で、相手のトンネルのアドレスから許可する" 1 "$(grep -cxF 'allow in on gre-k8s4 proto tcp from 172.31.250.1 to any port 179 # gre-overlay-k8s4-bgp' "$work/state")"
check "2 つ目の相手の gre も許可する" 1 "$(grep -cxF 'allow in on tun0 proto gre from 10.250.0.12 # gre-overlay-k8s1-gre' "$work/state")"

# 2. 冪等
GU_PEERS="k8s4,10.250.0.11,172.31.250.1;k8s1,10.250.0.12,172.31.250.3" run; rc=$?
check "再実行も成功する" 0 "$rc"
check "再実行で規則が増えない" 4 "$(rules)"

# 3. 相手を足すと、足した分だけが増える
GU_PEERS="k8s4,10.250.0.11,172.31.250.1;k8s1,10.250.0.12,172.31.250.3;k8s2,10.250.0.13,172.31.250.5" run
check "相手を足すと 2 つだけ増える" 6 "$(rules)"

# 4. 不正な定義は、何も足さずに失敗する
reset; GU_PEERS="k8s4,10.250.0.11,172.31.250.1;bad,10.250.0.999,172.31.250.3" run; rc=$?
check "不正な IP は失敗する" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "不正な定義では、先頭の正しい相手の規則も足さない" 0 "$(rules)"
reset; GU_PEERS="BAD_NAME,10.250.0.11,172.31.250.1" run; rc=$?
check "不正な名前は失敗する" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
reset; GU_PEERS="k8s4,10.250.0.11" run; rc=$?
check "項目が足りない定義は失敗する" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
reset; GU_PEERS="k8s4,10.250.0.11,172.31.250.1,extra" run; rc=$?
check "項目が多い定義は失敗する" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

# 5. GU_PEERS なしは失敗する(ufw が無いときの失敗は、スクリプトが PATH を足すので、このテストでは再現できない)
reset; run; rc=$?
check "GU_PEERS なしは失敗する" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
