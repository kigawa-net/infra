data "external" "ssh_key" {
  program = ["bash", "-c", <<-EOT
    value=$(bws secret get "${var.ssh_key_bitwarden_id}" | jq -r '.value')
    jq -n --arg value "$value" '{"value": $value}'
  EOT
  ]
}

data "external" "sudo_password" {
  program = ["bash", "-c", <<-EOT
    value=$(bws secret get "${var.sudo_password_bitwarden_id}" | jq -r '.value')
    jq -n --arg value "$value" '{"value": $value}'
  EOT
  ]
}

data "external" "join_info" {
  program = ["bash", "-c", <<-EOT
    ssh_key=$(bws secret get "${var.ssh_key_bitwarden_id}" | jq -r '.value')
    sudo_pass=$(bws secret get "${var.sudo_password_bitwarden_id}" | jq -r '.value')

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

module "bgp" {
  depends_on = [module.control_plane]
  source     = "../modules/bgp-bird"

  host            = var.host
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value

  bgp_router_id   = var.host
  bgp_local_as    = var.bgp_local_as
  bgp_peers       = var.bgp_peers
  advertised_vips = var.dns_vip != "" ? [var.dns_vip] : []
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

module "knot" {
  depends_on = [module.control_plane]
  source     = "../modules/knot"

  host            = var.host
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value

  zones = {
    "kigawa.net"  = file("${path.module}/../zones/kigawa.net.zone")
    "onemc.world" = file("${path.module}/../zones/onemc.world.zone")
  }
}

module "knot_resolver" {
  depends_on = [module.knot]
  source     = "../modules/knot-resolver"

  host            = var.host
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value
}
