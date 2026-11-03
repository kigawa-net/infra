#!/usr/bin/env bash
# gre-overlay.sh のオフラインテスト。状態を持つ偽の ip・modprobe・systemctl を使うので、実機のネットワークには触れない。
# 使い方: bash hardware/modules/gre-overlay-tunnel/test-gre-overlay.sh
set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$here/files/gre-overlay.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fails=0
check() { # 名前 期待 実際
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 (expected=$2 actual=$3)"; fails=$((fails + 1)); fi
}

mkdir -p "$work/fakebin"
# 偽 ip: $FAKE_STATE/<dev> に「local= remote= ttl= addr= mtu= up=」を持つ。呼び出しは $FAKE_LOG に残す。
cat > "$work/fakebin/ip" <<'EOS2'
#!/usr/bin/env bash
st="$FAKE_STATE"; mkdir -p "$st"
echo "ip $*" >> "$FAKE_LOG"
case "$1 $2" in
  "link show") [ -f "$st/$3" ] ;;
  "tunnel add")
    dev="$3"; [ -f "$st/$dev" ] && { echo "ioctl: File exists" >&2; exit 1; }
    shift 3; l=""; r=""; t=""
    while [ $# -gt 0 ]; do case "$1" in local) l="$2";; remote) r="$2";; ttl) t="$2";; esac; shift; done
    printf 'local=%s\nremote=%s\nttl=%s\naddr=\nmtu=\nup=0\n' "$l" "$r" "$t" > "$st/$dev" ;;
  "tunnel change")
    dev="$3"; [ -f "$st/$dev" ] || exit 1
    shift 3; l=""; r=""; t=""
    while [ $# -gt 0 ]; do case "$1" in local) l="$2";; remote) r="$2";; ttl) t="$2";; esac; shift; done
    sed -i "s/^local=.*/local=$l/; s/^remote=.*/remote=$r/; s/^ttl=.*/ttl=$t/" "$st/$dev" ;;
  "tunnel del") [ -f "$st/$3" ] || exit 1; rm -f "$st/$3" ;;
  "addr replace") [ -f "$st/$5" ] || exit 1; sed -i "s|^addr=.*|addr=$3|" "$st/$5" ;;
  "link set")
    dev="$3"; [ -f "$st/$dev" ] || exit 1
    shift 3; while [ $# -gt 0 ]; do case "$1" in mtu) sed -i "s/^mtu=.*/mtu=$2/" "$st/$dev"; shift;; up) sed -i "s/^up=.*/up=1/" "$st/$dev";; esac; shift; done ;;
  *) : ;;
esac
EOS2
printf '#!/bin/sh\necho "modprobe $*" >> "$FAKE_LOG"\n' > "$work/fakebin/modprobe"
printf '#!/bin/sh\necho "systemctl $*" >> "$FAKE_LOG"\n' > "$work/fakebin/systemctl"
chmod +x "$work/fakebin/"*

run() { # GO_TUNNELS は呼び出し側で渡す
  PATH="$work/fakebin:$PATH" FAKE_STATE="$work/state" FAKE_LOG="$work/log" \
    GO_CONF="$work/root/etc/tunnels.conf" GO_HELPER="$work/root/sbin/gre-overlay" \
    GO_UNIT_DIR="$work/root/units" GO_MODLOAD="$work/root/modules/gre-overlay.conf" \
    bash "$script" > "$work/out" 2>&1
}
helper() { PATH="$work/fakebin:$PATH" FAKE_STATE="$work/state" FAKE_LOG="$work/log" bash "$work/root/sbin/gre-overlay" "$@"; }
reset() { rm -rf "$work/root" "$work/state" "$work/log"; : > "$work/log"; }
val() { grep "^$2=" "$work/state/$1" 2>/dev/null | cut -d= -f2-; }

T2='gre-k8s4,10.250.0.1,10.250.0.11,172.31.250.0/31,1300;gre-k8s1,10.250.0.1,10.250.0.12,172.31.250.2/31,1300'

