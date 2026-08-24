#!/usr/bin/env bash
# Usage: ./platform/run.sh <module> <terraform-args...>
# BWS_ACCESS_TOKEN が設定されている必要があります
set -ue

script_dir=$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)
module="${1:?Usage: $0 <module> <terraform-args...>}"
shift

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export TF_VAR_keycloak_admin_password
export TF_VAR_github_app_private_key
AWS_ACCESS_KEY_ID=$(bws secret get eb5eb0e8-2a4a-4398-a756-b37000d87d64 --color no | jq -r '.value')
AWS_SECRET_ACCESS_KEY=$(bws secret get c39086cc-e112-40eb-b19f-b37000d89090 --color no | jq -r '.value')
TF_VAR_keycloak_admin_password=$(bws secret get e38ac3a1-1988-44a4-8421-b47000d79995 --color no | jq -r '.value')
# kigawa-net GitHub App (app_id 4316503) の秘密鍵。admin-panelサーバーが使っているのと
# 同じBWS secret(kigawa-net-private-key)を再利用し、platform/admin-panelとplatform/github
# のgithub providerをApp認証させる(PATは発行しない)。Appに必要な権限
# (admin-panel: "Secrets" organization write / github: "Administration" repository
# write, "Members" organization write)が付与されていない場合はそのモジュールのgithub
# provider認証が失敗するが、それは使っているモジュールだけの話なので他モジュールの
# 実行には影響しない。
TF_VAR_github_app_private_key=$(bws secret get 97b6eba7-6bd2-418d-9d64-b48a007a097a --color no 2>/dev/null | jq -r '.value // empty') || true

terraform -chdir="$script_dir/$module" "$@"
