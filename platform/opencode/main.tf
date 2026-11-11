# opencode.kigawa.net の oauth2-proxy 用パブリッククライアント(PKCE)。
# ログインを許可するユーザーは、oauth2-proxy 側(kigawa-net-k8s の opencode/oauth2-proxy-configmap.yaml)で絞る。
resource "keycloak_openid_client" "opencode" {
  realm_id  = var.keycloak_realm
  client_id = "opencode"
  name      = "OpenCode (opencode.kigawa.net)"
  enabled   = true

  access_type                  = "PUBLIC"
  standard_flow_enabled        = true
  direct_access_grants_enabled = false
  pkce_code_challenge_method   = "S256"

  valid_redirect_uris = ["${var.opencode_origin}/oauth2/callback"]
  web_origins         = [var.opencode_origin]
}

# oauth2-proxy の Cookie 暗号化キー(32 文字)。k8s の BitwardenSecret(opencode/oauth2-proxy-bws.yaml)から参照する。
resource "random_password" "cookie_secret" {
  length  = 32
  special = false
}

resource "bitwarden-secrets_secret" "cookie_secret" {
  key        = "opencode-oauth2-proxy-cookie-secret"
  value      = random_password.cookie_secret.result
  project_id = var.bws_project_id
}
