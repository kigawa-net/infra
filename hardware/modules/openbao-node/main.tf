terraform {
  required_providers {
    null = {
      source = "hashicorp/null"
    }
  }
}

# OpenBao のノード(raft の voter)を構築する(issue kigawa-net/infra#327、docs/openbao-implementation-design.md §2)。
# 構成の本体は files/openbao-node-setup.sh(冪等)。設定は files/openbao.hcl.tpl から描画する。
#
# 範囲と前提:
#   - 初期化(bao operator init)と unseal は、この module の対象外(手動、別手順)。鍵・root token はどこにも保存しない。
#   - TLS の証明書・秘密鍵は、この module を通らない。ノード自身が certbot で Let's Encrypt から発行・更新する
#     (DNS-01 / Cloudflare)。Terraform が渡すのは Cloudflare の API トークンだけ(README を参照)。
#   - ホストの FW(8200 / 8201 / 22 の制限)は、この module では扱わない。README を参照。
#   - 証明書の更新は deploy hook が SIGHUP で再読込する。設定・unit の変更は再起動する。

locals {
  deb_url = "https://github.com/openbao/openbao/releases/download/v${var.openbao_version}/openbao_${var.openbao_version}_linux_amd64.deb"

  # 自分自身は retry_join に入れない(raft の join 先は、他のノードだけ。fqdn で判定する)
  retry_peers = [for p in var.peers : p if p.fqdn != var.fqdn]

  config = templatefile("${path.module}/files/openbao.hcl.tpl", {
    fqdn       = var.fqdn
    node_id    = var.node_id
    wg_address = var.wg_address
    peers      = local.retry_peers
  })

  # /etc/hosts の管理ブロック(自分と全ピアの fqdn を、WireGuard の IP に向ける)
  hosts_lines   = distinct(concat([for p in var.peers : "${p.address} ${p.fqdn}"], ["${var.wg_address} ${var.fqdn}"]))
  hosts_entries = join("", [for l in local.hosts_lines : "${l}\n"])

  # Cloudflare の資格情報(certbot の dns-cloudflare 用の ini)。内容は STAGE_DIR 経由で渡し、コマンドラインには載せない
  cloudflare_ini = "dns_cloudflare_api_token = ${var.cloudflare_api_token}\n"

  service_unit = <<-UNIT
    [Unit]
    Description=OpenBao (raft, ${var.node_id})
    Documentation=https://openbao.org/docs/
    After=network-online.target wg-quick@wg0.service
    Wants=network-online.target wg-quick@wg0.service

    [Service]
    Type=simple
    User=openbao
    Group=openbao
    ExecStart=/usr/local/bin/bao server -config=/etc/openbao/openbao.hcl
    ExecReload=/bin/kill -HUP $MAINPID
    KillSignal=SIGTERM
    Restart=on-failure
    RestartSec=5
    TimeoutStopSec=60

    # 権限の縮小(ホストを侵害されたときの被害を抑える)
    NoNewPrivileges=yes
    ProtectSystem=strict
    ProtectHome=yes
    PrivateTmp=yes
    PrivateDevices=yes
    ProtectKernelTunables=yes
    ProtectKernelModules=yes
    ProtectKernelLogs=yes
    ProtectControlGroups=yes
    ProtectClock=yes
    ProtectHostname=yes
    RestrictSUIDSGID=yes
    RestrictRealtime=yes
    RestrictNamespaces=yes
    LockPersonality=yes
    MemoryDenyWriteExecute=yes
    RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
    SystemCallArchitectures=native
    SystemCallFilter=@system-service
    UMask=0077

    # core dump に秘密が出ないよう無効化。mlock(メモリを swap に出さない)のため IPC_LOCK だけを持たせる
    LimitCORE=0
    LimitNOFILE=65536
    LimitMEMLOCK=infinity
    CapabilityBoundingSet=CAP_IPC_LOCK
    AmbientCapabilities=CAP_IPC_LOCK

    # ProtectSystem=strict のもとで書けるのは /var/lib/openbao だけ(StateDirectory が例外として開ける)
    StateDirectory=openbao
    StateDirectoryMode=0700

    [Install]
    WantedBy=multi-user.target
    UNIT

  stage = "/home/${var.ssh_user}/.openbao-node-stage"

  # remote-exec の inline は、シバンなしで転送され、dash で動いてしまうため、シバン付きのスクリプトを bash で実行する
  # (node-exporter / journald-limit モジュールと同じ理由)。
  setup_script = file("${path.module}/files/openbao-node-setup.sh")
}

resource "null_resource" "openbao_node" {
  triggers = {
    host                 = var.host
    node_id              = var.node_id
    openbao_version      = var.openbao_version
    deb_sha256           = var.openbao_deb_sha256
    config_sha           = sha256(local.config)
    unit_sha             = sha256(local.service_unit)
    setup_sha            = sha256(local.setup_script)
    wipe_data_on_failure = tostring(var.wipe_data_on_failure)
    fqdn                 = var.fqdn
    acme_email           = var.acme_email
    acme_staging         = tostring(var.acme_staging)
    # トークンの変更で、資格情報の ini を置き直す。トークン本体ではなくハッシュだけを trigger に入れる
    cloudflare_ini_sha = sha256(local.cloudflare_ini)
    hosts_sha          = sha256(local.hosts_entries)
  }

  lifecycle {
    precondition {
      condition     = can(regex("^[0-9a-f]{64}$", var.openbao_deb_sha256))
      error_message = "openbao_deb_sha256 に、公式の .deb の SHA256(64 桁の 16 進)を設定すること。"
    }
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 ${local.stage}"]
  }

  provisioner "file" {
    content     = local.setup_script
    destination = "${local.stage}/openbao-node-setup.sh"
  }

  provisioner "file" {
    content     = local.config
    destination = "${local.stage}/openbao.hcl"
  }

  provisioner "file" {
    content     = local.service_unit
    destination = "${local.stage}/openbao.service"
  }

  provisioner "file" {
    content     = local.cloudflare_ini
    destination = "${local.stage}/cloudflare.ini"
  }

  provisioner "file" {
    content     = local.hosts_entries
    destination = "${local.stage}/hosts.entries"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S env OPENBAO_VERSION='${var.openbao_version}' DEB_URL='${local.deb_url}' DEB_SHA256='${var.openbao_deb_sha256}' STAGE_DIR='${local.stage}' WIPE_DATA_ON_FAILURE='${var.wipe_data_on_failure ? 1 : 0}' FQDN='${var.fqdn}' ACME_EMAIL='${var.acme_email}' ACME_STAGING='${var.acme_staging ? 1 : 0}' bash ${local.stage}/openbao-node-setup.sh",
    ]
  }
}
