#!/bin/bash
# files/maas-rack-install.sh のテスト。偽の systemctl / apt-get / dpkg-query / add-apt-repository / maas-rack を使い、実機にも、Region にも触れない。
# パスは環境変数で、使い捨てのディレクトリに差し替える(/etc や /usr/sbin には、書かない)。
#   bash hardware/modules/maas-rack/test-maas-rack.sh
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTALL="$here/files/maas-rack-install.sh"
ROLLBACK="$here/files/maas-rack-rollback.sh"
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
ng() { fail=$((fail + 1)); echo "FAIL - $1"; [ -f "${sb:-/nonexistent}/out" ] && tail -6 "$sb/out" | sed 's/^/       | /'; }
chk() { if ( eval "$2" ); then ok "$1"; else ng "$1"; fi; }

SECRET_VALUE="s3cr3t-DO-NOT-LEAK-$$"

# 使い捨てのサンドボックスと、偽のコマンドを作る。$1 = apt の計画に「アップグレード」を含めるか(1 なら含める)
mksb() {
  sb=$(mktemp -d)
  mkdir -p "$sb/bin" "$sb/apt" "$sb/nginx" "$sb/maas" "$sb/log" "$sb/sbin"
  : > "$sb/calls"
  touch "$sb/nginx/default"
  printf 'MemAvailable:    %s kB\n' "${MEM_KB:-4000000}" > "$sb/meminfo"
  cat > "$sb/bin/systemctl" <<EOF
#!/bin/bash
echo "systemctl \$*" >> "$sb/calls"
exit 0
EOF
  cat > "$sb/bin/dpkg-query" <<'EOF'
#!/bin/bash
printf 'bash install ok installed\ncoreutils install ok installed\n'
EOF
  cat > "$sb/bin/add-apt-repository" <<EOF
#!/bin/bash
echo "add-apt-repository \$*" >> "$sb/calls"
echo "deb https://ppa.example/maas/3.6" > "$sb/apt/maas-3.6.list"
EOF
  cat > "$sb/bin/apt-get" <<EOF
#!/bin/bash
echo "apt-get \$*" >> "$sb/calls"
case "\$*" in
  *"-s install"*)
    echo "Remv systemd-timesyncd [255]"
    echo "Inst maas-rack-controller (3.6.6 PPA)"
    [ "${UPGRADE:-0}" = 1 ] && echo "Inst openssl [3.0.13] (3.0.14 Ubuntu)"
    ;;
esac
exit 0
EOF
  cat > "$sb/bin/maas-rack" <<EOF
#!/bin/bash
echo "maas-rack \$*" >> "$sb/calls"
cat > "$sb/maas-rack.stdin"
echo "url: \$3" > "$sb/maas/rackd.conf"
EOF
  cat > "$sb/bin/shred" <<'EOF'
