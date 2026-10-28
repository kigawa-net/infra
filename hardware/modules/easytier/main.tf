locals {
  # ネストしたヒアドキュメントを避けるため、設定ファイルは単独の file provisioner で /tmp に置き、
  # セットアップスクリプトが 0600 で /etc/easytier/ に移す。Secret はプロセスの引数に出さず、設定ファイルにだけ書く。
  config_toml = <<-TOML
    instance_name = "${var.instance_name}"
    ipv4 = "${var.overlay_address}"
    dhcp = false
    listeners = [${join(", ", [for l in var.listeners : "\"${l}\""])}]

    [network_identity]
    network_name = "${var.network_name}"
    network_secret = "${var.network_secret}"
    %{for p in var.peers~}

    [[peer]]
    uri = "${p}"
    %{endfor~}
  TOML
}

resource "null_resource" "easytier" {
  triggers = {
    host             = var.host
    easytier_version = var.easytier_version
    easytier_arch    = var.easytier_arch
    easytier_sha256  = var.easytier_sha256
    config           = sha256(local.config_toml)
    ufw_allow        = join(",", var.ufw_allow)
    script           = filesha256("${path.module}/files/easytier-setup.sh")
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "file" {
    source      = "${path.module}/files/easytier-setup.sh"
    destination = "/tmp/easytier-setup.sh"
  }

  provisioner "file" {
    content     = local.config_toml
    destination = "/tmp/easytier.toml"
  }

  provisioner "remote-exec" {
    inline = [
      # root で接続するノード(ionos)は sudo を使わず直接実行する(hardware/ionos と同じ)。root でなければ sudo -S。
      "run() { env ET_VERSION='${var.easytier_version}' ET_ARCH='${var.easytier_arch}' ET_SHA256='${var.easytier_sha256}' ET_UFW_ALLOW='${join(" ", var.ufw_allow)}' bash /tmp/easytier-setup.sh; }; if [ \"$(id -u)\" -eq 0 ]; then run; else echo '${var.sudo_password}' | sudo -S env ET_VERSION='${var.easytier_version}' ET_ARCH='${var.easytier_arch}' ET_SHA256='${var.easytier_sha256}' ET_UFW_ALLOW='${join(" ", var.ufw_allow)}' bash /tmp/easytier-setup.sh; fi; rc=$?; rm -f /tmp/easytier-setup.sh /tmp/easytier.toml; exit $rc",
    ]
  }
}
