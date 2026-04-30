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
      "echo '$sudo_pass' | sudo -S bash -c 'export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; cp_host=\$(hostname -s); dead_id=\$(kubectl --kubeconfig=/etc/kubernetes/admin.conf exec -n kube-system etcd-\$cp_host -- etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key member list 2>/dev/null | grep ${var.remove_dead_control_plane_ip} | cut -d, -f1 | tr -d \" \"); [ -n \"\$dead_id\" ] && kubectl --kubeconfig=/etc/kubernetes/admin.conf exec -n kube-system etcd-\$cp_host -- etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key member remove \"\$dead_id\" || true' 2>&1" >&2 || true

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

resource "null_resource" "control_plane" {
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
      export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

      cleanup() {
        if [ $? -ne 0 ]; then
          echo "[cleanup] setup failed, rolling back..."
          kubeadm reset -f 2>/dev/null || true
          rm -f /home/${var.ssh_user}/.kube/config
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

      if [ ! -f /etc/kubernetes/admin.conf ]; then
        kubeadm join ${var.k8s_endpoint}:6443 \
          --token ${data.external.join_info.result.token} \
          --discovery-token-ca-cert-hash ${data.external.join_info.result.ca_cert_hash} \
          --control-plane \
          --certificate-key ${data.external.join_info.result.certificate_key}
      fi

      mkdir -p /home/${var.ssh_user}/.kube
      cp /etc/kubernetes/admin.conf /home/${var.ssh_user}/.kube/config
      chown ${var.ssh_user}:${var.ssh_user} /home/${var.ssh_user}/.kube/config
    SCRIPT
    destination = "/tmp/k8s-setup.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${data.external.sudo_password.result.value}' | sudo -S bash /tmp/k8s-setup.sh && rm -f /tmp/k8s-setup.sh",
    ]
  }
}
