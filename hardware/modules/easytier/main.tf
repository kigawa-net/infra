locals {
  # overlay_firewall のときだけ、Overlay のネットワーク(例: 10.250.0.0/24)を渡す。空なら、スクリプトは何もしない。
  overlay_cidr = var.overlay_firewall ? "${cidrhost(var.overlay_address, 0)}/${split("/", var.overlay_address)[1]}" : ""

  # ネストしたヒアドキュメントを避けるため、設定ファイルは単独の file provisioner で /tmp に置き、
  # セットアップスクリプトが 0600 で /etc/easytier/ に移す。Secret はプロセスの引数に出さず、設定ファイルにだけ書く。
  config_toml = <<-TOML
    instance_name = "${var.instance_name}"
    ipv4 = "${var.overlay_address}"
    dhcp = false
    listeners = [${join(", ", [for l in var.listeners : "\"${l}\""])}]
%{if var.secure_mode_enabled && var.credential_file != null}
    credential_file = "${var.credential_file}"
%{endif}

    [network_identity]
    network_name = "${var.network_name}"
    network_secret = "${var.network_secret}"
%{if var.secure_mode_enabled}

    [secure_mode]
    enabled = true
%{endif}
    %{for p in var.peers~}

    [[peer]]
    uri = "${p}"
    %{endfor~}
    %{for n in var.proxy_network~}

    # EasyTier 2.6.4 の正しいキーは [[proxy_network]] と cidr。以前の [[subnet_proxy]] / network は、無視され、
    # サブネットプロキシが、一度も効いていなかった(easytier-cli route の proxy_cidrs が空。手元で確認済み)。
    [[proxy_network]]
    cidr = "${n}"
    %{endfor~}
  TOML
}

resource "null_resource" "easytier" {
  lifecycle {
    precondition {
      condition = !var.secure_mode_enabled || tonumber(split(".", var.easytier_version)[0]) > 2 || (
        tonumber(split(".", var.easytier_version)[0]) == 2 && tonumber(split(".", var.easytier_version)[1]) >= 6
      )
      error_message = "Secure Mode には EasyTier 2.6.0 以降が必要。"
    }
  }

  triggers = {
    host             = var.host
    easytier_version = var.easytier_version
    easytier_arch    = var.easytier_arch
    easytier_sha256  = var.easytier_sha256
    config           = sha256(local.config_toml)
    ufw_allow        = join(",", var.ufw_allow)
    overlay_firewall = tostring(var.overlay_firewall)
    overlay_allow    = join(",", var.overlay_allow)
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
      "run() { env ET_VERSION='${var.easytier_version}' ET_ARCH='${var.easytier_arch}' ET_SHA256='${var.easytier_sha256}' ET_UFW_ALLOW='${join(" ", var.ufw_allow)}' ET_OVERLAY_CIDR='${local.overlay_cidr}' ET_OVERLAY_ALLOW='${join(" ", var.overlay_allow)}' bash /tmp/easytier-setup.sh; }; if [ \"$(id -u)\" -eq 0 ]; then run; else echo '${var.sudo_password}' | sudo -S env ET_VERSION='${var.easytier_version}' ET_ARCH='${var.easytier_arch}' ET_SHA256='${var.easytier_sha256}' ET_UFW_ALLOW='${join(" ", var.ufw_allow)}' ET_OVERLAY_CIDR='${local.overlay_cidr}' ET_OVERLAY_ALLOW='${join(" ", var.overlay_allow)}' bash /tmp/easytier-setup.sh; fi; rc=$?; rm -f /tmp/easytier-setup.sh /tmp/easytier.toml; exit $rc",
    ]
  }
}
