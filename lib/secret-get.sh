#!/usr/bin/env bash
# シークレット取得の抽象化ヘルパー。source して使う(実行はしない)。
#
#   source "<repo>/lib/secret-get.sh"
#   value=$(secret_get_value "<bitwarden-uuid>") || exit 1
#
# SECRET_BACKEND で取得元を切り替える(既定: bws)。
#   bws        Bitwarden のみ(従来通り。bws_get_value)
#   bao-first  OpenBao を先に読み、失敗したら Bitwarden にフォールバック
#   bao        OpenBao のみ
#
# UUID → OpenBao の KV パス/field の対応は SECRET_MAP_FILE(CSV: uuid,kv_path,field)で与える。
# 既定は scripts/secrets-to-migrate.csv。BAO_ADDR / BAO_TOKEN は呼び出し側の環境変数で設定する。
# 値は標準出力にのみ出す。エラーは標準エラーへ。値はログに出さない。

_SECRET_GET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/bws-retry.sh
source "$_SECRET_GET_DIR/bws-retry.sh"

# uuid から "kv_path field" をタブ区切りで返す。見つからなければ return 1。
_secret_lookup() {
  local id="$1"
  local map="${SECRET_MAP_FILE:-$_SECRET_GET_DIR/../scripts/secrets-to-migrate.csv}"
  local u p f
  [ -r "$map" ] || { echo "secret_get_value: mapping file not readable: $map" >&2; return 1; }
  while IFS=, read -r u p f || [ -n "$u" ]; do
    f=$(printf '%s' "$f" | tr -d '\r')
    if [ "$u" = "$id" ]; then
      printf '%s\t%s' "$p" "$f"
      return 0
    fi
  done < "$map"
  echo "secret_get_value: no OpenBao mapping for $id" >&2
  return 1
}

# OpenBao から値を読む。空・失敗は return 1。
_bao_get_value() {
  local id="$1" entry path field val
  entry=$(_secret_lookup "$id") || return 1
  path=$(printf '%s' "$entry" | cut -f1)
  field=$(printf '%s' "$entry" | cut -f2)
  command -v bao >/dev/null 2>&1 || { echo "secret_get_value: bao CLI not found" >&2; return 1; }
  val=$(bao kv get -field="$field" "$path" 2>/dev/null) || {
    echo "secret_get_value: bao kv get failed for $path#$field" >&2
    return 1
  }
  if [ -z "$val" ]; then
    echo "secret_get_value: empty value at $path#$field" >&2
    return 1
  fi
  printf '%s' "$val"
}

secret_get_value() {
  local id="${1:?secret_get_value: secret id is required}"
  local backend="${SECRET_BACKEND:-bws}"
  case "$backend" in
    bws) bws_get_value "$id" ;;
    bao) _bao_get_value "$id" ;;
    bao-first)
      _bao_get_value "$id" && return 0
      echo "secret_get_value: falling back to bws for $id" >&2
      bws_get_value "$id"
      ;;
    *)
      echo "secret_get_value: unknown SECRET_BACKEND '$backend' (bws|bao-first|bao)" >&2
      return 1
      ;;
  esac
}
