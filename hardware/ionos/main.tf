locals {
  haproxy_enabled = var.inuyama_ingress_vip != "" || var.minecraft_backend_vip != ""

  inuyama_prefix_list_rules = concat(
    [for index, prefix in var.inuyama_accepted_prefixes : format("ip prefix-list INUYAMA-IN seq %d permit %s", (index + 1) * 10, prefix)],
    ["ip prefix-list INUYAMA-IN seq 999 deny 0.0.0.0/0 le 32"],
  )
  ionos_prefix_list_rules = concat(
    [for index, prefix in var.ionos_advertised_prefixes : format("ip prefix-list IONOS-OUT seq %d permit %s", (index + 1) * 10, prefix)],
    ["ip prefix-list IONOS-OUT seq 999 deny 0.0.0.0/0 le 32"],
  )
  ionos_network_statements = [for prefix in var.ionos_advertised_prefixes : "  network ${prefix}"]

  k8s_wireguard_peers = concat(
    data.external.k8s1_wireguard_public_key.result.value != "" ? [{
      public_key           = data.external.k8s1_wireguard_public_key.result.value
      allowed_ips          = ["${var.k8s1_wireguard_address}/32"]
      endpoint             = ""
      persistent_keepalive = var.wireguard_persistent_keepalive
    }] : [],
    data.external.k8s2_wireguard_public_key.result.value != "" ? [{
      public_key           = data.external.k8s2_wireguard_public_key.result.value
      allowed_ips          = ["${var.k8s2_wireguard_address}/32"]
      endpoint             = ""
      persistent_keepalive = var.wireguard_persistent_keepalive
    }] : [],
  )

  wireguard_config = templatefile("${path.module}/templates/wg0.conf.tpl", {
    address     = var.wireguard_address
    listen_port = var.wireguard_listen_port
    mtu         = var.wireguard_mtu
    peers = concat([{
      public_key           = data.external.inuyama_wireguard_public_key.result.value
      allowed_ips          = var.wireguard_peer_allowed_ips
      endpoint             = var.inuyama_wireguard_endpoint
      persistent_keepalive = var.wireguard_persistent_keepalive
    }], local.k8s_wireguard_peers)
  })

  frr_config = templatefile("${path.module}/templates/frr.conf.tpl", {
    hostname                 = var.hostname
    ionos_asn                = var.ionos_asn
    bgp_router_id            = var.bgp_router_id
    inuyama_wg_address       = var.inuyama_wireguard_address
    inuyama_asn              = var.inuyama_asn
    wireguard_interface      = var.wireguard_interface
    inuyama_prefix_list      = join("\n", local.inuyama_prefix_list_rules)
    ionos_prefix_list        = join("\n", local.ionos_prefix_list_rules)
    ionos_network_statements = join("\n", local.ionos_network_statements)
  })

  haproxy_config = templatefile("${path.module}/templates/haproxy.cfg.tpl", {
    inuyama_ingress_vip   = var.inuyama_ingress_vip
    minecraft_backend_vip = var.minecraft_backend_vip
  })
}

data "external" "ssh_key" {
  program = ["bash", "-c", <<-EOT
    value=$(bws secret get "${var.ssh_key_bitwarden_id}" --color no | jq -r '.value')
    jq -n --arg value "$value" '{"value": $value}'
  EOT
  ]
}

data "external" "sudo_password" {
  program = ["bash", "-c", <<-EOT
    value=$(bws secret get "${var.sudo_password_bitwarden_id}" --color no | jq -r '.value')
    jq -n --arg value "$value" '{"value": $value}'
  EOT
  ]
}

data "external" "inuyama_wireguard_public_key" {
  program = ["bash", "-c", <<-EOT
    value=$(bws secret get "${var.inuyama_wireguard_public_key_bitwarden_id}" --color no | jq -r '.value')
    jq -n --arg value "$value" '{"value": $value}'
  EOT
  ]
}

