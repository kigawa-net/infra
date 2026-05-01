resource "null_resource" "control_plane" {
  triggers = {
    host = var.host
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
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
        if [ -n "${var.join_token}" ]; then
          kubeadm join ${var.k8s_endpoint}:6443 \
            --token ${var.join_token} \
            --discovery-token-ca-cert-hash ${var.join_ca_cert_hash} \
            --control-plane \
            --certificate-key ${var.join_certificate_key}
        else
          kubeadm init \
            --control-plane-endpoint ${var.k8s_endpoint}:6443 \
            --upload-certs \
            --pod-network-cidr ${var.pod_network_cidr}
          kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f ${var.cni_manifest_url}
        fi
      fi

      mkdir -p /home/${var.ssh_user}/.kube
      cp /etc/kubernetes/admin.conf /home/${var.ssh_user}/.kube/config
      chown ${var.ssh_user}:${var.ssh_user} /home/${var.ssh_user}/.kube/config
    SCRIPT
    destination = "/tmp/k8s-setup.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S bash /tmp/k8s-setup.sh && rm -f /tmp/k8s-setup.sh",
    ]
  }
}
