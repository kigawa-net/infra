#!/usr/bin/env bash
# Usage: ./run.sh <module> <terraform-args...>
# module: k8s1, k8s2, k8s4, k8s-worker5, alice, ionos, . (hardware/ 自体)
# BWS_ACCESS_TOKEN が設定されている必要があります
set -ue

script_dir=$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)
module="${1:?Usage: $0 <module> <terraform-args...>}"
shift

# bws の一時的な 503 で空の認証情報のまま進まないよう、再試行ヘルパーを使う(lib/bws-retry.sh)
source "$script_dir/../lib/bws-retry.sh"
AWS_ACCESS_KEY_ID=$(bws_get_value eb5eb0e8-2a4a-4398-a756-b37000d87d64)
AWS_SECRET_ACCESS_KEY=$(bws_get_value c39086cc-e112-40eb-b19f-b37000d89090)
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

terraform -chdir="$script_dir/$module" "$@"
