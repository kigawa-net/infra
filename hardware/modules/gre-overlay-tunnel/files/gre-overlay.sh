#!/bin/bash
# EasyTier の Overlay のアドレスを両端にした GRE トンネルを作り、再起動後も残す(docs/frr-gre-overlay-design.md)。
# 必須の環境変数: GO_TUNNELS(トンネルの定義。1 本は「名前,自分の Overlay,相手の Overlay,トンネル内のアドレス/長さ,MTU,相手のトンネル内のアドレス」で、複数は ; で区切る)。
#   例: gre-k8s4,10.250.0.1,10.250.0.11,172.31.250.0/31,1300,172.31.250.1;gre-k8s1,10.250.0.1,10.250.0.12,172.31.250.2/31,1300,172.31.250.3
# 任意: GO_FIREWALL(1 なら、下の許可を iptables の INPUT の先頭に入れる。既定 1)、GO_OVERLAY_IFACE(EasyTier の tun。既定 tun0)。
#   許可 1: -i <tun> -p gre -s <相手の Overlay>(GRE のパケットを、Overlay から受ける)
#   許可 2: -i <トンネル> -p tcp --dport 179 -s <相手のトンネル内のアドレス>(トンネルの中の BGP)
# 定義は GO_CONF に書き、gre-overlay.service(oneshot、easytier.service の後。easytier の再起動に連動する)が、起動時に作る。止めるとトンネルと許可を消す。
#   連動させる理由: control-plane の overlay-firewall は、easytier の起動のたびに、INPUT の先頭へ DROP のチェインへの飛ばし先を入れ直す。
#   その後ろに回った GRE の許可を、再起動で入れ直して、先頭に戻す。
# 設定を変えたときは、定義から外したトンネルとその許可だけを消す(残るトンネルは、作り直さず、その場で更新する。通信を切らない)。
# GO_CONF / GO_HELPER / GO_UNIT_DIR / GO_MODLOAD は、テスト(test-gre-overlay.sh)で差し替える。
set -eo pipefail
export PATH="${PATH:+$PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export DEBIAN_FRONTEND=noninteractive
umask 022

: "${GO_TUNNELS:?}"
fw="${GO_FIREWALL:-1}"
iface="${GO_OVERLAY_IFACE:-tun0}"
conf="${GO_CONF:-/etc/gre-overlay/tunnels.conf}"
helper="${GO_HELPER:-/usr/local/sbin/gre-overlay}"
unit_dir="${GO_UNIT_DIR:-/etc/systemd/system}"
modload="${GO_MODLOAD:-/etc/modules-load.d/gre-overlay.conf}"

if [ "$fw" = 1 ] && ! command -v iptables >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y iptables
fi

install -d -m 755 "$(dirname "$conf")" "$(dirname "$helper")" "$unit_dir" "$(dirname "$modload")"

# 前の定義(定義から外れたトンネルと、その許可を消すため)
old_conf=""
if [ -f "$conf" ]; then
  old_conf=$(cat "$conf")
fi

# ; で区切った定義を、1 行 1 本にして書く
printf '%s\n' "$GO_TUNNELS" | tr ';' '\n' | sed '/^$/d' > "$conf"
chmod 644 "$conf"
echo ip_gre > "$modload"
chmod 644 "$modload"

cat > "$helper" <<HELPER
#!/bin/bash
# gre-overlay.service から呼ぶ。up: 定義のトンネルと許可を作る(あれば更新する)。down: 定義のトンネルと許可を消す。drop: 1 本分の許可だけを消す。
set -u
export PATH="\${PATH:+\$PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
conf="$conf"
fw="$fw"
iface="$iface"

# 許可は、INPUT の先頭に入れる(ufw・overlay-firewall の DROP より前)。あれば何もしない。
ensure() { iptables -C INPUT "\$@" 2>/dev/null || iptables -I INPUT 1 "\$@"; }
unensure() { while iptables -C INPUT "\$@" 2>/dev/null; do iptables -D INPUT "\$@"; done; }

allow() { # 名前 相手の Overlay 相手のトンネル内のアドレス
  [ "\$fw" = 1 ] || return 0
  ensure -i "\$iface" -p gre -s "\$2" -j ACCEPT
  [ -z "\$3" ] || ensure -i "\$1" -p tcp --dport 179 -s "\$3" -j ACCEPT
}

disallow() {
  [ "\$fw" = 1 ] || return 0
  unensure -i "\$iface" -p gre -s "\$2" -j ACCEPT
  [ -z "\$3" ] || unensure -i "\$1" -p tcp --dport 179 -s "\$3" -j ACCEPT
}

up() {
  modprobe ip_gre
  rc=0
  while IFS=, read -r name lcl rmt addr mtu peer; do
    [ -n "\$name" ] || continue
    if ip link show "\$name" >/dev/null 2>&1; then
      ip tunnel change "\$name" mode gre local "\$lcl" remote "\$rmt" ttl 64 || rc=1
    else
      ip tunnel add "\$name" mode gre local "\$lcl" remote "\$rmt" ttl 64 || { rc=1; continue; }
    fi
    ip addr replace "\$addr" dev "\$name" || rc=1
    ip link set "\$name" mtu "\$mtu" up || rc=1
    allow "\$name" "\$rmt" "\${peer:-}" || rc=1
  done < "\$conf"
  return \$rc
}

down() {
  while IFS=, read -r name lcl rmt addr mtu peer; do
    [ -n "\$name" ] || continue
    disallow "\$name" "\$rmt" "\${peer:-}"
    ip tunnel del "\$name" 2>/dev/null || true
  done < "\$conf"
}

case "\${1:-}" in
  up) up ;;
  down) down ;;
  drop) disallow "\${2:?}" "\${3:?}" "\${4:-}" ;;
  *) echo "usage: \$0 up|down|drop <name> <remote> [<peer>]" >&2; exit 2 ;;
esac
HELPER
chmod 755 "$helper"

cat > "$unit_dir/gre-overlay.service" <<UNIT
[Unit]
Description=GRE tunnels over the EasyTier overlay
After=network-online.target easytier.service
PartOf=easytier.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$helper up
ExecStop=-$helper down

[Install]
WantedBy=multi-user.target
UNIT
chmod 644 "$unit_dir/gre-overlay.service"

systemctl daemon-reload
systemctl enable gre-overlay.service
"$helper" up
systemctl start gre-overlay.service

# 定義から外れたトンネルと、その許可を消す
while IFS=, read -r name lcl rmt addr mtu peer; do
  [ -n "$name" ] || continue
  if ! awk -F, -v n="$name" '$1 == n {found = 1} END {exit !found}' "$conf"; then
    ip tunnel del "$name" 2>/dev/null || true
    "$helper" drop "$name" "$rmt" "${peer:-}"
    echo "removed tunnel no longer in the definition: $name"
  fi
done <<< "$old_conf"

echo "=== GRE overlay tunnels ==="
ip -d -o link show type gre 2>/dev/null || true
if [ "$fw" = 1 ]; then
  echo "=== GRE overlay allow rules ==="
  iptables -S INPUT | grep -E -- '-p gre|--dport 179' || true
fi
