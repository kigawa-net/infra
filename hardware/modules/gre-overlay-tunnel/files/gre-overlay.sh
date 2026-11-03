#!/bin/bash
# EasyTier の Overlay のアドレスを両端にした GRE トンネルを作り、再起動後も残す(docs/frr-gre-overlay-design.md)。
# 必須の環境変数: GO_TUNNELS(トンネルの定義。1 本は「名前,自分の Overlay,相手の Overlay,トンネル内のアドレス/長さ,MTU」で、複数は ; で区切る)。
#   例: gre-k8s4,10.250.0.1,10.250.0.11,172.31.250.0/31,1300;gre-k8s1,10.250.0.1,10.250.0.12,172.31.250.2/31,1300
# 定義は GO_CONF に書き、gre-overlay.service(oneshot、easytier.service の後)が、起動時に作る。止めるとトンネルを消す。
# 設定を変えたときは、定義から外したトンネルだけを消す(残るトンネルは、作り直さず、その場で更新する。通信を切らない)。
# GO_CONF / GO_HELPER / GO_UNIT_DIR / GO_MODLOAD は、テスト(test-gre-overlay.sh)で差し替える。
set -eo pipefail
export PATH="${PATH:+$PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
umask 022

: "${GO_TUNNELS:?}"
conf="${GO_CONF:-/etc/gre-overlay/tunnels.conf}"
helper="${GO_HELPER:-/usr/local/sbin/gre-overlay}"
unit_dir="${GO_UNIT_DIR:-/etc/systemd/system}"
modload="${GO_MODLOAD:-/etc/modules-load.d/gre-overlay.conf}"

install -d -m 755 "$(dirname "$conf")" "$(dirname "$helper")" "$unit_dir" "$(dirname "$modload")"

# 前の定義の名前(定義から外れたトンネルを消すため)
old_names=""
if [ -f "$conf" ]; then
  old_names=$(awk -F, 'NF >= 5 {print $1}' "$conf")
fi

# ; で区切った定義を、1 行 1 本にして書く
printf '%s\n' "$GO_TUNNELS" | tr ';' '\n' | sed '/^$/d' > "$conf"
chmod 644 "$conf"
echo ip_gre > "$modload"
chmod 644 "$modload"

cat > "$helper" <<HELPER
#!/bin/bash
# gre-overlay.service から呼ぶ。up: 定義のトンネルを作る(あれば更新する)。down: 定義のトンネルを消す。
set -u
export PATH="\${PATH:+\$PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
conf="$conf"

up() {
  modprobe ip_gre
  rc=0
  while IFS=, read -r name lcl rmt addr mtu; do
    [ -n "\$name" ] || continue
    if ip link show "\$name" >/dev/null 2>&1; then
      ip tunnel change "\$name" mode gre local "\$lcl" remote "\$rmt" ttl 64 || rc=1
    else
      ip tunnel add "\$name" mode gre local "\$lcl" remote "\$rmt" ttl 64 || { rc=1; continue; }
    fi
    ip addr replace "\$addr" dev "\$name" || rc=1
    ip link set "\$name" mtu "\$mtu" up || rc=1
  done < "\$conf"
  return \$rc
}

down() {
  while IFS=, read -r name rest; do
    [ -n "\$name" ] || continue
    ip tunnel del "\$name" 2>/dev/null || true
  done < "\$conf"
}

case "\${1:-}" in
  up) up ;;
  down) down ;;
  *) echo "usage: \$0 up|down" >&2; exit 2 ;;
esac
HELPER
chmod 755 "$helper"

cat > "$unit_dir/gre-overlay.service" <<UNIT
[Unit]
Description=GRE tunnels over the EasyTier overlay
After=network-online.target easytier.service

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

# 定義から外れたトンネルを消す
for n in $old_names; do
  if ! awk -F, -v n="$n" '$1 == n {found = 1} END {exit !found}' "$conf"; then
    ip tunnel del "$n" 2>/dev/null || true
    echo "removed tunnel no longer in the definition: $n"
  fi
done

echo "=== GRE overlay tunnels ==="
ip -d -o link show type gre 2>/dev/null || true
