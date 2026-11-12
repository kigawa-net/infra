#!/bin/bash
# k8s1 の GRE トンネル(Terraform で入れたもの)の状態を、読むだけで確認する。手元から実行する。鍵と sudo のパスワードは bws から取り、画面に出さず、終わったら消す。
set -u
umask 077
BWS_ACCESS_TOKEN=$(tr -d '\n' < "$HOME/dev/bws"); export BWS_ACCESS_TOKEN
key=$(mktemp); pw=$(mktemp)
trap 'rm -f "$key" "$pw"' EXIT
bws secret get 0393671f-6ef0-4650-be98-b364013f8644 2>/dev/null | jq -r '.value' > "$key"
bws secret get 52b44d60-7cab-429f-929a-b4340139b6d8 2>/dev/null | jq -r '.value' > "$pw"
[ -s "$key" ] && [ -s "$pw" ] || { echo "NG: bws から取り出せなかった"; exit 1; }
opt=(-i "$key" -o IdentitiesOnly=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)
for h in 10.0.0.103 192.168.1.103; do ssh "${opt[@]}" kigawa@$h true 2>/dev/null && { host=$h; break; }; done
[ -n "${host:-}" ] || { echo "NG: k8s1 に SSH できない"; exit 1; }
cat "$pw" | ssh "${opt[@]}" kigawa@$host "sudo -S -p '' bash -c '
echo \"== gre-overlay.service\"; systemctl is-active gre-overlay.service; systemctl is-enabled gre-overlay.service
echo \"== トンネル\"; ip -d -o link show type gre | cut -c1-170; ip -o addr show type gre 2>/dev/null | cut -c1-110
echo \"== 定義\"; cat /etc/gre-overlay/tunnels.conf
echo \"== INPUT の先頭(GRE と 179/tcp の許可が、DROP の飛ばし先より前にあるか)\"; iptables -S INPUT | head -8
echo \"== EASYTIER-OVERLAY(gre の許可があるか)\"; iptables -S EASYTIER-OVERLAY
echo \"== easytier\"; systemctl is-active easytier.service; easytier-cli peer 2>&1 | head -4
'"
