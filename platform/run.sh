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
export TF_VAR_github_token
AWS_ACCESS_KEY_ID=$(bws secret get eb5eb0e8-2a4a-4398-a756-b37000d87d64 | jq -r '.value')
AWS_SECRET_ACCESS_KEY=$(bws secret get c39086cc-e112-40eb-b19f-b37000d89090 | jq -r '.value')
TF_VAR_keycloak_admin_password=$(bws secret get e38ac3a1-1988-44a4-8421-b47000d79995 | jq -r '.value')
# admin:org(組織シークレット管理)スコープを持つGitHub PAT。platform/admin-panelが
# ADMIN_PANEL_CI_TOKEN組織シークレットを登録するのに使う。
# TODO: 事前にPATを発行してBitwardenに保存し、そのsecret IDに置き換える。
# それまでは空文字にフォールバックする(他モジュールの実行を壊さないため。
# github_tokenを参照するのはplatform/admin-panelだけなので、他モジュールには影響しない)。
TF_VAR_github_token=$(bws secret get REPLACE_ME_GITHUB_PAT_BWS_ID 2>/dev/null | jq -r '.value // empty') || true

terraform -chdir="$script_dir/$module" "$@"
