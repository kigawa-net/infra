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
    Same key platform/admin-panel uses. Needs "Administration" (repository,
    write) and "Members" (organization, write) permissions granted in
    addition to its existing contents:write / secrets:write for this module
    to manage branch protection and team repository access.
  EOT
  type        = string
  sensitive   = true
}

variable "actions_bypass_repositories" {
  description = <<-EOT
    Repositories (subset of var.repositories) where the built-in
    github-actions bot may bypass the required-pull-request rule on the
    default branch. Used by CI workflows that need to commit directly to the
    default branch (e.g. an image-tag bump after building/pushing an image),
    without weakening the PR requirement for human contributors or for repos
    that don't need this.
  EOT
  type        = list(string)
  default     = ["admin-panel"]
}

variable "repositories" {
  description = "kigawa-net org repositories to apply default branch protection to"
  type        = list(string)
  default = [
    "kinfra", "lipl", "keruta", "kigawa-net-k8s", "kodel", "infra",
    "admin-panel", "kalender", "lp", "dilot", "fonsole", "leafia",
    "linfra", "keruta-executor", "keruta-coder-template", "fonsole-doc",
    "keruta-doc", "keruta-admin", "keruta-api", "keruta-sdk",
    "keruta-agent", "ktmut", "hakate", "krapition-doc", "fomage",
    "mc-manifest", "k8s-builders", "kest", "hakoniwa-core-plugin",
    "auth-server", "kweb", ".github", "server-chat", "keimvus",
    "RTPlugin", "config", "keimvus-maven-plugin", "craft-tools",
    "studilay-bot",
  ]
}

variable "default_branches" {
  description = <<-EOT
    Default branch per repository, sourced from `gh api repos/kigawa-net/<repo>
    --jq .default_branch` at authoring time. Kept as a static map (rather than
    read live via the github_repository data source) because that data source
    also fetches /license and errors out fatally on any repository without a
    LICENSE file (e.g. keimvus) — see kigawa-net/infra#80.
  EOT
  type        = map(string)
  default = {
    kinfra                  = "dev"
    lipl                    = "main"
    keruta                  = "develop"
    "kigawa-net-k8s"        = "main"
    kodel                   = "develop"
    infra                   = "main"
    "admin-panel"           = "main"
    kalender                = "master"
    lp                      = "main"
    dilot                   = "develop"
    fonsole                 = "develop"
    leafia                  = "main"
    linfra                  = "main"
    "keruta-executor"       = "main"
    "keruta-coder-template" = "main"
    "fonsole-doc"           = "main"
    "keruta-doc"            = "main"
    "keruta-admin"          = "main"
    "keruta-api"            = "main"
    "keruta-sdk"            = "develop"
    "keruta-agent"          = "main"
    ktmut                   = "main"
    hakate                  = "develop"
    "krapition-doc"         = "main"
    fomage                  = "main"
    "mc-manifest"           = "main"
    "k8s-builders"          = "main"
    kest                    = "main"
    "hakoniwa-core-plugin"  = "main"
    kweb                    = "master"
    ".github"               = "main"
    "server-chat"           = "main"
    keimvus                 = "main"
    RTPlugin                = "main"
    "craft-tools"           = "main"
    "studilay-bot"          = "main"
  }
}
