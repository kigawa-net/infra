terraform {
  required_providers {
    null = {
      source = "hashicorp/null"
    }
  }
}

# OpenBao の Raft スナップショットの定期取得(AppRole で読む)・age で暗号化・Backblaze B2(Object Lock)へ保存する (設計書 §7)。
# 取得・暗号化・アップロードは files/openbao-backup.sh。ここは、実行ホストへの配置だけを行う。
# enabled=false(既定)では、ホストに何も入れない。B2 の鍵・age の公開鍵・AppRole の資格情報が揃ってから true にする。
# 保持(削除)は、このモジュールも script も行わない。Object Lock と、B2 の Lifecycle ルールに任せる(README 参照)。

locals {
  backup_script = file("${path.module}/files/openbao-backup.sh")

  # B2 の S3 API のリージョンは、エンドポイントのホスト名に入っている(s3.<region>.backblazeb2.com)。明示されなければ、それを使う
  b2_endpoint_region  = can(regex("^https://s3\\.([a-z0-9-]+)\\.backblazeb2\\.com$", var.b2_endpoint)) ? regex("^https://s3\\.([a-z0-9-]+)\\.backblazeb2\\.com$", var.b2_endpoint)[0] : ""
  b2_region_effective = var.b2_region != "" ? var.b2_region : local.b2_endpoint_region

  # B2 の鍵と、AppRole の資格情報を含むため、root のみ読める(0600)。age の秘密鍵は、ここに置かない(公開鍵だけ)。
  # 値はダブルクォートで囲む。BAO_ENDPOINTS は空白区切りなので、クォートが無いと、シェルで分かれてしまう。
  env_file = <<-ENV
    B2_ENDPOINT="${var.b2_endpoint}"
    B2_REGION="${local.b2_region_effective}"
    B2_BUCKET="${var.b2_bucket}"
    B2_ACCESS_KEY_ID="${var.b2_access_key_id}"
    B2_SECRET_ACCESS_KEY="${var.b2_secret_access_key}"
    AGE_RECIPIENT="${var.age_recipient}"
    BAO_ENDPOINTS="${join(" ", var.bao_endpoints)}"
    OBJECT_LOCK_MODE="${var.object_lock_mode}"
    HEALTHCHECK_URL="${var.healthcheck_url}"
    TEXTFILE_DIR="${var.textfile_dir}"
    SNAPSHOT_BASE="${var.snapshot_base}"
    ENV

  approle_role_id_file   = "${var.approle_role_id}\n"
  approle_secret_id_file = "${var.approle_secret_id}\n"

  hosts_lines   = [for e in var.hosts_entries : "${e.address} ${e.fqdn}"]
  hosts_entries = join("", [for l in local.hosts_lines : "${l}\n"])

  service_unit = <<-UNIT
    [Unit]
    Description=OpenBao Raft snapshot backup to Backblaze B2 (Object Lock)
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=oneshot
    ExecStart=/usr/local/bin/openbao-backup.sh
    # 平文のスナップショットは、この RuntimeDirectory(/run、tmpfs)にだけ置く。停止のあとは、systemd が消す
    RuntimeDirectory=openbao-backup
    RuntimeDirectoryMode=0700
    # 失敗しても、次の timer で再実行される。長引いたときに、後続を詰まらせない
    TimeoutStartSec=1200
    # 実行ホスト(ionos-01)は、ゲートウェイと Karmada と共用。ほかを優先し、メモリは 300MB 以内、一度に 1 プロセス
    Nice=10
    IOSchedulingClass=idle
    MemoryMax=300M
    ProtectSystem=strict
    ProtectHome=true
    PrivateTmp=true
    NoNewPrivileges=true
    ReadWritePaths=${var.textfile_dir}
    UNIT

  timer_unit = <<-UNIT
    [Unit]
    Description=OpenBao Raft snapshot backup timer

    [Timer]
    # 有効化の数分後に初回を動かす。再起動後は、起動の 15 分後に動く
    OnActiveSec=3min
    OnBootSec=15min
    OnUnitActiveSec=${var.interval_minutes}min
    RandomizedDelaySec=120
    AccuracySec=30s

    [Install]
    WantedBy=timers.target
    UNIT

  # 作業ディレクトリ(SSH ユーザー専用、0700)。秘密を含むファイルを、/tmp(誰でも読める)に置かない
  stage = var.ssh_user == "root" ? "/root/.openbao-backup-staging" : "/home/${var.ssh_user}/.openbao-backup-staging"

  setup_script = <<-SCRIPT
    #!/bin/bash
    set -euo pipefail
    STAGE='${local.stage}'

    # age の導入(dpkg のロックを待ち、再試行する。etcd-backup と同じ流儀)
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

    install -d -m 0700 /etc/openbao-backup
    install -m 0600 "$STAGE/env" /etc/openbao-backup/env
    install -m 0600 "$STAGE/role_id" /etc/openbao-backup/role_id
    install -m 0600 "$STAGE/secret_id" /etc/openbao-backup/secret_id
    install -d -m 0755 "${var.textfile_dir}"
    install -m 0755 "$STAGE/openbao-backup.sh" /usr/local/bin/openbao-backup.sh
    install -m 0644 "$STAGE/openbao-backup.service" /etc/systemd/system/openbao-backup.service
    install -m 0644 "$STAGE/openbao-backup.timer" /etc/systemd/system/openbao-backup.timer

    # /etc/hosts の管理ブロック: bao-0N の FQDN を、EasyTier の overlay のアドレスに向ける(他の行は触らない)
    HOSTS_BEGIN='# BEGIN openbao-backup (managed by terraform)'
    HOSTS_END='# END openbao-backup (managed by terraform)'
    [ -f /etc/hosts ] || : > /etc/hosts
    awk -v b="$HOSTS_BEGIN" -v e="$HOSTS_END" '$0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip' /etc/hosts > "$STAGE/hosts.new"
    { echo "$HOSTS_BEGIN"; cat "$STAGE/hosts.entries"; echo "$HOSTS_END"; } >> "$STAGE/hosts.new"
    if ! cmp -s "$STAGE/hosts.new" /etc/hosts; then cat "$STAGE/hosts.new" > /etc/hosts; fi

    systemctl daemon-reload
    systemctl enable openbao-backup.timer
    systemctl restart openbao-backup.timer
    SCRIPT

  disable_script = <<-SCRIPT
    #!/bin/bash
    set -u
    STAGE='${local.stage}'
    systemctl disable --now openbao-backup.timer 2>/dev/null || true
    systemctl stop openbao-backup.service 2>/dev/null || true
    rm -f /etc/openbao-backup/env /etc/openbao-backup/role_id /etc/openbao-backup/secret_id
    if [ -f /etc/hosts ]; then
      awk '$0 == "# BEGIN openbao-backup (managed by terraform)" { skip = 1; next } $0 == "# END openbao-backup (managed by terraform)" { skip = 0; next } !skip' /etc/hosts > "$STAGE/hosts.new" && cat "$STAGE/hosts.new" > /etc/hosts
    fi
    SCRIPT
}

