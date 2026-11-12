#!/bin/bash
# k8s1 側の GRE テストを、手元から実行する。鍵と sudo のパスワードは bws から取り、画面に出さず、終わったら消す。
# 使い方: bash gre-test-k8s1.sh <up|down|status>
set -u
mode=${1:-status}
here=$(cd "$(dirname "$0")" && pwd)
umask 077
BWS_ACCESS_TOKEN=$(tr -d '\n' < "$HOME/dev/bws"); export BWS_ACCESS_TOKEN
key=$(mktemp); pw=$(mktemp)
trap 'rm -f "$key" "$pw"' EXIT
bws secret get 0393671f-6ef0-4650-be98-b364013f8644 2>/dev/null | jq -r '.value' > "$key"
bws secret get 52b44d60-7cab-429f-929a-b4340139b6d8 2>/dev/null | jq -r '.value' > "$pw"
[ -s "$key" ] && [ -s "$pw" ] || { echo "NG: bws から取り出せなかった"; exit 1; }
opt=(-i "$key" -o IdentitiesOnly=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)
for h in 10.0.0.103 192.168.1.103; do
  ssh "${opt[@]}" kigawa@$h true 2>/dev/null && { host=$h; break; }
done
[ -n "${host:-}" ] || { echo "NG: k8s1 に SSH できない"; exit 1; }
scp -q "${opt[@]}" "$here/gre-test-side.sh" kigawa@$host:/tmp/gre-test-side.sh || exit 1
cat "$pw" | ssh "${opt[@]}" kigawa@$host "sudo -S -p '' bash /tmp/gre-test-side.sh $mode k8s1; rc=\$?; rm -f /tmp/gre-test-side.sh; exit \$rc"
