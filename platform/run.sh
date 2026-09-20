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
export TF_VAR_google_idp_client_secret
export TF_VAR_azuread_terraform_client_certificate
export TF_VAR_azuread_terraform_client_certificate_password
AWS_ACCESS_KEY_ID=$(bws -c no secret get eb5eb0e8-2a4a-4398-a756-b37000d87d64 | jq -r '.value')
AWS_SECRET_ACCESS_KEY=$(bws -c no secret get c39086cc-e112-40eb-b19f-b37000d89090 | jq -r '.value')
TF_VAR_keycloak_admin_password=$(bws -c no secret get e38ac3a1-1988-44a4-8421-b47000d79995 | jq -r '.value')
# kalenderのGoogle IdPブローカー用クライアントシークレット。client_idはvariables.tfに
# デフォルト値としてコード管理済み(機密情報ではないため)。
TF_VAR_google_idp_client_secret=$(bws -c no secret get 24b9574a-4d71-440a-94e5-b4cb0034af8c | jq -r '.value // empty') || true
# kalender-terraform-automation サービスプリンシパルの認証用証明書(PFX/Base64)とそのパスワード。
# client_id/tenant_idはvariables.tfにデフォルト値としてコード管理済み(機密情報ではないため)。
TF_VAR_azuread_terraform_client_certificate=$(bws -c no secret get 2e7def30-bdd2-4e94-8afc-b4cb002f433a | jq -r '.value // empty') || true
TF_VAR_azuread_terraform_client_certificate_password=$(bws -c no secret get 62503b87-9577-43ae-abe3-b4cb002f76a0 | jq -r '.value // empty') || true
# kigawa-net GitHub App (app_id 4316503) の秘密鍵。admin-panelサーバーが使っているのと
# 同じBWS secret(kigawa-net-private-key)を再利用し、platform/admin-panelのgithub
# providerをApp認証させる(PATは発行しない)。Appに"Secrets"(organization, write)
# 権限が付与されていない場合はgithub providerの認証が失敗するが、それはこのモジュール
# だけの話なので他モジュールの実行には影響しない。
TF_VAR_github_app_private_key=$(bws -c no secret get 97b6eba7-6bd2-418d-9d64-b48a007a097a 2>/dev/null | jq -r '.value // empty') || true

terraform -chdir="$script_dir/$module" "$@"
