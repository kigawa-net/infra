# kalenderアプリ(Android/Web)のログイン用パブリッククライアント。
# realm "kigawa-net"は他アプリ(admin-panel等)と共用のため、redirect_uris/web_originsは
# kalenderのオリジンに限定する。
resource "keycloak_openid_client" "kalender" {
  realm_id  = var.keycloak_realm
  client_id = "kalender"
  name      = "Kalender"
  enabled   = true

  access_type                  = "PUBLIC"
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  pkce_code_challenge_method   = "S256"

  valid_redirect_uris = [
    "https://kalender-62z.pages.dev/*",
    "net.kigawa.kalender://oauth2redirect",
  ]

  web_origins = [
    "https://kalender-62z.pages.dev",
  ]
}

# kalenderバックエンド(server/)がKeycloak Admin API(federated-identity参照)を呼ぶための
# サービスアカウント専用クライアント。
resource "keycloak_openid_client" "kalender_org_service" {
  realm_id  = var.keycloak_realm
  client_id = "kalender-org-service"
  name      = "Kalender Backend Service Account"
  enabled   = true

  access_type                  = "CONFIDENTIAL"
  standard_flow_enabled        = false
  direct_access_grants_enabled = false
  service_accounts_enabled     = true
}

# NOTE: リソース名/属性名はmrparkers/keycloakプロバイダの実際のスキーマを
# `terraform providers schema` 等で確認してから `terraform plan` すること。
# (Federated-identity参照に必要な最小権限としてmanage-usersではなくview-usersを付与)
resource "keycloak_openid_client_service_account_role" "kalender_org_service_view_users" {
  realm_id                = var.keycloak_realm
  service_account_user_id = keycloak_openid_client.kalender_org_service.service_account_user_id
  client_id               = data.keycloak_openid_client.realm_management.id
  role                    = "view-users"
}

data "keycloak_openid_client" "realm_management" {
  realm_id  = var.keycloak_realm
  client_id = "realm-management"
}

resource "bitwarden-secrets_secret" "kalender_org_service_client_secret" {
  key        = "kalender-org-service-keycloak-client-secret"
  value      = keycloak_openid_client.kalender_org_service.client_secret
  project_id = var.bws_project_id
}

# Google Identity Provider (realm "kigawa-net" 共有 — 他アプリにも影響する変更)
# alias は "google" で自動決定されるため指定不可(terraform validateで確認済み)
resource "keycloak_oidc_google_identity_provider" "google" {
  realm = var.keycloak_realm

  client_id     = var.google_idp_client_id
  client_secret = var.google_idp_client_secret

  default_scopes = "openid email profile https://www.googleapis.com/auth/calendar https://www.googleapis.com/auth/calendar.events"

  store_token                   = true
  trust_email                   = true
  first_broker_login_flow_alias = "first broker login"
}

# 既存のkalender用Microsoft Entra(Azure AD)アプリ登録をclient_idから検索する。
# Object IDが分からなくても terraform import なしで既存アプリを参照できる。
data "azuread_application" "kalender" {
  client_id = var.microsoft_kalender_app_client_id
}

# Web版kalenderがAzure ADへ直接PKCEログインする際のリダイレクトURI。
# 現在発生している "invalid_request: redirect_uri" エラーの直接的な修正になる。
resource "azuread_application_redirect_uris" "kalender_spa" {
  application_id = data.azuread_application.kalender.id
  type           = "SPA"

  redirect_uris = [
    "https://kalender-62z.pages.dev/",
  ]
}

# Keycloakがブローカーとして使うための"Web"(confidential)プラットフォーム。
# SPAプラットフォームと同じアプリ登録に追加する(Azure ADは1アプリに複数プラットフォームを
# 併存できる。別アプリに分けても良いが、権限定義を共有できるこちらを採用)。
resource "azuread_application_redirect_uris" "kalender_web" {
  application_id = data.azuread_application.kalender.id
  type           = "Web"

  redirect_uris = [
    "https://user.kigawa.net/realms/kigawa-net/broker/microsoft/endpoint",
  ]
}

# Keycloakのbrokerクライアントシークレット。Google IdPと異なりこちらはTerraformが
# 生成するため、Bitwardenへの手動保存は不要。
resource "azuread_application_password" "kalender_keycloak_broker" {
  application_id = data.azuread_application.kalender.id
  display_name   = "kigawa-net-keycloak-broker"
}

# Microsoft (Azure AD) Identity Provider。mrparkers/keycloakプロバイダに
# Microsoft専用リソースが無いため、汎用の keycloak_oidc_identity_provider を使う。
# authorization_url/token_urlは汎用OIDCリソースでは必須(provider_id="microsoft"だけでは
# 自動補完されない、terraform validateで確認済み)。既存のWeb版実装(MicrosoftAuthControllerWeb.kt)
# と同じマルチテナント"common"エンドポイントを使う。
resource "keycloak_oidc_identity_provider" "microsoft" {
  realm       = var.keycloak_realm
  alias       = "microsoft"
  provider_id = "microsoft"

  authorization_url = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
  token_url         = "https://login.microsoftonline.com/common/oauth2/v2.0/token"

  client_id     = var.microsoft_kalender_app_client_id
  client_secret = azuread_application_password.kalender_keycloak_broker.value

  default_scopes = "openid email profile Calendars.ReadWrite offline_access"

  store_token                   = true
  trust_email                   = true
  first_broker_login_flow_alias = "first broker login"
}
