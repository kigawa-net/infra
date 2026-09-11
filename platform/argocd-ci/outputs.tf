output "token_bws_id" {
  description = "BWS secret ID for the ArgoCD API token — set as bwSecretId in a BitwardenSecret CRD"
  value       = bitwarden-secrets_secret.rpgcore_pr_ci_token.id
}
