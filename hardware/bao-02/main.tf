# bao-02(OpenBao の raft voter 2 台目(IONOS の別 VPS。bao-01 は K8s 上の StatefulSet)、kigawa-net/infra#327 Phase 1、docs/openbao-implementation-design.md §2)。
# enabled = false(既定)のときは、どのリソースも作らず、Bitwarden にも触れない(plan は no-op)。
# 実機に適用する前に、host / wg_address / peers / bws の ID / openbao_deb_sha256 を設定すること。

data "external" "ssh_key" {
  count = var.enabled ? 1 : 0

  program = ["bash", "-c", <<-EOT
    source "${path.module}/../../lib/bws-retry.sh"
    value=$(bws_get_value "${var.ssh_key_bitwarden_id}") || exit 1
    # bwsが503等で空/nullを返すと、空の値のまま後続のSSH/sudoに進んでしまう
    # (2026-10-03のionos障害と同じ構造)。空ならエラーにしてplan/applyを止める。
    if [ -z "$value" ] || [ "$value" = "null" ]; then
      echo "ssh_key: bws secret is empty" >&2
      exit 1
    fi
    jq -n --arg value "$value" '{"value": $value}'
  EOT
  ]
}

data "external" "sudo_password" {
  count = var.enabled ? 1 : 0

  program = ["bash", "-c", <<-EOT
    source "${path.module}/../../lib/bws-retry.sh"
    value=$(bws_get_value "${var.sudo_password_bitwarden_id}") || exit 1
    if [ -z "$value" ] || [ "$value" = "null" ]; then
      echo "sudo_password: bws secret is empty" >&2
      exit 1
    fi
    jq -n --arg value "$value" '{"value": $value}'
  EOT
  ]
}

# TLS の証明書・秘密鍵・CA は、外部の CA で発行したものを bws から読む(この IaC では発行しない)。
# ID が空のときは、Bitwarden に触れずに止める。
data "external" "tls_cert" {
  count = var.enabled ? 1 : 0

  program = ["bash", "-c", <<-EOT
    source "${path.module}/../../lib/bws-retry.sh"
    if [ -z "${var.tls_cert_bitwarden_id}" ]; then echo "tls_cert_bitwarden_id が未設定" >&2; exit 1; fi
    value=$(bws_get_value "${var.tls_cert_bitwarden_id}") || exit 1
    if [ -z "$value" ] || [ "$value" = "null" ]; then echo "tls_cert: bws secret is empty" >&2; exit 1; fi
    jq -n --arg value "$value" '{"value": $value}'
  EOT
  ]
}

data "external" "tls_key" {
  count = var.enabled ? 1 : 0

  program = ["bash", "-c", <<-EOT
    source "${path.module}/../../lib/bws-retry.sh"
    if [ -z "${var.tls_key_bitwarden_id}" ]; then echo "tls_key_bitwarden_id が未設定" >&2; exit 1; fi
    value=$(bws_get_value "${var.tls_key_bitwarden_id}") || exit 1
    if [ -z "$value" ] || [ "$value" = "null" ]; then echo "tls_key: bws secret is empty" >&2; exit 1; fi
    jq -n --arg value "$value" '{"value": $value}'
  EOT
  ]
}

data "external" "tls_ca" {
  count = var.enabled ? 1 : 0

  program = ["bash", "-c", <<-EOT
    source "${path.module}/../../lib/bws-retry.sh"
    if [ -z "${var.tls_ca_bitwarden_id}" ]; then echo "tls_ca_bitwarden_id が未設定" >&2; exit 1; fi
    value=$(bws_get_value "${var.tls_ca_bitwarden_id}") || exit 1
    if [ -z "$value" ] || [ "$value" = "null" ]; then echo "tls_ca: bws secret is empty" >&2; exit 1; fi
    jq -n --arg value "$value" '{"value": $value}'
  EOT
  ]
}

# 有効化の前提を、まとめて検査する(空のまま apply して、SSH の失敗や、壊れた設定を作らないため)。
resource "terraform_data" "enable_check" {
  count = var.enabled ? 1 : 0

  lifecycle {
    precondition {
      condition     = var.host != "" && var.wg_address != "" && var.openbao_deb_sha256 != ""
      error_message = "enabled = true には host / wg_address / openbao_deb_sha256 の設定が必要。"
    }
    precondition {
      condition     = var.tls_cert_bitwarden_id != "" && var.tls_key_bitwarden_id != "" && var.tls_ca_bitwarden_id != ""
      error_message = "enabled = true には tls_*_bitwarden_id の設定が必要。"
    }
    precondition {
      condition     = length(var.peers) > 0
      error_message = "enabled = true には peers(他のノード)の設定が必要。Raft の join 先が無いと、2 台目以降を参加させられない。"
    }
  }
}

# OpenBao ノードの構築(ホスト名・バージョン・TLS は modules/openbao-node を参照)
module "openbao_node" {
  source = "../modules/openbao-node"
  count  = var.enabled ? 1 : 0

  host            = var.host
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key[0].result.value
  sudo_password   = data.external.sudo_password[0].result.value

  node_id              = var.node_id
  wg_address           = var.wg_address
  peers                = var.peers
  openbao_version      = var.openbao_version
  openbao_deb_sha256   = var.openbao_deb_sha256
  tls_cert_pem         = data.external.tls_cert[0].result.value
  tls_key_pem          = data.external.tls_key[0].result.value
  tls_ca_pem           = data.external.tls_ca[0].result.value
  wipe_data_on_failure = var.wipe_data_on_failure
}

# journald の上限(他のノードと同じく、/run の ramdisk 圧迫対策、k8s-system#259)
module "journald_limit" {
  source = "../modules/journald-limit"
  count  = var.enabled ? 1 : 0

  host            = var.host
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key[0].result.value
  sudo_password   = data.external.sudo_password[0].result.value
}
