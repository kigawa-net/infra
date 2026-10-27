# bao-02(OpenBao の raft voter 2 台目(IONOS の別 VPS。bao-01 は K8s 上の StatefulSet)、kigawa-net/infra#327 Phase 1、docs/openbao-implementation-design.md §2)。
# 段階的な適用: enabled = true だけなら、WireGuard と journald-limit だけを適用する(OpenBao は入れない)。
# 先に WireGuard を適用して公開鍵を取り出し、ionos にピアを足してから、openbao_node_enabled = true にする。
# enabled = false(既定)のときは、どのリソースも作らず、Bitwarden にも触れない(plan は no-op)。
# 実機に適用する前に、host / wg_address / peers / bws の ID / openbao_deb_sha256 を設定すること。

locals {
  node_enabled = var.enabled && var.openbao_node_enabled
}

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
  count = local.node_enabled ? 1 : 0

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
  count = local.node_enabled ? 1 : 0

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
  count = local.node_enabled ? 1 : 0

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
      condition     = var.host != "" && var.wg_address != ""
      error_message = "enabled = true には host / wg_address の設定が必要。"
    }
    precondition {
      condition     = var.wireguard_server_public_key != ""
      error_message = "enabled = true には wireguard_server_public_key(IONOS hub の公開鍵)の設定が必要。bao-02 は WireGuard 経由でしか raft に参加できない。"
    }
  }
}

# OpenBao ノードを入れる前提(openbao_node_enabled = true のとき)。
resource "terraform_data" "node_check" {
  count = local.node_enabled ? 1 : 0

  lifecycle {
    precondition {
      condition     = var.openbao_deb_sha256 != ""
      error_message = "openbao_node_enabled = true には openbao_deb_sha256 の設定が必要。"
    }
    precondition {
      condition     = var.tls_cert_bitwarden_id != "" && var.tls_key_bitwarden_id != "" && var.tls_ca_bitwarden_id != ""
      error_message = "openbao_node_enabled = true には tls_*_bitwarden_id の設定が必要。"
    }
    precondition {
      condition     = length(var.peers) > 0
      error_message = "openbao_node_enabled = true には peers(他のノード)の設定が必要。Raft の join 先が無いと、2 台目以降を参加させられない。"
    }
  }
}

# WireGuard(IONOS hub への spoke)。他のスポークと同じく modules/wireguard を使う。
# 秘密鍵はホスト上で生成される(/etc/wireguard/privatekey。Terraform の state には入らない)。
# 公開鍵は /etc/wireguard/publickey に置かれ、apply の出力(=== Public key ===)にも出る。
# 読んだ公開鍵は hardware/ionos の bao02_wireguard_public_key に設定する(それまで IONOS 側にピアは出ない)。
module "wireguard" {
  source = "../modules/wireguard"
  count  = var.enabled ? 1 : 0

  host            = var.host
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key[0].result.value
  sudo_password   = data.external.sudo_password[0].result.value

  wireguard_address  = "${var.wg_address}/32"
  server_public_key  = var.wireguard_server_public_key
  server_endpoint    = var.wireguard_server_endpoint
  server_allowed_ips = var.wireguard_server_allowed_ips
}

# OpenBao ノードの構築(ホスト名・バージョン・TLS は modules/openbao-node を参照)
# WireGuard の設定(wg0 の起動)の後に構築する。wg_address で listen するため、先に wg0 が必要。
module "openbao_node" {
  source     = "../modules/openbao-node"
  count      = local.node_enabled ? 1 : 0
  depends_on = [module.wireguard, terraform_data.node_check]

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
