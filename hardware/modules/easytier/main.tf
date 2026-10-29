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

# ufw を使わないホスト向けの Overlay 遮断(iptables)。null_resource.easytier とは別のリソースにして、
# 既存のノードの script トリガーを変えない(= easytier を再起動しない)。
resource "null_resource" "overlay_iptables" {
  count      = var.overlay_iptables_firewall ? 1 : 0
  depends_on = [null_resource.easytier]

  lifecycle {
    precondition {
      condition     = !(var.overlay_firewall && var.overlay_iptables_firewall)
      error_message = "overlay_firewall(ufw)と overlay_iptables_firewall は同時に使えない。"
    }
  }

  triggers = {
    host          = var.host
    overlay_cidr  = "${cidrhost(var.overlay_address, 0)}/${split("/", var.overlay_address)[1]}"
    overlay_allow = join(",", var.overlay_allow)
    script        = filesha256("${path.module}/files/overlay-fw-iptables.sh")
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "file" {
    source      = "${path.module}/files/overlay-fw-iptables.sh"
    destination = "/tmp/overlay-fw-iptables.sh"
  }

  provisioner "remote-exec" {
    inline = [
      # root で接続するノードは sudo を使わず直接実行する(null_resource.easytier と同じ)。root でなければ sudo -S。
      "run() { env OF_CIDR='${cidrhost(var.overlay_address, 0)}/${split("/", var.overlay_address)[1]}' OF_ALLOW='${join(" ", var.overlay_allow)}' bash /tmp/overlay-fw-iptables.sh; }; if [ \"$(id -u)\" -eq 0 ]; then run; else echo '${var.sudo_password}' | sudo -S env OF_CIDR='${cidrhost(var.overlay_address, 0)}/${split("/", var.overlay_address)[1]}' OF_ALLOW='${join(" ", var.overlay_allow)}' bash /tmp/overlay-fw-iptables.sh; fi; rc=$?; rm -f /tmp/overlay-fw-iptables.sh; exit $rc",
    ]
  }
}
