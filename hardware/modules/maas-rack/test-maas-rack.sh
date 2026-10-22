#!/bin/bash
# files/maas-rack-install.sh のテスト。偽の systemctl / apt-get / dpkg-query / add-apt-repository / maas-rack を使い、実機にも、Region にも触れない。
# パスは環境変数で、使い捨てのディレクトリに差し替える(/etc や /usr/sbin には、書かない)。
#   bash hardware/modules/maas-rack/test-maas-rack.sh
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTALL="$here/files/maas-rack-install.sh"
ROLLBACK="$here/files/maas-rack-rollback.sh"
FIREWALL="$here/files/maas-rack-firewall.sh"
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
ng() { fail=$((fail + 1)); echo "FAIL - $1"; [ -f "${sb:-/nonexistent}/out" ] && tail -6 "$sb/out" | sed 's/^/       | /'; }
chk() { if ( eval "$2" ); then ok "$1"; else ng "$1"; fi; }

SECRET_VALUE="s3cr3t-DO-NOT-LEAK-$$"

# 使い捨てのサンドボックスと、偽のコマンドを作る。$1 = apt の計画に「アップグレード」を含めるか(1 なら含める)
mksb() {
  sb=$(mktemp -d)
  mkdir -p "$sb/bin" "$sb/apt" "$sb/nginx" "$sb/maas" "$sb/log" "$sb/sbin" "$sb/var" "$sb/chrony" "$sb/usrsbin" "$sb/units"
  cp "$FIREWALL" "$sb/firewall-src.sh"
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
# 実機の maas-rack register と同じく、先に rackd.conf を書く。secret のファイルは、成功したときだけ作る
echo "url: \$3" > "$sb/maas/rackd.conf"
[ "\${REGISTER_FAIL:-0}" = 1 ] && { echo "Secret could not be decoded" >&2; exit 1; }
echo ok > "$sb/var/secret"
exit 0
EOF
  cat > "$sb/bin/chronyc" <<EOF
#!/bin/bash
echo "chronyc \$*" >> "$sb/calls"
exit 0
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
    NGINX_SITES_DIR="$sb/nginx" MAAS_ETC_DIR="$sb/maas" MAAS_VAR_DIR="$sb/var" CHRONY_DIR="$sb/chrony" MEMINFO="$sb/meminfo" \
    SBIN_DIR="$sb/usrsbin" UNIT_DIR="$sb/units" FIREWALL_SRC="$sb/firewall-src.sh" LAN_CIDR=192.168.1.0/24 LAN_ADDRESS=192.168.1.20 DHCP_PEER_ADDRESS=192.168.1.120 \
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
chk "正常: chrony を enable --now する" 'grep -q "^systemctl enable --now chrony.service" "$sb/calls"'
chk "正常: chrony の起動が、Region への登録より前(時刻同期を最優先)" '[ "$(grep -n "^systemctl enable --now chrony" "$sb/calls" | head -1 | cut -d: -f1)" -lt "$(grep -n "^maas-rack register" "$sb/calls" | head -1 | cut -d: -f1)" ]'
chk "正常: sources.d に、上流の pool を置いた" 'grep -q "^pool ntp.ubuntu.com" "$sb/chrony/sources.d/ubuntu-pool.sources"'
chk "正常: 登録の後に、maas-rackd を start する(register は rackd を止めるため)" '[ "$(grep -n "^maas-rack register" "$sb/calls" | head -1 | cut -d: -f1)" -lt "$(grep -n "^systemctl start maas-rackd" "$sb/calls" | tail -1 | cut -d: -f1)" ]'
chk "正常: ファイアウォールのユニットを置いた(環境変数つき)" 'grep -q "^Environment=LAN_ADDRESS=192.168.1.20" "$sb/units/maas-rack-firewall.service" && grep -q "^Environment=LAN_CIDR=192.168.1.0/24" "$sb/units/maas-rack-firewall.service"'
chk "正常: unit に DHCP_PEER_ADDRESS(相手の Rack)が入る" 'grep -q "^Environment=DHCP_PEER_ADDRESS=192.168.1.120" "$sb/units/maas-rack-firewall.service"'
chk "正常: ファイアウォールのスクリプトを、実行可能にして置いた" '[ -x "$sb/usrsbin/maas-rack-firewall.sh" ]'
chk "正常: ファイアウォールを enable / restart する" 'grep -q "^systemctl enable maas-rack-firewall.service" "$sb/calls" && grep -q "^systemctl restart maas-rack-firewall.service" "$sb/calls"'
chk "正常: ファイアウォールは、rackd などの起動より前" '[ "$(grep -n "^systemctl restart maas-rack-firewall" "$sb/calls" | head -1 | cut -d: -f1)" -lt "$(grep -n "^systemctl start maas-rackd" "$sb/calls" | head -1 | cut -d: -f1)" ]'
chk "正常: ユニットは、rackd・http・proxy・syslog の前に実行される(Before=)" 'grep -q "^Before=.*maas-rackd.service" "$sb/units/maas-rack-firewall.service"'
chk "正常: 導入前のスナップショットを保存" '[ -s "$sb/log/pre-installed.txt" ] && [ -f "$sb/log/pre-ppa.txt" ]'

# ---- 2. 冪等: 2 回目は、登録をやり直さない(実機では、Terraform が、毎回、スクリプトをアップロードする) ----
printf '%s\n' "$SECRET_VALUE" > "$sb/secret"
cp "$FIREWALL" "$sb/firewall-src.sh"
: > "$sb/calls"
run_install; rc=$?
chk "冪等: 2 回目も終了コード 0" '[ "$rc" = 0 ]'
chk "冪等: 登録済みなら、maas-rack register を呼ばない" '! grep -q "^maas-rack register" "$sb/calls"'
chk "冪等: PPA を二重に追加しない" '! grep -q "^add-apt-repository" "$sb/calls"'
# 登録が途中で失敗した状態(rackd.conf に URL はあるが、secret が無い)は、登録済みとみなさず、登録し直す
rm -f "$sb/var/secret"
printf '%s\n' "$SECRET_VALUE" > "$sb/secret"
cp "$FIREWALL" "$sb/firewall-src.sh"
: > "$sb/calls"
run_install; rc=$?
chk "URL だけで secret が無い: 登録し直す" 'grep -q "^maas-rack register" "$sb/calls" && [ "$rc" = 0 ]'
rm -rf "$sb"

# ---- 2b. 登録の失敗: 後続(chrony・サービスの起動)を止めず、最後に、失敗として終わる ----
MEM_KB=4000000 UPGRADE=0 mksb
run_install REGISTER_FAIL=1; rc=$?
chk "登録の失敗: 終了コードは非 0(失敗を、apply に伝える)" '[ "$rc" != 0 ]'
chk "登録の失敗: chrony は起動済み" 'grep -q "^systemctl enable --now chrony.service" "$sb/calls"'
chk "登録の失敗: maas-rackd の start まで進んだ" 'grep -q "^systemctl start maas-rackd" "$sb/calls"'
chk "登録の失敗: secret のファイルを残さない" '[ ! -e "$sb/secret" ]'
chk "登録の失敗: secret が、出力にも、引数にも出ない" '! grep -qF "$SECRET_VALUE" "$sb/out" && ! grep -qF "$SECRET_VALUE" "$sb/calls"'
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

# ---- 3b. ファイアウォールの前提が無いとき: 何も入れずに中止する ----
MEM_KB=4000000 UPGRADE=0 mksb
run_install LAN_ADDRESS=; rc=$?
chk "LAN_ADDRESS なし: 中止する(終了コード 非 0)" '[ "$rc" != 0 ]'
chk "LAN_ADDRESS なし: パッケージを何も入れていない" '! grep -q "^apt-get" "$sb/calls"'
rm -rf "$sb"
MEM_KB=4000000 UPGRADE=0 mksb
run_install LAN_CIDR=; rc=$?
chk "LAN_CIDR なし: 中止する(終了コード 非 0)" '[ "$rc" != 0 ]'
rm -rf "$sb"
MEM_KB=4000000 UPGRADE=0 mksb
rm -f "$sb/firewall-src.sh"
run_install; rc=$?
chk "ファイアウォールのスクリプトが無い: 中止する(終了コード 非 0)" '[ "$rc" != 0 ]'
chk "ファイアウォールのスクリプトが無い: rackd を start していない" '! grep -q "^systemctl start maas-rackd" "$sb/calls"'
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

# ---- 5b. ファイアウォールのスクリプト(状態を持つ偽の iptables) ----
mkfw() {
  sb=$(mktemp -d)
  mkdir -p "$sb/bin" "$sb/ipt"
  : > "$sb/calls"
  # chain ごとにファイル($sb/ipt/<CHAIN>)に、ルールを 1 行ずつ保存する。chain の存在 = ファイルの存在。INPUT は、最初から存在する。
  cat > "$sb/bin/iptables" <<EOF
#!/bin/bash
echo "iptables \$*" >> "$sb/calls"
args=("\$@")
[ "\${args[0]}" = "-w" ] && args=("\${args[@]:2}")
op="\${args[0]}"; chain="\${args[1]:-}"; f="$sb/ipt/\$chain"
case "\$op" in
  -N) [ -e "\$f" ] && exit 1; : > "\$f" ;;
  -F) [ -e "\$f" ] || exit 1; : > "\$f" ;;
  -X) [ -e "\$f" ] || exit 1; rm -f "\$f" ;;
  -S) [ -e "\$f" ] || exit 1; echo "-N \$chain"; sed "s/^/-A \$chain /" "\$f" ;;
  -A) echo "\${args[*]:2}" >> "\$f" ;;
  -I) rest="\${args[*]:3}"; { echo "\$rest"; cat "\$f"; } > "\$f.new"; mv "\$f.new" "\$f" ;;
  -C) rest="\${args[*]:2}"; grep -qxF -- "\$rest" "\$f" ;;
  -D) rest="\${args[*]:2}"; n=\$(grep -nxF -- "\$rest" "\$f" | head -1 | cut -d: -f1); [ -n "\$n" ] || exit 1; sed -i "\${n}d" "\$f" ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$sb/bin/iptables"
  : > "$sb/ipt/INPUT"
  echo "-j KUBE-FIREWALL" >> "$sb/ipt/INPUT"
}
run_fw() { env IPTABLES="$sb/bin/iptables" LAN_CIDR=192.168.1.0/24 LAN_ADDRESS=192.168.1.20 DHCP_PEER_ADDRESS=192.168.1.120 "$@" > "$sb/out" 2>&1; }

