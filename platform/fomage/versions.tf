terraform {
  required_version = ">= 1.6"

  backend "s3" {
    bucket = "infra"
    key    = "platform/fomage/terraform.tfstate"
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
    keycloak = {
      source  = "mrparkers/keycloak"
      version = "~> 4.0"
    }
    # NOTE: platform/mcp-growi still uses the old "bitwarden-labs/bitwarden-sm" provider
    # (resource type bitwarden-sm_secret). That provider is gone from the registry; use
    # the current "bitwarden/bitwarden-secrets" provider (resource type
    # bitwarden-secrets_secret) for new modules instead, as platform/admin-panel does.
    bitwarden-secrets = {
      source  = "bitwarden/bitwarden-secrets"
      version = "~> 1.0"
    }
  }
}

provider "keycloak" {
  client_id = "admin-cli"
  username  = "admin"
  password  = var.keycloak_admin_password
  url       = var.keycloak_url
  realm     = "master"
}

provider "bitwarden-secrets" {
  api_url         = "https://api.bitwarden.com"
  identity_url    = "https://identity.bitwarden.com"
  organization_id = var.bws_organization_id
}
