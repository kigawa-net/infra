# Repositories created from scratch by this module, as opposed to the
# pre-existing ones that only get delete_branch_on_merge managed through
# github_repository.delete_branch_on_merge. Each repository must be handled by
# exactly one github_repository instance — otherwise Terraform would issue two
# creates for the same name and the second one fails with 422 already_exists —
# so the keys here are subtracted from that resource's for_each below.
# Every key added here must also be listed in var.repositories (variables.tf):
# branch protection comes from that list, and the key is subtracted from
# github_repository.delete_branch_on_merge. Asserted by the check block below.
locals {
  new_repositories = {
    # auto_init seeds README.md and license_template adds the MIT LICENSE in
    # the initial commit, so the repository is never empty. description is
    # intentionally left unset (kept empty).
    # visibility is intentionally required per entry: if omitted, the GitHub
    # provider falls back to its default of "private", silently contradicting
    # the intent that each new repository's visibility is an explicit choice.
    exkes = { visibility = "public" }
  }
}

# Terraform >= 1.6: fail fast if a local.new_repositories key is missing from
# var.repositories (no branch protection) or vice versa (a 422 already_exists
# from github_repository.delete_branch_on_merge trying to create a repository
# that github_repository.this already creates).
check "new_repositories_in_var_repositories" {
  assert {
    condition = alltrue([
      for k in keys(local.new_repositories) : contains(var.repositories, k)
    ])
    error_message = "Every key of local.new_repositories must also be listed in var.repositories: ${join(", ", [for k in keys(local.new_repositories) : k if !contains(var.repositories, k)])}. Missing entries get no branch protection (github_branch_protection.default iterates var.repositories)."
  }
}

# issue #69: PRがmergeされた際にheadブランチを自動削除する。github_repository
# リソースは本来リポジトリの新規作成用で、description/visibility/各種機能
# フラグなど非常に多くの属性を持つ。既存リポジトリをimportしてこの1属性だけ
# 変更したいので、他の属性はconfig側で指定せずlifecycle.ignore_changesで
# 保護し、意図せずTerraformが他の設定を「修正」しようとしないようにする。
resource "github_repository" "delete_branch_on_merge" {
  # local.new_repositories are created (and fully configured) by
  # github_repository.this instead; see the local's comment above.
  for_each = toset(setsubtract(var.repositories, keys(local.new_repositories)))

  name                   = each.value
  delete_branch_on_merge = true

  lifecycle {
    ignore_changes = [
      description,
      homepage_url,
      topics,
      visibility,
      has_issues,
      has_projects,
      has_wiki,
      has_discussions,
      is_template,
      allow_merge_commit,
      allow_squash_merge,
      allow_rebase_merge,
      allow_auto_merge,
      allow_update_branch,
      squash_merge_commit_title,
      squash_merge_commit_message,
      merge_commit_title,
      merge_commit_message,
      archived,
      archive_on_destroy,
      auto_init,
      gitignore_template,
      license_template,
      web_commit_signoff_required,
      pages,
      template,
      security_and_analysis,
    ]
  }
}

# New repositories owned by this module. Existing repositories stay under
# github_repository.delete_branch_on_merge above; this resource only handles
# the entries in local.new_repositories, creating them with an initial commit
# (README) plus an MIT LICENSE so they are usable from day one.
resource "github_repository" "this" {
  for_each = local.new_repositories

  name             = each.key
  visibility       = each.value.visibility
  auto_init        = true
  license_template = "mit"

  has_issues   = true
  has_projects = true
  has_wiki     = false

  delete_branch_on_merge = true
}

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

  # GraphQL node id of the built-in "github-actions" App (REST id 15368,
  # https://api.github.com/apps/github-actions). The REST
  # bypass_pull_request_allowances.apps=["github-actions"] field silently
  # fails to persist for this app (it's not an installed Marketplace app),
  # and github_repository_ruleset's bypass_actors rejects it outright
  # ("must be part of the ruleset source or owner organization"). Only the
  # classic protection's pull_request_bypassers field, keyed by GraphQL node
  # id, actually works.
  github_actions_app_node_id = "MDM6QXBwMTUzNjg="
}

resource "github_repository" "keruta_compute" {
  name        = "keruta-compute"
  description = "Decentralized compute network for the Keruta ecosystem"
  visibility  = "public"

  has_issues   = true
  has_projects = true
  has_wiki     = false

  auto_init = true
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
    # admin-panel's CI commits an image-tag bump directly to main after each
    # merge; let the github-actions bot bypass the PR requirement just for
    # that push instead of disabling the requirement repo-wide.
    pull_request_bypassers = contains(var.actions_bypass_repositories, each.value) ? [local.github_actions_app_node_id] : []
  }

  enforce_admins = false

  # A repository listed in var.repositories that is still being created by
  # github_repository.this would otherwise be protected before it exists
  # (the API returns 404). Waiting on the creation fixes that ordering.
  depends_on = [github_repository.this]
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
