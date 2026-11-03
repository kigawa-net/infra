#!/bin/bash
# files/maas-wol-webhook-install.sh のテスト(偽の systemctl / python3)と、files/maas-wol-webhook.py の単体テストの実行。実機には触れない。
#   bash hardware/modules/maas-rack/test-maas-wol-webhook.sh
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTALL="$here/files/maas-wol-webhook-install.sh"
PYSRC="$here/files/maas-wol-webhook.py"
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
ng() { fail=$((fail + 1)); echo "FAIL - $1"; [ -f "${sb:-/nonexistent}/out" ] && tail -6 "$sb/out" | sed 's/^/       | /'; }
chk() { if ( eval "$2" ); then ok "$1"; else ng "$1"; fi; }

# 環境変数: ACTIVE=0(systemctl is-active が inactive を返す)、PYFAIL=1(python3 が失敗する)、KEYGEN_FAIL=1(ssh-keygen -y が失敗する)
mksb() {
  sb=$(mktemp -d)
  mkdir -p "$sb/bin" "$sb/sbin" "$sb/units"
  : > "$sb/calls"
  cp "$PYSRC" "$sb/src.py"
  cat > "$sb/bin/systemctl" <<EOF
#!/bin/bash
echo "systemctl \$*" >> "$sb/calls"
if [ "\$1" = is-active ]; then [ "${ACTIVE:-1}" = 1 ] && exit 0 || exit 3; fi
exit 0
EOF
  cat > "$sb/bin/python3" <<EOF
#!/bin/bash
[ "${PYFAIL:-0}" = 1 ] && exit 1
exit 0
EOF
  # SSH のシャットダウンの設定の検査(ssh-keygen -y -f)と、ssh の存在の確認だけ。実際の鍵は読まない
  cat > "$sb/bin/ssh-keygen" <<EOF
#!/bin/bash
echo "ssh-keygen \$*" >> "$sb/calls"
[ "${KEYGEN_FAIL:-0}" = 1 ] && exit 1
exit 0
EOF
  cat > "$sb/bin/ssh" <<EOF
#!/bin/bash
exit 0
EOF
  chmod +x "$sb"/bin/*
}

run() { # 引数: 追加の環境変数(KEY=VAL ...)。CONF_DIR は、必ず一時ディレクトリにする(実機の /etc に触れない)
  [ -f "$sb/src.py" ] || cp "$PYSRC" "$sb/src.py"
  env EXTRA_PATH="$sb/bin" SBIN_DIR="$sb/sbin" UNIT_DIR="$sb/units" CONF_DIR="$sb/conf" SRC="$sb/src.py" BCAST=192.168.1.255 SKIP_VERIFY=1 VERIFY_TRIES=2 "$@" bash "$INSTALL" > "$sb/out" 2>&1
}

# シャットダウンの設定の元ファイル(中身はダミー。秘密鍵の形式は、偽の ssh-keygen が判定する)
mkshutdown_src() {
  printf '%s\n' '{"02:39:7a:2e:13:f0": {"host": "192.168.1.150", "user": "maas-shutdown"}}' > "$sb/t.json"
  printf '%s\n' 'DUMMY-PRIVATE-KEY-FOR-TEST' > "$sb/k"
  printf '%s\n' '192.168.1.150 ssh-ed25519 DUMMY-HOST-KEY' > "$sb/kh"
  printf '%s\n' 'TEST-TOKEN-0123456789abcdefABCDEF._~+/=-' > "$sb/tok"
}

# ---- 1. 初回 ----
mksb
run; rc=$?
chk "初回: 終了コード 0" '[ "$rc" = 0 ]'
chk "初回: スクリプトを置いた(実行可能)" '[ -x "$sb/sbin/maas-wol-webhook.py" ]'
chk "初回: 元のファイルを消した" '[ ! -e "$sb/src.py" ]'
chk "初回: ユニットに BCAST と、ループバックの BIND" 'grep -qx "Environment=BCAST=192.168.1.255" "$sb/units/maas-wol-webhook.service" && grep -qx "Environment=BIND=127.0.0.1" "$sb/units/maas-wol-webhook.service"'
chk "初回: ユニットのサンドボックス(NoNewPrivileges・ProtectSystem・権限の制限)" 'grep -qx "NoNewPrivileges=true" "$sb/units/maas-wol-webhook.service" && grep -qx "ProtectSystem=strict" "$sb/units/maas-wol-webhook.service" && grep -qx "CapabilityBoundingSet=CAP_NET_RAW" "$sb/units/maas-wol-webhook.service"'
chk "初回: daemon-reload・enable・restart" 'grep -q "^systemctl daemon-reload" "$sb/calls" && grep -q "^systemctl enable maas-wol-webhook.service" "$sb/calls" && grep -q "^systemctl restart maas-wol-webhook.service" "$sb/calls"'

# ---- 2. 冪等: 変更なし ----
: > "$sb/calls"
run; rc=$?
chk "冪等: 終了コード 0 で、変更なしと表示" '[ "$rc" = 0 ] && grep -q "変更なし" "$sb/out"'
chk "冪等: 再起動しない(active のとき)" '! grep -q "^systemctl restart" "$sb/calls"'
rm -rf "$sb"

# ---- 3. 止まっていれば、変更がなくても起動する ----
ACTIVE=0 mksb
run >/dev/null
: > "$sb/calls"
run; rc=$?
chk "inactive: 変更がなくても、restart する" '[ "$rc" = 0 ] && grep -q "^systemctl restart maas-wol-webhook.service" "$sb/calls"'
rm -rf "$sb"

# ---- 4. スクリプトが変わったら、再起動 ----
mksb
run >/dev/null
echo "# changed" >> "$sb/src.py" 2>/dev/null || { cp "$PYSRC" "$sb/src.py"; echo "# changed" >> "$sb/src.py"; }
: > "$sb/calls"
run; rc=$?
chk "スクリプトの更新: restart する" '[ "$rc" = 0 ] && grep -q "^systemctl restart maas-wol-webhook.service" "$sb/calls" && grep -q "# changed" "$sb/sbin/maas-wol-webhook.py"'
rm -rf "$sb"

# ---- 5. 入力の検証 ----
mksb
run BCAST=bcast; rc=$?
chk "BCAST が不正: 中止し、何も呼ばない" '[ "$rc" = 1 ] && [ ! -s "$sb/calls" ] && [ ! -e "$sb/sbin/maas-wol-webhook.py" ]'
run PORT=abc; rc=$?
chk "PORT が不正: 中止" '[ "$rc" = 1 ] && [ ! -s "$sb/calls" ]'
rm -f "$sb/src.py"
run SRC="$sb/nonexistent.py"; rc=$?
chk "スクリプトが無い: 中止" '[ "$rc" = 1 ] && [ ! -s "$sb/calls" ]'
rm -rf "$sb"

# ---- 6. 起動後の確認(SKIP_VERIFY なし) ----
PYFAIL=1 mksb
run SKIP_VERIFY=0 PYFAIL=1; rc=$?
chk "応答しない: 失敗(終了コード 1)" '[ "$rc" = 1 ] && grep -q "応答しない" "$sb/out"'
rm -rf "$sb"
mksb
run SKIP_VERIFY=0; rc=$?
chk "応答する: 成功" '[ "$rc" = 0 ]'
rm -rf "$sb"

# ---- 6b. SSH によるシャットダウン(/off。kigawa-net/infra#416)の設定(認証トークン #417 を含む)----
TOK='TEST-TOKEN-0123456789abcdefABCDEF._~+/=-'
run_all4() { # 4 つそろえて渡す(引数: 追加の環境変数)
  run SHUTDOWN_TARGETS_SRC="$sb/t.json" SHUTDOWN_KEY_SRC="$sb/k" SHUTDOWN_KNOWN_HOSTS_SRC="$sb/kh" SHUTDOWN_AUTH_TOKEN_SRC="$sb/tok" "$@"
}
mksb
mkshutdown_src
run_all4; rc=$?
chk "設定が 4 つそろう: 成功し、表・鍵・known_hosts・トークンを置く" '[ "$rc" = 0 ] && [ -f "$sb/conf/shutdown-targets.json" ] && [ -f "$sb/conf/shutdown.key" ] && [ -f "$sb/conf/known_hosts" ] && [ -f "$sb/conf/auth-token" ]'
chk "設定が 4 つそろう: ディレクトリ 0700、鍵とトークン 0600、表と known_hosts 0644" '[ "$(stat -c %a "$sb/conf")" = 700 ] && [ "$(stat -c %a "$sb/conf/shutdown.key")" = 600 ] && [ "$(stat -c %a "$sb/conf/auth-token")" = 600 ] && [ "$(stat -c %a "$sb/conf/shutdown-targets.json")" = 644 ] && [ "$(stat -c %a "$sb/conf/known_hosts")" = 644 ]'
chk "設定が 4 つそろう: トークンの中身が、そのまま置かれる(改行は付けない)" '[ "$(cat "$sb/conf/auth-token")" = "$TOK" ]'
chk "設定が 4 つそろう: 元のファイル(鍵・トークンを含む)を消した" '[ ! -e "$sb/t.json" ] && [ ! -e "$sb/k" ] && [ ! -e "$sb/kh" ] && [ ! -e "$sb/tok" ]'
chk "設定が 4 つそろう: 鍵の形式を、置く前に(元のファイルで)ssh-keygen -y -f で検査した" 'grep -q "^ssh-keygen -y -f $sb/k\$" "$sb/calls"'
chk "設定が 4 つそろう: ユニットに、CONF_DIR の読み取り専用と SHUTDOWN_* と AUTH_TOKEN_FILE" 'grep -q "^ReadOnlyPaths=/var/lib/maas $sb/conf\$" "$sb/units/maas-wol-webhook.service" && grep -qx "Environment=SHUTDOWN_KEY=$sb/conf/shutdown.key" "$sb/units/maas-wol-webhook.service" && grep -qx "Environment=AUTH_TOKEN_FILE=$sb/conf/auth-token" "$sb/units/maas-wol-webhook.service"'
chk "設定が 4 つそろう: 出力に SSH の有効を表示し、秘密の中身は出さない" 'grep -q "SSH のシャットダウン: 有効" "$sb/out" && ! grep -q "DUMMY-PRIVATE-KEY" "$sb/out" && ! grep -q "$TOK" "$sb/out"'
: > "$sb/calls"
mkshutdown_src
run_all4; rc=$?
chk "設定が同じ: 変更なし(再起動しない)" '[ "$rc" = 0 ] && grep -q "変更なし" "$sb/out" && ! grep -q "^systemctl restart" "$sb/calls"'
rm -rf "$sb"

mksb
mkshutdown_src
run SHUTDOWN_TARGETS_SRC="$sb/t.json" SHUTDOWN_KEY_SRC="$sb/k" SHUTDOWN_KNOWN_HOSTS_SRC="$sb/kh"; rc=$?
chk "一部だけ(トークンが無い): ABORT し、何も置かず、元のファイルも残す" '[ "$rc" = 1 ] && grep -q "4 つそろえる" "$sb/out" && [ ! -e "$sb/conf/shutdown.key" ] && [ -f "$sb/t.json" ] && [ -f "$sb/k" ] && [ ! -s "$sb/calls" ]'
rm -rf "$sb"

mksb
mkshutdown_src
run SHUTDOWN_TARGETS_SRC="$sb/t.json" SHUTDOWN_KEY_SRC="$sb/k" SHUTDOWN_AUTH_TOKEN_SRC="$sb/tok"; rc=$?
chk "一部だけ(known_hosts が無い): ABORT" '[ "$rc" = 1 ] && [ ! -e "$sb/conf/shutdown.key" ] && [ -f "$sb/tok" ]'
rm -rf "$sb"

mksb
mkshutdown_src
run SHUTDOWN_TARGETS_SRC="$sb/t.json" SHUTDOWN_KNOWN_HOSTS_SRC="$sb/kh" SHUTDOWN_AUTH_TOKEN_SRC="$sb/tok"; rc=$?
chk "一部だけ(鍵が無い): ABORT" '[ "$rc" = 1 ] && [ ! -e "$sb/conf/known_hosts" ] && [ -f "$sb/kh" ]'
rm -rf "$sb"

for badtok in 'short-token' 'TEST-TOKEN-0123456789abcdef with-space-XYZ' 'TEST-TOKEN-0123456789abcdefABCDEF*x' "TEST-TOKEN-0123456789abcdefABCDEF'x"; do
  mksb
  mkshutdown_src
  printf '%s\n' "$badtok" > "$sb/tok"
  run_all4; rc=$?
  chk "トークンの形式が不正($badtok): ABORT し、何も置かない" '[ "$rc" = 1 ] && grep -q "認証トークンの形式が不正" "$sb/out" && [ ! -e "$sb/conf/auth-token" ] && [ ! -e "$sb/conf/shutdown.key" ] && [ -f "$sb/tok" ]'
  rm -rf "$sb"
done

mksb
mkshutdown_src
printf 'TEST-TOKEN-0123456789abcdefABCDEF\nsecond-line\n' > "$sb/tok"
run_all4; rc=$?
chk "トークンが 2 行: ABORT(改行は不可)" '[ "$rc" = 1 ] && [ ! -e "$sb/conf/auth-token" ]'
rm -rf "$sb"

KEYGEN_FAIL=1 mksb
mkshutdown_src
run_all4 KEYGEN_FAIL=1; rc=$?
chk "鍵の形式が不正: ABORT し、鍵を置かない(元のファイルは残す)" '[ "$rc" = 1 ] && grep -q "秘密鍵の形式が不正" "$sb/out" && [ ! -e "$sb/conf/shutdown.key" ] && [ -f "$sb/k" ]'
rm -rf "$sb"

mksb
mkshutdown_src
run SHUTDOWN_TARGETS_SRC="$sb/nonexistent.json" SHUTDOWN_KEY_SRC="$sb/k" SHUTDOWN_KNOWN_HOSTS_SRC="$sb/kh" SHUTDOWN_AUTH_TOKEN_SRC="$sb/tok"; rc=$?
chk "元のファイルが無い: ABORT" '[ "$rc" = 1 ] && grep -q "空、または無い" "$sb/out" && [ ! -e "$sb/conf/known_hosts" ]'
rm -rf "$sb"

mksb
mkshutdown_src
run_all4 >/dev/null
mkshutdown_src
run >/dev/null; rc=$?
chk "無効化(4 つとも空): 成功し、CONF_DIR の設定ファイルを消す(トークンを含む)" '[ "$rc" = 0 ] && [ ! -e "$sb/conf/shutdown-targets.json" ] && [ ! -e "$sb/conf/shutdown.key" ] && [ ! -e "$sb/conf/known_hosts" ] && [ ! -e "$sb/conf/auth-token" ]'
chk "無効化: 出力に SSH の無効を表示" 'grep -q "SSH のシャットダウン: 無効" "$sb/out"'
rm -rf "$sb"

mksb
run >/dev/null; rc=$?
chk "設定を一度も渡さない: 成功し、CONF_DIR に何も置かない" '[ "$rc" = 0 ] && { [ ! -d "$sb/conf" ] || [ -z "$(ls -A "$sb/conf")" ]; }'
rm -rf "$sb"

# ---- 7. 静的な確認 ----
chk "構文" 'bash -n "$INSTALL" && python3 -I -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$PYSRC"'
chk "ほかのサービス(rackd・dhcpd・firewall など)に触れない(コメント行は除く)" '! grep -v "^[[:space:]]*#" "$INSTALL" | grep -E "maas-rackd|maas-dhcpd|maas-agent|maas-rack-firewall|iptables|ufw"'
chk "webhook のスクリプトが、ループバック以外の BIND を拒否する" 'grep -q "ループバックだけ" "$PYSRC"'

# ---- 8. Python の単体テスト ----
chk "webhook の単体テスト(test_maas_wol_webhook.py)" 'python3 -I "$here/test_maas_wol_webhook.py" >/dev/null 2>&1'

echo "---"
echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
