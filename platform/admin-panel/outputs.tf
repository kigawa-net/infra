output "ci_token_bws_id" {
  description = "BWS secret ID for ci-token — set as bwSecretId in admin-panel's k8s/base/github-app-bws.yaml"
  value       = bitwarden-secrets_secret.ci_token.id
}
