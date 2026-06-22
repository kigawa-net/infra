#!/usr/bin/env bash
# Usage: ./run.sh <module> <terraform-args...>
# module: k8s1, k8s2, k8s4, k8s-worker5, alice, . (hardware/ 自体)
# BWS_ACCESS_TOKEN が設定されている必要があります
set -ue

script_dir=$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)
module="${1:?Usage: $0 <module> <terraform-args...>}"
shift

export AWS_ACCESS_KEY_ID=$(bws secret get eb5eb0e8-2a4a-4398-a756-b37000d87d64 | jq -r '.value')
export AWS_SECRET_ACCESS_KEY=$(bws secret get c39086cc-e112-40eb-b19f-b37000d89090 | jq -r '.value')

terraform -chdir="$script_dir/$module" "$@"
