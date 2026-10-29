#!/usr/bin/env bash
# frr-overlay-peer の FRR 設定テンプレートのオフラインテスト。本番・ネットワークには触れない。
# terraform console で templatefile を描画し、prefix-list・neighbor・out の route-map を確認する。
# 使い方: bash hardware/modules/frr-overlay-peer/test-frr-overlay-peer.sh
set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
tpl="$here/templates/frr.conf.tpl"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fails=0
check() { # 名前 期待 実際
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 (expected=$2 actual=$3)"; fails=$((fails + 1)); fi
}

if ! command -v terraform >/dev/null 2>&1; then
  echo "FAIL - terraform が見つからない"
  exit 1
fi

# terraform console は、この作業ディレクトリ(空)で動かす。プロバイダは使わない。
render() { # 式(HCL)を渡すと、描画結果を標準出力に出す
  (cd "$work" && printf '%s\n' "$1" | terraform console -no-color 2>&1)
}

# 描画: bao-02 相当(AS 65041、router-id 10.250.0.1、neighbor は Inuyama の 3 台)
conf=$(render "templatefile(\"$tpl\", {router_id = \"10.250.0.1\", local_as = 65041, remote_as = 65010, neighbors = [\"10.250.0.11\", \"10.250.0.12\", \"10.250.0.13\"], import_prefixes = [\"10.0.0.0/24\", \"192.168.1.0/24\"]})")
printf '%s\n' "$conf" > "$work/bao02.conf"

check "router bgp は local_as(65041)" 1 "$(grep -c '^router bgp 65041$' "$work/bao02.conf")"
check "router-id は overlay の IP" 1 "$(grep -c '^ bgp router-id 10.250.0.1$' "$work/bao02.conf")"
check "neighbor 10.250.0.11 の remote-as は 65010" 1 "$(grep -c '^ neighbor 10.250.0.11 remote-as 65010$' "$work/bao02.conf")"
check "neighbor 10.250.0.12 の remote-as は 65010" 1 "$(grep -c '^ neighbor 10.250.0.12 remote-as 65010$' "$work/bao02.conf")"
check "neighbor 10.250.0.13 の remote-as は 65010" 1 "$(grep -c '^ neighbor 10.250.0.13 remote-as 65010$' "$work/bao02.conf")"
check "update-source は overlay の IP" 3 "$(grep -c '^ neighbor 10.250.0.1[123] update-source 10.250.0.1$' "$work/bao02.conf")"
check "import の prefix-list は 2 件" 2 "$(grep -c '^ip prefix-list OVERLAY-IN seq [0-9]* permit ' "$work/bao02.conf")"
check "10.0.0.0/24 を完全一致で受ける" 1 "$(grep -c '^ip prefix-list OVERLAY-IN seq 10 permit 10.0.0.0/24$' "$work/bao02.conf")"
check "192.168.1.0/24 を完全一致で受ける" 1 "$(grep -c '^ip prefix-list OVERLAY-IN seq 20 permit 192.168.1.0/24$' "$work/bao02.conf")"
check "ge / le を付けていない" 0 "$(grep -c 'permit .* \(ge\|le\) ' "$work/bao02.conf")"
check "import の route-map は permit 10 と、最後の deny 100" 2 "$(grep -c '^route-map OVERLAY-IN \(permit 10\|deny 100\)$' "$work/bao02.conf")"
check "neighbor の in 方向に OVERLAY-IN を当てる" 3 "$(grep -c '^  neighbor 10.250.0.1[123] route-map OVERLAY-IN in$' "$work/bao02.conf")"
check "out の route-map が無い(何も広告しない)" 0 "$(grep -c 'route-map .* out' "$work/bao02.conf")"
check "network / redistribute が無い" 0 "$(grep -c '^  network \|redistribute' "$work/bao02.conf")"
check "ebgp-requires-policy が有効" 1 "$(grep -c '^ bgp ebgp-requires-policy$' "$work/bao02.conf")"
check "ipv4 unicast の address-family で activate" 3 "$(grep -c '^  neighbor 10.250.0.1[123] activate$' "$work/bao02.conf")"

# 描画: import_prefixes が空なら、permit が無く、全部 deny になる
conf=$(render "templatefile(\"$tpl\", {router_id = \"10.250.0.31\", local_as = 65042, remote_as = 65010, neighbors = [\"10.250.0.11\"], import_prefixes = []})")
printf '%s\n' "$conf" > "$work/bao03.conf"
check "import が空なら permit が無い" 0 "$(grep -c 'permit 10$' "$work/bao03.conf")"
check "import が空でも deny 100 がある" 1 "$(grep -c '^route-map OVERLAY-IN deny 100$' "$work/bao03.conf")"
check "bao-03 の AS は 65042" 1 "$(grep -c '^router bgp 65042$' "$work/bao03.conf")"

# 行頭の空白の崩れ(テンプレートの ~ の位置)で、neighbor 行が address-family の外に出ていないか
check "neighbor の remote-as 行は 1 行 1 neighbor" 1 "$(grep -c '^ neighbor 10.250.0.11 remote-as' "$work/bao03.conf")"

if [ "$fails" -eq 0 ]; then echo "all ok"; else echo "$fails FAILED"; exit 1; fi
