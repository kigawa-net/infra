#!/usr/bin/env bash
# wireguard module のセットアップ・スクリプト(provisioner "file" の `<<-SCRIPT`)の回帰テスト(#286)。
#   - heredoc の終端 `WG_EOF` が、描画後に列 0 にある(`<<-` は全行の最小のインデントを取り除くので、列 0 の行が 1 つあると、
#     インデントが除かれず、終端が壊れて、スクリプトの残りが設定ファイルに書き込まれる)
#   - `bash -n` が通る
#   - 設定を生成する部分を、実際に(一時ディレクトリで)実行して、できた設定ファイルに、wg-quick が解釈できない行がない
# Docker(hashicorp/terraform:1.6)で描画する。ネットワーク・本番には触れない。使い方: bash test-render.sh
set -uo pipefail
MOD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
ng() { fail=$((fail + 1)); echo "FAIL - $1"; }

mkdir -p "$T/tf" "$T/d"
cp "$MOD/variables.tf" "$T/tf/variables.tf"
# main.tf から、先頭の locals ブロックと、provisioner "file" の heredoc を取り出して、描画用のルートモジュールにする
python3 -I - "$MOD/main.tf" "$T/tf/main.tf" <<'PY'
import re
import sys

src = open(sys.argv[1]).read()
m_locals = re.match(r'(locals \{.*?\n\}\n)', src, re.S)
m_script = re.search(r'content\s*=\s*<<-SCRIPT\n(.*?)\n\s*SCRIPT\n', src, re.S)
assert m_locals and m_script, 'main.tf の構造が想定と違います(locals / SCRIPT)'
out = m_locals.group(1) + '\nlocals {\n  script = <<-SCRIPT\n' + m_script.group(1) + '\n  SCRIPT\n}\n\noutput "script" { value = local.script }\n'
open(sys.argv[2], 'w').write(out)
PY
[ -s "$T/tf/main.tf" ] || { echo "描画用の main.tf を作れませんでした"; exit 2; }

render() { # $1=名前 $2...=terraform の -var
  local name=$1
  shift
  echo "local.script" | docker run --rm -i -u "$(id -u):$(id -g)" -e TF_DATA_DIR=/d -v "$T/d:/d" -v "$T/tf:/w" -w /w \
    hashicorp/terraform:1.6 console -no-color \
    -var host=h -var ssh_user=u -var ssh_private_key=k -var sudo_password=p \
    -var wireguard_address=172.31.252.6/30 -var server_public_key=OH5QiXaMfpmH8nHVU1Onnfom4BZcq4zx5Ux6R6R4LR0= \
    "$@" > "$T/$name.raw" 2> "$T/$name.err" || { echo "terraform console が失敗しました($name)"; cat "$T/$name.err"; return 1; }
  # console は、複数行の文字列を <<EOT ... EOT で出す。外側の 2 行を除く
  sed -e '1d' -e '$d' "$T/$name.raw" > "$T/$name.sh"
}

