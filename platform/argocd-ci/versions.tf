terraform {
  required_version = ">= 1.6"

  backend "s3" {
    bucket = "infra"
    key    = "platform/argocd-ci/terraform.tfstate"
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
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    argocd = {
      source  = "argoproj-labs/argocd"
      version = "~> 7.0"
    }
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

provider "kubernetes" {
  config_path = "~/.kube/config"
}

# core=true でArgoCDのHTTP APIログイン(admin/OIDC)を経由せず、現在の
# デフォルトkubeconfigコンテキスト経由でArgoCDのKubernetesリソースを
# 直接操作する。admin.enabled=falseでも、CLIのOIDCセッション切れでも
# 影響を受けない。
provider "argocd" {
  core = true
}

provider "bitwarden-secrets" {
  api_url         = "https://api.bitwarden.com"
  identity_url    = "https://identity.bitwarden.com"
  organization_id = var.bws_organization_id
}

# kigawa-net GitHub App (app_id 4316503) をOneServerMC org側のinstallation
# (147092566)で認証させ、RpgCoreリポジトリにActions secretを書き込む。
provider "github" {
  owner = "OneServerMC"

  app_auth {
    id              = var.github_app_id
    installation_id = var.github_app_installation_id
    pem_file        = var.github_app_private_key
  }
}
