terraform {
  required_version = ">= 1.6"

  backend "s3" {
    bucket = "infra"
    key    = "hardware/103/terraform.tfstate"
    region = "auto"
    endpoints = {
      s3 = "https://e9f30fd43ef4cc3d46050e34dad5c811.r2.cloudflarestorage.com"
    }
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    force_path_style            = true
  }

  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.0"
    }
  }
}
