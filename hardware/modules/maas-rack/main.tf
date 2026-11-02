# MAAS の Rack コントローラーを、host に deb で直接インストールする(kigawa-net/infra#207、docs/maas-design.md)。
#
# Rack は k8s に載せない。MAAS 3.6 の Rack(Ubuntu 24.04 の PPA は 3.6 以降のみ)を control-plane(k8s2 / k8s4)に入れ、
# DHCP は primary / secondary の 2 台で failover する。**この module は、DHCP を有効にしない**(DHCP の切り替えは、後の別の段階)。
#
# enabled = false(既定)のときは、何も作らない。true にすると、files/maas-rack-install.sh を host で実行する。
# 導入で、systemd-timesyncd が chrony に置き換わり、bind9(mask)・nginx(default サイトを無効)・avahi(無効)が入る/変わる。
# 失敗して中途半端な状態になったら、host で files/maas-rack-rollback.sh を実行して戻す(自動では戻さない)。

locals {
  install_script  = file("${path.module}/files/maas-rack-install.sh")
  rollback_script = file("${path.module}/files/maas-rack-rollback.sh")
  firewall_script = file("${path.module}/files/maas-rack-firewall.sh")
  upgrade_script  = file("${path.module}/files/maas-rack-upgrade.sh")
  shim_script     = file("${path.module}/files/maas-rack-shim.sh")

  # MAAS 用の Wake on LAN の webhook(MAAS に WoL のドライバが無いため、webhook ドライバで 127.0.0.1 のサービスを呼ぶ)
  wol_script         = file("${path.module}/files/maas-wol-webhook.py")
  wol_install_script = file("${path.module}/files/maas-wol-webhook-install.sh")
  wol_broadcast      = var.wol_broadcast != "" ? var.wol_broadcast : cidrhost(var.lan_cidr, -1)

  # SSH によるシャットダウン(/off。kigawa-net/infra#416)。3 つそろったときだけ、webhook に設定を渡す。一部だけは、precondition で止める。
  wol_shutdown_any = length(var.wol_shutdown_targets) > 0 || var.wol_shutdown_private_key != "" || var.wol_shutdown_known_hosts != ""
  wol_shutdown_all = length(var.wol_shutdown_targets) > 0 && var.wol_shutdown_private_key != "" && var.wol_shutdown_known_hosts != ""
  wol_shutdown_on  = local.wol_shutdown_all && var.wol_webhook_enabled

  wol_shutdown_targets_file = jsonencode(var.wol_shutdown_targets)
  wol_shutdown_hosts_file   = var.wol_shutdown_known_hosts == "" ? "" : "${trimspace(var.wol_shutdown_known_hosts)}\n"

  # 有効なときだけ、再実行の条件に加える(無効のままなら、このキーは triggers に増えない。ただし、webhook のスクリプトを変えた PR では、
  # wol_script_hash / wol_install_hash が変わり、既存の host(k8s2 / k8s4)も再実行される。計画で確認すること)。
  # 鍵の内容は、平文で triggers に入れない(sha256 のみ)。
  wol_shutdown_triggers = local.wol_shutdown_on ? {
    wol_shutdown_targets_hash     = sha256(local.wol_shutdown_targets_file)
    wol_shutdown_key_hash         = sha256(var.wol_shutdown_private_key)
    wol_shutdown_known_hosts_hash = sha256(local.wol_shutdown_hosts_file)
  } : {}

  # webhook の install に渡す、一時ファイルの場所(有効のときだけ。無効なら、install が CONF_DIR の設定を消す)
  wol_shutdown_env       = local.wol_shutdown_on ? "SHUTDOWN_TARGETS_SRC=/tmp/maas-wol-shutdown-targets.json SHUTDOWN_KEY_SRC=/tmp/maas-wol-shutdown.key SHUTDOWN_KNOWN_HOSTS_SRC=/tmp/maas-wol-shutdown-known-hosts" : ""
  wol_shutdown_tmp_files = "/tmp/maas-wol-shutdown.key /tmp/maas-wol-shutdown-targets.json /tmp/maas-wol-shutdown-known-hosts"
}