# 1. 2 本のトンネルを作る
reset; GO_TUNNELS="$T2" run; rc=$?
check "2 本の定義で成功する" 0 "$rc"
check "gre-k8s4 を作る" 1 "$([ -f "$work/state/gre-k8s4" ] && echo 1 || echo 0)"
check "gre-k8s1 を作る" 1 "$([ -f "$work/state/gre-k8s1" ] && echo 1 || echo 0)"
check "gre-k8s4 の自分の Overlay" 10.250.0.1 "$(val gre-k8s4 local)"
check "gre-k8s4 の相手の Overlay" 10.250.0.11 "$(val gre-k8s4 remote)"
check "gre-k8s1 の相手の Overlay" 10.250.0.12 "$(val gre-k8s1 remote)"
check "ttl は 64" 64 "$(val gre-k8s4 ttl)"
check "gre-k8s4 のトンネル内のアドレス" 172.31.250.0/31 "$(val gre-k8s4 addr)"
check "gre-k8s1 のトンネル内のアドレス" 172.31.250.2/31 "$(val gre-k8s1 addr)"
check "MTU は 1300" 1300 "$(val gre-k8s4 mtu)"
check "up にする" 1 "$(val gre-k8s4 up)"
check "ip_gre を読み込む" 1 "$(grep -c '^modprobe ip_gre' "$work/log" | awk '{print ($1>=1)?1:0}')"
check "定義を 2 行で書く" 2 "$(wc -l < "$work/root/etc/tunnels.conf")"
check "ip_gre を起動時に読み込む設定を書く" ip_gre "$(cat "$work/root/modules/gre-overlay.conf")"
check "ユニットは easytier.service の後" 1 "$(grep -c '^After=.*easytier.service' "$work/root/units/gre-overlay.service")"
check "ユニットは oneshot で RemainAfterExit" 2 "$(grep -cE '^(Type=oneshot|RemainAfterExit=yes)$' "$work/root/units/gre-overlay.service")"
check "ユニットの ExecStart はヘルパーの up" 1 "$(grep -cxF "ExecStart=$work/root/sbin/gre-overlay up" "$work/root/units/gre-overlay.service")"
check "ユニットを有効にする" 1 "$(grep -cxF 'systemctl enable gre-overlay.service' "$work/log")"

# 2. 冪等: もう一度流しても、作り直さず(add は 2 回のまま)、change で更新する
GO_TUNNELS="$T2" run; rc=$?
check "再実行でも成功する" 0 "$rc"
check "再実行でトンネルを作り直さない(add は 2 回のまま)" 2 "$(grep -c '^ip tunnel add' "$work/log")"
check "再実行は change で更新する" 2 "$(grep -c '^ip tunnel change' "$work/log")"
check "再実行でトンネルは 2 本のまま" 2 "$(ls "$work/state" | wc -l)"

# 3. 定義から外したトンネルだけを消す(残る方は作り直さない)
GO_TUNNELS='gre-k8s4,10.250.0.1,10.250.0.11,172.31.250.0/31,1300' run; rc=$?
check "1 本に減らして成功する" 0 "$rc"
check "外したトンネル(gre-k8s1)を消す" 0 "$([ -f "$work/state/gre-k8s1" ] && echo 1 || echo 0)"
check "残るトンネル(gre-k8s4)は残る" 1 "$([ -f "$work/state/gre-k8s4" ] && echo 1 || echo 0)"
check "残る方を作り直さない(add は 2 回のまま)" 2 "$(grep -c '^ip tunnel add' "$work/log")"

# 4. MTU・アドレスの変更は、その場で反映される
GO_TUNNELS='gre-k8s4,10.250.0.1,10.250.0.11,172.31.250.0/31,1280' run
check "MTU の変更が反映される" 1280 "$(val gre-k8s4 mtu)"

# 5. ヘルパー: down で全部消し、up で作り直す(再起動の想定)
helper down
check "down で全部消える" 0 "$(ls "$work/state" | wc -l)"
helper up; rc=$?
check "up で、定義のトンネルが戻る" 1 "$([ -f "$work/state/gre-k8s4" ] && echo 1 || echo 0)"
check "up は成功する" 0 "$rc"
check "ヘルパーに引数なしは、使い方を出して失敗する" 2 "$(helper >/dev/null 2>&1; echo $?)"

# 6. 必須の環境変数がないと失敗する
reset; PATH="$work/fakebin:$PATH" FAKE_STATE="$work/state" FAKE_LOG="$work/log" GO_CONF="$work/root/c" GO_HELPER="$work/root/h" \
  GO_UNIT_DIR="$work/root/u" GO_MODLOAD="$work/root/m" bash "$script" >/dev/null 2>&1; rc=$?
check "GO_TUNNELS がないと失敗する" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

if [ "$fails" -eq 0 ]; then echo "all ok"; else echo "$fails FAILED"; exit 1; fi
