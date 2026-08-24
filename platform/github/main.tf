locals {
  # auth-server, config, keimvus-maven-plugin are private repos on a plan
  # without the branch protection API (GET .../protection returns 403
  # "Upgrade to GitHub Pro or make this repository public"). Excluded here
  # rather than from var.repositories so other resources in this module can
  # still target the full repository list.
  branch_protection_unsupported = ["auth-server", "config", "keimvus-maven-plugin"]
  branch_protection_repositories = [
    for r in var.repositories : r if !contains(local.branch_protection_unsupported, r)
  ]
}

# Requires a PR before merging to the default branch; approvals are not
# required (required_approving_review_count = 0) per team preference.
#
# repository_id is passed as the repo name (the provider accepts either the
# GraphQL node id or the name) rather than looked up via the
# github_repository data source, which also fetches /license and errors out
# fatally on any repository without a LICENSE file (e.g. keimvus).
resource "github_branch_protection" "default" {
  for_each = toset(local.branch_protection_repositories)

  repository_id = each.value
  pattern       = var.default_branches[each.value]

  required_pull_request_reviews {
    required_approving_review_count = 0
  }

  enforce_admins = false
}

data "github_team" "dev_team" {
  slug = "dev-team"
}

resource "github_team_repository" "dev_team" {
  team_id    = data.github_team.dev_team.id
  repository = "hakoniwa-core-plugin"
  permission = "push"
}

# Not applied yet (no webhooks or repo secrets currently exist to bring under
# management). When needed:
#   resource "github_repository_webhook" "example" {
#     repository = "<repo>"
#     events     = ["push"]
#     configuration {
#       url          = "https://example.invalid/webhook"
#       content_type = "json"
#     }
#   }
#   resource "github_actions_secret" "example" {
#     repository      = "<repo>"
#     secret_name     = "EXAMPLE_SECRET"
#     plaintext_value = data.external.example_secret.result.value # from bws
#   }
