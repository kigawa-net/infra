#!/bin/bash
# `*.karmada-system.svc` を、ループバックの別々のアドレスに向け、その 443 を、各サービスの実ポートへ REDIRECT する。
#
# IONOS の HAProxy が 0.0.0.0:443 を占有しているため、ローカルで 443 を待ち受けられない。
# `iptables -t nat -A OUTPUT -d <ループバック> -p tcp --dport 443 -j REDIRECT --to-ports <実ポート>` なら、衝突しない
# (宛先が、nat の段階で、127.0.0.1 の実ポートに書き換わる)。コンテナ(iptables-nft、HAProxy 役が 0.0.0.0:443 を占有)で検証済み。
#
# 使い方: karmada-cp-redirect.sh start|stop|status
# 対応表: /etc/karmada/redirect.table(1 行 = `<127.0.0.x> <実ポート>`)。Terraform が書く。
# 冪等: start は、すでにあるルールを重複して足さない。stop は、無いルールを無視する。
set -eu

TABLE="${REDIRECT_TABLE:-/etc/karmada/redirect.table}"
IPT="${IPTABLES:-iptables}"

[ -r "$TABLE" ] || { echo "karmada-cp-redirect: $TABLE がありません" >&2; exit 1; }

# 表の内容を、先に検証する(ループバックのアドレスと、ポート番号だけを許す)
rows=()
while read -r ip port rest; do
  [ -z "${ip:-}" ] && continue
  case "$ip" in \#*) continue ;; esac
  if ! [[ "$ip" =~ ^127\.0\.0\.[0-9]{1,3}$ ]] || ! [[ "${port:-}" =~ ^[0-9]{2,5}$ ]] || [ -n "${rest:-}" ]; then
    echo "karmada-cp-redirect: 表の行が不正です: '$ip $port ${rest:-}'" >&2
    exit 1
  fi
  rows+=("$ip $port")
done < "$TABLE"
[ "${#rows[@]}" -gt 0 ] || { echo "karmada-cp-redirect: 表が空です" >&2; exit 1; }

have() { "$IPT" -t nat -C OUTPUT -d "$1" -p tcp --dport 443 -j REDIRECT --to-ports "$2" 2>/dev/null; }

case "${1:-}" in
  start)
    for r in "${rows[@]}"; do
      set -- $r
      have "$1" "$2" || "$IPT" -t nat -A OUTPUT -d "$1" -p tcp --dport 443 -j REDIRECT --to-ports "$2"
    done
    ;;
  stop)
    for r in "${rows[@]}"; do
      set -- $r
      if have "$1" "$2"; then "$IPT" -t nat -D OUTPUT -d "$1" -p tcp --dport 443 -j REDIRECT --to-ports "$2"; fi
    done
    ;;
  status)
    rc=0
    for r in "${rows[@]}"; do
      set -- $r
      if have "$1" "$2"; then echo "ok      $1:443 -> :$2"; else echo "missing $1:443 -> :$2"; rc=1; fi
    done
    exit $rc
    ;;
  *)
    echo "使い方: $0 start|stop|status" >&2
    exit 2
    ;;
esac
