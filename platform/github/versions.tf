terraform {
  required_version = ">= 1.6"

  backend "s3" {
    bucket = "infra"
    key    = "platform/github/terraform.tfstate"
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
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }
}

provider "github" {
  owner = "kigawa-net"

  app_auth {
    id              = var.github_app_id
    installation_id = var.github_app_installation_id
    pem_file        = var.github_app_private_key
  }
}