mkfw
run_fw bash "$FIREWALL" apply; rc=$?
chk "firewall apply: 終了コード 0" '[ "$rc" = 0 ]'
chk "firewall apply: INPUT の先頭から MAAS-RACK を呼ぶ" '[ "$(head -1 "$sb/ipt/INPUT")" = "-j MAAS-RACK" ]'
chk "firewall apply: 既存の INPUT のルール(KUBE-FIREWALL)を残す" 'grep -qx -- "-j KUBE-FIREWALL" "$sb/ipt/INPUT"'
chk "firewall apply: lo を許可(最初のルール)" '[ "$(head -1 "$sb/ipt/MAAS-RACK")" = "-i lo -j RETURN" ]'
chk "firewall apply: LAN から LAN のアドレス宛ての udp 69/123/5247 を許可" 'grep -qx -- "-s 192.168.1.0/24 -d 192.168.1.20 -p udp -m multiport --dports 69,123,5247 -j RETURN" "$sb/ipt/MAAS-RACK"'
chk "firewall apply: LAN から LAN のアドレス宛ての tcp 5247/5248/3128/8000 を許可" 'grep -qx -- "-s 192.168.1.0/24 -d 192.168.1.20 -p tcp -m multiport --dports 5247,5248,3128,8000 -j RETURN" "$sb/ipt/MAAS-RACK"'
chk "firewall apply: それ以外の udp 69/123/5247/67 は DROP" 'grep -qx -- "-p udp -m multiport --dports 69,123,5247,67 -j DROP" "$sb/ipt/MAAS-RACK"'
chk "firewall apply: tcp 5249(内部 HTTP)は、DROP の側にだけ現れる(許可しない)" 'grep -qx -- "-p tcp -m multiport --dports 5247,5248,3128,8000,5249,647,7911 -j DROP" "$sb/ipt/MAAS-RACK" && ! grep -- "RETURN" "$sb/ipt/MAAS-RACK" | grep -q 5249'
chk "firewall DHCP: クライアントのブロードキャスト(0.0.0.0:68 → 255.255.255.255:67)を許可" 'grep -qx -- "-s 0.0.0.0/32 -d 255.255.255.255/32 -p udp --sport 68 --dport 67 -j RETURN" "$sb/ipt/MAAS-RACK"'
chk "firewall DHCP: LAN からのブロードキャストと、LAN から LAN アドレス宛ての unicast(更新)を許可" 'grep -qx -- "-s 192.168.1.0/24 -d 255.255.255.255/32 -p udp --dport 67 -j RETURN" "$sb/ipt/MAAS-RACK" && grep -qx -- "-s 192.168.1.0/24 -d 192.168.1.20 -p udp --dport 67 -j RETURN" "$sb/ipt/MAAS-RACK"'
chk "firewall failover: 相手の Rack(192.168.1.120)から LAN アドレス宛ての tcp 647,7911 だけ許可" 'grep -qx -- "-s 192.168.1.120/32 -d 192.168.1.20 -p tcp -m multiport --dports 647,7911 -j RETURN" "$sb/ipt/MAAS-RACK"'
chk "firewall failover: LAN 全体に、647 / 7911 を許可していない(相手の 1 アドレスだけ)" '[ "$(grep -c -- "--dports 647,7911 -j RETURN" "$sb/ipt/MAAS-RACK")" = 1 ]'
chk "firewall DHCP / failover の許可は、DROP より前" '[ "$(grep -n -- "--dport 67 -j RETURN" "$sb/ipt/MAAS-RACK" | tail -1 | cut -d: -f1)" -lt "$(grep -n -- "-j DROP" "$sb/ipt/MAAS-RACK" | head -1 | cut -d: -f1)" ] && [ "$(grep -n -- "647,7911 -j RETURN" "$sb/ipt/MAAS-RACK" | cut -d: -f1)" -lt "$(grep -n -- "-j DROP" "$sb/ipt/MAAS-RACK" | head -1 | cut -d: -f1)" ]'
chk "firewall apply: DROP は、許可のルールより後(順序)" '[ "$(grep -n -- "-j RETURN" "$sb/ipt/MAAS-RACK" | sed -n 3p | cut -d: -f1)" != "" ] && [ "$(grep -n -- "-j DROP" "$sb/ipt/MAAS-RACK" | head -1 | cut -d: -f1)" -gt "$(grep -n -- "-d 192.168.1.20 -p tcp" "$sb/ipt/MAAS-RACK" | head -1 | cut -d: -f1)" ]'
chk "firewall apply: SSH(22)・etcd(2379 / 2380)・apiserver(6443)・WireGuard・BGP(179)には触れない" '! grep -E "(\\b22\\b|2379|2380|6443|\\b179\\b|51820)" "$sb/ipt/MAAS-RACK"'

