// Kinfra parent configuration for hardware/ modules.
//
// bucket/key/region/endpoints are already hardcoded in each module's own
// versions.tf `backend "s3" {}` block, so they must NOT be repeated in
// backendConfig{} below (terraform init would reject the same backend
// argument being supplied both in the .tf file and via -backend-config).
// Only the R2 credentials, which are intentionally omitted from the .tf
// files, are supplied via backendConfig{}.
//
// r2Bucket/r2Endpoint are separate from backendConfig{} for the same reason,
// but ARE needed by kinfra's change-detection feature (kigawa-net/kinfra#349/#350),
// which stores a per-sub-project content hash cache in this same R2 bucket to
// decide which sub-projects to skip on plan/apply/deploy.
projectName = "infra-hardware"

terraform {
    workingDirectory = "."
    r2Bucket = "infra"
    r2Endpoint = "https://e9f30fd43ef4cc3d46050e34dad5c811.r2.cloudflarestorage.com"
    backendConfig {
        // R2 access key / secret key (Bitwarden Secret Manager, referenced by ID
        // to match the existing hardware/run.sh convention used across this repo)
        accessKey = bws("eb5eb0e8-2a4a-4398-a756-b37000d87d64")
        secretKey = bws("c39086cc-e112-40eb-b19f-b37000d89090")
    }
}

subProjects {
    subProject("k8s1")
    subProject("k8s2")
    subProject("k8s4")
    subProject("k8s-worker3")
    subProject("k8s-worker5")
    subProject("alice")
}
