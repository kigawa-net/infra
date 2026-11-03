#!/usr/bin/env bash
# gre-overlay-tunnel.sh のオフラインテスト。偽の ip / iptables / ufw / modprobe / systemctl を状態ファイルで持つので、実機のネットワークには触れない。
# 使い方: bash hardware/modules/gre-overlay-tunnel/test-gre-overlay-tunnel.sh
set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$here/files/gre-overlay-tunnel.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fails=0
check() { # 名前 期待 実際
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 (expected=$2 actual=$3)"; fails=$((fails + 1)); fi
}

mkdir -p "$work/fakebin"

# 偽 ip: $FAKE_IP_STATE に "dev <名前> <local> <remote>" と "addr <dev> <cidr>" を持つ。全呼び出しを $FAKE_LOG に残す。
cat > "$work/fakebin/ip" <<'EOS'
#!/usr/bin/env bash
st="$FAKE_IP_STATE"; touch "$st"
echo "ip $*" >> "$FAKE_LOG"
args=(); dflag=0
for a in "$@"; do if [ "$a" = -d ]; then dflag=1; else args+=("$a"); fi; done
set -- "${args[@]}"
if [ "$1" = -br ]; then
  awk '$1=="dev"{print $2}' "$st"; exit 0
fi
case "$1 $2" in
  "link show")   # link show dev NAME
    name=$4
    line=$(grep -m1 "^dev $name " "$st") || exit 1
    if [ "$dflag" = 1 ]; then
      read -r _ _ l r <<<"$line"
      echo "gre remote $r local $l ttl 64"
    fi ;;
  "tunnel add")  # tunnel add NAME mode gre local L remote R ttl 64
    name=$3
    if grep -q "^dev $name " "$st"; then echo "RTNETLINK answers: File exists" >&2; exit 2; fi
    echo "dev $name $7 $9" >> "$st" ;;
  "tunnel del")  # tunnel del NAME
    name=$3
    grep -q "^dev $name " "$st" || exit 1
    grep -v "^dev $name \|^addr $name " "$st" > "$st.n"; mv "$st.n" "$st" ;;
  "addr replace")  # addr replace CIDR dev DEV
    dev=$5
    grep -q "^dev $dev " "$st" || exit 1
    grep -qxF "addr $dev $3" "$st" || echo "addr $dev $3" >> "$st" ;;
  "link set")    # link set DEV mtu M up
    grep -q "^dev $3 " "$st" || exit 1 ;;
  *) ;;
esac
EOS

# 偽 iptables: $FAKE_IPT_STATE に "rule:<表:>チェイン 引数" を持つ。
cat > "$work/fakebin/iptables" <<'EOS'
#!/usr/bin/env bash
st="$FAKE_IPT_STATE"; touch "$st"
echo "iptables $*" >> "$FAKE_LOG"
pfx=""
if [ "$1" = "-t" ]; then pfx="$2:"; shift 2; fi
op=$1; shift
case "$op" in
  -C) c="$pfx$1"; shift; grep -qxF "rule:$c $*" "$st" ;;
  -A) c="$pfx$1"; shift; echo "rule:$c $*" >> "$st" ;;
  -D) c="$pfx$1"; shift
      grep -qxF "rule:$c $*" "$st" || exit 1
      grep -vxF "rule:$c $*" "$st" > "$st.n"; mv "$st.n" "$st" ;;
  *) ;;
esac
EOS

# 偽 ufw: $FAKE_UFW_STATE に "<規則> # <印>" を持つ(status の表示をまねる)。
cat > "$work/fakebin/ufw" <<'EOS'
#!/usr/bin/env bash
st="$FAKE_UFW_STATE"; touch "$st"
echo "ufw $*" >> "$FAKE_LOG"
case "$1" in
  status) echo "Status: active"; cat "$st" ;;
  insert)  # insert 1 <規則...> comment <印>
    shift 2
    args=("$@"); n=$#
    tag=${args[$((n-1))]}
    body=${args[*]:0:$((n-2))}
    echo "$body # $tag" >> "$st" ;;
  *) ;;
esac
EOS

printf '#!/bin/sh\necho "modprobe $*" >> "$FAKE_LOG"\n' > "$work/fakebin/modprobe"
printf '#!/bin/sh\necho "systemctl $*" >> "$FAKE_LOG"\n' > "$work/fakebin/systemctl"
chmod +x "$work/fakebin/"*

CONF_DST="$work/root/etc/gre-overlay/tunnels.conf"
BIN="$work/root/sbin/gre-overlay"
UNIT_DIR="$work/root/unit"
MODS_DIR="$work/root/modules"
SRC="$work/src.conf"

