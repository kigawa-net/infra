output "cookie_secret_bws_id" {
  description = "kigawa-net-k8s の opencode/oauth2-proxy-bws.yaml の bwSecretId に設定する"
  value       = bitwarden-secrets_secret.cookie_secret.id
}