resource "null_resource" "openbao_backup" {
  triggers = {
    host          = var.host
    enabled       = tostring(var.enabled)
    script_sha    = sha256(local.backup_script)
    service_sha   = sha256(local.service_unit)
    timer_sha     = sha256(local.timer_unit)
    env_sha       = sha256(local.env_file)
    role_sha      = sha256(local.approle_role_id_file)
    secret_sha    = sha256(local.approle_secret_id_file)
    hosts_sha     = sha256(local.hosts_entries)
    setup_sha     = sha256(local.setup_script)
    disable_sha   = sha256(local.disable_script)
    textfile_dir  = var.textfile_dir
    snapshot_base = var.snapshot_base
  }

  lifecycle {
    precondition {
      condition     = !var.enabled || local.b2_endpoint_region != ""
      error_message = "enabled=true には、b2_endpoint(https://s3.<region>.backblazeb2.com)が必要。"
    }
    precondition {
      condition     = !var.enabled || local.b2_region_effective == local.b2_endpoint_region
      error_message = "b2_region(${local.b2_region_effective})が、b2_endpoint のリージョン(${local.b2_endpoint_region})と違う。"
    }
    precondition {
      condition = !var.enabled || (
        var.b2_bucket != "" &&
        can(regex("^[A-Za-z0-9+/=_-]{8,}$", var.b2_access_key_id)) &&
        can(regex("^[A-Za-z0-9+/=_-]{8,}$", var.b2_secret_access_key))
      )
      error_message = "enabled=true には、B2 のバケット名と、アプリケーションキー(ID と secret。英数字と +/=_- のみ)が必要。書き込み専用のキーを使う(README 参照)。"
    }
    precondition {
      condition     = !var.enabled || can(regex("^age1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{58}$", var.age_recipient))
      error_message = "enabled=true には、age の公開鍵(age1...)が必要。秘密鍵は、ホストに置かない。"
    }
    precondition {
      condition     = !var.enabled || (length(var.bao_endpoints) > 0 && alltrue([for e in var.bao_endpoints : can(regex("^https://[A-Za-z0-9.-]+(:[0-9]+)?$", e))]))
      error_message = "enabled=true には、bao_endpoints(https://host:port の一覧)が必要。"
    }
    precondition {
      condition = !var.enabled || (
        can(regex("^[A-Za-z0-9._-]{8,}$", var.approle_role_id)) &&
        can(regex("^[A-Za-z0-9._-]{8,}$", var.approle_secret_id))
      )
      error_message = "enabled=true には、AppRole の role_id と secret_id が必要(README の手順で発行する)。"
    }
    precondition {
      condition     = var.healthcheck_url == "" || can(regex("^https://[A-Za-z0-9._~:/?=&%+-]+$", var.healthcheck_url))
      error_message = "healthcheck_url は空か、https:// で始まる、引用符や $ を含まない URL。"
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
    destination = "${local.stage}/openbao-backup.sh"
  }

  provisioner "file" {
    content     = local.service_unit
    destination = "${local.stage}/openbao-backup.service"
  }

  provisioner "file" {
    content     = local.timer_unit
    destination = "${local.stage}/openbao-backup.timer"
  }

  provisioner "file" {
    content     = var.enabled ? local.env_file : ""
    destination = "${local.stage}/env"
  }

  # AppRole の資格情報(root のみ読める /etc/openbao-backup/ に置く)。秘密は、コマンドラインや変数のログには載せない
  provisioner "file" {
    content     = var.enabled ? local.approle_role_id_file : ""
    destination = "${local.stage}/role_id"
  }

  provisioner "file" {
    content     = var.enabled ? local.approle_secret_id_file : ""
    destination = "${local.stage}/secret_id"
  }

  provisioner "file" {
    content     = var.enabled ? local.hosts_entries : ""
    destination = "${local.stage}/hosts.entries"
  }

  provisioner "file" {
    content     = var.enabled ? local.setup_script : local.disable_script
    destination = "${local.stage}/openbao-backup-setup.sh"
  }

  # sudo のパスワードは、コマンドラインに載せず、0700 の作業ディレクトリのファイルから、標準入力で渡す
  provisioner "file" {
    content     = "${var.sudo_password}\n"
    destination = "${local.stage}/.sudo"
  }

  # 失敗を、後始末の成功で隠さない。後始末(作業ディレクトリの削除)は、成否に関わらず行い、終了コードはセットアップのもの
  provisioner "remote-exec" {
    inline = [
      "if [ \"$(id -u)\" -eq 0 ]; then bash ${local.stage}/openbao-backup-setup.sh; rc=$?; else sudo -S -p '' bash ${local.stage}/openbao-backup-setup.sh < ${local.stage}/.sudo; rc=$?; fi; rm -rf ${local.stage}; exit $rc",
    ]
  }
}
