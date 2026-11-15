#!/bin/bash
# OpenBao が Sealed(Unseal が必要)になったら、Discord Webhook に通知する(issue #444)。
# systemd timer(openbao-sealed-alert.timer)が、このノード上で定期的に実行する。
#
# - 状態は /v1/sys/seal-status で確認する(認証不要)。未初期化(initialized=false)は通知しない。
# - 通知は、Sealed になった時、Sealed が続く間の REMIND_SEC ごと、Unseal された時(復旧)に送る。
# - OpenBao に接続できない時は何もしない(プロセス停止は別の監視の対象。再起動すれば Sealed で立ち上がり、ここで検知する)。
# - Webhook の URL は、環境変数 DISCORD_WEBHOOK_URL で受け取る(systemd の EnvironmentFile。0600 root)。
#   curl のコマンドラインには載せず、-K - で標準入力から渡す(ps に出さない)。
#
# 環境変数:
#   DISCORD_WEBHOOK_URL  (必須)
#   FQDN                 (必須) このノードの証明書の名前。通知の見出しと、接続先に使う
#   STATE_FILE           状態の保存先(既定 /var/lib/openbao-sealed-alert/state)
#   REMIND_SEC           Sealed が続くときの再通知の間隔(既定 21600 = 6 時間)
#   BAO_PORT             既定 8200
set -u

: "${DISCORD_WEBHOOK_URL:?DISCORD_WEBHOOK_URL が未設定}" "${FQDN:?FQDN が未設定}"
state_file="${STATE_FILE:-/var/lib/openbao-sealed-alert/state}"
remind="${REMIND_SEC:-21600}"
port="${BAO_PORT:-8200}"

# 証明書は fqdn 用なので、名前は fqdn のまま、接続先だけをループバックに固定する(検証は無効にしない)
body=$(curl -sS --max-time 10 --resolve "$FQDN:$port:127.0.0.1" "https://$FQDN:$port/v1/sys/seal-status") || {
  echo "openbao-sealed-alert: seal-status に接続できません(OpenBao が停止中の可能性。今回は何もしません)" >&2
  exit 0
}

compact=$(printf '%s' "$body" | tr -d ' \n\r\t')
case "$compact" in
  *'"initialized":false'*) cur="uninitialized" ;;
  *'"sealed":true'*) cur="sealed" ;;
  *'"sealed":false'*) cur="unsealed" ;;
  *)
    echo "openbao-sealed-alert: seal-status の応答を解釈できません" >&2
    exit 0
    ;;
esac

prev="unsealed"
prev_at=0
if [ -f "$state_file" ]; then
  read -r prev prev_at < "$state_file" || true
  case "$prev_at" in '' | *[!0-9]*) prev_at=0 ;; esac
fi
now=$(date +%s)

send() {
  local msg="$1"
  printf 'url = "%s"\n' "$DISCORD_WEBHOOK_URL" |
    curl -sS --max-time 15 -K - -X POST -H 'Content-Type: application/json' \
      --data "{\"content\":\"$msg\"}" -o /dev/null
}

save() {
  mkdir -p "$(dirname "$state_file")" && printf '%s %s\n' "$1" "$2" > "$state_file"
}

case "$cur" in
  sealed)
    if [ "$prev" != "sealed" ]; then
      send "🔒 OpenBao が Sealed です(Unseal が必要): $FQDN" || exit 1
      save sealed "$now"
    elif [ $((now - prev_at)) -ge "$remind" ]; then
      send "🔒 OpenBao は Sealed のままです(Unseal が必要): $FQDN" || exit 1
      save sealed "$now"
    fi
    ;;
  unsealed)
    if [ "$prev" = "sealed" ]; then
      send "🔓 OpenBao が Unseal されました(復旧): $FQDN" || exit 1
    fi
    save unsealed "$now"
    ;;
  uninitialized)
    # 未初期化は Unseal の対象ではない。状態だけ進める(通知しない)
    save unsealed "$now"
    ;;
esac