data "external" "k8s1_wireguard_public_key" {
  program = ["bash", "-c", <<-EOT
    if [ -z "${var.k8s1_wireguard_ssh_host}" ]; then
      jq -n '{"value": ""}'; exit 0
    fi
    ssh_key=$(bws secret get "${var.k8s_ssh_key_bitwarden_id}" --color no | jq -r '.value')
    tmpkey=$(mktemp)
    chmod 600 "$tmpkey"
    printf '%s\n' "$ssh_key" > "$tmpkey"
    value=$(ssh \
      -i "$tmpkey" \
      -o StrictHostKeyChecking=no \
      -o BatchMode=yes \
      -o ConnectTimeout=5 \
      "${var.k8s1_wireguard_ssh_user}@${var.k8s1_wireguard_ssh_host}" \
      'cat /etc/wireguard/publickey' 2>/dev/null) || value=""
    rm -f "$tmpkey"
    jq -n --arg value "$value" '{"value": $value}'
  EOT
  ]
}

data "external" "k8s2_wireguard_public_key" {
  program = ["bash", "-c", <<-EOT
    if [ -z "${var.k8s2_wireguard_ssh_host}" ]; then
      jq -n '{"value": ""}'; exit 0
    fi
    ssh_key=$(bws secret get "${var.k8s_ssh_key_bitwarden_id}" --color no | jq -r '.value')
    tmpkey=$(mktemp)
    chmod 600 "$tmpkey"
    printf '%s\n' "$ssh_key" > "$tmpkey"
    value=$(ssh \
      -i "$tmpkey" \
      -o StrictHostKeyChecking=no \
      -o BatchMode=yes \
      -o ConnectTimeout=5 \
      "${var.k8s2_wireguard_ssh_user}@${var.k8s2_wireguard_ssh_host}" \
      'cat /etc/wireguard/publickey' 2>/dev/null) || value=""
    rm -f "$tmpkey"
    jq -n --arg value "$value" '{"value": $value}'
  EOT
  ]
}

