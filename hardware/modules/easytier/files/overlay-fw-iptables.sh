#!/bin/bash
# ufw を使わないホスト(control-plane など)で、Overlay からの受信を iptables で許可リスト制にする。
# 必須の環境変数: OF_CIDR(Overlay のネットワーク。例: 10.250.0.0/24)。任意: OF_ALLOW(空白区切りの 22/tcp など。既定は空)。
# ルールは、easytier.service の ExecStartPost(apply)/ ExecStopPost(remove)に結びつける。再起動しても残り、tunnel が無いときは外れる。
# easytier.service は再起動しない(tunnel を切らない)。
# OF_CONF / OF_HELPER / OF_DROPIN_DIR は、テスト(test-overlay-fw-iptables.sh)で差し替える。
set -eo pipefail
export PATH="${PATH:+$PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export DEBIAN_FRONTEND=noninteractive
umask 022

: "${OF_CIDR:?}"
conf="${OF_CONF:-/etc/easytier/overlay-fw.conf}"
helper="${OF_HELPER:-/usr/local/sbin/easytier-overlay-fw}"
dropin_dir="${OF_DROPIN_DIR:-/etc/systemd/system/easytier.service.d}"

if ! command -v iptables >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y iptables
fi

install -d -m 755 "$(dirname "$conf")" "$(dirname "$helper")" "$dropin_dir"

cat > "$conf" <<CONF
CIDR="$OF_CIDR"
ALLOW="${OF_ALLOW:-}"
CONF

cat > "$helper" <<HELPER
#!/bin/bash
# easytier-overlay-fw apply|remove(easytier.service の ExecStartPost / ExecStopPost から呼ばれる)
set -eo pipefail
. "$conf"
chain=EASYTIER-OVERLAY

remove() {
  while iptables -C INPUT -s "\$CIDR" -j \$chain 2>/dev/null; do iptables -D INPUT -s "\$CIDR" -j \$chain; done
  iptables -F \$chain 2>/dev/null || true
  iptables -X \$chain 2>/dev/null || true
}

apply() {
  iptables -N \$chain 2>/dev/null || iptables -F \$chain
  iptables -A \$chain -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A \$chain -p icmp -j ACCEPT
  for rule in \$ALLOW; do
    iptables -A \$chain -p "\${rule#*/}" --dport "\${rule%/*}" -j ACCEPT
  done
  iptables -A \$chain -j DROP
  iptables -C INPUT -s "\$CIDR" -j \$chain 2>/dev/null || iptables -I INPUT 1 -s "\$CIDR" -j \$chain
}

case "\${1:-}" in
  apply) apply ;;
  remove) remove ;;
  *) echo "usage: \$0 apply|remove" >&2; exit 2 ;;
esac
HELPER
chmod 755 "$helper"

# apply が失敗したら、service を失敗させる(Overlay が無遮断のまま上がらないように)。remove の失敗は無視する。
cat > "$dropin_dir/overlay-fw.conf" <<DROPIN
[Service]
ExecStartPost=$helper apply
ExecStopPost=-$helper remove
DROPIN
chmod 644 "$dropin_dir/overlay-fw.conf"

systemctl daemon-reload
"$helper" apply

echo "=== EasyTier overlay firewall (iptables) ==="
iptables -S EASYTIER-OVERLAY || true
