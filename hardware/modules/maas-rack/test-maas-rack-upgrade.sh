#!/bin/bash
# files/maas-rack-upgrade.sh のテスト。偽の dpkg-query / apt-get / add-apt-repository / systemctl を使い、実機にも、Region にも触れない。
#   bash hardware/modules/maas-rack/test-maas-rack-upgrade.sh
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
UPGRADE="$here/files/maas-rack-upgrade.sh"
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
ng() { fail=$((fail + 1)); echo "FAIL - $1"; [ -f "${sb:-/nonexistent}/out" ] && tail -6 "$sb/out" | sed 's/^/       | /'; }
chk() { if ( eval "$2" ); then ok "$1"; else ng "$1"; fi; }

# 使い捨てのサンドボックスと、偽のコマンドを作る。$1 = 入っている Rack のバージョン(空なら、未導入)
# 環境変数: REMOVE=1(計画に削除を含める)、NOCAND=1(計画に、目標の版を含めない)、SVC_FAIL=1(maas-agent が active にならない)
mksb() {
  sb=$(mktemp -d)
  mkdir -p "$sb/bin" "$sb/apt" "$sb/log" "$sb/maas" "$sb/var"
  : > "$sb/calls"
  printf '%s' "$1" > "$sb/ver"
  echo "deb https://ppa.example/maas/3.6" > "$sb/apt/maas-3.6.list"
  echo "url: http://region.example/MAAS" > "$sb/maas/rackd.conf"
  echo "shared-secret-DO-NOT-LEAK" > "$sb/var/secret"
  cat > "$sb/bin/dpkg-query" <<EOF
#!/bin/bash
case "\$*" in
  *'\${Version}'*maas-rack-controller*) cat "$sb/ver" ;;
  *'\${Package} \${Status}'*) printf 'maas-rack-controller install ok installed\nmaas-agent install ok installed\nmaas-common install ok installed\n' ;;
  *'\${Package} \${Version}'*) printf 'maas-rack-controller %s\n' "\$(cat "$sb/ver")" ;;
  *'\${Status}'*maas-rack-controller*) if [ "${BADSTATUS:-0}" = 1 ]; then printf 'install ok half-configured'; else printf 'install ok installed'; fi ;;
esac
exit 0
EOF
  cat > "$sb/bin/add-apt-repository" <<EOF
#!/bin/bash
echo "add-apt-repository \$*" >> "$sb/calls"
v=\${2#ppa:maas/}
echo "deb https://ppa.example/maas/\$v" > "$sb/apt/maas-\$v.list"
EOF
  cat > "$sb/bin/apt-get" <<EOF
#!/bin/bash
echo "apt-get \$*" >> "$sb/calls"
case "\$*" in
  *"-s install"*)
    [ "${NOCAND:-0}" = 1 ] || echo "Inst maas-rack-controller [1:3.6.6-17672-g.08d455f29-0ubuntu1~24.04.1] (1:3.7.4-18072-g.5db61257d-0ubuntu1~24.04.1 PPA:3.7 [amd64])"
    echo "Inst maas-agent [1:3.6.6] (1:3.7.4 PPA:3.7 [amd64])"
    echo "Inst python3-httpx (0.28 Ubuntu:24.04 [all])"
    [ "${REMOVE:-0}" = 1 ] && echo "Remv python3-something [1.0]"
    [ "${UNEXPECTED:-0}" = 1 ] && echo "Inst libssl3t64 [3.0.13-0ubuntu3] (3.0.13-0ubuntu3.5 Ubuntu:24.04/noble-updates [amd64])"
    ;;
  *"install -y --only-upgrade"*)
    printf '1:3.7.4-18072-g.5db61257d-0ubuntu1~24.04.1' > "$sb/ver"
    ;;
esac
exit 0
EOF
  cat > "$sb/bin/systemctl" <<EOF
#!/bin/bash
echo "systemctl \$*" >> "$sb/calls"
case "\$1" in
  restart) touch "$sb/restarted"; [ "\$2" = maas-agent.service ] && touch "$sb/agent-restarted" ;;
  is-active)
    case "\$2" in
      maas-agent.service)
        if [ "${SVC_FAIL:-0}" = 1 ]; then echo inactive; exit 3; fi
        if [ "${AGENT_DOWN_UNTIL_RESTART:-0}" = 1 ] && [ ! -e "$sb/agent-restarted" ]; then echo inactive; exit 3; fi ;;
      maas-dhcpd.service)
        if [ "${DHCP_OFF:-0}" = 1 ]; then echo inactive; exit 3; fi
        if [ "${DHCP_FAIL_AFTER:-0}" = 1 ] && [ -e "$sb/restarted" ]; then echo inactive; exit 3; fi ;;
    esac
    echo active ;;
