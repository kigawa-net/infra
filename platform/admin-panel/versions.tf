terraform {
  required_version = ">= 1.6"

  backend "s3" {
    bucket = "infra"
    key    = "platform/admin-panel/terraform.tfstate"
    region = "auto"
    endpoints = {
      s3 = "https://e9f30fd43ef4cc3d46050e34dad5c811.r2.cloudflarestorage.com"
    }
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    use_path_style              = true
  }

  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    # NOTE: platform/mcp-growi still uses the old "bitwarden-labs/bitwarden-sm" source
    # (local key "bitwarden-sm", resource type bitwarden-sm_secret). That provider no
    # longer exists on the registry — it was renamed/republished as bitwarden/bitwarden-secrets
    # with a different resource type name (bitwarden-secrets_secret). Don't copy the old
    # source for new modules; mcp-growi itself needs a careful `terraform state mv`-based
    # migration since it already has live state under the old resource type (a blind rename
    # would make Terraform propose destroying and recreating that production secret).
    bitwarden-secrets = {
      source  = "bitwarden/bitwarden-secrets"
      version = "~> 1.0"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }
}

provider "bitwarden-secrets" {
  api_url         = "https://api.bitwarden.com"
  identity_url    = "https://identity.bitwarden.com"
  organization_id = var.bws_organization_id
}

provider "github" {
  owner = "kigawa-net"

  app_auth {
    id              = var.github_app_id
    installation_id = var.github_app_installation_id
    pem_file        = var.github_app_private_key
  }
}