# 偽の環境で、コマンドを実行する(引数の先頭に VAR=値 を書けば、その環境変数を追加できる)
fake() {
  env PATH="$work/fakebin:$PATH" FAKE_LOG="$work/log" FAKE_IP_STATE="$work/ip.state" \
    FAKE_IPT_STATE="$work/ipt.state" FAKE_UFW_STATE="$work/ufw.state" \
    GRE_CONF="$CONF_DST" GRE_BIN="$BIN" GRE_UNIT_DIR="$UNIT_DIR" GRE_MODULES_LOAD_DIR="$MODS_DIR" \
    "$@"
}
reset() { rm -rf "$work/root" "$work/ip.state" "$work/ipt.state" "$work/ufw.state" "$work/log"; touch "$work/ip.state" "$work/ipt.state" "$work/ufw.state" "$work/log"; }
write_src() { printf '%s\n' "$1" > "$SRC"; }
# 設定を入れて(install)、ログを空にする。以降の up / down は、置かれたスクリプトで試す。
setup() { # 設定の中身
  reset
  write_src "$1"
  fake GRE_SRC_CONF="$SRC" bash "$script" install >"$work/out" 2>&1 || { echo "setup の install が失敗: $(cat "$work/out")"; exit 1; }
  : > "$work/log"
}
count() { grep -cxF -- "$1" "$work/log" || true; }     # ログに完全一致する行の数
flag() { if "$@"; then echo 1; else echo 0; fi; }

base_conf='local 10.250.0.1
peer k8s4 10.250.0.11 172.31.250.0/31 172.31.250.1
peer k8s1 10.250.0.12 172.31.250.2/31 172.31.250.3'

# 1. install: 設定・スクリプト・unit・modules-load を置き、トンネルは作らない
setup "$base_conf"
check "install の後、設定が src と同じ内容になる" 1 "$(flag cmp -s "$SRC" "$CONF_DST")"
check "install で /usr/local/sbin 相当のスクリプトを実行可能にする" 1 "$(flag test -x "$BIN")"
check "unit に After=easytier.service" 1 "$(grep -cxF 'After=easytier.service' "$UNIT_DIR/gre-overlay.service")"
check "unit に Wants=easytier.service" 1 "$(grep -cxF 'Wants=easytier.service' "$UNIT_DIR/gre-overlay.service")"
check "unit は oneshot で RemainAfterExit" 2 "$(grep -cxF -e 'Type=oneshot' -e 'RemainAfterExit=yes' "$UNIT_DIR/gre-overlay.service")"
check "unit の ExecStart は up" 1 "$(grep -cxF "ExecStart=$BIN up" "$UNIT_DIR/gre-overlay.service")"
check "unit の ExecStop は down(停止時にトンネルを消す)" 1 "$(grep -cxF "ExecStop=$BIN down" "$UNIT_DIR/gre-overlay.service")"
check "modules-load に ip_gre を書く" 1 "$(grep -cxF 'ip_gre' "$MODS_DIR/gre-overlay.conf")"
: > "$work/log"
fake GRE_SRC_CONF="$SRC" bash "$script" install >/dev/null 2>&1
check "install は daemon-reload・enable・restart する" 3 "$(grep -c '^systemctl \(daemon-reload\|enable gre-overlay.service\|restart gre-overlay.service\)$' "$work/log")"
check "install はトンネルを直接作らない" 0 "$(grep -c '^ip tunnel add' "$work/log")"
check "install は ufw を呼ばない(既定)" 0 "$(grep -c '^ufw ' "$work/log")"
check "install は iptables の規則を追加しない(既定)" 0 "$(grep -c '^iptables .* -[AI] ' "$work/log")"

# 2. up: 相手ごとにトンネル・アドレス・MTU
: > "$work/log"
fake bash "$BIN" up >"$work/out" 2>&1; rc=$?
check "up は成功する" 0 "$rc"
check "k8s4 のトンネルを、local と remote で作る" 1 "$(count 'ip tunnel add gre-k8s4 mode gre local 10.250.0.1 remote 10.250.0.11 ttl 64')"
check "k8s1 のトンネルを、local と remote で作る" 1 "$(count 'ip tunnel add gre-k8s1 mode gre local 10.250.0.1 remote 10.250.0.12 ttl 64')"
check "トンネルのアドレスを /31 で付ける" 1 "$(count 'ip addr replace 172.31.250.0/31 dev gre-k8s4')"
check "MTU 1300 で up する(既定)" 1 "$(count 'ip link set gre-k8s4 mtu 1300 up')"
check "ip_gre を読み込む" 1 "$(count 'modprobe ip_gre')"
check "clamp_mss が 0 のとき、TCPMSS の規則を追加しない" 0 "$(grep -c 'mangle -A' "$work/log")"
check "firewall が none のとき ufw を呼ばない" 0 "$(grep -c '^ufw ' "$work/log")"