resource "null_resource" "ionos_gateway" {
  triggers = {
    setup_version                  = "1"
    host                           = var.host
    inuyama_wireguard_publickey_id = var.inuyama_wireguard_public_key_bitwarden_id
    inuyama_wireguard_publickey    = sha256(data.external.inuyama_wireguard_public_key.result.value)
    wireguard_config               = sha256(local.wireguard_config)
    k8s1_wireguard_public_key      = sha256(data.external.k8s1_wireguard_public_key.result.value)
    k8s2_wireguard_public_key      = sha256(data.external.k8s2_wireguard_public_key.result.value)
    frr_config                     = sha256(local.frr_config)
    haproxy_config                 = sha256(local.haproxy_config)
    firewall                       = tostring(var.manage_firewall)
    haproxy_enabled                = tostring(local.haproxy_enabled)
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = data.external.ssh_key.result.value
  }

  provisioner "file" {
    content     = local.wireguard_config
    destination = "/tmp/ionos-wg0.conf.tpl"
  }

  provisioner "file" {
    content     = local.frr_config
    destination = "/tmp/ionos-frr.conf"
  }

  provisioner "file" {
    content     = local.haproxy_config
    destination = "/tmp/ionos-haproxy.cfg"
  }

  provisioner "file" {
    content     = <<-SCRIPT
      #!/bin/bash
      set -eo pipefail
      export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      umask 077
      exec > >(tee -a /tmp/ionos-gateway-setup.log) 2>&1

      case "${var.wireguard_interface}" in
        ""|*[!a-zA-Z0-9._-]*)
          echo "wireguard_interface contains unsupported characters"
          exit 1
          ;;
      esac

      haproxy_enabled="${local.haproxy_enabled}"
      manage_firewall="${var.manage_firewall}"

      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y ca-certificates frr haproxy iproute2 iptables prometheus-node-exporter ufw wireguard

      install -d -m 711 /etc/wireguard

      if [ ! -f /etc/wireguard/ionos_private.key ]; then
        wg genkey > /etc/wireguard/ionos_private.key
        wg pubkey < /etc/wireguard/ionos_private.key > /etc/wireguard/ionos_public.key
      fi

      chmod 600 /etc/wireguard/ionos_private.key
      ionos_private_key=$(cat /etc/wireguard/ionos_private.key)

      sed "s|__IONOS_PRIVATE_KEY__|$ionos_private_key|g" /tmp/ionos-wg0.conf.tpl > /etc/wireguard/${var.wireguard_interface}.conf
      chmod 600 /etc/wireguard/${var.wireguard_interface}.conf

      cat > /etc/sysctl.d/99-ionos-gateway.conf <<SYSCTL
      net.ipv4.ip_forward = 1
      SYSCTL
      sysctl --system

      install -d -m 755 /etc/systemd/system/frr.service.d
      cat > /etc/systemd/system/frr.service.d/ionos-gateway.conf <<UNIT
      [Unit]
      After=network-online.target wg-quick@${var.wireguard_interface}.service
      Wants=network-online.target wg-quick@${var.wireguard_interface}.service
      UNIT

      install -d -m 755 /etc/systemd/system/haproxy.service.d
      cat > /etc/systemd/system/haproxy.service.d/ionos-gateway.conf <<UNIT
      [Unit]
      After=network-online.target wg-quick@${var.wireguard_interface}.service
      Wants=network-online.target wg-quick@${var.wireguard_interface}.service
      UNIT

      systemctl daemon-reload
      systemctl enable wg-quick@${var.wireguard_interface}
      systemctl restart wg-quick@${var.wireguard_interface}

      install -m 640 -o frr -g frr /tmp/ionos-frr.conf /etc/frr/frr.conf
      sed -i 's/^zebra=.*/zebra=yes/' /etc/frr/daemons
      sed -i 's/^bgpd=.*/bgpd=yes/' /etc/frr/daemons
      systemctl enable frr
      systemctl restart frr

      install -m 644 /tmp/ionos-haproxy.cfg /etc/haproxy/haproxy.cfg
      if [ "$haproxy_enabled" = "true" ]; then
        haproxy -c -f /etc/haproxy/haproxy.cfg
        systemctl enable haproxy
        systemctl restart haproxy
      else
        systemctl disable --now haproxy || true
      fi

      if [ "$manage_firewall" = "true" ]; then
        ufw allow ${var.firewall_ssh_port}/tcp
        ufw allow 80/tcp
        ufw allow 443/tcp
        ufw allow 25565/tcp
        ufw allow ${var.wireguard_listen_port}/udp
        ufw allow in on ${var.wireguard_interface} from ${var.inuyama_wireguard_address} to any port 179 proto tcp
        ufw allow in on ${var.wireguard_interface} from ${var.inuyama_wireguard_address} to any port 9100 proto tcp
        ufw deny 179/tcp
        ufw deny 6443/tcp
        ufw deny 2379:2380/tcp
        ufw deny 10250/tcp
        ufw --force enable
      fi

      systemctl enable prometheus-node-exporter
      systemctl restart prometheus-node-exporter

      wg show ${var.wireguard_interface}
      vtysh -c 'show bgp summary' || true
    SCRIPT
    destination = "/tmp/ionos-gateway-setup.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "if [ \"$(id -u)\" -eq 0 ]; then bash /tmp/ionos-gateway-setup.sh && rm -f /tmp/ionos-gateway-setup.sh /tmp/ionos-wg0.conf.tpl /tmp/ionos-frr.conf /tmp/ionos-haproxy.cfg; else echo '${data.external.sudo_password.result.value}' | sudo -S bash /tmp/ionos-gateway-setup.sh && rm -f /tmp/ionos-gateway-setup.sh /tmp/ionos-wg0.conf.tpl /tmp/ionos-frr.conf /tmp/ionos-haproxy.cfg; fi",
    ]
  }
}