esac
exit 0
EOF
  chmod +x "$sb"/bin/*
  cat > "$sb/shim-fake.sh" <<'EOF'
#!/bin/bash
echo "${FAKE_SHIM_OUT:-shim: present}"
exit "${FAKE_SHIM_RC:-0}"
EOF
}

run_upgrade() { # 引数: 追加の環境変数(KEY=VAL ...)
  env EXTRA_PATH="$sb/bin" LOG_DIR="$sb/log" APT_SOURCES_DIR="$sb/apt" MAAS_ETC_DIR="$sb/maas" MAAS_VAR_DIR="$sb/var" \
    SERVICE_WAIT_SEC=2 SHIM_SCRIPT="$sb/shim-fake.sh" "$@" bash "$UPGRADE" > "$sb/out" 2>&1
}

OLD_VER='1:3.6.6-17672-g.08d455f29-0ubuntu1~24.04.1'

# ---- 1. 正常系: 3.6 -> 3.7 ----
mksb "$OLD_VER"
run_upgrade MAAS_VERSION=3.7; rc=$?
chk "正常: 終了コード 0" '[ "$rc" = 0 ]'
chk "正常: 3.7 の PPA を追加" 'grep -q "^add-apt-repository -y ppa:maas/3.7" "$sb/calls"'
chk "正常: 計画(-s)を先に確認" 'grep -q "^apt-get -s install --only-upgrade" "$sb/calls"'
chk "正常: --only-upgrade で、設定ファイルは現状維持(force-confold)" 'grep -q "^apt-get install -y --only-upgrade -o Dpkg::Options::=--force-confold" "$sb/calls"'
chk "正常: 対象は maas 系のパッケージ(maas-rack-controller を含む)" 'grep "^apt-get install -y --only-upgrade" "$sb/calls" | grep -q "maas-rack-controller"'
chk "正常: maas-rackd を再起動" 'grep -q "^systemctl restart maas-rackd.service" "$sb/calls"'
chk "正常: maas-agent を再起動" 'grep -q "^systemctl restart maas-agent.service" "$sb/calls"'
chk "正常: 古い 3.6 の PPA を外した" '[ ! -e "$sb/apt/maas-3.6.list" ]'
chk "正常: 新しい 3.7 の PPA は残る" '[ -e "$sb/apt/maas-3.7.list" ]'
chk "正常: バックアップを作った(rackd.conf を含む)" 'ls "$sb"/log/upgrade-before-*/etc-maas/rackd.conf >/dev/null 2>&1'
chk "正常: バックアップは root だけが読める(0700)" '[ "$(stat -c %a "$(ls -d "$sb"/log/upgrade-before-* | head -1)")" = 700 ]'
chk "正常: 更新の後のバージョンを表示" 'grep -q "^version: .* -> 1:3.7.4" "$sb/out"'
chk "正常: maas-dhcpd を、有効・無効・起動・停止・再起動しない" '! grep -E "^systemctl (enable|disable|stop|start|restart|mask).*maas-dhcpd" "$sb/calls"'
chk "正常: secret の値を出力に出さない" '! grep -rq "shared-secret-DO-NOT-LEAK" "$sb/out"'
rm -rf "$sb"

# ---- 2. 冪等: すでに目標の版 ----
mksb '1:3.7.4-18072-g.5db61257d-0ubuntu1~24.04.1'
rm -f "$sb/apt/maas-3.6.list"; echo "deb https://ppa.example/maas/3.7" > "$sb/apt/maas-3.7.list"
run_upgrade MAAS_VERSION=3.7; rc=$?
chk "冪等: 終了コード 0" '[ "$rc" = 0 ]'
chk "冪等: apt-get を呼ばない" '! grep -q "^apt-get" "$sb/calls"'
chk "冪等: サービスを再起動しない" '! grep -q "^systemctl restart" "$sb/calls"'
chk "冪等: PPA を追加しない" '! grep -q "^add-apt-repository" "$sb/calls" && [ -e "$sb/apt/maas-3.7.list" ]'
rm -rf "$sb"