# 3. 冪等: 2 回目の up は、設定が同じトンネルを残す(作り直さない)
: > "$work/log"
fake bash "$BIN" up >"$work/out" 2>&1; rc=$?
check "再 up は成功する" 0 "$rc"
check "再 up で tunnel add を呼ばない" 0 "$(grep -c '^ip tunnel ' "$work/log")"
check "再 up で keep と出す" 1 "$(grep -c '^keep gre-k8s4 ' "$work/out")"
check "再 up でもデバイスは 1 つずつ" 1 "$(grep -c '^dev gre-k8s4 ' "$work/ip.state")"

# 4. 食い違い: remote が違うトンネルは、消して作り直す
sed -i 's/^dev gre-k8s4 10.250.0.1 10.250.0.11$/dev gre-k8s4 10.250.0.1 10.250.0.99/' "$work/ip.state"
: > "$work/log"
fake bash "$BIN" up >"$work/out" 2>&1
check "remote が違うトンネルは tunnel del する" 1 "$(count 'ip tunnel del gre-k8s4')"
check "remote が違うトンネルは、正しい remote で作り直す" 1 "$(grep -c '^dev gre-k8s4 10.250.0.1 10.250.0.11$' "$work/ip.state")"

# 5. 停止: トンネルを消す(設定のすべての相手)
: > "$work/log"
fake bash "$BIN" down >"$work/out" 2>&1; rc=$?
check "down は成功する" 0 "$rc"
check "down で gre-k8s4 と gre-k8s1 を消す" 2 "$(grep -c '^ip tunnel del gre-' "$work/log")"
check "down の後、gre のデバイスが残らない" 0 "$(grep -c '^dev gre-' "$work/ip.state")"
check "down は、トンネルが無くても成功する(再実行)" 0 "$(fake bash "$BIN" down >/dev/null 2>&1; echo $?)"

# 6. MTU の変更
setup "local 10.250.0.1
mtu 1280
peer k8s4 10.250.0.11 172.31.250.0/31 172.31.250.1"
fake bash "$BIN" up >/dev/null 2>&1
check "mtu を設定どおりに使う" 1 "$(count 'ip link set gre-k8s4 mtu 1280 up')"

# 7. 相手が 3 つ(bao-02 側の想定)
setup "local 10.250.0.1
peer k8s4 10.250.0.11 172.31.250.0/31 172.31.250.1
peer k8s1 10.250.0.12 172.31.250.2/31 172.31.250.3
peer k8s2 10.250.0.13 172.31.250.4/31 172.31.250.5"
fake bash "$BIN" up >/dev/null 2>&1
check "相手が 3 つなら、トンネルも 3 つ作る" 3 "$(grep -c '^ip tunnel add gre-' "$work/log")"
check "3 つ目のトンネル(gre-k8s2)も作る" 1 "$(count 'ip tunnel add gre-k8s2 mode gre local 10.250.0.1 remote 10.250.0.13 ttl 64')"

# 8. 名前の長さ: 11 文字まで(gre- を足して 15 文字)。12 文字は止める。大文字も止める
setup "local 10.250.0.1
peer abcdefghijk 10.250.0.11 172.31.250.0/31 172.31.250.1"
fake bash "$BIN" up >/dev/null 2>&1
check "11 文字の名前は gre-abcdefghijk を作る" 1 "$(count 'ip tunnel add gre-abcdefghijk mode gre local 10.250.0.1 remote 10.250.0.11 ttl 64')"
for bad in abcdefghijkl K8S4 "k8s-4"; do
  reset
  write_src "local 10.250.0.1
peer $bad 10.250.0.11 172.31.250.0/31 172.31.250.1"
  fake GRE_SRC_CONF="$SRC" bash "$script" install >/dev/null 2>&1; rc=$?
  check "名前 '$bad' は install で止める" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  check "名前 '$bad' のとき設定を置かない" 0 "$(flag test -e "$CONF_DST")"
done