#!/bin/bash
for a in "$@"; do case "$a" in -*) ;; *) rm -f "$a";; esac; done
EOF
  chmod +x "$sb"/bin/*
  printf '%s\n' "$SECRET_VALUE" > "$sb/secret"
}

run_install() { # 引数: 追加の環境変数(KEY=VAL ...)
  env EXTRA_PATH="$sb/bin" LOG_DIR="$sb/log" POLICY="$sb/sbin/policy-rc.d" APT_SOURCES_DIR="$sb/apt" \
    NGINX_SITES_DIR="$sb/nginx" MAAS_ETC_DIR="$sb/maas" MEMINFO="$sb/meminfo" \
    MAAS_URL="https://maas.example/MAAS" SECRET_FILE="$sb/secret" "$@" bash "$INSTALL" > "$sb/out" 2>&1
}

# ---- 1. 正常系 ----
MEM_KB=4000000 UPGRADE=0 mksb
run_install; rc=$?
chk "正常: 終了コード 0" '[ "$rc" = 0 ]'
chk "正常: policy-rc.d が、終了後に残っていない" '[ ! -e "$sb/sbin/policy-rc.d" ]'
chk "正常: apt-get install は --no-upgrade 付き" 'grep -q "^apt-get install -y --no-upgrade maas-rack-controller" "$sb/calls"'
chk "正常: nginx の default サイトが外れた" '[ ! -e "$sb/nginx/default" ]'
chk "正常: bind9 / named を mask" 'grep -q "^systemctl mask named.service bind9.service" "$sb/calls"'
chk "正常: timesyncd を停止" 'grep -q "^systemctl stop systemd-timesyncd.service" "$sb/calls"'
chk "正常: maas-dhcpd / maas-dhcpd6 を disable" 'grep -q "^systemctl disable --now maas-dhcpd.service maas-dhcpd6.service" "$sb/calls"'
chk "正常: maas-dhcpd を enable / start していない" '! grep -E "^systemctl (enable|start).*maas-dhcpd" "$sb/calls"'
chk "正常: maas-rackd を enable / start" 'grep -q "^systemctl enable maas-rackd.service" "$sb/calls" && grep -q "^systemctl start maas-rackd.service" "$sb/calls"'
chk "正常: 登録した(--url のみ。secret は引数に無い)" 'grep -q "^maas-rack register --url https://maas.example/MAAS$" "$sb/calls"'
chk "正常: secret は stdin で渡った" 'grep -qF "$SECRET_VALUE" "$sb/maas-rack.stdin"'
chk "正常: secret が、どのコマンドの引数にも、出力にも出ていない" '! grep -qF "$SECRET_VALUE" "$sb/calls" && ! grep -qF "$SECRET_VALUE" "$sb/out"'
chk "正常: secret のファイルが消えた" '[ ! -e "$sb/secret" ]'
chk "正常: 導入前のスナップショットを保存" '[ -s "$sb/log/pre-installed.txt" ] && [ -f "$sb/log/pre-ppa.txt" ]'

# ---- 2. 冪等: 2 回目は、登録をやり直さない ----
printf '%s\n' "$SECRET_VALUE" > "$sb/secret"
: > "$sb/calls"
run_install; rc=$?
chk "冪等: 2 回目も終了コード 0" '[ "$rc" = 0 ]'
chk "冪等: 登録済みなら、maas-rack register を呼ばない" '! grep -q "^maas-rack register" "$sb/calls"'
chk "冪等: PPA を二重に追加しない" '! grep -q "^add-apt-repository" "$sb/calls"'
rm -rf "$sb"

# ---- 3. 中止する条件 ----
MEM_KB=1000000 UPGRADE=0 mksb
run_install; rc=$?
chk "メモリ不足(約 1GB < 2000MB): 中止する(終了コード 1)" '[ "$rc" = 1 ]'
chk "メモリ不足: パッケージを何も入れていない" '! grep -q "^apt-get install" "$sb/calls"'
chk "メモリ不足: 中止のメッセージ" 'grep -q "ABORT" "$sb/out"'
rm -rf "$sb"

MEM_KB=4000000 UPGRADE=1 mksb
run_install; rc=$?
chk "既存パッケージのアップグレードが計画にある: 中止する(終了コード 1)" '[ "$rc" = 1 ]'
chk "アップグレードあり: パッケージを何も入れていない" '! grep -q "^apt-get install -y" "$sb/calls"'
chk "アップグレードあり: policy-rc.d が残っていない(trap)" '[ ! -e "$sb/sbin/policy-rc.d" ]'
rm -rf "$sb"

# ---- 4. SECRET_FILE が無いとき: 登録しない(導入の後処理は、行う) ----
MEM_KB=4000000 UPGRADE=0 mksb
run_install SECRET_FILE=; rc=$?
chk "SECRET_FILE なし: 終了コード 0" '[ "$rc" = 0 ]'
chk "SECRET_FILE なし: 登録しない" '! grep -q "^maas-rack register" "$sb/calls"'
rm -rf "$sb"

# ---- 5. MAAS_URL が無いとき: 何もせずに失敗 ----
MEM_KB=4000000 UPGRADE=0 mksb
run_install MAAS_URL=; rc=$?
chk "MAAS_URL なし: 失敗する(終了コード 非 0)" '[ "$rc" != 0 ]'
chk "MAAS_URL なし: パッケージを何も入れていない" '! grep -q "^apt-get" "$sb/calls"'
rm -rf "$sb"

# ---- 6. 静的な確認 ----
chk "install.sh の構文" 'bash -n "$INSTALL"'
chk "rollback.sh の構文" 'bash -n "$ROLLBACK"'
chk "rollback.sh は autoremove を実行しない(コメント行は除く)" '! grep -v "^[[:space:]]*#" "$ROLLBACK" | grep -q "autoremove"'
chk "install.sh は --no-upgrade を使う" 'grep -q -- "--no-upgrade" "$INSTALL"'
chk "install.sh は DHCP を enable / start しない" '! grep -E "^systemctl (enable|start).*maas-dhcpd" "$INSTALL"'

echo "---"
echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
