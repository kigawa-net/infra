variable "bws_project_id" {
  description = "Bitwarden Secrets Manager project ID for admin-panel's secrets"
  type        = string
  default     = "3f39dcb2-4e04-4c80-bcc4-b3e100e4e27a"
}

variable "bws_organization_id" {
  description = "Bitwarden Secrets Manager organization ID (same org used by the k8s BitwardenSecret CRDs)"
  type        = string
  default     = "a2b57f3d-6e2b-4467-b499-b31e00bfd804"
}

variable "github_app_id" {
  description = "App ID of the kigawa-net GitHub App used to authenticate the github provider"
  type        = string
  default     = "4316503"
}

variable "github_app_installation_id" {
  description = "Installation ID of the kigawa-net GitHub App on the kigawa-net org"
  type        = string
  default     = "147092408"
}

variable "github_app_private_key" {
  description = <<-EOT
    PEM private key of the kigawa-net GitHub App, injected by run.sh from BWS.
    Same key admin-panel's server uses (kigawa-net/admin-panel#46) — the App
    needs the "Secrets" (organization, write) permission granted for this to
    work, in addition to its existing contents:write.
  EOT
  type        = string
  sensitive   = true
}
