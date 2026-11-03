terraform {
  required_providers {
    null = {
      source = "hashicorp/null"
    }
  }
}

locals {
  frr_conf = templatefile("${path.module}/templates/frr.conf.tpl", {
    router_id       = var.router_id
    local_as        = var.local_as
    remote_as       = var.remote_as
    neighbors       = var.neighbors
    import_prefixes = var.import_prefixes
  })

  # bgp-frr と同じ dpkg のロック待ち・apt のリトライ。FRR の起動は、設定を置いてから、bgpd=yes で行う。
  setup_script = <<-SCRIPT
    #!/bin/bash
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive

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
        if apt-get "$@"; then return 0; fi
        sleep 5
      done
      return 1
    }

    # FRR が無いときだけ入れる。reload(frr-reload.py)のために frr-pythontools も入れる。
    if ! command -v vtysh >/dev/null 2>&1; then
      apt_retry update -y
      apt_retry install -y frr frr-pythontools
    fi

    # bgpd を有効にする(zebra は frr.service が常に起動する)。
    if grep -q '^bgpd=' /etc/frr/daemons; then
      sed -i 's/^bgpd=.*/bgpd=yes/' /etc/frr/daemons
    else
      printf '\nbgpd=yes\n' >> /etc/frr/daemons
    fi

    # 冪等: 設定が同じで、frr が動いていれば、何もしない(再起動で BGP の経路が消えるのを避ける)。
    if cmp -s /tmp/frr-overlay-peer.conf /etc/frr/frr.conf \
      && systemctl is-active --quiet frr.service; then
      echo 'FRR is already running with the same configuration; skipping restart'
    else
      install -o frr -g frr -m 0640 /tmp/frr-overlay-peer.conf /etc/frr/frr.conf
      systemctl enable frr.service
      # 動いていれば、差分だけを reload する(既存のセッションを切らない)。失敗したら、再起動に進む。
      if systemctl is-active --quiet frr.service && systemctl reload frr.service; then
        echo 'FRR was reloaded with the new configuration (no restart)'
      else
        systemctl restart frr.service
        echo 'FRR was (re)started'
      fi
    fi

    vtysh -c 'show bgp ipv4 unicast summary' || true
  SCRIPT
}

resource "null_resource" "frr" {
  triggers = {
    host        = var.host
    config_hash = sha256(local.frr_conf)
    setup_hash  = sha256(local.setup_script)
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "file" {
    content     = local.frr_conf
    destination = "/tmp/frr-overlay-peer.conf"
  }
  provisioner "file" {
    content     = local.setup_script
    destination = "/tmp/frr-overlay-peer-setup.sh"
  }
  provisioner "remote-exec" {
    inline = [
      "printf '%s\\n' '${replace(var.sudo_password, "'", "'\"'\"'")}' | sudo -S bash /tmp/frr-overlay-peer-setup.sh; rc=$?; rm -f /tmp/frr-overlay-peer.conf /tmp/frr-overlay-peer-setup.sh; exit $rc",
    ]
  }
}
