#!/usr/bin/env bash
# Bitwarden Secrets Manager CLI (bws) の再試行ヘルパー。source して使う(実行はしない)。
#
#   source "<repo>/lib/bws-retry.sh"
#   value=$(bws_get_value "<secret-id>") || exit 1
#
# 背景(2026-10-03):
#   Bitwarden の API が断続的に 503 Service Unavailable を返す(同期の約 2.5%)。
#   `value=$(bws secret get ... | jq -r .value)` は失敗しても空文字のまま後続に進むため、
#   ionos の wg0.conf が `PublicKey =` 空で生成され wg-quick@wg0 が起動できずゲートウェイが
#   停止した。CI の WireGuard トンネル用秘密鍵も同じ理由で空になり失敗した。
#
# 仕様:
#   - 一時的なエラー(5xx/429/タイムアウト/接続系)だけを、指数バックオフで再試行する。
#     待ち時間は BWS_RETRY_SLEEP 秒(既定 2)から倍々。回数は BWS_RETRIES(既定 5)。
#   - 永続的なエラー(未存在・認証失敗など)や、値が空/null の場合は再試行せず即座に失敗する。
#   - 失敗時は return 1 で、標準出力には何も出さない。呼び出し側は `|| exit 1` などで止めること
#     (`export X=$(...)` は失敗が隠れるので、代入してから export する)。
#   - シークレットの値は標準エラーにも出さない。

bws_get_value() {
  local id="${1:?bws_get_value: secret id is required}"
  local tries="${BWS_RETRIES:-5}"
  local delay="${BWS_RETRY_SLEEP:-2}"
  local attempt out err val errfile

  errfile=$(mktemp) || return 1

  for ((attempt = 1; attempt <= tries; attempt++)); do
    if out=$(bws secret get "$id" --color no 2>"$errfile"); then
      val=$(printf '%s' "$out" | jq -r '.value // empty' 2>/dev/null) || val=""
      if [ -n "$val" ]; then
        rm -f "$errfile"
        printf '%s' "$val"
        return 0
      fi
      echo "bws_get_value: secret $id has an empty or null value" >&2
      rm -f "$errfile"
      return 1
    fi

    err=$(cat "$errfile" 2>/dev/null || true)
    if ! printf '%s' "$err" | grep -qiE '(^|[^0-9])(429|50[0-9])([^0-9]|$)|timed? ?out|timeout|connection|temporar|unavailable|reset|resolve'; then
      echo "bws_get_value: non-retryable error for $id: ${err:0:200}" >&2
      rm -f "$errfile"
      return 1
    fi

    if ((attempt < tries)); then
      echo "bws_get_value: transient error for $id (attempt $attempt/$tries), retrying in ${delay}s" >&2
      sleep "$delay"
      delay=$((delay * 2))
    fi
  done

  echo "bws_get_value: failed after $tries attempts for $id" >&2
  rm -f "$errfile"
  return 1
}
