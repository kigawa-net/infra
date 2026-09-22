output "ci_token_bws_id" {
  description = "BWS secret ID for ci-token — set as bwSecretId in admin-panel's k8s/base/github-app-bws.yaml"
  value       = bitwarden-secrets_secret.ci_token.id
}

output "mariadb_root_password_bws_id" {
  description = "BWS secret ID for the MariaDB root password — set as bwSecretId in admin-panel's k8s/base/admin-panel-db-bws.yaml"
  value       = bitwarden-secrets_secret.mariadb_root_password.id
}

output "mariadb_app_password_bws_id" {
  description = "BWS secret ID for the MariaDB app-user password — set as bwSecretId in admin-panel's k8s/base/admin-panel-db-bws.yaml"
  value       = bitwarden-secrets_secret.mariadb_app_password.id
}
