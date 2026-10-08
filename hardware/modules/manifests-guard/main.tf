terraform {
  required_providers {
    null = {
      source = "hashicorp/null"
    }
  }
}

# /etc/kubernetes/manifests/ の余分なファイル(`.bak` など)と、pod 名の重複を検知して、メトリクスに書く (issue #263)。
# 検知するだけで、ファイルは変更・削除しない。検知とアラートの内容は files/manifests-guard.sh と、
# kigawa01/k8s-system の prometheus/manifests-guard-rules.yml。

locals {
  guard_script = file("${path.module}/files/manifests-guard.sh")

  service_unit = <<-UNIT
    [Unit]
    Description=Detect stray files and duplicate pods in /etc/kubernetes/manifests (issue #263)

    [Service]
    Type=oneshot
    Environment=TEXTFILE_DIR=${var.textfile_dir}
    ExecStart=/usr/local/bin/manifests-guard.sh
    Nice=10
    UNIT

  timer_unit = <<-UNIT
    [Unit]
    Description=Check /etc/kubernetes/manifests periodically (issue #263)

    [Timer]
    OnActiveSec=1min
    OnBootSec=3min
    OnUnitActiveSec=${var.interval_minutes}min
    AccuracySec=10s

    [Install]
    WantedBy=timers.target
    UNIT

  # sudo のパスワードを、remote-exec のスクリプト(/tmp に 0777 で置かれ、誰でも読める)に埋めない。
  # SSH ユーザー専用(0700)の作業ディレクトリのファイルから、標準入力で渡す(etcd-backup と同じ)。
  stage = "/home/${var.ssh_user}/.manifests-guard-staging"

  setup_script = <<-SCRIPT
    #!/bin/bash
    set -euo pipefail
    install -d -m 0755 "${var.textfile_dir}"
    install -m 0755 ${local.stage}/manifests-guard.sh /usr/local/bin/manifests-guard.sh
    install -m 0644 ${local.stage}/manifests-guard.service /etc/systemd/system/manifests-guard.service
    install -m 0644 ${local.stage}/manifests-guard.timer /etc/systemd/system/manifests-guard.timer
    systemctl daemon-reload
    systemctl enable manifests-guard.timer
    systemctl restart manifests-guard.timer
    SCRIPT

  disable_script = <<-SCRIPT
    #!/bin/bash
    set -u
    systemctl disable --now manifests-guard.timer 2>/dev/null || true
    systemctl stop manifests-guard.service 2>/dev/null || true
    rm -f "${var.textfile_dir}/k8s_manifests_guard.prom"
    SCRIPT
}

resource "null_resource" "manifests_guard" {
  triggers = {
    host         = var.host
    enabled      = tostring(var.enabled)
    script_sha   = sha256(local.guard_script)
    service_sha  = sha256(local.service_unit)
    timer_sha    = sha256(local.timer_unit)
    setup_sha    = sha256(local.setup_script)
    disable_sha  = sha256(local.disable_script)
    textfile_dir = var.textfile_dir
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
    content     = local.guard_script
    destination = "${local.stage}/manifests-guard.sh"
  }

  provisioner "file" {
    content     = local.service_unit
    destination = "${local.stage}/manifests-guard.service"
  }

  provisioner "file" {
    content     = local.timer_unit
    destination = "${local.stage}/manifests-guard.timer"
  }

  provisioner "file" {
    content     = var.enabled ? local.setup_script : local.disable_script
    destination = "${local.stage}/setup.sh"
  }

  provisioner "file" {
    content     = "${var.sudo_password}\n"
    destination = "${local.stage}/.sudo"
  }

  # 失敗を、後始末の成功で隠さない。後始末(作業ディレクトリの削除)は、成否に関わらず行い、
  # 終了コードは、セットアップのものを返す。
  provisioner "remote-exec" {
    inline = [
      "sudo -S -p '' bash ${local.stage}/setup.sh < ${local.stage}/.sudo; rc=$?; rm -rf ${local.stage}; exit $rc",
    ]
  }
}
