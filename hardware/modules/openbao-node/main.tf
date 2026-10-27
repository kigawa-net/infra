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
#   - TLS の証明書・秘密鍵・CA は、この module の外で発行し、変数で渡す(この module は発行しない)。
#   - ホストの FW(8200 / 8201 / 22 の制限)は、この module では扱わない。README を参照。
#   - 証明書の変更は SIGHUP で再読込する。設定・unit の変更は再起動する。

locals {
  deb_url = "https://github.com/openbao/openbao/releases/download/v${var.openbao_version}/openbao_${var.openbao_version}_linux_amd64.deb"

  # 自分自身は retry_join に入れない(raft の join 先は、他のノードだけ)
  retry_peers = [for p in var.peers : p if p.node_id != var.node_id]

  config = templatefile("${path.module}/files/openbao.hcl.tpl", {
    node_id    = var.node_id
    wg_address = var.wg_address
    peers      = local.retry_peers
  })

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

  # 証明書・鍵の変更は、SIGHUP で再読込する(設定の変更のように再起動はしない)。ハッシュだけ trigger に入れる
  tls_hash = sha256(join("", [var.tls_cert_pem, var.tls_key_pem, var.tls_ca_pem]))

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
    tls_sha              = local.tls_hash
    setup_sha            = sha256(local.setup_script)
    wipe_data_on_failure = tostring(var.wipe_data_on_failure)
  }

  lifecycle {
    precondition {
      condition     = can(regex("^[0-9a-f]{64}$", var.openbao_deb_sha256))
      error_message = "openbao_deb_sha256 に、公式の .deb の SHA256(64 桁の 16 進)を設定すること。"
    }
    precondition {
      condition     = var.tls_cert_pem != "" && var.tls_key_pem != "" && var.tls_ca_pem != ""
      error_message = "TLS の証明書・秘密鍵・CA が空。外部の CA で発行したものを、bws から渡すこと(この module は発行しない)。"
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
    content     = var.tls_cert_pem
    destination = "${local.stage}/tls.crt"
  }

  provisioner "file" {
    content     = var.tls_key_pem
    destination = "${local.stage}/tls.key"
  }

  provisioner "file" {
    content     = var.tls_ca_pem
    destination = "${local.stage}/ca.crt"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S env OPENBAO_VERSION='${var.openbao_version}' DEB_URL='${local.deb_url}' DEB_SHA256='${var.openbao_deb_sha256}' STAGE_DIR='${local.stage}' WIPE_DATA_ON_FAILURE='${var.wipe_data_on_failure ? 1 : 0}' bash ${local.stage}/openbao-node-setup.sh",
    ]
  }
}
