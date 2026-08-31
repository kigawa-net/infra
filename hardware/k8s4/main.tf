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

data "external" "inuyama_wireguard_private_key" {
  program = ["bash", "-c", <<-EOT
    value=$(bws secret get "${var.inuyama_wireguard_private_key_bitwarden_id}" --color no | jq -r '.value')
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

data "external" "join_info" {
  program = ["bash", "-c", <<-EOT
    ssh_key=$(bws secret get "${var.ssh_key_bitwarden_id}" --color no | jq -r '.value')
    sudo_pass=$(bws secret get "${var.sudo_password_bitwarden_id}" --color no | jq -r '.value')

    tmpkey=$(mktemp)
    chmod 600 "$tmpkey"
    printf '%s\n' "$ssh_key" > "$tmpkey"

    ssh \
      -i "$tmpkey" \
      -o StrictHostKeyChecking=no \
      -o BatchMode=yes \
      "${var.control_plane_ssh_user}@${var.control_plane_host}" \
      "echo '$sudo_pass' | sudo -S bash -c 'export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; cp_host=\$(hostname -s); for dead_ip in ${var.remove_dead_control_plane_ips}; do dead_id=\$(kubectl --kubeconfig=/etc/kubernetes/admin.conf exec -n kube-system etcd-\$cp_host -- etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key member list 2>/dev/null | grep \$dead_ip | cut -d, -f1 | tr -d \" \"); if [ -n \"\$dead_id\" ]; then for attempt in 1 2 3; do kubectl --kubeconfig=/etc/kubernetes/admin.conf exec -n kube-system etcd-\$cp_host -- etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key member remove \"\$dead_id\" && break; sleep 3; done; fi; done' 2>&1" >&2 || true

    full_cmd=$(ssh \
      -i "$tmpkey" \
      -o StrictHostKeyChecking=no \
      -o BatchMode=yes \
      "${var.control_plane_ssh_user}@${var.control_plane_host}" \
      "echo '$sudo_pass' | sudo -S bash -c 'cert=\$(kubeadm init phase upload-certs --upload-certs 2>&1 | grep -oE \"[0-9a-f]{64}\"); echo \"\$(kubeadm token create --print-join-command 2>/dev/null) --control-plane --certificate-key \$cert\"' 2>/dev/null")

    rm -f "$tmpkey"

    token=$(printf '%s' "$full_cmd"    | grep -oP '(?<=--token )\S+')
    hash=$(printf '%s' "$full_cmd"     | grep -oP '(?<=--discovery-token-ca-cert-hash )\S+')
    cert_key=$(printf '%s' "$full_cmd" | grep -oP '(?<=--certificate-key )\S+')
    printf '{"token":"%s","ca_cert_hash":"%s","certificate_key":"%s"}' "$token" "$hash" "$cert_key"
  EOT
  ]
}

module "control_plane" {
  source = "../modules/k8s-control-plane"

  host            = var.host
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value

  k8s_version  = var.k8s_version
  k8s_endpoint = var.k8s_endpoint

  join_token           = data.external.join_info.result.token
  join_ca_cert_hash    = data.external.join_info.result.ca_cert_hash
  join_certificate_key = data.external.join_info.result.certificate_key
}

resource "null_resource" "inuyama_wireguard" {
  depends_on = [module.control_plane]

  triggers = {
    host                  = var.host
    interface             = var.inuyama_wireguard_interface
    address               = var.inuyama_wireguard_address
    listen_port           = tostring(var.wireguard_listen_port)
    alice_address         = var.alice_wireguard_address
    alice_public_key      = sha256(var.alice_wireguard_public_key)
    alice_endpoint        = var.alice_wireguard_endpoint
    inuyama_public_key    = sha256(data.external.inuyama_wireguard_public_key.result.value)
    private_key_secret_id = var.inuyama_wireguard_private_key_bitwarden_id
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = data.external.ssh_key.result.value
  }

  provisioner "file" {
    content     = data.external.inuyama_wireguard_private_key.result.value
    destination = "/tmp/inuyama-wireguard-private.key"
  }

  provisioner "file" {
    content     = <<-SCRIPT
      #!/bin/bash
      set -eo pipefail
      export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      umask 077
      exec > >(tee -a /tmp/inuyama-wireguard-setup.log) 2>&1

      case "${var.inuyama_wireguard_interface}" in
        ""|*[!a-zA-Z0-9._-]*)
          echo "inuyama_wireguard_interface contains unsupported characters"
          exit 1
          ;;
      esac

      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -f -y
      apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y ca-certificates wireguard

      install -d -m 700 /etc/wireguard

      derived_public_key=$(wg pubkey < /tmp/inuyama-wireguard-private.key)
      configured_public_key="${data.external.inuyama_wireguard_public_key.result.value}"
      if [ "$derived_public_key" != "$configured_public_key" ]; then
        echo "WireGuard private/public key pair mismatch"
        exit 1
      fi

      install -m 600 /tmp/inuyama-wireguard-private.key /etc/wireguard/inuyama_private.key
      printf '%s\n' "$configured_public_key" > /etc/wireguard/inuyama_public.key
      chmod 600 /etc/wireguard/inuyama_private.key /etc/wireguard/inuyama_public.key
      inuyama_private_key=$(cat /etc/wireguard/inuyama_private.key)

      cat > /etc/wireguard/${var.inuyama_wireguard_interface}.conf <<WGCONF
      [Interface]
      Address = ${var.inuyama_wireguard_address}
      ListenPort = ${var.wireguard_listen_port}
      PrivateKey = $inuyama_private_key
      MTU = ${var.wireguard_mtu}

      [Peer]
      PublicKey = ${var.alice_wireguard_public_key}
      AllowedIPs = ${var.alice_wireguard_address}/32
      Endpoint = ${var.alice_wireguard_endpoint}
      PersistentKeepalive = 25
      WGCONF

      chmod 600 /etc/wireguard/${var.inuyama_wireguard_interface}.conf
      systemctl enable wg-quick@${var.inuyama_wireguard_interface}
      systemctl restart wg-quick@${var.inuyama_wireguard_interface}
      wg show ${var.inuyama_wireguard_interface}
    SCRIPT
    destination = "/tmp/inuyama-wireguard-setup.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${data.external.sudo_password.result.value}' | sudo -S bash /tmp/inuyama-wireguard-setup.sh && rm -f /tmp/inuyama-wireguard-setup.sh /tmp/inuyama-wireguard-private.key",
    ]
  }
}

