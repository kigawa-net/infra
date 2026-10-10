terraform {
  required_providers {
    null = {
      source = "hashicorp/null"
    }
  }
}

# Karmada の外部 etcd のメンバー(IONOS = etcd #3)を、IaC で構成し、learner として参加させる(kigawa-net/kigawa-net-k8s#272)。
# 構成の本体は files/karmada-etcd-member.sh。冪等で、参加済みなら、何もしない(設定が変わったときだけ、再起動する)。
#
# 前提と範囲:
#   - 証明書(/etc/etcd/pki/{ca.crt,tls.crt,tls.key})は、この IaC の外で用意する(秘密鍵を Terraform の state に入れないため)。
#   - 参加は learner まで。promote は、しない。voter が 1 つのクラスターに、2 つ目の voter を足すと、quorum が 2 になり、
#     どちらかが止まるだけで書き込みが止まる。3 つ目が追いついてから、続けて promote する(手動、別の判断)。
#   - 参加の操作は、IONOS 自身から、既存のメンバーに対して行う(IONOS の証明書は、client 認証にも使える)。

locals {
  member_script = file("${path.module}/files/karmada-etcd-member.sh")

  peer_url = "https://${var.advertise_address}:2380"

  service_unit = <<-UNIT
    [Unit]
    Description=Karmada external etcd (member ${var.member_name})
    Documentation=https://etcd.io/docs/
    After=network-online.target wg-quick@wg0.service
    Wants=network-online.target wg-quick@wg0.service

    [Service]
    Type=notify
    User=etcd
    Group=etcd
    EnvironmentFile=/etc/etcd/etcd.env
    ExecStart=/usr/local/bin/etcd
    Restart=on-failure
    RestartSec=5
    LimitNOFILE=65536
    # IONOS は、メモリが 1.8GB の VM で、WireGuard / FRR / HAProxy も載っている。
    # etcd が肥大化しても、ほかのサービスを巻き込まないよう、cgroup で上限を設ける。
    MemoryHigh=${var.memory_high}
    MemoryMax=${var.memory_max}
    OOMScoreAdjust=300

    [Install]
    WantedBy=multi-user.target
    UNIT

  # ETCD_INITIAL_CLUSTER は、参加時に、スクリプトが追記する(`member add` の出力の値)。ここには書かない。
  etcd_env = <<-ENV
    # Karmada の external etcd #3(${var.member_name})。Terraform(hardware/modules/karmada-etcd-member)が管理する。手で編集しない。
    # ETCD_PEER_SKIP_CLIENT_SAN_VERIFICATION は暫定(kigawa-net-k8s#272 の案 A)。CA の署名の検証は残る。タイマーは全メンバーで同一(#269)。
    ETCD_NAME=${var.member_name}
    ETCD_DATA_DIR=/var/lib/karmada-etcd
    # WireGuard のアドレスだけで待ち受ける(公開 IP では、待ち受けない)
    ETCD_LISTEN_CLIENT_URLS=https://${var.advertise_address}:2379,https://127.0.0.1:2379
    ETCD_ADVERTISE_CLIENT_URLS=https://${var.advertise_address}:2379
    ETCD_LISTEN_PEER_URLS=${local.peer_url}
    ETCD_INITIAL_ADVERTISE_PEER_URLS=${local.peer_url}
    ETCD_INITIAL_CLUSTER_TOKEN=${var.initial_cluster_token}
    ETCD_INITIAL_CLUSTER_STATE=existing
    ETCD_CLIENT_CERT_AUTH=true
    ETCD_TRUSTED_CA_FILE=/etc/etcd/pki/ca.crt
    ETCD_CERT_FILE=/etc/etcd/pki/tls.crt
    ETCD_KEY_FILE=/etc/etcd/pki/tls.key
    ETCD_PEER_CLIENT_CERT_AUTH=true
    ETCD_PEER_TRUSTED_CA_FILE=/etc/etcd/pki/ca.crt
    ETCD_PEER_CERT_FILE=/etc/etcd/pki/tls.crt
    ETCD_PEER_KEY_FILE=/etc/etcd/pki/tls.key
    ETCD_PEER_SKIP_CLIENT_SAN_VERIFICATION=${var.peer_skip_client_san_verification}
    ETCD_HEARTBEAT_INTERVAL=${var.heartbeat_interval_ms}
    ETCD_ELECTION_TIMEOUT=${var.election_timeout_ms}
    ETCD_QUOTA_BACKEND_BYTES=${var.quota_backend_bytes}
    ETCD_LISTEN_METRICS_URLS=http://127.0.0.1:2381
    ETCD_LOGGER=zap
    ENV

  stage = "/root/.karmada-etcd-member-staging"
}

resource "null_resource" "karmada_etcd_member" {
  triggers = {
    host                              = var.host
    member_name                       = var.member_name
    advertise_address                 = var.advertise_address
    seed_endpoints                    = var.seed_endpoints
    etcd_version                      = var.etcd_version
    etcd_tarball_sha256               = var.etcd_tarball_sha256
    script_sha                        = sha256(local.member_script)
    unit_sha                          = sha256(local.service_unit)
    env_sha                           = sha256(local.etcd_env)
    peer_skip_client_san_verification = tostring(var.peer_skip_client_san_verification)
    join                              = tostring(var.join)
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
    content     = local.member_script
    destination = "${local.stage}/karmada-etcd-member.sh"
  }

  provisioner "file" {
    content     = local.service_unit
    destination = "${local.stage}/karmada-etcd.service"
  }

  provisioner "file" {
    content     = local.etcd_env
    destination = "${local.stage}/etcd.env"
  }

  provisioner "remote-exec" {
    inline = [
      "JOIN='${var.join ? 1 : 0}' STAGE_DIR='${local.stage}' MEMBER_NAME='${var.member_name}' PEER_URL='${local.peer_url}' SEED_ENDPOINTS='${var.seed_endpoints}' ETCD_VERSION='${var.etcd_version}' TARBALL_SHA256='${var.etcd_tarball_sha256}' CERT_IP='${var.advertise_address}' bash ${local.stage}/karmada-etcd-member.sh",
    ]
  }
}
