# journald のディスク使用量に上限を設ける(kigawa-net/infra#254)。
#
# 2026-10-09、コントロールプレーンの / が逼迫していた(k8s4 は空き 3.9 GB、k8s1 は 9.4 GB)。
# journal は、k8s1 で 2.0 GB、k8s4 で 1.4 GB を使っていた。journald の既定の上限は、ファイルシステムの 10%(最大 4 GB)で、
# 小さい / では、他の用途の空きを圧迫する。上限を明示して、/ の枯渇に巻き込まれにくくする。
#
# SystemMaxUse と RuntimeMaxUse の両方が必要:
#   - SystemMaxUse  … /var/log/journal(ディスク)の上限
#   - RuntimeMaxUse … /run/log/journal(ramdisk / tmpfs)の上限
# k8s-worker4 は 2026-10-11 時点で /var/log/journal 2.2G に加え
# /run/log/journal にも 357M たまっており、SystemMaxUse だけでは
# tmpfs 側の journal を制限できない。journald は起動時に
# 「Storage=auto(既定)」で /var/log/journal が使えるならそちらを使い、
# 使えないときだけ /run/log/journal にフォールバックするため、
# 現在は使われていなくても Storage の切り替えや設定ミスで
# runtime journal に流れ込むと上限が効かなくなる。
locals {
  # /etc/systemd/journald.conf.d/ に置く drop-in。本体の journald.conf は触らない。
  dropin = <<-CONF
    [Journal]
    SystemMaxUse=${var.system_max_use}
    RuntimeMaxUse=${var.runtime_max_use}
    CONF

  # drop-in の中身が 바뀌ったときに再適用するため、内容のハッシュを trigger に含める。
  # (drop-in の文言を変えても null_resource が置換されず、
  #  既存ノードに設定が届かない状態になっていた)
  dropin_hash = sha256(local.dropin)

  # remote-exec の inline は、シバンなしで転送され、dash で動いてしまうため、シバン付きのスクリプトを、bash で明示的に実行する
  # (node-exporter モジュールと同じ理由)。
  setup_script = <<-SCRIPT
    #!/bin/bash
    set -eo pipefail
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    install -d -m 0755 /etc/systemd/journald.conf.d
    install -m 0644 /tmp/50-size-limit.conf /etc/systemd/journald.conf.d/50-size-limit.conf
    rm -f /tmp/50-size-limit.conf

    # 設定を読み込ませる。journald の再起動で、ログは失われない(ソケットは systemd が保持する)。
    systemctl restart systemd-journald

    # 上限を超えている古いログを、一度だけ削除する(上限を設けても、既存のファイルは、新しく書くときまで縮まないため)。
    # --vacuum-size は /var/log/journal 側にだけ効くので、runtime journal
    # (/run/log/journal、tmpfs)に残った分:--vacuum-time の上限で期限切れにする。
    journalctl --vacuum-size=${var.system_max_use}
    journalctl --vacuum-time=${var.runtime_max_days}

    echo "journald: $(journalctl --disk-usage)"
    echo "  /var/log/journal: $(du -sh /var/log/journal 2>/dev/null | cut -f1 || echo '(なし)')"
    echo "  /run/log/journal: $(du -sh /run/log/journal 2>/dev/null | cut -f1 || echo '(なし)')"
    echo "  有効な設定: $(systemd-analyze cat-config systemd/journald.conf 2>/dev/null | grep -E '^(SystemMaxUse|RuntimeMaxUse)' | tr '\n' ' ')"
    SCRIPT
}

resource "null_resource" "journald_limit" {
  triggers = {
    host              = var.host
    system_max_use    = var.system_max_use
    runtime_max_use   = var.runtime_max_use
    runtime_max_days  = var.runtime_max_days
    dropin_hash       = local.dropin_hash
    setup_script_hash = sha256(local.setup_script)
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "file" {
    content     = local.dropin
    destination = "/tmp/50-size-limit.conf"
  }

  provisioner "file" {
    content     = local.setup_script
    destination = "/tmp/journald-limit-setup.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S bash /tmp/journald-limit-setup.sh && rm -f /tmp/journald-limit-setup.sh",
    ]
  }
}