run_fw bash "$FIREWALL" apply; rc=$?
chk "firewall 冪等: 2 回目も終了コード 0" '[ "$rc" = 0 ]'
chk "firewall 冪等: INPUT からの呼び出しは 1 つだけ" '[ "$(grep -cx -- "-j MAAS-RACK" "$sb/ipt/INPUT")" = 1 ]'
chk "firewall 冪等: chain のルールが重複しない(lo のルールが 1 つ)" '[ "$(grep -cx -- "-i lo -j RETURN" "$sb/ipt/MAAS-RACK")" = 1 ]'

run_fw bash "$FIREWALL" remove; rc=$?
chk "firewall remove: 終了コード 0" '[ "$rc" = 0 ]'
chk "firewall remove: INPUT から呼び出しが消えた" '! grep -qx -- "-j MAAS-RACK" "$sb/ipt/INPUT"'
chk "firewall remove: chain が消えた" '[ ! -e "$sb/ipt/MAAS-RACK" ]'
chk "firewall remove: 既存の INPUT のルールは残る" 'grep -qx -- "-j KUBE-FIREWALL" "$sb/ipt/INPUT"'
run_fw bash "$FIREWALL" remove; rc=$?
chk "firewall remove 冪等: 2 回目も終了コード 0" '[ "$rc" = 0 ]'
rm -rf "$sb"

