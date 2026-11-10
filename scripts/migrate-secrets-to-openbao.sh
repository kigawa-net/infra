#!/usr/bin/env bash
# Bitwarden → OpenBao 移行スクリプト。
#
#   scripts/migrate-secrets-to-openbao.sh --dry-run  secrets.csv
#   scripts/migrate-secrets-to-openbao.sh --execute  secrets.csv
#
# CSV 形式: uuid,kv_path,field (ヘッダ行 `uuid,...` と # 始まりのコメントは読み飛ばす)
#   kv_path は KV v2 の `secret/...` 形式(`bao kv` が data/ を補う)。
#
# --dry-run : Bitwarden から値を取得できるか、OpenBao に既存かを確認する。何も書き込まない。
# --execute : OpenBao に値が無い項目だけ投入する(既存はスキップ=冪等。上書きしない)。
# 秘密値は標準出力・標準エラーのどちらにも出さない(OpenBao へは stdin で渡す)。
# 必要な環境変数: BWS_ACCESS_TOKEN, BAO_ADDR, BAO_TOKEN
set -uo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/bws-retry.sh
source "$script_dir/../lib/bws-retry.sh"

usage() { echo "Usage: $0 (--dry-run|--execute) <secrets.csv>" >&2; exit 2; }

[ $# -eq 2 ] || usage
mode="$1"; csv="$2"
case "$mode" in --dry-run|--execute) ;; *) usage ;; esac
[ -r "$csv" ] || { echo "CSV not readable: $csv" >&2; exit 2; }
command -v bao >/dev/null 2>&1 || { echo "bao CLI not found" >&2; exit 2; }

n_ok=0; n_skip=0; n_fail=0

while IFS=, read -r uuid path field || [ -n "$uuid" ]; do
  field=$(printf '%s' "$field" | tr -d '\r')
  case "$uuid" in ''|'#'*|uuid) continue ;; esac
  if [ -z "$path" ] || [ -z "$field" ]; then
    echo "FAIL  $uuid: malformed row (kv_path/field missing)" >&2
    n_fail=$((n_fail+1)); continue
  fi

  src=$(bws_get_value "$uuid") || {
    echo "FAIL  $uuid -> $path#$field: cannot read from Bitwarden" >&2
    n_fail=$((n_fail+1)); continue
  }

  # 既存確認(読めて非空なら既存)
  path_exists=0
  if bao kv get "$path" >/dev/null 2>&1; then path_exists=1; fi
  existing=$(bao kv get -field="$field" "$path" 2>/dev/null || true)

  if [ -n "$existing" ]; then
    if [ "$existing" = "$src" ]; then
      echo "SKIP  $uuid -> $path#$field (already present, identical)"
    else
      echo "SKIP  $uuid -> $path#$field (already present, DIFFERS from Bitwarden; not overwritten)"
    fi
    unset existing src
    n_skip=$((n_skip+1)); continue
  fi
  unset existing

  if [ "$mode" = "--dry-run" ]; then
    echo "WOULD $uuid -> $path#$field (Bitwarden OK, absent in OpenBao)"
    unset src
    n_ok=$((n_ok+1)); continue
  fi

  # 既存パスは他 field を壊さないよう patch、無ければ put。値は stdin(field=-)で渡す。
  if [ "$path_exists" -eq 1 ]; then cmd=patch; else cmd=put; fi
  if printf '%s' "$src" | bao kv "$cmd" "$path" "$field=-" >/dev/null 2>&1; then
    echo "OK    $uuid -> $path#$field ($cmd)"
    n_ok=$((n_ok+1))
  else
    echo "FAIL  $uuid -> $path#$field: bao kv $cmd failed" >&2
    n_fail=$((n_fail+1))
  fi
  unset src
done < "$csv"

echo "summary: ${mode#--}=$n_ok skipped=$n_skip failed=$n_fail"
[ "$n_fail" -eq 0 ]
