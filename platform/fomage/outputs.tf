output "develop_client_secret_bws_id" {
  description = "BWS secret ID for fomage's develop-realm (dev/stg) client secret — set as bwSecretId in kigawa-net-k8s's fomage-keycloak BitwardenSecret for fonsole/dev and fonsole/stg"
  value       = bitwarden-secrets_secret.fomage_develop_client_secret.id
}

output "manage_client_secret_bws_id" {
  description = "BWS secret ID for fomage's manage-realm (prod) client secret — set as bwSecretId in kigawa-net-k8s's fomage-keycloak BitwardenSecret for fonsole/prod"
  value       = bitwarden-secrets_secret.fomage_manage_client_secret.id
}
