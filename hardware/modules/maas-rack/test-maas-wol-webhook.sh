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

# 環境変数: ACTIVE=0(systemctl is-active が inactive を返す)、PYFAIL=1(python3 が失敗する)
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
  chmod +x "$sb"/bin/*
}

run() { # 引数: 追加の環境変数(KEY=VAL ...)
  [ -f "$sb/src.py" ] || cp "$PYSRC" "$sb/src.py"
  env EXTRA_PATH="$sb/bin" SBIN_DIR="$sb/sbin" UNIT_DIR="$sb/units" SRC="$sb/src.py" BCAST=192.168.1.255 SKIP_VERIFY=1 VERIFY_TRIES=2 "$@" bash "$INSTALL" > "$sb/out" 2>&1
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

# ---- 7. 静的な確認 ----
chk "構文" 'bash -n "$INSTALL" && python3 -I -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$PYSRC"'
chk "ほかのサービス(rackd・dhcpd・firewall など)に触れない(コメント行は除く)" '! grep -v "^[[:space:]]*#" "$INSTALL" | grep -E "maas-rackd|maas-dhcpd|maas-agent|maas-rack-firewall|iptables|ufw"'
chk "webhook のスクリプトが、ループバック以外の BIND を拒否する" 'grep -q "ループバックだけ" "$PYSRC"'

# ---- 8. Python の単体テスト ----
chk "webhook の単体テスト(test_maas_wol_webhook.py)" 'python3 -I "$here/test_maas_wol_webhook.py" >/dev/null 2>&1'

echo "---"
echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
