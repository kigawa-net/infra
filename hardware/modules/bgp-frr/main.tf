terraform {
  required_providers {
    null = {
      source = "hashicorp/null"
    }
  }
}

locals {
  frr_conf = templatefile("${path.module}/templates/frr.conf.tpl", {
    bgp_router_id      = var.bgp_router_id
    bgp_local_as       = var.bgp_local_as
    bgp_peers          = var.bgp_peers
    kube_vip_as        = var.kube_vip_as
    advertised_vips    = var.advertised_vips
    external_bgp_peers = var.external_bgp_peers
  })

  # Keep these shared files compatible with bgp-bird.
  local_vip_setup = <<-SCRIPT
    #!/bin/bash
    %{~for vip in var.advertised_vips}
    ip addr add ${vip}/32 dev lo 2>/dev/null || true
    %{~endfor}
    SCRIPT
  local_vip_unit  = <<-UNIT
    [Unit]
    Description=Local VIP addresses on loopback
    After=network.target

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=/bin/bash /usr/local/bin/local-vip-setup.sh

    [Install]
    WantedBy=multi-user.target
    UNIT

  setup_script = <<-SCRIPT
    #!/bin/bash
    set -euo pipefail
    masked_by_setup=false
    cleanup() {
      if "$masked_by_setup"; then
        systemctl unmask --runtime frr.service
      fi
      rm -f /tmp/frr-module.conf /tmp/frr-local-vip-setup.sh /tmp/frr-local-vip.service /tmp/frr-module-setup.sh
    }
    trap cleanup EXIT

    # Never override an administrator's mask. Block package postinst auto-start
    # until configuration is installed and BIRD's listener has disappeared.
    case "$(systemctl is-enabled frr.service 2>/dev/null || true)" in
      masked*) echo 'frr.service is already masked; resolve manually first' >&2; exit 1 ;;
    esac
    systemctl mask --runtime frr.service
    masked_by_setup=true

    # Same dpkg wait_lock + 20-attempt pattern as keepalived; exhaustion fails.
    wait_lock() {
      for i in $(seq 1 60); do
        fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1 || return 0
        sleep 5
      done
      return 1
    }
    apt_retry() {
      for a in $(seq 1 20); do
        wait_lock || true
        if DEBIAN_FRONTEND=noninteractive apt-get "$@"; then return 0; fi
        sleep 5
      done
      return 1
    }
    apt_retry update -y
    apt_retry install -y frr

    install -d -o frr -g frr -m 0755 /etc/frr
    if grep -q '^bgpd=' /etc/frr/daemons; then
      sed -i 's/^bgpd=.*/bgpd=yes/' /etc/frr/daemons
    else
      printf '\nbgpd=yes\n' >> /etc/frr/daemons
    fi
    # zebra is always enabled by the FRR service; no zebra=yes toggle needed.
    install -o frr -g frr -m 0640 /tmp/frr-module.conf /etc/frr/frr.conf
    ip addr del 127.0.0.100/32 dev lo 2>/dev/null || true
    rm -f /etc/netplan/99-bgp-loopback.yaml
    install -m 0755 /tmp/frr-local-vip-setup.sh /usr/local/bin/local-vip-setup.sh
    install -m 0644 /tmp/frr-local-vip.service /etc/systemd/system/local-vip.service
    systemctl daemon-reload
    systemctl enable --now local-vip.service
    systemctl restart local-vip.service

    # Only an explicit migration request may remove the BIRD manifest.
    %{if var.stop_bird~}
    rm -f /etc/kubernetes/manifests/bird.yaml
    %{endif~}
    # Existing FRR must release its own socket before the conflict check.
    systemctl stop frr.service
    port_free=false
    for i in $(seq 1 60); do
      listeners=$(ss -H -ltn 'sport = :179')
      if [ -z "$listeners" ]; then port_free=true; break; fi
      sleep 2
    done
    if ! "$port_free"; then
      echo 'TCP port 179 is still in use; FRR was not started' >&2
      exit 1
    fi
    systemctl unmask --runtime frr.service
    masked_by_setup=false
    systemctl enable --now frr
    systemctl restart frr
    SCRIPT
}

resource "null_resource" "frr" {
  triggers = {
    host        = var.host
    config_hash = sha256(local.frr_conf)
    setup_hash  = sha256(local.setup_script)
    vip_hash    = sha256("${local.local_vip_setup}\n${local.local_vip_unit}")
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "file" {
    content     = local.frr_conf
    destination = "/tmp/frr-module.conf"
  }
  provisioner "file" {
    content     = local.local_vip_setup
    destination = "/tmp/frr-local-vip-setup.sh"
  }
  provisioner "file" {
    content     = local.local_vip_unit
    destination = "/tmp/frr-local-vip.service"
  }
  provisioner "file" {
    content     = local.setup_script
    destination = "/tmp/frr-module-setup.sh"
  }
  provisioner "remote-exec" {
    inline = [
      "printf '%s\\n' '${replace(var.sudo_password, "'", "'\"'\"'")}' | sudo -S bash /tmp/frr-module-setup.sh",
    ]
  }
}
