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

locals {
  k8s_version_short = regex("^\\d+\\.\\d+", var.k8s_version)
}

resource "null_resource" "worker_node" {

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = data.external.ssh_key.result.value
  }

  provisioner "file" {
    content = <<-SCRIPT
      #!/usr/bin/env bash
      set -euo pipefail
      exec > >(tee -a /tmp/k8s-setup.log) 2>&1

      cleanup() {
        if [ $? -ne 0 ]; then
          echo "=== Cleanup: rolling back changes ==="
          kubeadm reset -f 2>/dev/null || true
          apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
          apt-get remove -y --purge kubelet kubeadm kubectl 2>/dev/null || true
          apt-get remove -y --purge containerd 2>/dev/null || true
          rm -f /etc/apt/sources.list.d/kubernetes.list
          rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
          rm -f /etc/modules-load.d/k8s.conf
          rm -f /etc/sysctl.d/k8s.conf
          apt-get autoremove -y 2>/dev/null || true
          echo "=== Cleanup complete ==="
        fi
      }
      trap cleanup EXIT

      swapoff -a
      sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

      modprobe br_netfilter || true
      modprobe overlay || true
      printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf
      printf 'net.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward = 1\n' > /etc/sysctl.d/k8s.conf
      sysctl --system

      apt-get update -y
      apt-get install -y containerd
      mkdir -p /etc/containerd
      containerd config default > /etc/containerd/config.toml
      sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
      systemctl enable --now containerd

      apt-get install -y apt-transport-https ca-certificates curl gpg
      mkdir -p /etc/apt/keyrings
      curl -fsSL https://pkgs.k8s.io/core:/stable:/v${local.k8s_version_short}/deb/Release.key | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
      echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${local.k8s_version_short}/deb/ /' > /etc/apt/sources.list.d/kubernetes.list
      apt-get update -y
      apt-get install -y kubelet kubeadm kubectl
      apt-mark hold kubelet kubeadm kubectl

      if [ ! -f /etc/kubernetes/kubelet.conf ]; then
        kubeadm join ${var.k8s_endpoint}:6443 \
          --token ${data.external.join_info.result.token} \
          --discovery-token-ca-cert-hash ${data.external.join_info.result.ca_cert_hash} \
          || { echo "kubeadm join failed with exit code: \$?"; exit 1; }
      fi

      # --- NVIDIA GPU support (GTX 650 / Kepler GK107) ---
      # nvidia-driver-470 is the last release supporting Kepler architecture.
      # Do NOT use ubuntu-drivers autoinstall: it installs 525+ which dropped Kepler support.
      apt-get install -y software-properties-common
      add-apt-repository -y ppa:graphics-drivers/ppa
      apt-get update -y
      apt-get install -y nvidia-driver-470

      # Install NVIDIA Container Toolkit
      curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
      curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
      apt-get update -y
      apt-get install -y nvidia-container-toolkit
      nvidia-ctk runtime configure --runtime=containerd
      systemctl restart containerd

      echo "=== k8s-worker3 setup complete. Reboot required to activate NVIDIA driver. ==="
      trap - EXIT
    SCRIPT
    destination = "/tmp/k8s-setup.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${data.external.sudo_password.result.value}' | sudo -S bash /tmp/k8s-setup.sh && rm -f /tmp/k8s-setup.sh",
    ]
  }

  triggers = {
    ssh_key       = data.external.ssh_key.result.value
    sudo_password = data.external.sudo_password.result.value
    token         = data.external.join_info.result.token
    ca_cert_hash  = data.external.join_info.result.ca_cert_hash
  }

  lifecycle {
    postcondition {
      condition     = length(self.triggers.token) > 0
      error_message = "join_info did not return a token"
    }
    postcondition {
      condition     = length(self.triggers.ca_cert_hash) > 0
      error_message = "join_info did not return a ca_cert_hash"
    }
  }
}