check() { # $1=名前 $2=table_off(true/false) $3=PostUp の期待数
  local name=$1 table_off=$2 postups=$3 f="$T/$1.sh"
  [ -s "$f" ] || { ng "$name: 描画できていない"; return; }
  bash -n "$f" 2> "$T/$name.syntax" && ok "$name: bash -n が通る" || { ng "$name: bash -n が失敗"; cat "$T/$name.syntax"; }
  # 終端 WG_EOF が、列 0 にある
  grep -qx 'WG_EOF' "$f" && ok "$name: heredoc の終端 WG_EOF が列 0 にある" || ng "$name: heredoc の終端 WG_EOF が列 0 にない(スクリプトの残りが設定に混ざる)"
  # 設定を生成する部分(`cat > ...conf <<WG_EOF` から WG_EOF まで)だけを、一時ディレクトリで実行する
  mkdir -p "$T/$name.etc"
  awk '/cat > \/etc\/wireguard\/.*<<WG_EOF/ {on=1} on {print} /^WG_EOF$/ {on=0}' "$f" \
    | sed "s#/etc/wireguard#$T/$name.etc#g" > "$T/$name.gen.sh"
  [ -s "$T/$name.gen.sh" ] || { ng "$name: 設定の生成部分を取り出せない"; return; }
  (private_key=DUMMYPRIVATEKEY; . "$T/$name.gen.sh") > /dev/null 2>&1
  local conf
  conf=$(ls "$T/$name.etc"/*.conf 2> /dev/null | head -1)
  [ -n "$conf" ] || { ng "$name: 設定ファイルができていない"; return; }
  # wg-quick が解釈する行: 空行、コメント、セクション見出し、`キー = 値`
  local bad
  bad=$(grep -nvE '^[[:space:]]*($|#|\[(Interface|Peer)\]|(Address|ListenPort|PrivateKey|PostUp|PostDown|PreUp|PreDown|Table|MTU|DNS|SaveConfig|FwMark|PublicKey|PresharedKey|AllowedIPs|Endpoint|PersistentKeepalive)[[:space:]]*=)' "$conf" || true)
  [ -z "$bad" ] && ok "$name: 設定ファイルに、解釈できない行がない" || { ng "$name: 設定ファイルに解釈できない行がある"; echo "$bad" | cut -c1-80; }
  # スクリプトの残りが混ざっていない(混ざっていると、systemctl の行などが入る)
  ! grep -qE 'systemctl|chmod|WG_EOF|wg show' "$conf" && ok "$name: 設定ファイルに、スクリプトの残りが混ざっていない" || ng "$name: 設定ファイルに、スクリプトの残りが混ざっている"
  # Table = off と PostUp の数
  local has_table
  has_table=$(grep -cE '^[[:space:]]*Table[[:space:]]*=[[:space:]]*off' "$conf" || true)
  if [ "$table_off" = true ]; then
    [ "$has_table" = 1 ] && ok "$name: Table = off がある" || ng "$name: Table = off がない"
  else
    [ "$has_table" = 0 ] && ok "$name: Table = off がない(table_off = false)" || ng "$name: table_off = false なのに Table = off がある"
  fi
  local n
  n=$(grep -cE '^[[:space:]]*PostUp[[:space:]]*=' "$conf" || true)
  [ "$n" = "$postups" ] && ok "$name: PostUp が $postups 行" || ng "$name: PostUp が $n 行(期待: $postups)"
  # [Interface] が先頭、[Peer] がその後にある
  [ "$(grep -nE '^[[:space:]]*\[Interface\]' "$conf" | head -1 | cut -d: -f1)" -lt "$(grep -nE '^[[:space:]]*\[Peer\]' "$conf" | head -1 | cut -d: -f1)" ] \
    && ok "$name: [Interface] が [Peer] より前にある" || ng "$name: [Interface] / [Peer] の順序が不正"
}

# 1. table_off = false(既定): 従来の構成(k8s1 / k8s4 など)
render default && check default false 0
# 2. table_off = true、extra_post_up が 1 行
render postup1 -var table_off=true -var 'extra_post_up=["ip route add 172.31.254.2/32 dev %i"]' && check postup1 true 1
# 3. table_off = true、extra_post_up が複数行(`||` と `2>/dev/null` を含む。k8s2 の wg1 と同じ)
render postup5 -var table_off=true \
  -var 'extra_post_up=["ip route add 172.31.254.2/32 dev %i","ip rule del from 10.0.0.0/24 to 172.31.254.2/32 lookup 200 priority 100 2>/dev/null || true","ip route replace 172.31.254.2/32 via 10.0.0.140 dev enp0s31f6 table 200 || true","ip rule add from 10.0.0.0/24 to 172.31.254.2/32 lookup 200 priority 100 || true"]' \
  && check postup5 true 4
# 4. table_off = true、PostUp なし(wg-ionos と同じ)
render notpostup -var table_off=true && check notpostup true 0

echo "--- $pass passed, $fail failed"
exit $((fail > 0))
