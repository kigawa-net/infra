#!/usr/bin/env bash
# bgp-frr module のセットアップ・スクリプトの、FRR の「何もしない / reload / 停止・起動」の判定のテスト。
#   - module を、そのままルートモジュールとして、Docker(hashicorp/terraform:1.6)の `terraform console` で `local.setup_script` を描画する
#   - `bash -n` が通る
#   - 判定部分(`already_running=false` から、停止・起動の本体の `if` まで)を取り出して、偽の systemctl / grep 対象で実行し、
#     4 つの場面を確認する(変更なし → 何もしない、設定の変更 → reload、reload 失敗 → 停止・起動に進む、停止中 → 停止・起動に進む)
# ネットワーク・本番には触れない。使い方: bash test-reload.sh
set -uo pipefail
MOD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
ng() { fail=$((fail + 1)); echo "FAIL - $1"; }

mkdir -p "$T/tf/templates" "$T/d"
cp "$MOD/variables.tf" "$T/tf/"
cp "$MOD"/templates/* "$T/tf/templates/"
# main.tf から、先頭の locals ブロック(setup_script を含む)だけを取り出す(リソース・provider なしで、console を動かすため)
python3 -I - "$MOD/main.tf" "$T/tf/main.tf" <<'PY'
import re
import sys

src = open(sys.argv[1]).read()
m = re.search(r'(?m)^(locals \{.*?\n\}\n)', src, re.S)
assert m and 'setup_script' in m.group(1), 'main.tf の構造が想定と違います(先頭の locals に setup_script がありません)'
open(sys.argv[2], 'w').write(m.group(1))
PY
[ -s "$T/tf/main.tf" ] || { echo "描画用の main.tf を作れませんでした"; exit 2; }
echo 'local.setup_script' | docker run --rm -i -u "$(id -u):$(id -g)" -e TF_DATA_DIR=/d -v "$T/d:/d" -v "$T/tf:/w" -w /w \
  hashicorp/terraform:1.6 console -no-color \
  -var host=h -var ssh_user=u -var ssh_private_key=k -var sudo_password=p -var bgp_router_id=10.0.0.1 \
  > "$T/script.raw" 2> "$T/script.err" || { echo "terraform console が失敗しました"; cat "$T/script.err"; exit 2; }
sed -e '1d' -e '$d' "$T/script.raw" > "$T/script.sh"
[ -s "$T/script.sh" ] || { echo "スクリプトを描画できませんでした"; exit 2; }

bash -n "$T/script.sh" 2> "$T/syntax.err" && ok "bash -n が通る" || { ng "bash -n が失敗"; cat "$T/syntax.err"; }

# 判定部分を取り出す: `already_running=false` から、停止・起動の本体の `if ! "$already_running" && ! "$reloaded"; then`(2 つ目)の直前まで。
# ただし 1 つ目の `if ... then`(apt install などを含む前半)も、`! "$reloaded"` の条件であることを確認する
n=$(grep -c 'if ! "\$already_running" && ! "\$reloaded"; then' "$T/script.sh")
[ "$n" = 2 ] && ok "停止・起動の 2 つのブロックが、どちらも「reload 済みでなければ」の条件になっている" || ng "停止・起動のブロックの条件が不正(個数: $n)"

awk '/^[[:space:]]*already_running=false/ {on=1} on {print} /^[[:space:]]*reloaded=false/ {seen=1} seen && /^[[:space:]]*fi$/ && ++c == 2 {exit}' "$T/script.sh" > "$T/decide.sh"
# 2 つ目の fi までだと、reload の if の fi で終わる(already_running の if の fi が 1 つ目)
[ -s "$T/decide.sh" ] && grep -q 'systemctl reload frr.service' "$T/decide.sh" || { ng "判定部分を取り出せない"; echo "== 取り出した内容"; cat "$T/decide.sh"; }

# 偽の環境: systemctl(is-active と reload の結果を、環境変数で変える)、/tmp/frr-module.conf と /etc/frr を一時ディレクトリに置き換える
mkdir -p "$T/bin" "$T/etc/frr"
cat > "$T/bin/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "$FAKE_LOG"
case "$1" in
  is-active) [ "${FAKE_ACTIVE:-1}" = 1 ] ;;
  reload) [ "${FAKE_RELOAD_OK:-1}" = 1 ] ;;
  *) true ;;
esac
EOF
cat > "$T/bin/install" <<'EOF'
#!/bin/bash
# install -o frr -g frr -m 0640 SRC DST  → 所有者の指定を無視して cp する
args=()
skip=0
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in -o | -g | -m) skip=1 ;; *) args+=("$a") ;; esac
done
cp "${args[0]}" "${args[1]}"
EOF
chmod +x "$T/bin/systemctl" "$T/bin/install"
sed -e "s#/tmp/frr-module.conf#$T/frr-module.conf#g" -e "s#/etc/frr#$T/etc/frr#g" "$T/decide.sh" > "$T/decide.fake.sh"
printf 'bgpd=yes\n' > "$T/etc/frr/daemons"

# $1=FRR が動いているか(1/0) $2=reload の成否(1/0) $3=設定が同じか(same/diff) → 結果(skip / reloaded / restart)
scenario() {
  : > "$T/log"
  printf 'conf-v2\n' > "$T/frr-module.conf"
  if [ "$3" = same ]; then printf 'conf-v2\n' > "$T/etc/frr/frr.conf"; else printf 'conf-v1\n' > "$T/etc/frr/frr.conf"; fi
  local out
  out=$(PATH="$T/bin:$PATH" FAKE_LOG="$T/log" FAKE_ACTIVE="$1" FAKE_RELOAD_OK="$2" bash -c ". '$T/decide.fake.sh'; echo \"already_running=\$already_running reloaded=\$reloaded\"" 2> /dev/null | tail -1)
  case "$out" in
    "already_running=true reloaded=false") echo skip ;;
    "already_running=false reloaded=true") echo reloaded ;;
    "already_running=false reloaded=false") echo restart ;;
    *) echo "unexpected:$out" ;;
  esac
}

[ "$(scenario 1 1 same)" = skip ] && ok "動いていて、設定が同じ: 何もしない(reload もしない)" || ng "動いていて、設定が同じ"
! grep -q 'reload' "$T/log" && ok "  (同じ設定では、systemctl reload を呼ばない)" || ng "  同じ設定で reload を呼んだ"
[ "$(scenario 1 1 diff)" = reloaded ] && ok "動いていて、設定が変わった: reload する(停止・起動に進まない)" || ng "設定が変わったときの reload"
[ "$(cat "$T/etc/frr/frr.conf")" = conf-v2 ] && ok "  (新しい設定ファイルが置かれている)" || ng "  設定ファイルが更新されていない"
[ "$(scenario 1 0 diff)" = restart ] && ok "reload が失敗した: 従来どおり、停止・起動に進む" || ng "reload の失敗時"
[ "$(cat "$T/etc/frr/frr.conf")" = conf-v2 ] && ok "  (失敗しても、新しい設定ファイルは置かれている)" || ng "  失敗時に設定ファイルが更新されていない"
[ "$(scenario 0 1 diff)" = restart ] && ok "FRR が止まっている: reload せず、従来どおり、停止・起動に進む" || ng "FRR が止まっているとき"
! grep -q 'reload' "$T/log" && ok "  (止まっているとき、systemctl reload を呼ばない)" || ng "  止まっているのに reload を呼んだ"

echo "--- $pass passed, $fail failed"
exit $((fail > 0))