mkfw
run_fw DHCP_PEER_ADDRESS= bash "$FIREWALL" apply; rc=$?
chk "firewall: DHCP_PEER_ADDRESS が空なら、failover の許可を作らない(647 / 7911 は DROP のみ)" '[ "$rc" = 0 ] && ! grep -q -- "647,7911 -j RETURN" "$sb/ipt/MAAS-RACK" && grep -q -- "647,7911 -j DROP" "$sb/ipt/MAAS-RACK"'
rm -rf "$sb"

mkfw
run_fw LAN_ADDRESS= bash "$FIREWALL" apply; rc=$?
chk "firewall: LAN_ADDRESS なしの apply は失敗し、何も入れない" '[ "$rc" != 0 ] && [ ! -e "$sb/ipt/MAAS-RACK" ]'
rm -rf "$sb"

# ---- 6. 静的な確認 ----
chk "install.sh の構文" 'bash -n "$INSTALL"'
chk "rollback.sh の構文" 'bash -n "$ROLLBACK"'
chk "firewall.sh の構文" 'bash -n "$FIREWALL"'
chk "rollback.sh は autoremove を実行しない(コメント行は除く)" '! grep -v "^[[:space:]]*#" "$ROLLBACK" | grep -q "autoremove"'
chk "install.sh は --no-upgrade を使う" 'grep -q -- "--no-upgrade" "$INSTALL"'
chk "install.sh は DHCP を enable / start しない" '! grep -E "^systemctl (enable|start).*maas-dhcpd" "$INSTALL"'

echo "---"
echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
