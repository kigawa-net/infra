resource "random_password" "ci_token" {
  length  = 64
  special = false

  lifecycle {
    ignore_changes = [result]
  }
}

resource "bitwarden-sm_secret" "ci_token" {
  key        = "admin-panel-github-app-ci-token"
  value      = random_password.ci_token.result
  project_id = var.bws_project_id
}
