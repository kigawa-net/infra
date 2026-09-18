output "org_service_client_secret_bws_id" {
  description = "BWS secret ID for kalender-org-service client-secret — set as bwSecretId in k8s-system/keycloak/kalender-org-service-keycloak-bws.yaml"
  value       = bitwarden-secrets_secret.kalender_org_service_client_secret.id
}
