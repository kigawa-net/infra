#!/bin/bash
# files/static-network.sh のテスト。偽の ip / networkctl を使い、実機には触れない。
#   bash hardware/modules/static-network/test-static-network.sh
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$here/files/static-network.sh"
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
ng() { fail=$((fail + 1)); echo "FAIL - $1"; [ -f "${sb:-/nonexistent}/out" ] && tail -6 "$sb/out" | sed 's/^/       | /'; }
chk() { if ( eval "$2" ); then ok "$1"; else ng "$1"; fi; }

# 環境変数: NOAPPLY=1(networkctl reconfigure をしても、アドレスと経路が付かない)
mksb() {
  sb=$(mktemp -d)
  mkdir -p "$sb/bin" "$sb/net"
  : > "$sb/calls"
  cat > "$sb/bin/ip" <<EOF
#!/bin/bash
case "\$*" in
  *"addr show dev"*)
    echo "2: ens18    inet 192.168.1.105/24 brd 192.168.1.255 scope global ens18"
    [ -e "$sb/applied" ] && echo "2: ens18    inet 192.168.1.228/24 brd 192.168.1.255 scope global secondary ens18"
    ;;
  *"route show default"*)
    [ -e "$sb/applied" ] && echo "default via 192.168.1.1 dev ens18"
    ;;
esac
exit 0
EOF
  cat > "$sb/bin/networkctl" <<EOF
#!/bin/bash
echo "networkctl \$*" >> "$sb/calls"
if [ "\$1" = reconfigure ]; then
  if [ -e "$sb/net/10-netplan-ens18.network.d/50-static-address-route.conf" ] && [ "${NOAPPLY:-0}" != 1 ]; then touch "$sb/applied"; else rm -f "$sb/applied"; fi
fi
exit 0
EOF
  chmod +x "$sb"/bin/*
}

run() { # 引数: 追加の環境変数(KEY=VAL ...)
  env EXTRA_PATH="$sb/bin" DROPIN_BASE="$sb/net" VERIFY_WAIT_SEC=2 IFACE=ens18 ADDRESS=192.168.1.228/24 GATEWAY=192.168.1.1 "$@" bash "$SCRIPT" > "$sb/out" 2>&1
}

DROPIN='net/10-netplan-ens18.network.d/50-static-address-route.conf'

# ---- 1. 正常系 ----
mksb
run; rc=$?
chk "正常: 終了コード 0" '[ "$rc" = 0 ]'
chk "正常: ドロップインを置いた" '[ -f "$sb/$DROPIN" ]'
chk "正常: ドロップインに、アドレスとゲートウェイがある" 'grep -qx "Address=192.168.1.228/24" "$sb/$DROPIN" && grep -qx "Gateway=192.168.1.1" "$sb/$DROPIN" && grep -qx "\[Route\]" "$sb/$DROPIN"'
chk "正常: networkctl reload の後に reconfigure ens18" 'grep -n "" "$sb/calls" | grep -q "networkctl reload" && grep -q "^networkctl reconfigure ens18" "$sb/calls"'
chk "正常: 設定したと表示する" 'grep -q "^static-network: 設定した" "$sb/out"'

# ---- 2. 冪等 ----
: > "$sb/calls"
run; rc=$?
chk "冪等: 終了コード 0" '[ "$rc" = 0 ]'
chk "冪等: すでに設定済みと表示し、networkctl を呼ばない" 'grep -q "すでに設定済み" "$sb/out" && [ ! -s "$sb/calls" ]'
rm -rf "$sb"

# ---- 3. 反映しても付かない: 戻して、失敗 ----
NOAPPLY=1 mksb
run NOAPPLY=1; rc=$?
chk "付かない: 失敗(終了コード 1)" '[ "$rc" = 1 ]'
chk "付かない: ドロップインを消して戻す" '[ ! -e "$sb/$DROPIN" ] && [ ! -d "$sb/net/10-netplan-ens18.network.d" ]'
chk "付かない: 戻した後にも reload と reconfigure を呼ぶ" '[ "$(grep -c "^networkctl reconfigure ens18" "$sb/calls")" = 2 ] && [ "$(grep -c "^networkctl reload" "$sb/calls")" = 2 ]'
chk "付かない: ABORT を表示" 'grep -q "^ABORT" "$sb/out"'
rm -rf "$sb"

# ---- 4. 以前のドロップインがあり、反映に失敗: 以前の内容に戻す ----
NOAPPLY=1 mksb
mkdir -p "$sb/net/10-netplan-ens18.network.d"
printf '[Network]\nAddress=192.168.1.200/24\n\n[Route]\nGateway=192.168.1.1\n' > "$sb/$DROPIN"
run NOAPPLY=1; rc=$?
chk "以前のドロップインあり・失敗: 以前の内容に戻す" '[ "$rc" = 1 ] && grep -qx "Address=192.168.1.200/24" "$sb/$DROPIN"'
rm -rf "$sb"

# ---- 5. 入力の検証 ----
mksb
run ADDRESS=192.168.1.228; rc=$?
chk "ADDRESS が CIDR でない: 中止し、何も呼ばない" '[ "$rc" = 1 ] && [ ! -s "$sb/calls" ] && [ ! -d "$sb/net/10-netplan-ens18.network.d" ]'
run GATEWAY=gw; rc=$?
chk "GATEWAY が不正: 中止" '[ "$rc" = 1 ] && [ ! -s "$sb/calls" ]'
run IFACE='ens18/../x'; rc=$?
chk "IFACE が不正(パスの文字): 中止" '[ "$rc" = 1 ] && [ ! -s "$sb/calls" ]'
run IFACE=; rc=$?
chk "IFACE が空: 中止" '[ "$rc" != 0 ] && [ ! -s "$sb/calls" ]'
rm -rf "$sb"

# ---- 6. 静的な確認 ----
chk "構文" 'bash -n "$SCRIPT"'
chk "既存のアドレスを消さない・NIC を落とさない・netplan apply をしない(コメント行は除く)" '! grep -v "^[[:space:]]*#" "$SCRIPT" | grep -E "netplan (apply|try)|ip (addr|address) (del|flush)|ip link set|systemctl (restart|stop) (systemd-)?networkd"'
chk "/run のファイルを直接書かない(ドロップインは /etc)" '! grep -v "^[[:space:]]*#" "$SCRIPT" | grep -E "/run/systemd/network"'

echo "---"
echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
