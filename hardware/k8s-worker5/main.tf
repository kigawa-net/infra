data "external" "ssh_key" {
  program = ["bash", "-c", <<-EOT
    value=$(bws secret get "${var.control_plane_ssh_key_bitwarden_id}" | jq -r '.value')
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
    ssh_key=$(bws secret get "${var.control_plane_ssh_key_bitwarden_id}" | jq -r '.value')
    sudo_pass=$(bws secret get "${var.sudo_password_bitwarden_id}" | jq -r '.value')

    tmpkey=$(mktemp)
    chmod 600 "$tmpkey"
    printf '%s\n' "$ssh_key" > "$tmpkey"

    cmd=$(ssh \
      -i "$tmpkey" \
      -o StrictHostKeyChecking=no \
      -o BatchMode=yes \
      "${var.control_plane_ssh_user}@${var.control_plane_host}" \
      "echo '$sudo_pass' | sudo -S kubeadm token create --print-join-command 2>/dev/null")

    rm -f "$tmpkey"

    token=$(printf '%s' "$cmd" | grep -oP '(?<=--token )\S+')
    hash=$(printf '%s' "$cmd"  | grep -oP '(?<=--discovery-token-ca-cert-hash )\S+')
    printf '{"token":"%s","ca_cert_hash":"%s"}' "$token" "$hash"
  EOT
  ]
}

resource "null_resource" "worker_node" {
  triggers = {
    host = var.host
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
      set -x
      export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      exec > >(tee -a /tmp/k8s-setup.log)
      exec 2>&1

      cleanup() {
        if [ $? -ne 0 ]; then
          echo "[cleanup] setup failed, rolling back..."
          kubeadm reset -f 2>/dev/null || true
          apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
          apt-get remove -y --purge kubelet kubeadm kubectl 2>/dev/null || true
          apt-get remove -y --purge containerd 2>/dev/null || true
          rm -f /etc/apt/sources.list.d/kubernetes.list
          rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
          rm -f /etc/modules-load.d/k8s.conf
          rm -f /etc/sysctl.d/k8s.conf
          apt-get autoremove -y 2>/dev/null || true
          echo "[cleanup] rollback complete"
        fi
      }
      trap cleanup EXIT

      swapoff -a
      sed -i '/ swap / s/^\(.*\)$/#\1/' /etc/fstab

      apt-get update -y
      apt-get install -y kmod

      printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf
      modprobe overlay || true
      modprobe br_netfilter || true

      printf 'net.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward = 1\n' > /etc/sysctl.d/k8s.conf
      sysctl --system

      apt-get install -y containerd
      mkdir -p /etc/containerd
      containerd config default > /etc/containerd/config.toml
      sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
      systemctl enable --now containerd

      apt-get install -y apt-transport-https ca-certificates curl gpg
      mkdir -p /etc/apt/keyrings
      curl -fsSL https://pkgs.k8s.io/core:/stable:/v${var.k8s_version}/deb/Release.key | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
      echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${var.k8s_version}/deb/ /' > /etc/apt/sources.list.d/kubernetes.list
      apt-get update -y
      apt-get install -y kubelet kubeadm kubectl
      apt-mark hold kubelet kubeadm kubectl

      if [ ! -f /etc/kubernetes/kubelet.conf ]; then
        kubeadm join ${var.k8s_endpoint}:6443 \
          --token ${data.external.join_info.result.token} \
          --discovery-token-ca-cert-hash ${data.external.join_info.result.ca_cert_hash} \
           || { echo "kubeadm join failed with exit code: $?"; exit 1; }
      fi
    SCRIPT
    destination = "/tmp/k8s-setup.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${data.external.sudo_password.result.value}' | sudo -S bash /tmp/k8s-setup.sh && rm -f /tmp/k8s-setup.sh",
    ]
  }
}

module "node_exporter" {
  source = "../modules/node-exporter"

  host            = var.host
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value
}

# iBGPメッシュ参加用に、既存のプライマリIP(192.168.1.150/24, eno1)を維持したまま
# セカンダリIP(var.server_ip)をnetplan経由で追加する。既存のaddressesリストを
# 上書きするとプライマリIPを失いSSH接続自体を失うため、既存ファイルを直接
# バックアップした上でリストに追記する(新規drop-inファイルにはしない)。
resource "null_resource" "bgp_static_ip" {
  triggers = {
    server_ip = var.server_ip
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
      set -euo pipefail

      IFACE="eno1"
      EXISTING_IP="192.168.1.150/24"
      NEW_IP="${var.server_ip}/24"

      if ip -4 addr show "$IFACE" | grep -qF "$${NEW_IP%/*}"; then
        echo "bgp_static_ip: $NEW_IP already present on $IFACE, skipping"
        exit 0
      fi

      NETPLAN_FILE=$(grep -l "$IFACE" /etc/netplan/*.yaml 2>/dev/null | head -1)
      if [ -z "$NETPLAN_FILE" ]; then
        echo "bgp_static_ip: could not find netplan file defining $IFACE" >&2
        exit 1
      fi

      cp "$NETPLAN_FILE" "$NETPLAN_FILE.bak.$(date +%s)"
      sed -i "\#- $${EXISTING_IP}#a\\      - $${NEW_IP}" "$NETPLAN_FILE"

      netplan generate
      netplan apply
      sleep 2

      ip -4 addr show "$IFACE" | grep -qF "$${NEW_IP%/*}" \
        || { echo "bgp_static_ip: $NEW_IP not present on $IFACE after netplan apply" >&2; exit 1; }
    SCRIPT
    destination = "/tmp/bgp-static-ip.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${data.external.sudo_password.result.value}' | sudo -S bash /tmp/bgp-static-ip.sh && rm -f /tmp/bgp-static-ip.sh",
    ]
  }
}

module "bgp" {
  depends_on = [null_resource.bgp_static_ip]
  source     = "../modules/bgp-bird"

  host            = var.host
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value

  bgp_router_id = var.server_ip
  bgp_local_as  = var.bgp_local_as
  bgp_peers     = var.bgp_peers
}
