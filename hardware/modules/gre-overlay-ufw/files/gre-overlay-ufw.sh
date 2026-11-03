#!/bin/bash
# bao 側(ufw)で、GRE トンネルのための受信を許可する(docs/frr-gre-overlay-design.md §6.2)。
# 必須の環境変数: GU_PEERS(「名前,相手の Overlay,相手のトンネルのアドレス」を ; で区切る)。
#   例: k8s4,10.250.0.11,172.31.250.1;k8s1,10.250.0.12,172.31.250.3
# 規則は、ufw status の「# <印>」(コメント)で見つける。あれば足さない(再実行しても重複しない)。
# ufw が無い、または、定義が不正なら、何も足さずに止める。
set -eo pipefail
export PATH="${PATH:+$PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

: "${GU_PEERS:?}"
command -v ufw >/dev/null 2>&1 || { echo "gre-overlay-ufw: ufw が無い(host-hardening で入れる)" >&2; exit 1; }

valid_ipv4() {
  local IFS=. o x
  [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  read -r -a o <<<"$1"
  for x in "${o[@]}"; do
    [ "$x" -le 255 ] || return 1
  done
}

# 先に全部検証する(不正な定義で、半端に規則を足さないため)
entries=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  IFS=, read -r name overlay tunnel extra <<<"$line"
  [[ $name =~ ^[a-z0-9-]{1,11}$ ]] || { echo "gre-overlay-ufw: 名前が不正: $name" >&2; exit 1; }
  valid_ipv4 "$overlay" || { echo "gre-overlay-ufw: $name の Overlay が IPv4 ではない: $overlay" >&2; exit 1; }
  valid_ipv4 "$tunnel" || { echo "gre-overlay-ufw: $name のトンネルのアドレスが IPv4 ではない: $tunnel" >&2; exit 1; }
  [ -z "${extra:-}" ] || { echo "gre-overlay-ufw: 項目が多い: $line" >&2; exit 1; }
  entries+=("$name $overlay $tunnel")
done < <(printf '%s\n' "$GU_PEERS" | tr ';' '\n')
[ "${#entries[@]}" -gt 0 ] || { echo "gre-overlay-ufw: peers が空" >&2; exit 1; }

allow() { # 印 ufw の規則(insert 1 で先頭に入れる)
  local tag=$1
  shift
  if ufw status 2>/dev/null | grep -qF "# $tag"; then
    echo "ufw rule exists: $tag"
    return 0
  fi
  ufw insert 1 "$@" comment "$tag"
}

for e in "${entries[@]}"; do
  read -r name overlay tunnel <<<"$e"
  allow "gre-overlay-$name-gre" allow in on tun0 proto gre from "$overlay"
  allow "gre-overlay-$name-bgp" allow in on "gre-$name" proto tcp from "$tunnel" to any port 179
done

echo "=== ufw (gre-overlay) ==="
ufw status | grep -F "# gre-overlay-" || true
