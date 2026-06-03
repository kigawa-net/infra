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

locals {
  install_script = <<-SCRIPT
    #!/bin/bash
    set -euo pipefail
    LOG=/tmp/knot-resolver-install.log
    exec > >(tee -a "$LOG") 2>&1

    export DEBIAN_FRONTEND=noninteractive

    echo "=== apt-get install curl gpg ==="
    apt-get install -y curl gpg

    echo "=== Fetching GPG key ==="
    mkdir -p /etc/apt/keyrings
    curl -fsSL \
      https://keys.openpgp.org/vks/v1/by-fingerprint/CC57AC4EDA32021608543664D959241751179EC7 \
      | gpg --batch --dearmor --yes \
          -o /etc/apt/keyrings/labs-nic-cz-knot-resolver.gpg

    echo "=== Adding apt source ==="
    . /etc/os-release
    echo "deb [signed-by=/etc/apt/keyrings/labs-nic-cz-knot-resolver.gpg] \
https://pkg.labs.nic.cz/knot-resolver $${VERSION_CODENAME} main" \
      > /etc/apt/sources.list.d/labs-nic-cz-knot-resolver.list
    cat /etc/apt/sources.list.d/labs-nic-cz-knot-resolver.list

    echo "=== apt-get update ==="
    apt-get update

    echo "=== Installing knot-resolver ==="
    apt-get install -y --allow-change-held-packages knot-resolver

    echo "=== Creating directories ==="
    mkdir -p /var/cache/knot-resolver /var/run/knot-resolver
    chown -R knot-resolver: /var/cache/knot-resolver /var/run/knot-resolver \
      2>/dev/null \
      || chown -R _knot-resolver: /var/cache/knot-resolver /var/run/knot-resolver

    echo "=== Done ==="
  SCRIPT
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

  provisioner "file" {
    content     = local.install_script
    destination = "/tmp/knot-resolver-install.sh"
  }

  provisioner "file" {
    content     = local.kresd_conf
    destination = "/tmp/kresd.conf"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S bash /tmp/knot-resolver-install.sh",
      "echo '${var.sudo_password}' | sudo -S cp /tmp/kresd.conf /etc/knot-resolver/kresd.conf",
      "echo '${var.sudo_password}' | sudo -S systemctl enable knot-resolver",
      "echo '${var.sudo_password}' | sudo -S systemctl restart knot-resolver",
      "echo '${var.sudo_password}' | sudo -S rm -f /tmp/kresd.conf /tmp/knot-resolver-install.sh",
    ]
  }
}
