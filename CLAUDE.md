# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.
日本語で話す。

## Running Terraform

Each node is an independent Terraform root module. Use the `run.sh` wrapper in the node's directory — it fetches R2 credentials from Bitwarden and passes all arguments to `terraform`:

```bash
# Initialize (first time or after provider changes)
./hardware/k8s2/run.sh init

# Plan / apply / destroy
./hardware/k8s2/run.sh plan
./hardware/k8s2/run.sh apply
./hardware/k8s2/run.sh destroy
```

`BWS_ACCESS_TOKEN` must be set in the environment before running any of these.

## Repository Structure

```
hardware/
  run.sh              # wrapper: injects R2 creds via bws, runs terraform
  main.tf             # original combined module (worker at 192.168.1.50)
  k8s2/               # control-plane node at 192.168.1.20
  k8s-worker5/        # worker node at 192.168.1.50
application/          # empty (future use)
platform/             # empty (future use)
```

Each subdirectory under `hardware/` is a self-contained Terraform root module with its own backend state key in Cloudflare R2 (`hardware/<last-octet>/terraform.tfstate`).

## Architecture

### Secrets

All secrets come from Bitwarden Secrets Manager via the `bws` CLI. Terraform accesses them through `data "external"` blocks that call `bws secret get <uuid> | jq -r '.value'`. The R2 backend credentials are injected by `run.sh` (not in `.tf` files).

### Provisioning Pattern

Each module uses a single `null_resource` with SSH provisioners:

1. `data "external" "ssh_key"` — fetches the SSH private key from bws
2. `data "external" "sudo_password"` — fetches the sudo password from bws
3. `data "external" "join_info"` — SSHes to the existing control plane to generate a kubeadm join token (and certificate key for control-plane joins); for control-plane modules, also removes dead etcd members before generating the token
4. `provisioner "file"` — uploads a bash setup script to `/tmp/k8s-setup.sh`
5. `provisioner "remote-exec"` — runs the script via `echo '<password>' | sudo -S bash /tmp/k8s-setup.sh`

The setup script uses `trap cleanup EXIT` to roll back (purge packages, `kubeadm reset -f`, delete config files) if any step fails.

### Control-plane vs Worker join

- **Worker** (`hardware/`, `k8s-worker5/`): `data "external" "join_info"` SSHes to control plane and runs `sudo kubeadm token create --print-join-command`. Join uses `--token` and `--discovery-token-ca-cert-hash`.
- **Control-plane** (`k8s2/`): `join_info` pipes the sudo password via SSH (`echo '$sudo_pass' | sudo -S bash -c '...'`) to run two commands: `kubeadm init phase upload-certs --upload-certs` (gets `certificate_key`) and `kubeadm token create --print-join-command`. Join additionally uses `--control-plane --certificate-key`.

### Heredoc quoting rules

Inside Terraform `<<-EOT` heredocs used for `data "external"` programs:
- `${var.foo}` is Terraform interpolation — expands at plan time
- `\$var` or `$(...)` is bash — escapes the Terraform interpolator

Inside `<<-SCRIPT` heredocs used for provisioner `file` content:
- `${var.foo}` still interpolates as Terraform
- Remote bash variables must use `\${var}` to avoid Terraform treating them as interpolations

The `sudo -S bash -c '...'` inner commands use single quotes on the SSH command line, so dollar signs inside must be escaped as `\$` and inner double-quotes as `\"`.

### `run.sh` pattern

All `run.sh` files follow this structure:

```bash
#!/usr/bin/env bash
set -ue
script_dir=$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)
export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
AWS_ACCESS_KEY_ID=$(bws secret get <uuid> | jq -r '.value')
AWS_SECRET_ACCESS_KEY=$(bws secret get <uuid> | jq -r '.value')
terraform -chdir="$script_dir" "$@"
```

### Adding a new node

1. Create `hardware/<node-name>/` with `main.tf`, `variables.tf`, `versions.tf`, `outputs.tf`, `run.sh`
2. Set the backend `key` to `hardware/<last-octet>/terraform.tfstate`
3. Copy the appropriate `main.tf` template (worker or control-plane) and update `variables.tf` defaults for the new host IP
4. Run `./hardware/<node-name>/run.sh init` then `apply`
