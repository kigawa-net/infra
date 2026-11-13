#!/bin/bash
# 指定した送信元(EasyTier の Overlay のアドレス)からの TCP を、iptables の INPUT の先頭で許可する。
# 用途: CI(GitHub のランナー)が、k8s4 のサブネットプロキシ(proxy_network)経由で、10.0.0.0/24 の TCP(SSH)へ届くようにする。
#   EasyTier の TCP プロキシは、k8s4 のカーネルの、ランダムなポートで受けるため、control-plane の overlay-firewall
#   (Overlay からは ESTABLISHED・ICMP・許可ポートだけ受け、残りは DROP)では、ポートで許可できない。ICMP は通るのに TCP だけ届かない(障害の症状)。
#   そこで、送信元で許可する(CI ランナーの Overlay のアドレスだけ)。
# 必須: OA_SOURCES(空白区切りの送信元。IP または CIDR)
# 定義は OA_CONF に書き、overlay-allow-source.service(oneshot、easytier.service の後。easytier の再起動に連動する)が、起動時に入れる。
#   連動させる理由: overlay-firewall は、easytier の起動のたびに、INPUT の先頭へ DROP のチェインへの飛ばし先を入れ直す。
#   その後ろに回った許可を、再起動で入れ直して、先頭に戻す(gre-overlay と同じ作り)。
# OA_CONF / OA_HELPER / OA_UNIT_DIR は、テスト(test-overlay-allow-source.sh)で差し替える。
set -eo pipefail
export PATH="${PATH:+$PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export DEBIAN_FRONTEND=noninteractive
umask 022

: "${OA_SOURCES:?OA_SOURCES が必要}"
conf="${OA_CONF:-/etc/overlay-allow-source/sources.conf}"
helper="${OA_HELPER:-/usr/local/sbin/overlay-allow-source}"
unit_dir="${OA_UNIT_DIR:-/etc/systemd/system}"
testing="${OA_TESTING:-0}"

if ! command -v iptables >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y iptables
fi

install -d -m 755 "$(dirname "$conf")" "$(dirname "$helper")" "$unit_dir"

# 古い定義(今回の定義から外れた送信元)を、先に消す
if [ -f "$conf" ]; then
  # shellcheck disable=SC1090
  . "$conf"
  for old in ${SOURCES:-}; do
    case " $OA_SOURCES " in
      *" $old "*) ;;
      *) while iptables -C INPUT -s "$old" -p tcp -j ACCEPT 2>/dev/null; do iptables -D INPUT -s "$old" -p tcp -j ACCEPT; done ;;
    esac
  done
fi

cat > "$conf" <<CONF
SOURCES="$OA_SOURCES"
CONF

cat > "$helper" <<HELPER
#!/bin/bash
set -eo pipefail
export PATH="\${PATH:+\$PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
. "$conf"
# 許可は、INPUT の先頭に入れる(overlay-firewall の DROP より前)。あれば何もしない。
ensure() { iptables -C INPUT "\$@" 2>/dev/null || iptables -I INPUT 1 "\$@"; }
unensure() { while iptables -C INPUT "\$@" 2>/dev/null; do iptables -D INPUT "\$@"; done; }
case "\${1:-}" in
  up)   for s in \$SOURCES; do ensure -s "\$s" -p tcp -j ACCEPT; done ;;
  down) for s in \$SOURCES; do unensure -s "\$s" -p tcp -j ACCEPT; done ;;
  *) echo "usage: \$0 up|down" >&2; exit 2 ;;
esac
HELPER
chmod 755 "$helper"

cat > "$unit_dir/overlay-allow-source.service" <<UNIT
[Unit]
Description=Allow TCP from selected EasyTier overlay sources (CI runner via subnet proxy)
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
chmod 644 "$unit_dir/overlay-allow-source.service"

if [ "$testing" != 1 ]; then
  systemctl daemon-reload
  systemctl enable overlay-allow-source.service
  "$helper" up
  systemctl start overlay-allow-source.service
else
  "$helper" up
fi

echo "--- INPUT のこの許可:"
iptables -S INPUT | grep -E -- "-p tcp -j ACCEPT" | head -5 || true
