locals {
  control_plane_script = <<-SCRIPT
    #!/bin/bash
    set -eo pipefail
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
    exec > >(tee -a /tmp/k8s-control-plane-setup.log) 2>&1

    _kubeadm_ran=0

    # 2026-09-23のインシデント: 既にkubeadm join/init済みのノード(admin.confが
    # 既存)に対してこのスクリプトを再実行した際、途中のapt-get等が失敗すると
    # cleanup()が発動し、まだ新規joinを一度もしていないのに(_kubeadm_ran=0の
    # ままでも)kubelet/kubeadm/kubectl/containerdをpurgeしてしまい、正常に
    # 稼働していたcontrol-planeノードのkubeletが消えてNotReadyになった
    # (k8s4・k8s2の両方で発生)。スクリプト開始時点で既にadmin.confが存在した
    # かどうかを記録し、「既存ノードの再調整」の場合はcleanup()でのpurgeを
    # スキップする(真にゼロから新規joinを試みて失敗した場合のみロールバック
    # する、という本来の意図に限定する)。
    _preexisting_node=0
    if [ -f /etc/kubernetes/admin.conf ]; then
      _preexisting_node=1
    fi

    cleanup() {
      if [ $? -ne 0 ]; then
        echo "[cleanup] setup failed"
        if [ "$_preexisting_node" = "1" ]; then
          echo "[cleanup] this node was already joined before this run; skipping package purge/kubeadm reset to avoid taking down a working control-plane node"
          if [ "$_kubeadm_ran" = "1" ]; then
            kubeadm reset -f 2>/dev/null || true
            rm -f /home/${var.ssh_user}/.kube/config
          fi
          return
        fi
        echo "[cleanup] fresh install failed, rolling back..."
        if [ "$_kubeadm_ran" = "1" ]; then
          kubeadm reset -f 2>/dev/null || true
          rm -f /home/${var.ssh_user}/.kube/config
        fi
        apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
        DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge kubelet kubeadm kubectl 2>/dev/null || true
        DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge containerd 2>/dev/null || true
        rm -f /etc/apt/sources.list.d/kubernetes.list
        rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        rm -f /etc/modules-load.d/k8s.conf
        rm -f /etc/sysctl.d/k8s.conf
        DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>/dev/null || true
        echo "[cleanup] rollback complete"
      fi
    }
    trap cleanup EXIT

    # 同一ホスト上の他モジュール(wireguard/keepalived/knot等)のapt-getとの
    # 並列実行やOSのunattended-upgradesとの競合でdpkgロックが取れず失敗することが
    # ある。事前にロックが空くのを待つだけではチェック直後に別プロセスが
    # 取ってしまうTOCTOU競合があるため、実際に失敗した場合はリトライする
    # (hardware/modules/wireguardと同じ対応)。
    wait_for_dpkg_lock() {
      for i in $(seq 1 60); do
        if ! fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1; then
          return 0
        fi
        echo "dpkg lock is held by another process, waiting... ($i/60)"
        sleep 5
      done
      echo "timed out waiting for dpkg lock" >&2
      return 1
    }

    apt_get_retry() {
      for attempt in $(seq 1 20); do
        wait_for_dpkg_lock
        if "$@"; then
          return 0
        fi
        echo "apt-get command failed (attempt $attempt/20), retrying in 5s..." >&2
        sleep 5
      done
      echo "apt-get command failed after 20 attempts" >&2
      return 1
    }

    apt_get_retry apt-get update -y
    apt_get_retry apt-get install -y kmod

    printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf
    modprobe overlay || true
    modprobe br_netfilter || true

    printf 'net.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward = 1\n' > /etc/sysctl.d/k8s.conf
    sysctl --system

    apt_get_retry apt-get install -y containerd
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    systemctl enable --now containerd

    apt_get_retry apt-get install -y apt-transport-https ca-certificates curl gpg
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v${var.k8s_version}/deb/Release.key | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${var.k8s_version}/deb/ /' > /etc/apt/sources.list.d/kubernetes.list
    apt_get_retry apt-get update -y
    apt_get_retry apt-get install -y kubelet kubeadm kubectl
    apt-mark hold kubelet kubeadm kubectl
    systemctl enable --now kubelet

    if [ ! -f /etc/kubernetes/admin.conf ]; then
      _kubeadm_ran=1
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
}

resource "null_resource" "disable_swap" {
  triggers = {
    host = var.host
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S bash -c 'swapoff -a; sed -i \"/swap/d\" /etc/fstab; echo swap disabled'",
    ]
  }
}

resource "null_resource" "control_plane" {
  depends_on = [null_resource.disable_swap]

  triggers = {
    host                 = var.host
    control_plane_script = sha256(local.control_plane_script)
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "file" {
    content     = local.control_plane_script
    destination = "/tmp/k8s-setup.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S bash /tmp/k8s-setup.sh && rm -f /tmp/k8s-setup.sh",
    ]
  }
}
