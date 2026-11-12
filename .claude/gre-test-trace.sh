#!/bin/bash
# bao-02 から LAN へ ping している間、k8s1 で全インターフェースを見る。事前に、両側で gre-test-*.sh up 済みであること。
# 鍵と sudo のパスワードは bws から取り、画面に出さず、終わったら消す。bao-02 の鍵は /tmp/bao02_key。
set -u
here=$(cd "$(dirname "$0")" && pwd)
umask 077
[ -s /tmp/bao02_key ] || { echo "NG: /tmp/bao02_key が無い"; exit 1; }
BWS_ACCESS_TOKEN=$(tr -d '\n' < "$HOME/dev/bws"); export BWS_ACCESS_TOKEN
key=$(mktemp); pw=$(mktemp); out=$(mktemp)
trap 'rm -f "$key" "$pw" "$out"' EXIT
bws secret get 0393671f-6ef0-4650-be98-b364013f8644 2>/dev/null | jq -r '.value' > "$key"
bws secret get 52b44d60-7cab-429f-929a-b4340139b6d8 2>/dev/null | jq -r '.value' > "$pw"
[ -s "$key" ] && [ -s "$pw" ] || { echo "NG: bws から取り出せなかった"; exit 1; }
opt=(-i "$key" -o IdentitiesOnly=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)
for h in 10.0.0.103 192.168.1.103; do ssh "${opt[@]}" kigawa@$h true 2>/dev/null && { host=$h; break; }; done
[ -n "${host:-}" ] || { echo "NG: k8s1 に SSH できない"; exit 1; }
scp -q "${opt[@]}" "$here/gre-test-side.sh" kigawa@$host:/tmp/gre-test-side.sh || exit 1
k8s1() { cat "$pw" | ssh "${opt[@]}" kigawa@$host "sudo -S -p '' bash /tmp/gre-test-side.sh $1 k8s1"; }
echo "######## k8s1: diag"; k8s1 diag
echo "######## k8s1 で 10 秒間キャプチャしながら、bao-02 から ping"
k8s1 cap > "$out" 2>&1 &
cap_pid=$!
sleep 3
ssh -i /tmp/bao02_key -o IdentitiesOnly=yes root@207.231.111.196 bash -s ping1 bao02 < "$here/gre-test-side.sh"
wait $cap_pid
echo "######## k8s1 のキャプチャ"; cat "$out"
ssh "${opt[@]}" kigawa@$host "rm -f /tmp/gre-test-side.sh"
