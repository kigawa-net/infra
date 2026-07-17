// Project-level config for the legacy combined hardware/ root module itself
// (as opposed to the per-node modules under hardware/<name>/, which are
// declared as subProjects in kinfra-parent.kts). Used by top-level
// `kinfra plan`/`kinfra apply` when logged in with repoPath pointing at hardware/.
projectId = "hardware"

terraform {
    workingDirectory = "."
    backendConfig {
        accessKey = bws("eb5eb0e8-2a4a-4398-a756-b37000d87d64")
        secretKey = bws("c39086cc-e112-40eb-b19f-b37000d89090")
    }
}