resource "null_resource" "ionos_wireguard" {
  depends_on = [null_resource.inuyama_wireguard]

  triggers = {
    host             = var.host
    interface        = var.ionos_wireguard_interface
    address          = var.ionos_wireguard_address
    ionos_address    = "172.31.254.2"
    ionos_public_key = sha256(var.ionos_wireguard_public_key)
    ionos_endpoint   = var.ionos_wireguard_endpoint
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = data.external.ssh_key.result.value
  }

  provisioner "file" {
    content     = <<-SCRIPT
      #!/bin/bash
      set -eo pipefail
      export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      umask 077
      exec > >(tee -a /tmp/ionos-wireguard-setup.log) 2>&1

      case "${var.ionos_wireguard_interface}" in
        ""|*[!a-zA-Z0-9._-]*)
          echo "ionos_wireguard_interface contains unsupported characters"
          exit 1
          ;;
      esac

      # wg0 (alice向け) のセットアップで既に /etc/wireguard/inuyama_private.key が
      # 配置されている前提 (このinuyama鍵をionos向けwg1でも共用する)
      if [ ! -f /etc/wireguard/inuyama_private.key ]; then
        echo "/etc/wireguard/inuyama_private.key not found; inuyama_wireguard (wg0) must be applied first"
        exit 1
      fi
      inuyama_private_key=$(cat /etc/wireguard/inuyama_private.key)

      cat > /etc/wireguard/${var.ionos_wireguard_interface}.conf <<WGCONF
      [Interface]
      Address = ${var.ionos_wireguard_address}
      PrivateKey = $inuyama_private_key
      MTU = ${var.wireguard_mtu}

      [Peer]
      PublicKey = ${var.ionos_wireguard_public_key}
      AllowedIPs = 172.31.254.2/32
      Endpoint = ${var.ionos_wireguard_endpoint}
      PersistentKeepalive = 25
      WGCONF

      chmod 600 /etc/wireguard/${var.ionos_wireguard_interface}.conf
      systemctl enable wg-quick@${var.ionos_wireguard_interface}
      systemctl restart wg-quick@${var.ionos_wireguard_interface}
      wg show ${var.ionos_wireguard_interface}
    SCRIPT
    destination = "/tmp/ionos-wireguard-setup.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${data.external.sudo_password.result.value}' | sudo -S bash /tmp/ionos-wireguard-setup.sh && rm -f /tmp/ionos-wireguard-setup.sh",
    ]
  }
}

module "bgp" {
  depends_on = [module.control_plane, null_resource.inuyama_wireguard, null_resource.ionos_wireguard]
  source     = "../modules/bgp-bird"

  host            = var.host
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value

  bgp_router_id   = var.server_ip
  bgp_local_as    = var.bgp_local_as
  bgp_peers       = var.bgp_peers
  advertised_vips = var.dns_vip != "" ? [var.dns_vip] : []
  external_bgp_peers = [
    {
      local_ip        = trimsuffix(var.inuyama_wireguard_address, "/30")
      local_as        = var.inuyama_asn
      neighbor_ip     = var.alice_wireguard_address
      neighbor_as     = var.alice_bgp_as
      import_prefixes = []
      export_prefixes = ["10.0.0.0/16"]
    },
    {
      local_ip        = trimsuffix(var.ionos_wireguard_address, "/30")
      local_as        = var.inuyama_asn
      neighbor_ip     = "172.31.254.2"
      neighbor_as     = var.ionos_bgp_as
      import_prefixes = []
      export_prefixes = ["10.0.0.0/16"]
    }
  ]
}

