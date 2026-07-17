// Minimal project-level config for platform/ itself. platform/ has no root
// Terraform module of its own (only platform/mcp-growi/ does, declared as a
// subProject in kinfra-parent.kts), but kinfra requires a kinfra.kts to exist
// at the repoPath root for any command (including `sub list`/`sub plan`) to
// run at all.
projectId = "platform"

terraform {
    workingDirectory = "."
}
