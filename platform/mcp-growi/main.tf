resource "keycloak_openid_client" "mcp_growi" {
  realm_id  = var.keycloak_realm
  client_id = "mcp-growi"
  name      = "mcp-growi"
  enabled   = true

  access_type = "CONFIDENTIAL"

  valid_redirect_uris = [
    "https://mcp-growi.kigawa.net/oauth2/callback",
  ]

  web_origins = [
    "https://mcp-growi.kigawa.net",
  ]
}

resource "random_password" "cookie_secret" {
  length  = 32
  special = false

  lifecycle {
    ignore_changes = [result]
  }
}

resource "bitwarden-sm_secret" "client_secret" {
  key        = "mcp-growi-keycloak-client-secret"
  value      = keycloak_openid_client.mcp_growi.client_secret
  project_id = var.bws_project_id
}

resource "bitwarden-sm_secret" "cookie_secret" {
  key        = "mcp-growi-keycloak-cookie-secret"
  value      = random_password.cookie_secret.result
  project_id = var.bws_project_id
}