# ---- 2b. すでに目標の版でも、サービスが active でなければ、再起動を試し、直らなければ失敗(前回の更新が途中で失敗した後の、再実行) ----
AGENT_DOWN_UNTIL_RESTART=1 mksb '1:3.7.4-18072-g.5db61257d-0ubuntu1~24.04.1'
run_upgrade MAAS_VERSION=3.7 AGENT_DOWN_UNTIL_RESTART=1; rc=$?
chk "再実行(同じ版): maas-agent が止まっていたら、再起動して、成功" '[ "$rc" = 0 ] && grep -q "^systemctl restart maas-agent.service" "$sb/calls"'
chk "再実行(同じ版): パッケージの更新(apt-get install)はしない" '! grep -q "^apt-get install" "$sb/calls"'
rm -rf "$sb"
SVC_FAIL=1 mksb '1:3.7.4-18072-g.5db61257d-0ubuntu1~24.04.1'
run_upgrade MAAS_VERSION=3.7 SVC_FAIL=1; rc=$?
chk "再実行(同じ版): サービスが直らなければ、失敗(成功扱いにしない)" '[ "$rc" = 1 ]'
chk "再実行(同じ版): 失敗のときは、古い PPA を外さない" '[ -e "$sb/apt/maas-3.6.list" ]'
rm -rf "$sb"
mksb '1:3.7.4-18072-g.5db61257d-0ubuntu1~24.04.1'
run_upgrade MAAS_VERSION=3.7; rc=$?
chk "再実行(同じ版): サービスが正常なら、成功し、古い PPA が残っていれば外す" '[ "$rc" = 0 ] && [ ! -e "$sb/apt/maas-3.6.list" ]'
rm -rf "$sb"

# ---- 2c. DHCP: 更新の前に active だった maas-dhcpd が、更新の後に active でなければ失敗 ----
DHCP_FAIL_AFTER=1 mksb "$OLD_VER"
run_upgrade MAAS_VERSION=3.7 DHCP_FAIL_AFTER=1 SERVICE_WAIT_SEC=2; rc=$?
chk "DHCP が戻らない: 失敗(終了コード 1)" '[ "$rc" = 1 ]'
chk "DHCP が戻らない: 古い PPA は外さない" '[ -e "$sb/apt/maas-3.6.list" ]'
chk "DHCP が戻らない: maas-dhcpd を、この script が起動・有効化しない(rackd に任せる)" '! grep -E "^systemctl (enable|start|restart).*maas-dhcpd" "$sb/calls"'
rm -rf "$sb"
DHCP_OFF=1 mksb "$OLD_VER"
run_upgrade MAAS_VERSION=3.7 DHCP_OFF=1; rc=$?
chk "DHCP が、更新の前から止まっている: 確認の対象外(成功する)" '[ "$rc" = 0 ] && grep -q "確認の対象外" "$sb/out"'
rm -rf "$sb"

# ---- 2d. maas 系ではないパッケージのアップグレードが計画に入ったら中止 ----
UNEXPECTED=1 mksb "$OLD_VER"
run_upgrade MAAS_VERSION=3.7 UNEXPECTED=1; rc=$?
chk "無関係なアップグレード: 中止(終了コード 1)" '[ "$rc" = 1 ] && grep -q "libssl3t64" "$sb/out"'
chk "無関係なアップグレード: 実際の install を実行しない" '! grep -q "^apt-get install" "$sb/calls"'
rm -rf "$sb"

# ---- 2e. パッケージが中途半端な状態(half-configured)なら中止 ----
BADSTATUS=1 mksb "$OLD_VER"
run_upgrade MAAS_VERSION=3.7 BADSTATUS=1; rc=$?
chk "中途半端な状態: 中止(終了コード 1)" '[ "$rc" = 1 ] && grep -q "half-configured" "$sb/out"'
chk "中途半端な状態: apt-get を呼ばない" '! grep -q "^apt-get" "$sb/calls"'
rm -rf "$sb"

# ---- 2f. 3.7 以降の Rack だけの構成の不具合の回避(maas-rack-shim.sh)との連携 ----
mksb '1:3.7.4-18072-g.5db61257d-0ubuntu1~24.04.1'
rm -f "$sb/apt/maas-3.6.list"
run_upgrade MAAS_VERSION=3.7 FAKE_SHIM_OUT="shim: installed(maas-region-api 3.7.4 から 5 ファイル)"; rc=$?
chk "回避を入れた(すでに 3.7): rackd と agent を再起動する" '[ "$rc" = 0 ] && grep -q "^systemctl restart maas-rackd.service" "$sb/calls" && grep -q "^systemctl restart maas-agent.service" "$sb/calls"'
chk "回避を入れた(すでに 3.7): パッケージの更新(apt-get install)はしない" '! grep -q "^apt-get install" "$sb/calls"'
rm -rf "$sb"
mksb '1:3.7.4-18072-g.5db61257d-0ubuntu1~24.04.1'
rm -f "$sb/apt/maas-3.6.list"
run_upgrade MAAS_VERSION=3.7 FAKE_SHIM_OUT="shim: present"; rc=$?
chk "回避が、すでにある: 再起動しない" '[ "$rc" = 0 ] && ! grep -q "^systemctl restart" "$sb/calls"'
rm -rf "$sb"
mksb '1:3.7.4-18072-g.5db61257d-0ubuntu1~24.04.1'
run_upgrade MAAS_VERSION=3.7 FAKE_SHIM_RC=1; rc=$?
chk "回避スクリプトが失敗: 中止(終了コード 1)" '[ "$rc" = 1 ] && grep -q "maas-rack-shim.sh が失敗した" "$sb/out"'
chk "回避スクリプトが失敗: サービスを再起動しない" '! grep -q "^systemctl restart" "$sb/calls"'
rm -rf "$sb"
mksb '1:3.6.6-17672-g.08d455f29-0ubuntu1~24.04.1'
run_upgrade MAAS_VERSION=3.6 FAKE_SHIM_RC=1; rc=$?
chk "目標が 3.6: 回避スクリプトを呼ばない(失敗しても影響しない)" '[ "$rc" = 0 ]'
rm -rf "$sb"
mksb "$OLD_VER"
run_upgrade MAAS_VERSION=3.7 FAKE_SHIM_OUT="shim: installed(maas-region-api 3.7.4 から 5 ファイル)"; rc=$?
chk "3.6 から 3.7 に更新: 更新の後に回避を入れ、成功する" '[ "$rc" = 0 ] && grep -q "^apt-get install -y --only-upgrade" "$sb/calls"'
rm -rf "$sb"

