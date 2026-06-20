terraform {
  required_version = ">= 1.6"

  required_providers {
    keycloak = {
      source  = "mrparkers/keycloak"
      version = "~> 4.4"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }

  backend "s3" {
    bucket = "terraform-state"
    key    = "platform/keycloak/terraform.tfstate"
    region = "auto"

    # Cloudflare R2 — endpoint injected by run.sh
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    force_path_style            = true
  }
}

data "external" "keycloak_password" {
  program = ["sh", "-c", "bws secret get ${var.keycloak_password_secret_id} | jq '{value: .value}'"]
}

provider "keycloak" {
  client_id = "admin-cli"
  username  = var.keycloak_admin_username
  password  = data.external.keycloak_password.result["value"]
  url       = var.keycloak_url
}

# kigawa-net realm（既存）を参照
data "keycloak_realm" "kigawa_net" {
  realm = "kigawa-net"
}

# admin-panel クライアント
resource "keycloak_openid_client" "admin_panel" {
  realm_id  = data.keycloak_realm.kigawa_net.id
  client_id = "admin-panel"
  name      = "Admin Panel"
  enabled   = true

  access_type              = "PUBLIC"
  standard_flow_enabled    = true
  direct_access_grants_enabled = false

  valid_redirect_uris = [
    "https://admin.kigawa.net/callback",
  ]

  web_origins = [
    "https://admin.kigawa.net",
  ]

  login_theme = "keycloak"
}
