#!/bin/bash
# Overlay のアドレスを両端にした GRE トンネルを張る(設計書 docs/frr-gre-overlay-design.md §2〜§6)。
# 使い方:
#   install : 設定を検証し、/etc/gre-overlay/tunnels.conf に置く。このスクリプトを /usr/local/sbin/gre-overlay に入れ、
#             systemd の gre-overlay.service を作って(再)起動する。Terraform の provisioner が呼ぶ。
#   up      : 設定のトンネルを張る。冪等(既にあるトンネルは、設定が同じなら残す)。gre-overlay.service の ExecStart。
#   down    : 設定のトンネルを消す。gre-overlay.service の ExecStop。
# 設定ファイル(1 行 1 項目。Terraform が描画する):
#   local <自分の Overlay の IP>         例: local 10.250.0.1
#   mtu <MTU>                            既定 1300(§8。576〜1336)
#   clamp_mss <0|1>                      1 のとき、gre+ へ出る TCP の SYN の MSS を、PMTU に合わせて絞る(§6.1。control-plane 側)
#   firewall <none|ufw>                  ufw のとき、tun0 から相手の Overlay の gre を許可し、gre-<名前> から相手のトンネルの 179/tcp を許可する(§6.2。bao 側)
#   peer <名前> <相手の Overlay の IP> <自分のトンネルの CIDR(/31)> <相手のトンネルの IP>
#     インターフェース名は gre-<名前>。名前は小文字英数字で 11 文字以内(gre- を足して 15 文字)。
# テスト(test-gre-overlay-tunnel.sh)で差し替える環境変数: GRE_SRC_CONF(install の設定の元)、GRE_CONF、GRE_BIN、
#   GRE_UNIT_DIR、GRE_MODULES_LOAD_DIR。
set -eo pipefail
export PATH="${PATH:+$PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export DEBIAN_FRONTEND=noninteractive
umask 022

conf="${GRE_CONF:-/etc/gre-overlay/tunnels.conf}"
bin="${GRE_BIN:-/usr/local/sbin/gre-overlay}"
unit_dir="${GRE_UNIT_DIR:-/etc/systemd/system}"
modules_dir="${GRE_MODULES_LOAD_DIR:-/etc/modules-load.d}"

die() {
  echo "gre-overlay-tunnel: $*" >&2
  exit 1
}

valid_ipv4() {
  local IFS=. o x
  [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  read -r -a o <<<"$1"
  for x in "${o[@]}"; do
    [ "$x" -le 255 ] || return 1
  done
}

# 設定を読んで検証する。不正なら止める(実機に半端なトンネルを作らないため)。
load_conf() {
  local f=$1 kind a b c d _ p name overlay cidr peer_addr
  LOCAL=""
  MTU=1300
  CLAMP_MSS=0
  FIREWALL=none
  PEERS=()
  [ -r "$f" ] || die "設定がない: $f"
  while read -r kind a b c d _ || [ -n "$kind" ]; do
    case "$kind" in
      "" | \#*) ;;
      local) LOCAL=$a ;;
      mtu) MTU=$a ;;
      clamp_mss) CLAMP_MSS=$a ;;
      firewall) FIREWALL=$a ;;
      peer) PEERS+=("$a $b $c $d") ;;
      *) die "不明な項目: $kind" ;;
    esac
  done <"$f"

  valid_ipv4 "$LOCAL" || die "local が IPv4 ではない: $LOCAL"
  [[ $MTU =~ ^[0-9]+$ ]] && [ "$MTU" -ge 576 ] && [ "$MTU" -le 1336 ] || die "mtu は 576〜1336: $MTU"
  case "$CLAMP_MSS" in 0 | 1) ;; *) die "clamp_mss は 0 か 1: $CLAMP_MSS" ;; esac
  case "$FIREWALL" in none | ufw) ;; *) die "firewall は none か ufw: $FIREWALL" ;; esac
  [ "${#PEERS[@]}" -gt 0 ] || die "peer が 1 つもない"

  local names=()
  for p in "${PEERS[@]}"; do
    read -r name overlay cidr peer_addr <<<"$p"
    [[ $name =~ ^[a-z0-9]{1,11}$ ]] || die "peer 名は小文字英数字 1〜11 文字: $name"
    valid_ipv4 "$overlay" || die "peer $name の Overlay の IP が IPv4 ではない: $overlay"
    [[ $cidr =~ ^([0-9.]+)/31$ ]] && valid_ipv4 "${BASH_REMATCH[1]}" || die "peer $name のトンネルの CIDR は /31: $cidr"
    valid_ipv4 "$peer_addr" || die "peer $name のトンネルの相手の IP が IPv4 ではない: $peer_addr"
    [ "$peer_addr" != "${cidr%/31}" ] || die "peer $name: 相手のトンネルの IP が自分と同じ"
    names+=("$name")
  done
  if [ -n "$(printf '%s\n' "${names[@]}" | sort | uniq -d)" ]; then
    die "peer 名が重複している"
  fi
}