resource "null_resource" "maas_rack" {
  count = var.enabled ? 1 : 0

  # ファイアウォール無しでは、Rack を公開しない(TFTP などが、ホストの全アドレスで待ち受けるため)。
  lifecycle {
    precondition {
      condition     = var.lan_address != ""
      error_message = "maas-rack: enabled のときは、lan_address(このホストの LAN 側のアドレス)が必須です。"
    }

    precondition {
      condition     = !local.wol_shutdown_any || local.wol_shutdown_all
      error_message = "maas-rack: wol_shutdown_targets・wol_shutdown_private_key・wol_shutdown_known_hosts は、3 つそろえて指定してください(一部だけは不可)。"
    }
  }

  triggers = merge({
    host                 = var.host
    maas_url             = var.maas_url
    min_available_mb     = var.min_available_mb
    install_script_hash  = sha256(local.install_script)
    rollback_script_hash = sha256(local.rollback_script)
    firewall_script_hash = sha256(local.firewall_script)
    upgrade_script_hash  = sha256(local.upgrade_script)
    shim_script_hash     = sha256(local.shim_script)
    wol_enabled          = var.wol_webhook_enabled
    wol_script_hash      = sha256(local.wol_script)
    wol_install_hash     = sha256(local.wol_install_script)
    wol_broadcast        = local.wol_broadcast
    wol_port             = var.wol_webhook_port
    maas_version         = var.maas_version
    lan_cidr             = var.lan_cidr
    lan_address          = var.lan_address
    dhcp_peer_address    = var.dhcp_peer_address
  }, local.wol_shutdown_triggers)

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "file" {
    content     = local.install_script
    destination = "/tmp/maas-rack-install.sh"
  }

  provisioner "file" {
    content     = local.rollback_script
    destination = "/tmp/maas-rack-rollback.sh"
  }

  provisioner "file" {
    content     = local.firewall_script
    destination = "/tmp/maas-rack-firewall.sh"
  }

  provisioner "file" {
    content     = local.upgrade_script
    destination = "/tmp/maas-rack-upgrade.sh"
  }

  provisioner "file" {
    content     = local.shim_script
    destination = "/tmp/maas-rack-shim.sh"
  }

  provisioner "file" {
    content     = local.wol_script
    destination = "/tmp/maas-wol-webhook.py"
  }

  provisioner "file" {
    content     = local.wol_install_script
    destination = "/tmp/maas-wol-webhook-install.sh"
  }

  # secret の置き場所を、先に 0600 で作る(file provisioner は、既存のファイルの権限を保つ)。
  provisioner "remote-exec" {
    inline = [
      "install -m 0600 /dev/null /tmp/maas-rack-secret",
    ]
  }

  provisioner "file" {
    content     = var.maas_secret
    destination = "/tmp/maas-rack-secret"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S install -d -m 0755 /var/lib/maas-rack-module && echo '${var.sudo_password}' | sudo -S install -m 0755 /tmp/maas-rack-rollback.sh /var/lib/maas-rack-module/maas-rack-rollback.sh && rm -f /tmp/maas-rack-rollback.sh",
      # 成功しても失敗しても、secret のファイルを host に残さない(失敗時は、終了コードを保って、apply を失敗させる)。
      "echo '${var.sudo_password}' | sudo -S env MAAS_VERSION='${var.maas_version}' MAAS_URL='${var.maas_url}' MIN_AVAILABLE_MB='${var.min_available_mb}' LAN_CIDR='${var.lan_cidr}' LAN_ADDRESS='${var.lan_address}' DHCP_PEER_ADDRESS='${var.dhcp_peer_address}' FIREWALL_SRC=/tmp/maas-rack-firewall.sh SECRET_FILE=/tmp/maas-rack-secret bash /tmp/maas-rack-install.sh; rc=$?; rm -f /tmp/maas-rack-secret /tmp/maas-rack-install.sh /tmp/maas-rack-firewall.sh; exit $rc",
    ]
  }

  # 入っている Rack が、maas_version より古ければ、上げる(冪等。すでに同じ版なら、何もしない)。Region を先に上げておくこと。
  # 複数台(k8s2 / k8s4)を、同時に更新しない。DHCP は 2 台で failover するので、1 台ずつ apply して、確認する。
  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S env MAAS_VERSION='${var.maas_version}' bash /tmp/maas-rack-upgrade.sh; rc=$?; rm -f /tmp/maas-rack-upgrade.sh /tmp/maas-rack-shim.sh; exit $rc",
    ]
  }

  # SSH によるシャットダウン(/off)の設定を、一時ファイルに置く(秘密鍵を含む。ログに出さない)。直前の手順(webhook)で、必ず消す。
  # 鍵は、先に 0600 で作ってから書く(file provisioner は、既存のファイルの権限を保つ)。無効のときは、空の内容を置いて、webhook の手順で消す。
  provisioner "remote-exec" {
    inline = [
      "install -m 0600 /dev/null /tmp/maas-wol-shutdown.key",
    ]
  }

  provisioner "file" {
    content     = var.wol_shutdown_private_key
    destination = "/tmp/maas-wol-shutdown.key"
  }

  provisioner "file" {
    content     = local.wol_shutdown_targets_file
    destination = "/tmp/maas-wol-shutdown-targets.json"
  }

  provisioner "file" {
    content     = local.wol_shutdown_hosts_file
    destination = "/tmp/maas-wol-shutdown-known-hosts"
  }

  # MAAS 用の Wake on LAN の webhook(127.0.0.1 だけで待ち受け。ほかのサービスには触れない)。無効のときは、何もせず、置いたファイルだけ消す。
  # SSH のシャットダウンは、wol_webhook_enabled が true で、3 つそろったときだけ有効(install が、CONF_DIR に置く。無効なら、CONF_DIR の設定を消す)。
  provisioner "remote-exec" {
    inline = [
      var.wol_webhook_enabled ?
      "echo '${var.sudo_password}' | sudo -S env BCAST='${local.wol_broadcast}' PORT='${var.wol_webhook_port}' SRC=/tmp/maas-wol-webhook.py ${local.wol_shutdown_env} bash /tmp/maas-wol-webhook-install.sh; rc=$?; rm -f /tmp/maas-wol-webhook.py /tmp/maas-wol-webhook-install.sh ${local.wol_shutdown_tmp_files}; exit $rc" :
      "rm -f /tmp/maas-wol-webhook.py /tmp/maas-wol-webhook-install.sh ${local.wol_shutdown_tmp_files}",
    ]
  }
}
