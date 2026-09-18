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
export TF_VAR_bws_project_id
export TF_VAR_google_idp_client_id
export TF_VAR_google_idp_client_secret
export TF_VAR_azuread_tenant_id
export TF_VAR_azuread_terraform_client_id
export TF_VAR_azuread_terraform_client_certificate
export TF_VAR_azuread_terraform_client_certificate_password
AWS_ACCESS_KEY_ID=$(bws -c no secret get eb5eb0e8-2a4a-4398-a756-b37000d87d64 | jq -r '.value')
AWS_SECRET_ACCESS_KEY=$(bws -c no secret get c39086cc-e112-40eb-b19f-b37000d89090 | jq -r '.value')
TF_VAR_keycloak_admin_password=$(bws -c no secret get e38ac3a1-1988-44a4-8421-b47000d79995 | jq -r '.value')
# platform/kalender用。TODO: 下記のBWSシークレットUUIDを実際の値に差し替えること
# (kigawa-net/kalender#57のStage A対応、詳細はPR参照)。
# 未設定のままだと platform/kalender の terraform plan/apply はCIで失敗する。
# - bws_project_id: kalenderのシークレットを格納するBitwardenプロジェクトID
# - google_idp_*: Google Cloud Consoleで新規作成した「ウェブアプリケーション」OAuthクライアント
#   (Microsoftと違いGoogleにはazuread相当のTerraformプロバイダが無いため手動作成・BWS保存が必要)
# - azuread_tenant_id: Terraform自動化用サービスプリンシパルが所属する実テナントID(GUID)
# - azuread_terraform_client_id: 同サービスプリンシパルのアプリケーション(クライアント)ID
# - azuread_terraform_client_certificate: 同サービスプリンシパルの認証用PFX証明書をBase64
#   エンコードした文字列(クライアントシークレットではなく証明書認証を使う方針のため)
# - azuread_terraform_client_certificate_password: 上記PFXのパスワード(無しなら空文字列)
TF_VAR_bws_project_id=$(bws -c no secret get REPLACE_WITH_BWS_PROJECT_ID_SECRET_UUID | jq -r '.value // empty') || true
TF_VAR_google_idp_client_id=$(bws -c no secret get REPLACE_WITH_GOOGLE_IDP_CLIENT_ID_UUID | jq -r '.value // empty') || true
TF_VAR_google_idp_client_secret=$(bws -c no secret get REPLACE_WITH_GOOGLE_IDP_CLIENT_SECRET_UUID | jq -r '.value // empty') || true
TF_VAR_azuread_tenant_id=$(bws -c no secret get REPLACE_WITH_AZUREAD_TENANT_ID_UUID | jq -r '.value // empty') || true
TF_VAR_azuread_terraform_client_id=$(bws -c no secret get REPLACE_WITH_AZUREAD_TERRAFORM_CLIENT_ID_UUID | jq -r '.value // empty') || true
TF_VAR_azuread_terraform_client_certificate=$(bws -c no secret get REPLACE_WITH_AZUREAD_TERRAFORM_CLIENT_CERTIFICATE_UUID | jq -r '.value // empty') || true
TF_VAR_azuread_terraform_client_certificate_password=$(bws -c no secret get REPLACE_WITH_AZUREAD_TERRAFORM_CLIENT_CERTIFICATE_PASSWORD_UUID | jq -r '.value // empty') || true
# kigawa-net GitHub App (app_id 4316503) の秘密鍵。admin-panelサーバーが使っているのと
# 同じBWS secret(kigawa-net-private-key)を再利用し、platform/admin-panelのgithub
# providerをApp認証させる(PATは発行しない)。Appに"Secrets"(organization, write)
# 権限が付与されていない場合はgithub providerの認証が失敗するが、それはこのモジュール
# だけの話なので他モジュールの実行には影響しない。
TF_VAR_github_app_private_key=$(bws -c no secret get 97b6eba7-6bd2-418d-9d64-b48a007a097a 2>/dev/null | jq -r '.value // empty') || true

terraform -chdir="$script_dir/$module" "$@"
