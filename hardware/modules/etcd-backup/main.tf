terraform {
  required_providers {
    null = {
      source = "hashicorp/null"
    }
  }
}

# etcd の定期スナップショットを、age で暗号化して R2 に置く (issue #189)。
# 取得・暗号化・アップロード・保持は files/etcd-backup.sh。ここは、ノードへの配置だけを行う。
# enabled=false(既定)では、何もしない。age の公開鍵と R2 の認証情報が揃ったときに、true にする。

locals {
  backup_script = file("${path.module}/files/etcd-backup.sh")

  # 認証情報と設定。root のみ読める(0600)。公開鍵だけを置き、復号用の秘密鍵は置かない。
  env_file = <<-ENV
    R2_ENDPOINT=${var.r2_endpoint}
    R2_BUCKET=${var.r2_bucket}
    R2_ACCESS_KEY_ID=${var.r2_access_key_id}
    R2_SECRET_ACCESS_KEY=${var.r2_secret_access_key}
    AGE_RECIPIENT=${var.age_recipient}
    NODE_NAME=${var.node_name}
    RETENTION_DAYS=${var.retention_days}
    MIN_KEEP=${var.min_keep}
    TEXTFILE_DIR=${var.textfile_dir}
    ENV

  service_unit = <<-UNIT
    [Unit]
    Description=etcd snapshot backup to R2 (issue #189)
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=oneshot
    ExecStart=/usr/local/bin/etcd-backup.sh
    # 失敗しても、次の timer で再実行される。長引いたときに、後続を詰まらせない
    TimeoutStartSec=1800
    Nice=10
    IOSchedulingClass=idle
    UNIT

  timer_unit = <<-UNIT
    [Unit]
    Description=etcd snapshot backup timer (issue #189)

    [Timer]
    # 有効化(timer の開始)の 2 分後に初回を動かす。OnBootSec だけだと、起動から時間が経ったあとの
    # 有効化で、初回がいつになるか不確か。再起動後は、起動の 10 分後に動く。
    OnActiveSec=2min
    OnBootSec=10min
    OnUnitActiveSec=${var.interval_minutes}min
    RandomizedDelaySec=60
    AccuracySec=10s

    [Install]
    WantedBy=timers.target
    UNIT

  # R2 の認証情報を含む環境ファイルを、/tmp(誰でも読める)に置かないための、SSH ユーザー専用(0700)の作業ディレクトリ
  stage = "/home/${var.ssh_user}/.etcd-backup-staging"

  setup_script = <<-SCRIPT
    #!/bin/bash
    set -euo pipefail
    cleanup() { rm -f ${local.stage}/etcd-backup.sh ${local.stage}/etcd-backup.service ${local.stage}/etcd-backup.timer ${local.stage}/etcd-backup.env ${local.stage}/etcd-backup-setup.sh; }
    trap cleanup EXIT

    # age の導入(dpkg のロックを待ち、再試行する。keepalived / bgp-frr と同じ流儀)
    if ! command -v age >/dev/null 2>&1; then
      for a in $(seq 1 20); do
        for i in $(seq 1 60); do
          fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1 || break
          sleep 5
        done
        if DEBIAN_FRONTEND=noninteractive apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y age; then break; fi
        sleep 5
      done
      command -v age >/dev/null 2>&1 || { echo 'age could not be installed' >&2; exit 1; }
    fi

    install -d -m 0700 /etc/etcd-backup
    install -m 0600 ${local.stage}/etcd-backup.env /etc/etcd-backup/env
    install -d -m 0755 "${var.textfile_dir}"
    install -m 0755 ${local.stage}/etcd-backup.sh /usr/local/bin/etcd-backup.sh
    install -m 0644 ${local.stage}/etcd-backup.service /etc/systemd/system/etcd-backup.service
    install -m 0644 ${local.stage}/etcd-backup.timer /etc/systemd/system/etcd-backup.timer
    systemctl daemon-reload
    systemctl enable etcd-backup.timer
    systemctl restart etcd-backup.timer
    SCRIPT

  disable_script = <<-SCRIPT
    #!/bin/bash
    set -u
    systemctl disable --now etcd-backup.timer 2>/dev/null || true
    systemctl stop etcd-backup.service 2>/dev/null || true
    rm -f /etc/etcd-backup/env ${local.stage}/etcd-backup-setup.sh
    SCRIPT
}

resource "null_resource" "etcd_backup" {
  triggers = {
    host         = var.host
    enabled      = tostring(var.enabled)
    script_sha   = sha256(local.backup_script)
    service_sha  = sha256(local.service_unit)
    timer_sha    = sha256(local.timer_unit)
    env_sha      = sha256(local.env_file)
    setup_sha    = sha256(local.setup_script)
    disable_sha  = sha256(local.disable_script)
    textfile_dir = var.textfile_dir
  }

  lifecycle {
    precondition {
      condition = !var.enabled || (
        startswith(var.age_recipient, "age1") &&
        var.r2_access_key_id != "" &&
        var.r2_secret_access_key != ""
      )
      error_message = "enabled=true には、age の公開鍵(age1...)と、R2 の認証情報(access key id / secret)が必要。"
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
    content     = var.enabled ? local.backup_script : "#!/bin/true\n"
    destination = "${local.stage}/etcd-backup.sh"
  }

  provisioner "file" {
    content     = local.service_unit
    destination = "${local.stage}/etcd-backup.service"
  }

  provisioner "file" {
    content     = local.timer_unit
    destination = "${local.stage}/etcd-backup.timer"
  }

  provisioner "file" {
    content     = var.enabled ? local.env_file : ""
    destination = "${local.stage}/etcd-backup.env"
  }

  provisioner "file" {
    content     = var.enabled ? local.setup_script : local.disable_script
    destination = "${local.stage}/etcd-backup-setup.sh"
  }

  # sudo のパスワードは、remote-exec のスクリプト(/tmp に 0777 で置かれ、誰でも読める)に埋めず、
  # 0700 の作業ディレクトリのファイルから、標準入力で渡す。
  provisioner "file" {
    content     = "${var.sudo_password}\n"
    destination = "${local.stage}/.sudo"
  }

  # 失敗(sudo、パッケージの導入、timer の有効化)を、後始末の成功で、隠さない。
  # 後始末(作業ディレクトリの削除)は、成否に関わらず行い、終了コードは、セットアップのものを返す。
  provisioner "remote-exec" {
    inline = [
      "sudo -S -p '' bash ${local.stage}/etcd-backup-setup.sh < ${local.stage}/.sudo; rc=$?; rm -rf ${local.stage}; exit $rc",
    ]
  }
}
