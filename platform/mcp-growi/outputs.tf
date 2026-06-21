output "client_secret_bws_id" {
  description = "BWS secret ID for client-secret — set as bwSecretId in mcp-server-bws.yaml"
  value       = bitwarden-sm_secret.client_secret.id
}

output "cookie_secret_bws_id" {
  description = "BWS secret ID for cookie-secret — set as bwSecretId in mcp-server-bws.yaml"
  value       = bitwarden-sm_secret.cookie_secret.id
}
