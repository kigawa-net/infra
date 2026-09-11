variable "bws_organization_id" {
  description = "Bitwarden Secrets Manager organization ID (same org used by the k8s BitwardenSecret CRDs)"
  type        = string
  default     = "a2b57f3d-6e2b-4467-b499-b31e00bfd804"
}

variable "bws_project_id" {
  description = "Bitwarden project ID to store the generated ArgoCD API token under (same project as the github-app-kigawa-net secrets)"
  type        = string
  default     = "3f39dcb2-4e04-4c80-bcc4-b3e100e4e27a"
}

variable "github_app_id" {
  description = "App ID of the kigawa-net GitHub App used to authenticate the github provider"
  type        = string
  default     = "4316503"
}

variable "github_app_installation_id" {
  description = "Installation ID of the kigawa-net GitHub App on the OneServerMC org"
  type        = string
  default     = "147092566"
}

variable "github_app_private_key" {
  description = "PEM-encoded private key of the kigawa-net GitHub App (from BWS secret 97b6eba7-6bd2-418d-9d64-b48a007a097a, set via TF_VAR_github_app_private_key in run.sh)"
  type        = string
  sensitive   = true
}
