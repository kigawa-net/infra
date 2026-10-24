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
}

resource "null_resource" "maas_rack" {
  count = var.enabled ? 1 : 0

  # ファイアウォール無しでは、Rack を公開しない(TFTP などが、ホストの全アドレスで待ち受けるため)。
  lifecycle {
    precondition {
      condition     = var.lan_address != ""
      error_message = "maas-rack: enabled のときは、lan_address(このホストの LAN 側のアドレス)が必須です。"
    }
  }

  triggers = {
    host                 = var.host
    maas_url             = var.maas_url
    min_available_mb     = var.min_available_mb
    install_script_hash  = sha256(local.install_script)
    rollback_script_hash = sha256(local.rollback_script)
    firewall_script_hash = sha256(local.firewall_script)
    upgrade_script_hash  = sha256(local.upgrade_script)
    shim_script_hash     = sha256(local.shim_script)
    maas_version         = var.maas_version
    lan_cidr             = var.lan_cidr
    lan_address          = var.lan_address
    dhcp_peer_address    = var.dhcp_peer_address
  }

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
}
