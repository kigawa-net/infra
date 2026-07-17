// Kinfra parent configuration for platform/ modules.
//
// bucket/key/region/endpoints are already hardcoded in each module's own
// versions.tf `backend "s3" {}` block; only the R2 credentials (intentionally
// omitted from the .tf files) are supplied here via -backend-config.
//
// Note: platform/mcp-growi also needs TF_VAR_keycloak_admin_password (a plain
// Terraform variable, not backend config). kinfra's variableMappings/bws()-based
// tfvars generation is currently only wired for the top-level `plan`/`apply`
// commands, not `sub plan`/`sub apply` (which this workflow uses per-module) -
// see kigawa-net/kinfra follow-up. Until that's fixed, the CI workflow exports
// TF_VAR_keycloak_admin_password itself before invoking kinfra, matching what
// platform/run.sh already does today.
projectName = "infra-platform"

terraform {
    workingDirectory = "."
    backendConfig {
        accessKey = bws("eb5eb0e8-2a4a-4398-a756-b37000d87d64")
        secretKey = bws("c39086cc-e112-40eb-b19f-b37000d89090")
    }
}

subProjects {
    subProject("mcp-growi")
}
