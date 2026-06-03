locals {
  kresd_conf = <<-CONF
logging:
  level: notice

network:
  listen:
    - interface: "0.0.0.0@53"
    - interface: "0.0.0.0@853"
      kind: dot

cache:
  size-max: ${var.cache_size_mb}M
  storage: /var/cache/knot-resolver

forward:
  - subtree: "cluster.local."
    servers:
      - "${var.coredns_ip}"

%{~ for d in var.internal_domains ~}
  - subtree: "${d}."
    servers:
      - "${var.internal_dns_ip}"

%{~ endfor ~}
  - subtree: "."
    servers:
      - 8.8.8.8
      - 8.8.4.4
      - 1.1.1.1
      - 1.0.0.1
CONF
}

resource "null_resource" "knot_resolver" {
  triggers = {
    host       = var.host
    kresd_conf = local.kresd_conf
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "remote-exec" {
    inline = [
      # CZ.NIC repo を追加して knot-resolver v6 をインストール
      # Ubuntu 22.04 の標準リポジトリは v5 (YAML設定非対応)、Ubuntu 24.04 では削除済みのため
      "echo '${var.sudo_password}' | sudo -S bash -c 'apt-get install -y curl gpg && mkdir -p /etc/apt/keyrings && curl -fsSL https://pkg.labs.nic.cz/doc/repository.gpg | gpg --dearmor --yes -o /etc/apt/keyrings/labs-nic-cz-knot-resolver.gpg && . /etc/os-release && echo \"deb [signed-by=/etc/apt/keyrings/labs-nic-cz-knot-resolver.gpg] https://pkg.labs.nic.cz/knot-resolver $${VERSION_CODENAME} main\" > /etc/apt/sources.list.d/labs-nic-cz-knot-resolver.list && apt-get update && apt-get install -y knot-resolver'",
      "echo '${var.sudo_password}' | sudo -S mkdir -p /var/cache/knot-resolver /var/run/knot-resolver",
      "echo '${var.sudo_password}' | sudo -S bash -c 'chown -R knot-resolver: /var/cache/knot-resolver /var/run/knot-resolver 2>/dev/null || chown -R _knot-resolver: /var/cache/knot-resolver /var/run/knot-resolver'",
    ]
  }

  provisioner "file" {
    content     = local.kresd_conf
    destination = "/tmp/kresd.conf"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S cp /tmp/kresd.conf /etc/knot-resolver/kresd.conf",
      "echo '${var.sudo_password}' | sudo -S systemctl enable knot-resolver",
      "echo '${var.sudo_password}' | sudo -S systemctl restart knot-resolver",
      "echo '${var.sudo_password}' | sudo -S rm -f /tmp/kresd.conf",
    ]
  }
}