module "kube_vip" {
  depends_on = [module.control_plane]
  source     = "../modules/kube-vip"

  host            = var.host
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value

  vip_address   = var.kube_vip_address
  interface     = var.kube_vip_interface
  api_server_ip = var.kube_vip_api_server_ip
}

resource "null_resource" "alice_gateway_services" {
  depends_on = [module.control_plane]

  triggers = {
    host                   = var.host
    metallb_namespace      = var.alice_metallb_namespace
    metallb_pool_name      = var.alice_metallb_pool_name
    metallb_base_range     = var.alice_metallb_base_range
    metallb_reserved_range = var.alice_metallb_reserved_range
    ingress_vip            = var.alice_ingress_vip
    minecraft_vip          = var.alice_minecraft_vip
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = data.external.ssh_key.result.value
  }

  provisioner "file" {
    content     = <<-SCRIPT
      #!/bin/bash
      set -eo pipefail
      export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      exec > >(tee -a /tmp/alice-gateway-services.log) 2>&1

      KUBECTL="kubectl --kubeconfig=/etc/kubernetes/admin.conf --server=https://${var.host}:6443 --request-timeout=30s"

      for attempt in 1 2 3 4 5; do
        if $KUBECTL get --raw=/readyz >/dev/null; then
          break
        fi
        if [ "$attempt" = "5" ]; then
          echo "kubernetes api is not ready"
          exit 1
        fi
        sleep 5
      done

      $KUBECTL -n ${var.alice_metallb_namespace} patch ipaddresspool ${var.alice_metallb_pool_name} --type=merge -p '{"spec":{"addresses":["${var.alice_metallb_base_range}","${var.alice_metallb_reserved_range}"],"autoAssign":true,"avoidBuggyIPs":true}}'

      cat > /tmp/alice-gateway-services.yaml <<YAML
      apiVersion: v1
      kind: Service
      metadata:
        name: alice-ingress
        namespace: system
        labels:
          app.kigawa.net/component: alice-gateway
          app.kigawa.net/managed-by: terraform
      spec:
        type: LoadBalancer
        loadBalancerIP: ${var.alice_ingress_vip}
        externalTrafficPolicy: Cluster
        selector:
          app.kubernetes.io/instance: haproxy
          app.kubernetes.io/name: kubernetes-ingress
        ports:
        - appProtocol: http
          name: http
          port: 80
          protocol: TCP
          targetPort: http
        - appProtocol: https
          name: https
          port: 443
          protocol: TCP
          targetPort: https
      ---
      apiVersion: v1
      kind: Service
      metadata:
        name: alice-minecraft
        namespace: kigawa-net
        labels:
          app.kigawa.net/component: alice-gateway
          app.kigawa.net/managed-by: terraform
      spec:
        type: LoadBalancer
        loadBalancerIP: ${var.alice_minecraft_vip}
        externalTrafficPolicy: Cluster
        selector:
          app: mc-router
        ports:
        - name: mc-router
          port: 25565
          protocol: TCP
          targetPort: 25565
      YAML

      $KUBECTL apply -f /tmp/alice-gateway-services.yaml
      $KUBECTL -n system get svc alice-ingress -o wide
      $KUBECTL -n kigawa-net get svc alice-minecraft -o wide
    SCRIPT
    destination = "/tmp/alice-gateway-services.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${data.external.sudo_password.result.value}' | sudo -S bash -c 'bash /tmp/alice-gateway-services.sh && rm -f /tmp/alice-gateway-services.sh /tmp/alice-gateway-services.yaml'",
    ]
  }
}

locals {
  knot_zones = {
    "kigawa.net"  = file("${path.module}/../zones/kigawa.net.zone")
    "onemc.world" = file("${path.module}/../zones/onemc.world.zone")
  }
}

module "knot" {
  depends_on = [module.control_plane]
  source     = "../modules/knot"

  host            = var.host
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value

  zones = local.knot_zones
}

module "knot_resolver" {
  depends_on = [module.knot]
  source     = "../modules/knot-resolver"

  host                 = var.host
  ssh_user             = var.ssh_user
  ssh_private_key      = data.external.ssh_key.result.value
  sudo_password        = data.external.sudo_password.result.value
  dns_vip              = var.dns_vip
  zones_reload_trigger = sha256(join("", values(local.knot_zones)))
}

module "keepalived" {
  source = "../modules/keepalived"

  host            = var.host
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value

  interface         = var.kube_vip_interface
  virtual_router_id = 1
  priority          = 90
  virtual_ip        = var.gateway_vip
  state             = "BACKUP"
}

module "node_exporter" {
  source = "../modules/node-exporter"

  host            = var.host
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value
}

module "dual_stack_network" {
  source = "../modules/dual-stack-network"

  host            = var.host
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value

  interface       = var.kube_vip_interface
  primary_cidr    = "${var.host}/24"
  primary_gateway = "192.168.1.1"
  secondary_cidr  = "${var.server_ip}/24"
  nameservers     = ["192.168.1.1", "10.0.0.1"]
}
