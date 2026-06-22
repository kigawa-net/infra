# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Conventions

- 日本語で話す。
- GitHub の操作（issue・PR の作成・閲覧・コメント・レビューなど）はすべて `gh` コマンドで行う。
- 作業フロー: issue 作成 → ブランチ作成 → 実装 → PR 作成（`Closes #N` を body に記載）→ レビュー → マージ。
  - ブランチ名は `<type>/<short-description>` 形式（例: `feat/add-node`, `fix/dns-config`）。
  - PR はタイトル・本文・レビューコメントを日本語で作成する。コマンド名、ファイルパス、識別子、固有名詞は原文のまま記載してよい。
  - PR は必ずレビューを経てからマージする。直接 `main` にコミットしない。
  - issueのクローズはPRマージ時に自動で行う（手動closeしない）。

## Running Terraform

Each node is an independent Terraform root module. Use the shared `hardware/run.sh` — it fetches R2 credentials from Bitwarden and passes all arguments to `terraform`:

```bash
# Usage: ./hardware/run.sh <module> <terraform-args...>
# module: k8s1, k8s2, k8s4, k8s-worker5, alice, . (hardware/ 自体)

# Initialize (first time or after provider changes)
./hardware/run.sh k8s1 init

# Plan / apply / destroy
./hardware/run.sh k8s1 plan
./hardware/run.sh k8s1 apply
./hardware/run.sh k8s1 destroy
```

`BWS_ACCESS_TOKEN` must be set in the environment before running any of these.

## Repository Structure

```
hardware/
  run.sh              # 共通wrapper: R2クレデンシャル取得 + terraform実行
  main.tf             # original combined module (10.0.0.51)
  modules/
    k8s-control-plane/  # control-plane共通モジュール
  k8s1/               # control-plane node at 10.0.0.103 (クラスタ初期化ノード)
  k8s2/               # control-plane node at 10.0.0.120
  k8s4/               # control-plane node at 10.0.0.140
  k8s-worker5/        # worker node at 10.0.0.40
  alice/              # public gateway at 161.248.62.66
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

`hardware/run.sh` が唯一のエントリーポイント。モジュール名を第1引数に取る:

```bash
#!/usr/bin/env bash
set -ue
script_dir=$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)
module="${1:?Usage: $0 <module> <terraform-args...>}"
shift
export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
AWS_ACCESS_KEY_ID=$(bws secret get <uuid> | jq -r '.value')
AWS_SECRET_ACCESS_KEY=$(bws secret get <uuid> | jq -r '.value')
terraform -chdir="$script_dir/$module" "$@"
```

### Adding a new node

1. Create `hardware/<node-name>/` with `main.tf`, `variables.tf`, `versions.tf`, `outputs.tf`
2. Set the backend `key` to `hardware/<last-octet>/terraform.tfstate`
3. Copy the appropriate `main.tf` template (worker or control-plane) and update `variables.tf` defaults for the new host IP
4. Run `./hardware/run.sh <node-name> init` then `apply`
