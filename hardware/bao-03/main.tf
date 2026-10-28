# bao-03(OpenBao の raft voter 3 台目。host-hye1、143.203.220.195、Debian 13、2 vCPU / 1.9GB。bao-01 は K8s 上の StatefulSet、bao-02 は ServerCheap)、kigawa-net/infra#327 Phase 1、docs/openbao-implementation-design.md §2)。
# 段階的な適用: enabled = true だけなら、WireGuard と journald-limit だけを適用する(OpenBao は入れない)。
# 先に WireGuard を適用して公開鍵を取り出し、ionos にピアを足してから、openbao_node_enabled = true にする。
# enabled = false のときは、どのリソースも作らず、Bitwarden にも触れない(plan は no-op)。
# 実機に適用する前に、host / wg_address / peers / bws の ID(cloudflare_api_token_bitwarden_id 含む)/ openbao_deb_sha256 を設定すること。
# TLS の証明書・秘密鍵は、ノード自身が certbot で発行する(Terraform は読まない)。

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

# Cloudflare の API トークン(certbot の DNS-01 用。kigawa.net の DNS 編集のみ、IP 制限つき)。
# TLS の秘密鍵は Terraform を通らない。トークンだけを bws から読む(SSH 鍵と同じく、state には入る)。
# ID が空のときは、Bitwarden に触れずに止める。
data "external" "cloudflare_api_token" {
  count = local.node_enabled ? 1 : 0

  program = ["bash", "-c", <<-EOT
    source "${path.module}/../../lib/bws-retry.sh"
    if [ -z "${var.cloudflare_api_token_bitwarden_id}" ]; then echo "cloudflare_api_token_bitwarden_id が未設定" >&2; exit 1; fi
    value=$(bws_get_value "${var.cloudflare_api_token_bitwarden_id}") || exit 1
    if [ -z "$value" ] || [ "$value" = "null" ]; then echo "cloudflare_api_token: bws secret is empty" >&2; exit 1; fi
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
      error_message = "enabled = true には wireguard_server_public_key(IONOS hub の公開鍵)の設定が必要。bao-03 は WireGuard 経由でしか raft に参加できない。"
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
      condition     = var.cloudflare_api_token_bitwarden_id != ""
      error_message = "openbao_node_enabled = true には cloudflare_api_token_bitwarden_id の設定が必要(certbot の DNS-01 に使う Cloudflare のトークン)。"
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
# 読んだ公開鍵は hardware/ionos の bao03_wireguard_public_key に設定する(それまで IONOS 側にピアは出ない)。
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

# OpenBao ノードの構築(バージョン・TLS は modules/openbao-node を参照)
# WireGuard の設定(wg0 の起動)の後に構築する。wg_address で listen するため、先に wg0 が必要。
# TLS の証明書は、ノードが certbot で発行する(fqdn の DNS-01 に、Cloudflare のトークンを使う)。
module "openbao_node" {
  source     = "../modules/openbao-node"
  count      = local.node_enabled ? 1 : 0
  depends_on = [module.wireguard, terraform_data.node_check]

  host            = var.host
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key[0].result.value
  sudo_password   = data.external.sudo_password[0].result.value

  node_id              = var.node_id
  wg_address           = var.openbao_address
  after_units          = var.openbao_after_units
  fqdn                 = var.fqdn
  peers                = var.peers
  openbao_version      = var.openbao_version
  openbao_deb_sha256   = var.openbao_deb_sha256
  cloudflare_api_token = data.external.cloudflare_api_token[0].result.value
  acme_email           = var.acme_email
  acme_staging         = var.acme_staging
  wipe_data_on_failure = var.wipe_data_on_failure
  memory_high          = var.openbao_memory_high
  memory_max           = var.openbao_memory_max
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

# 公開 IP の VPS の SSH と受信ファイアウォールを固める(kigawa-net/infra#337)。
# WireGuard の後に適用する(ufw が wg0 を参照するため)。
module "host_hardening" {
  source     = "../modules/host-hardening"
  count      = var.enabled ? 1 : 0
  depends_on = [module.wireguard]

  host            = var.host
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key[0].result.value
  sudo_password   = data.external.sudo_password[0].result.value

  # WireGuard のハブ(IONOS)。wireguard_server_endpoint(host:port)のホスト部分
  wireguard_hub_address  = split(":", var.wireguard_server_endpoint)[0]
  tcp_ports_on_wireguard = [8200, 8201]
  # EasyTier のオーバーレイ(tun0)でも通す。Raft を、ハブを通らない経路に切り替えられるようにする(docs/openbao-implementation-design.md「Raft の経路」)
  extra_interfaces = ["tun0"]
}

# EasyTier のネットワーク Secret(bws から読む。空なら止める)
data "external" "easytier_network_secret" {
  count = var.enabled && var.easytier_enabled ? 1 : 0

  program = ["bash", "-c", <<-EOT
    source "${path.module}/../../lib/bws-retry.sh"
    if [ -z "${var.easytier_network_secret_bitwarden_id}" ]; then echo "easytier_network_secret_bitwarden_id が未設定" >&2; exit 1; fi
    value=$(bws_get_value "${var.easytier_network_secret_bitwarden_id}") || exit 1
    if [ -z "$value" ] || [ "$value" = "null" ]; then echo "easytier_network_secret: bws secret is empty" >&2; exit 1; fi
    jq -n --arg value "$value" '{"value": $value}'
  EOT
  ]
}

# 公開ノードとして、他のノードからの接続(11010 の tcp/udp)を受ける。WireGuard・FRR・BGP には触れない。
module "easytier" {
  source     = "../modules/easytier"
  count      = var.enabled && var.easytier_enabled ? 1 : 0
  depends_on = [module.host_hardening]

  host            = var.host
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key[0].result.value
  sudo_password   = data.external.sudo_password[0].result.value

  easytier_version = var.easytier_version
  easytier_sha256  = var.easytier_sha256
  network_name     = var.easytier_network_name
  network_secret   = data.external.easytier_network_secret[0].result.value
  overlay_address  = var.easytier_overlay_address
  peers            = var.easytier_peers
  ufw_allow        = ["11010/tcp", "11010/udp"]
}