# 9. TCP の MSS の clamp(clamp_mss 1 のとき、起動で入れ、停止で外す。再実行で重複しない)
MSS_RULE='iptables -t mangle -A FORWARD -o gre+ -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu'
setup "local 10.250.0.1
clamp_mss 1
peer k8s4 10.250.0.11 172.31.250.0/31 172.31.250.1"
fake bash "$BIN" up >/dev/null 2>&1
check "clamp_mss 1 で、mangle の FORWARD に TCPMSS を入れる" 1 "$(count "$MSS_RULE")"
fake bash "$BIN" up >/dev/null 2>&1
check "clamp の規則は、再 up でも 1 つ" 1 "$(grep -c '^rule:mangle:FORWARD ' "$work/ipt.state")"
fake bash "$BIN" down >/dev/null 2>&1
check "down で clamp の規則を外す" 0 "$(grep -c '^rule:mangle:FORWARD ' "$work/ipt.state")"
setup "local 10.250.0.1
clamp_mss 0
peer k8s4 10.250.0.11 172.31.250.0/31 172.31.250.1"
fake bash "$BIN" up >/dev/null 2>&1
check "clamp_mss 0 のとき、TCPMSS の規則を入れない" 0 "$(grep -c 'mangle -A' "$work/log")"

# 10. ufw モード(bao 側): 相手の Overlay から tun0 への gre、トンネル上の 179/tcp を許可する。再実行で重複しない
setup "local 10.250.0.1
firewall ufw
peer k8s4 10.250.0.11 172.31.250.0/31 172.31.250.1"
fake bash "$BIN" up >"$work/out" 2>&1; rc=$?
check "firewall ufw の up は成功する" 0 "$rc"
check "tun0 から相手の Overlay の gre を許可する(先頭に入れる)" 1 "$(count 'ufw insert 1 allow in on tun0 proto gre from 10.250.0.11 comment gre-overlay-k8s4-gre')"
check "gre-k8s4 から相手のトンネルの 179/tcp を許可する" 1 "$(count 'ufw insert 1 allow in on gre-k8s4 proto tcp from 172.31.250.1 to any port 179 comment gre-overlay-k8s4-bgp')"
fake bash "$BIN" up >/dev/null 2>&1
check "ufw の規則は再 up で重複しない(gre)" 1 "$(grep -c 'gre from 10.250.0.11 # gre-overlay-k8s4-gre' "$work/ufw.state")"
check "ufw の規則は再 up で重複しない(179/tcp)" 1 "$(grep -c '# gre-overlay-k8s4-bgp$' "$work/ufw.state")"
check "ufw モードでも、TCPMSS の規則を追加しない(clamp 0)" 0 "$(grep -c 'mangle -A' "$work/log")"

# 11. firewall none(既定)のとき、ufw に触れない
setup "local 10.250.0.1
firewall none
peer k8s4 10.250.0.11 172.31.250.0/31 172.31.250.1"
fake bash "$BIN" up >/dev/null 2>&1
check "firewall none のとき ufw を呼ばない" 0 "$(grep -c '^ufw ' "$work/log")"

# 12. 不正な設定は install で止まり、何も置かない(検証)
bad_confs=(
  "local 10.250.0.1
bogus 1
peer k8s4 10.250.0.11 172.31.250.0/31 172.31.250.1"
  "local 10.250.0.256
peer k8s4 10.250.0.11 172.31.250.0/31 172.31.250.1"
  "local 10.250.0.1
mtu 2000
peer k8s4 10.250.0.11 172.31.250.0/31 172.31.250.1"
  "local 10.250.0.1
peer k8s4 10.250.0.11 172.31.250.0/30 172.31.250.1"
  "local 10.250.0.1
peer k8s4 10.250.0.11 172.31.250.0/31 172.31.250.0"
  "local 10.250.0.1
firewall foo
peer k8s4 10.250.0.11 172.31.250.0/31 172.31.250.1"
  "local 10.250.0.1
peer k8s4 10.250.0.11 172.31.250.0/31 172.31.250.1
peer k8s4 10.250.0.12 172.31.250.2/31 172.31.250.3"
  "local 10.250.0.1"
)
badn=0
for bc in "${bad_confs[@]}"; do
  reset
  write_src "$bc"
  fake GRE_SRC_CONF="$SRC" bash "$script" install >/dev/null 2>&1; rc=$?
  check "不正な設定 #$((++badn)) は install が失敗する" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
  check "不正な設定 #$badn は設定を置かない" 0 "$(flag test -e "$CONF_DST")"
done

# 13. 設定がないときの up は失敗する
reset
fake bash "$BIN" up >/dev/null 2>&1; rc=$?
check "設定がないと up は失敗する" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

# 14. install の再実行は成功し、設定を変えると、上書きされる
setup "$base_conf"
fake GRE_SRC_CONF="$SRC" bash "$script" install >/dev/null 2>&1; rc=$?
check "install を 2 回実行しても成功する" 0 "$rc"
check "install を 2 回実行しても unit が 1 つ" 1 "$(grep -c '^\[Service\]' "$UNIT_DIR/gre-overlay.service")"

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