# トンネルが、設定どおり(local が自分、remote が相手)か。
tunnel_matches() { # dev remote
  local info
  info=$(ip -d link show dev "$1" 2>/dev/null | tr '\n\t' '  ') || return 1
  case " $info " in *" remote $2 "*) ;; *) return 1 ;; esac
  case " $info " in *" local $LOCAL "*) return 0 ;; esac
  return 1
}

# ufw の規則。status に印(コメント)があれば、既にあるとみなして足さない(再実行で重複させない)。
ufw_allow() { # 印 ufw の規則(insert 1 で先頭に入れる)
  local tag=$1
  shift
  if ufw status 2>/dev/null | grep -qF "# $tag"; then
    echo "ufw rule exists: $tag"
    return 0
  fi
  ufw insert 1 "$@" comment "$tag"
}

# 停止と起動で同じ規則。TCP の MSS を、PMTU に合わせて絞る(gre+ へ出る SYN)。
MSS_ARGS=(-o 'gre+' -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu)
mss_on() {
  iptables -t mangle -C FORWARD "${MSS_ARGS[@]}" 2>/dev/null || iptables -t mangle -A FORWARD "${MSS_ARGS[@]}"
}
mss_off() {
  while iptables -t mangle -C FORWARD "${MSS_ARGS[@]}" 2>/dev/null; do
    iptables -t mangle -D FORWARD "${MSS_ARGS[@]}"
  done
}

up() {
  load_conf "$conf"
  modprobe ip_gre || die "ip_gre を読み込めない"

  local p name overlay cidr peer_addr dev
  for p in "${PEERS[@]}"; do
    read -r name overlay cidr peer_addr <<<"$p"
    dev="gre-$name"
    if ip link show dev "$dev" >/dev/null 2>&1 && tunnel_matches "$dev" "$overlay"; then
      echo "keep $dev (remote $overlay)"
    else
      if ip link show dev "$dev" >/dev/null 2>&1; then
        ip tunnel del "$dev"
      fi
      ip tunnel add "$dev" mode gre local "$LOCAL" remote "$overlay" ttl 64
      echo "create $dev (remote $overlay)"
    fi
    ip addr replace "$cidr" dev "$dev"
    ip link set "$dev" mtu "$MTU" up
    if [ "$FIREWALL" = ufw ]; then
      ufw_allow "gre-overlay-$name-gre" allow in on tun0 proto gre from "$overlay"
      ufw_allow "gre-overlay-$name-bgp" allow in on "$dev" proto tcp from "$peer_addr" to any port 179
    fi
  done

  if [ "$CLAMP_MSS" = 1 ]; then
    mss_on
  else
    mss_off
  fi
}

down() {
  if [ -r "$conf" ]; then
    load_conf "$conf"
    local p name dev
    for p in "${PEERS[@]}"; do
      read -r name _ <<<"$p"
      dev="gre-$name"
      if ip link show dev "$dev" >/dev/null 2>&1; then
        ip tunnel del "$dev"
        echo "remove $dev"
      fi
    done
  fi
  mss_off
}

install_gre() {
  local src=${GRE_SRC_CONF:-}
  [ -n "$src" ] || die "GRE_SRC_CONF(設定の元のファイル)がない"
  # 先に検証する(不正な設定で、unit や設定を置き換えない)
  load_conf "$src"

  if [ "$CLAMP_MSS" = 1 ] && ! command -v iptables >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y iptables
  fi
  if [ "$FIREWALL" = ufw ] && ! command -v ufw >/dev/null 2>&1; then
    die "firewall = ufw だが ufw が無い(host-hardening で入れる)"
  fi

  install -d -m 755 "$(dirname "$conf")" "$(dirname "$bin")" "$unit_dir" "$modules_dir"
  install -m 644 "$src" "$conf"
  install -m 755 "$0" "$bin"
  printf 'ip_gre\n' >"$modules_dir/gre-overlay.conf"

  # EasyTier の後に起動する(Overlay の IP が、トンネルの local として使われるため)。停止時にトンネルを消す。
  cat >"$unit_dir/gre-overlay.service" <<UNIT
[Unit]
Description=GRE tunnels over the EasyTier overlay (docs/frr-gre-overlay-design.md)
After=easytier.service
Wants=easytier.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$bin up
ExecStop=$bin down

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable gre-overlay.service
  # 設定が変わっていても、down の後に up で合う
  systemctl restart gre-overlay.service

  echo "=== GRE overlay tunnels ==="
  ip -br link show type gre || true
}

case "${1:-}" in
  install) install_gre ;;
  up) up ;;
  down) down ;;
  *) echo "usage: $0 install|up|down" >&2; exit 2 ;;
esac
