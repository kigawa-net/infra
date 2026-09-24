output "token_bws_id" {
  description = "BWS secret ID for the ArgoCD API token — set as bwSecretId in a BitwardenSecret CRD"
  value       = bitwarden-secrets_secret.rpgcore_pr_ci_token.id
}

output "kigawa_net_k8s_ci_dryrun_token_bws_id" {
  description = "BWS secret ID for the kigawa-net-k8s CI dry-run ServiceAccount token — consumed by platform/github to populate the CI_DRYRUN_SA_TOKEN Actions secret"
  value       = bitwarden-secrets_secret.kigawa_net_k8s_ci_dryrun_token.id
}