# ---- 3. 未導入: スキップ ----
mksb ""
run_upgrade MAAS_VERSION=3.7; rc=$?
chk "未導入: 終了コード 0(スキップ)" '[ "$rc" = 0 ]'
chk "未導入: 何も呼ばない" '[ ! -s "$sb/calls" ]'
rm -rf "$sb"

# ---- 4. ダウングレードは中止 ----
mksb '1:3.8.1-1-0ubuntu1~24.04.1'
run_upgrade MAAS_VERSION=3.7; rc=$?
chk "ダウングレード: 中止(終了コード 1)" '[ "$rc" = 1 ]'
chk "ダウングレード: apt-get を呼ばない" '! grep -q "^apt-get" "$sb/calls"'
rm -rf "$sb"

# ---- 5. 計画に削除が含まれたら中止 ----
REMOVE=1 mksb "$OLD_VER"
run_upgrade MAAS_VERSION=3.7 REMOVE=1; rc=$?
chk "削除を含む計画: 中止(終了コード 1)" '[ "$rc" = 1 ]'
chk "削除を含む計画: 実際の install を実行しない" '! grep -q "^apt-get install" "$sb/calls"'
chk "削除を含む計画: 古い PPA は残す" '[ -e "$sb/apt/maas-3.6.list" ]'
chk "削除を含む計画: サービスを再起動しない" '! grep -q "^systemctl restart" "$sb/calls"'
rm -rf "$sb"

# ---- 6. 目標の版が計画に無い(PPA が、その版を出していない) ----
NOCAND=1 mksb "$OLD_VER"
run_upgrade MAAS_VERSION=3.7 NOCAND=1; rc=$?
chk "目標の版が無い: 中止(終了コード 1)" '[ "$rc" = 1 ]'
chk "目標の版が無い: 実際の install を実行しない" '! grep -q "^apt-get install" "$sb/calls"'
rm -rf "$sb"

# ---- 7. 更新の後に、サービスが起動しない ----
SVC_FAIL=1 mksb "$OLD_VER"
run_upgrade MAAS_VERSION=3.7 SVC_FAIL=1; rc=$?
chk "起動失敗: 終了コード 1" '[ "$rc" = 1 ]'
chk "起動失敗: 古い PPA は、外さない(戻せるように)" '[ -e "$sb/apt/maas-3.6.list" ]'
chk "起動失敗: バックアップの場所を表示" 'grep -q "upgrade-before-" "$sb/out"'
rm -rf "$sb"

# ---- 8. MAAS_VERSION が無いとき ----
mksb "$OLD_VER"
run_upgrade; rc=$?
chk "MAAS_VERSION 無し: 失敗" '[ "$rc" != 0 ]'
chk "MAAS_VERSION 無し: 何も呼ばない" '[ ! -s "$sb/calls" ]'
rm -rf "$sb"

# ---- 9. 静的な確認 ----
chk "upgrade.sh の構文" 'bash -n "$UPGRADE"'
chk "upgrade.sh は autoremove / purge / dist-upgrade を使わない(コメント行は除く)" '! grep -v "^[[:space:]]*#" "$UPGRADE" | grep -E "autoremove|purge|dist-upgrade|full-upgrade"'
chk "upgrade.sh は maas-dhcpd を操作しない(コメント行は除く)" '! grep -v "^[[:space:]]*#" "$UPGRADE" | grep -E "systemctl (enable|disable|stop|start|restart|mask).*dhcpd"'

echo "---"
echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
