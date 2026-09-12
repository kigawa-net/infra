# fomage(kigawa-net-k8s#207/#208, kigawa-net/fomage#5)のKeycloakクライアントを
# develop/manage 両レルムに作成する。dev/stg環境はdevelopレルムのクライアントを
# 共用し、prodのみ高権限アカウント向けのmanageレルムを使う(ユーザー指定の方針)。

# project_idを直接指定する既知の安全な方法がまだ無いため、CIマシンアカウントから
# 確実に読めることが分かっている既存シークレット(admin-panelのGitHub App
# private key)のproject_idを流用する。platform/admin-panelと同じ手法。
data "bitwarden-secrets_secret" "known_project_anchor" {
  id = "97b6eba7-6bd2-418d-9d64-b48a007a097a"
}

resource "keycloak_openid_client" "fomage_develop" {
  realm_id  = "develop"
  client_id = "fomage"
  name      = "fomage"
  enabled   = true

  access_type = "CONFIDENTIAL"

  valid_redirect_uris = [
    "https://fomage-dev.kigawa.net/login/oauth2/code/keycloak",
    "https://fomage-stg.kigawa.net/login/oauth2/code/keycloak",
  ]

  web_origins = [
    "https://fomage-dev.kigawa.net",
    "https://fomage-stg.kigawa.net",
  ]
}

resource "keycloak_openid_client" "fomage_manage" {
  realm_id  = "manage"
  client_id = "fomage"
  name      = "fomage"
  enabled   = true

  access_type = "CONFIDENTIAL"

  valid_redirect_uris = [
    "https://fomage.kigawa.net/login/oauth2/code/keycloak",
  ]

  web_origins = [
    "https://fomage.kigawa.net",
  ]
}

resource "bitwarden-secrets_secret" "fomage_develop_client_secret" {
  key        = "fomage-develop-keycloak-client-secret"
  value      = keycloak_openid_client.fomage_develop.client_secret
  project_id = data.bitwarden-secrets_secret.known_project_anchor.project_id
}

resource "bitwarden-secrets_secret" "fomage_manage_client_secret" {
  key        = "fomage-manage-keycloak-client-secret"
  value      = keycloak_openid_client.fomage_manage.client_secret
  project_id = data.bitwarden-secrets_secret.known_project_anchor.project_id
}
