# 公開 IP を持つ VPS の、SSH と受信ファイアウォールを固める(kigawa-net/infra#337)。
#
# - sshd: パスワード認証と kbd-interactive を無効にし、root は鍵だけにする。
#   cloud-init の 50-cloud-init.conf が `PasswordAuthentication yes` を持つので、
#   sshd_config.d は先に読まれた値が勝つ(first-match)ことを使って、00- で上書きする。
# - ufw: 受信は既定で拒否。ssh は公開のまま(CI の GitHub-hosted runner は送信元を絞れない)、
#   WireGuard のハブからの UDP、wireguard_interface 上の指定 tcp ポートだけ許可する。
#
# ロックアウトを避けるため: sshd は `sshd -t` と有効な設定の確認に通ってから reload し、
# ufw は ssh を許可してから有効にする。失敗したら drop-in を戻す。
locals {
  sshd_dropin = <<-CONF
    # hardware/modules/host-hardening が置く。手で編集しない。
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PermitRootLogin prohibit-password
    PubkeyAuthentication yes
    CONF

  ufw_wg_rules = join("\n", [
    for p in var.tcp_ports_on_wireguard :
    "ufw allow in on ${var.wireguard_interface} proto tcp to any port ${p} comment 'openbao ${p} (wireguard)'"
  ])

  # remote-exec の inline は dash で動いてしまうため、シバン付きのスクリプトを bash で明示的に実行する(journald-limit と同じ理由)。
  setup_script = <<-SCRIPT
    #!/bin/bash
    set -eo pipefail
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    dropin=/etc/ssh/sshd_config.d/00-hardening.conf
    had_dropin=0
    if [ -e "$dropin" ]; then had_dropin=1; cp -a "$dropin" /tmp/00-hardening.conf.bak; fi

    rollback_sshd() {
      if [ "$had_dropin" = 1 ]; then mv /tmp/00-hardening.conf.bak "$dropin"; else rm -f "$dropin"; fi
      echo "host-hardening: sshd の設定を戻しました" >&2
    }

    # 1. sshd。検証に通らなければ、reload せずに戻す
    install -d -m 0755 /etc/ssh/sshd_config.d
    install -m 0644 /tmp/00-hardening.conf "$dropin"
    rm -f /tmp/00-hardening.conf
    if ! sshd -t; then rollback_sshd; exit 1; fi
    effective=$(sshd -T)
    for want in "passwordauthentication no" "kbdinteractiveauthentication no" "permitrootlogin prohibit-password" "pubkeyauthentication yes"; do
      if ! echo "$effective" | grep -qx "$want"; then
        echo "host-hardening: 有効な設定に '$want' が無い(ほかの drop-in が勝っている)" >&2
        rollback_sshd
        exit 1
      fi
    done
    systemctl reload ssh
    rm -f /tmp/00-hardening.conf.bak

    # 2. ufw。ssh を許可してから有効にする(ロックアウト防止)
    if ! command -v ufw >/dev/null; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y ufw
    fi
    ufw default deny incoming
    ufw default allow outgoing
    ufw default deny routed
    ufw allow ${var.ssh_port}/tcp comment 'ssh'
    ufw allow from ${var.wireguard_hub_address} proto udp comment 'wireguard hub'
    ${local.ufw_wg_rules}
    ufw --force enable

    echo "host-hardening: 完了"
    ufw status verbose
    sshd -T | grep -E '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin) '
    SCRIPT
}

resource "null_resource" "host_hardening" {
  triggers = {
    host                   = var.host
    ssh_port               = var.ssh_port
    wireguard_interface    = var.wireguard_interface
    wireguard_hub_address  = var.wireguard_hub_address
    tcp_ports_on_wireguard = join(",", var.tcp_ports_on_wireguard)
    sshd_dropin_hash       = sha256(local.sshd_dropin)
    setup_script_hash      = sha256(local.setup_script)
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "file" {
    content     = local.sshd_dropin
    destination = "/tmp/00-hardening.conf"
  }

  provisioner "file" {
    content     = local.setup_script
    destination = "/tmp/host-hardening-setup.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S bash /tmp/host-hardening-setup.sh && rm -f /tmp/host-hardening-setup.sh",
    ]
  }
}
