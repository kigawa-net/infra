# journald のディスク使用量に上限を設ける(kigawa-net/infra#254、k8s-system#259)。
#
# 2026-10-09、コントロールプレーンの / が逼迫していた(k8s4 は空き 3.9 GB、k8s1 は 9.4 GB)。
# journal は、k8s1 で 2.0 GB、k8s4 で 1.4 GB を使っていた。journald の既定の上限は、ファイルシステムの 10%(最大 4 GB)で、
# 小さい / では、他の用途の空きを圧迫する。上限を明示して、/ の枯渇に巻き込まれにくくする。
#
# SystemMaxUse と RuntimeMaxUse の両方が必要(k8s-system#259 のレビュー指摘)。
# journald は 2 つの保存先を持ち、既定の Storage=auto では
# /var/log/journal が存在すればそちら(stored として SystemMaxUse の対象)へ、
# 永続化できないもの(runtime)だけを /run/log/journal(RuntimeMaxUse の対象)へ書く。
# worker4 では /var/log/journal 2.3 GB に対し /run/log/journal も 357 MB あり、
# SystemMaxUse だけでは ramdisk 側の圧縮に至らない。
locals {
  # /etc/systemd/journald.conf.d/ に置く drop-in。本体の journald.conf は触らない。
  # (drop-in のほうが journald.conf より優先される)
  dropin = <<-CONF
    [Journal]
    SystemMaxUse=${var.system_max_use}
    RuntimeMaxUse=${var.runtime_max_use}
    CONF

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
    # runtime と system の両方に効くが、引数はサイズ指定なので個別制御はできない。
    journalctl --vacuum-size=${var.system_max_use}

    echo "journald: $(journalctl --disk-usage)"
    echo "  /var/log/journal: $(du -sh /var/log/journal 2>/dev/null | cut -f1 || echo 'n/a')"
    echo "  /run/log/journal : $(du -sh /run/log/journal 2>/dev/null | cut -f1 || echo 'n/a')"
    echo "--- 反映確認 ---"
    systemctl show systemd-journald -p Environment 2>/dev/null | head -1 || true
    grep -E 'SystemMaxUse|RuntimeMaxUse' /etc/systemd/journald.conf.d/50-size-limit.conf
    SCRIPT
}

resource "null_resource" "journald_limit" {
  triggers = {
    host = var.host

    # 設定ファイルそのものの内容を hash で持たせる。値だけを trigger にすると、
    # drop-in の雛形 changed を検知できず、既存ノードに再適用されない
    # (k8s-system#259 のレビュー指摘 2)。
    # 実際、RuntimeMaxUse を追加した変更が、この hash なしでは伝播しない。
    dropin_hash = sha256(local.dropin)
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
